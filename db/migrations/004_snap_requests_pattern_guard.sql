-- 004: SNAP request store + pattern-guarded AI decision + lookup by payment ID and source account.
-- Run once in the Neon SQL Editor (database neondb) AFTER 003. Idempotent.
--  * snap_requests: every SNAP transfer that passed signature + decryption is stored (request, headers, pattern, decision, response code)
--  * pi_ingest: stores the SNAP request, computes occurrence / repeat-pattern evidence per source account, passes it to the AI agent
--  * pi_decide: SNAP pattern guard - a single occurrence without a repeated pattern is never classified as fraud/gambling
--  * pi_transactions: exact filters payment_id + source_account, returns decision detail and SNAP request status

CREATE TABLE IF NOT EXISTS snap_requests (
  snap_id               bigserial PRIMARY KEY,
  partner_reference_no  text NOT NULL UNIQUE,
  transaction_id        text NOT NULL UNIQUE REFERENCES payment_transactions(transaction_id),
  partner_id            text,
  external_id           text,
  channel_id            text,
  payment_id            text NOT NULL,
  source_account        text NOT NULL,
  beneficiary_account   text,
  amount                numeric(18,2) NOT NULL,
  currency              char(3) NOT NULL DEFAULT 'IDR',
  request               jsonb NOT NULL,            -- decrypted SNAP body (tokenized IDs only)
  pattern               jsonb,                     -- occurrence / repeat-pattern evidence used by the decision
  status                text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','DECIDED')),
  decision_method       text,
  classification        text,
  recommended_action    text,
  risk_score            int,
  investigation_ref     text,
  response_code         text,
  response_message      text,
  received_at           timestamptz NOT NULL DEFAULT now(),
  decided_at            timestamptz
);
CREATE INDEX IF NOT EXISTS ix_snap_payer ON snap_requests (payment_id, source_account, received_at DESC);

CREATE OR REPLACE FUNCTION pi_ingest(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  errs   text[] := '{}';
  v_tx   text := upper(nullif(trim(p->>'transaction_id'), ''));
  v_pid  text := upper(nullif(trim(p->>'payment_id'), ''));
  v_cur  text := upper(coalesce(nullif(trim(p->>'currency'), ''), 'IDR'));
  v_ch   text := upper(nullif(trim(p->>'channel'), ''));
  v_mid  text := upper(nullif(trim(p->>'merchant_id'), ''));
  v_cp   text := upper(nullif(trim(p->>'counterparty_account'), ''));
  v_src  text := upper(nullif(trim(p->>'source_account'), ''));
  v_desc text := nullif(trim(p->>'description'), '');
  v_dev  text := nullif(trim(p->>'device_id'), '');
  v_ipc  text := upper(nullif(trim(p->>'ip_country'), ''));
  v_amt  numeric;
  v_time timestamptz;
  ident jsonb; merch jsonb; watch jsonb; hist jsonb; recent jsonb;
  sig jsonb := '[]';
  h_cnt int; h_avg numeric; h_dev_known boolean; h_gmb int; h_1h int;
  m_flag boolean; m_mcc text; m_lic text; w_max text; w_cat text;
  hr int;
  v_snap jsonb := CASE WHEN jsonb_typeof(p->'snap') = 'object' THEN p->'snap' END;
  pat jsonb; p_first timestamptz; p_rep int; p_vel int; p_flag int; p_conf boolean;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('valid', false, 'status', 'REJECTED', 'errors', jsonb_build_array('request body must be a JSON object'));
  END IF;
  IF v_tx IS NULL THEN errs := array_append(errs, 'transaction_id is required');
  ELSIF v_tx !~ '^TX-[A-Z0-9-]{4,40}$' THEN errs := array_append(errs, 'transaction_id must match TX-[A-Z0-9-]{4,40}');
  ELSIF EXISTS (SELECT 1 FROM payment_transactions WHERE transaction_id = v_tx) THEN
    errs := array_append(errs, 'transaction_id already exists (replay rejected)');
  END IF;
  IF v_pid IS NULL THEN errs := array_append(errs, 'payment_id is required');
  ELSIF v_pid ~ '^[0-9]{16}$' THEN errs := array_append(errs, 'raw national ID numbers (NIK) are not accepted; send a tokenized payment_id such as PID-TKN-7Q2M9A');
  ELSIF v_pid !~ '^PID-TKN-[A-Z0-9]{4,32}$' THEN errs := array_append(errs, 'payment_id must be a tokenized ID such as PID-TKN-7Q2M9A');
  END IF;
  BEGIN v_amt := (p->>'amount')::numeric; EXCEPTION WHEN others THEN v_amt := NULL; END;
  IF v_amt IS NULL THEN errs := array_append(errs, 'amount is required and must be numeric');
  ELSIF v_amt <= 0 OR v_amt > 1000000000000 THEN errs := array_append(errs, 'amount must be greater than 0 and at most 1,000,000,000,000');
  END IF;
  IF v_cur !~ '^[A-Z]{3}$' THEN errs := array_append(errs, 'currency must be a 3-letter ISO code'); END IF;
  IF v_ch IS NULL OR v_ch NOT IN ('BANK_TRANSFER','QRIS','EWALLET','CARD','VIRTUAL_ACCOUNT') THEN
    errs := array_append(errs, 'channel must be one of BANK_TRANSFER, QRIS, EWALLET, CARD, VIRTUAL_ACCOUNT');
  END IF;
  BEGIN v_time := coalesce(nullif(p->>'transaction_time', '')::timestamptz, now());
  EXCEPTION WHEN others THEN errs := array_append(errs, 'transaction_time must be ISO-8601'); END;
  IF v_mid IS NOT NULL AND v_mid !~ '^MRC-[A-Z0-9]{3,20}$' THEN errs := array_append(errs, 'merchant_id must match MRC-[A-Z0-9]{3,20}'); END IF;
  IF v_cp IS NOT NULL AND v_cp !~ '^[A-Z0-9-]{4,40}$' THEN errs := array_append(errs, 'counterparty_account must be 4-40 chars of A-Z, 0-9 or -'); END IF;
  IF v_src IS NOT NULL AND v_src !~ '^[A-Z0-9-]{4,40}$' THEN errs := array_append(errs, 'source_account must be 4-40 chars of A-Z, 0-9 or -'); END IF;
  IF v_snap IS NOT NULL AND v_src IS NULL THEN errs := array_append(errs, 'sourceAccountNo is required for SNAP transfers'); END IF;
  IF v_snap IS NOT NULL AND EXISTS (SELECT 1 FROM snap_requests WHERE partner_reference_no = upper(v_snap->>'partner_reference_no')) THEN
    errs := array_append(errs, 'partnerReferenceNo already exists (replay rejected)');
  END IF;
  IF length(v_desc) > 280 THEN errs := array_append(errs, 'description must be at most 280 characters'); END IF;
  IF length(v_dev) > 64 THEN errs := array_append(errs, 'device_id must be at most 64 characters'); END IF;
  IF v_ipc IS NOT NULL AND v_ipc !~ '^[A-Z]{2}$' THEN errs := array_append(errs, 'ip_country must be a 2-letter ISO code'); END IF;

  IF cardinality(errs) > 0 THEN
    RETURN jsonb_build_object('valid', false, 'status', 'REJECTED', 'errors', to_jsonb(errs));
  END IF;

  INSERT INTO payment_transactions (transaction_id, payment_id, amount, currency, channel, merchant_id, counterparty_account,
                                    source_account, description, device_id, ip_country, transaction_time)
  VALUES (v_tx, v_pid, v_amt, v_cur, v_ch, v_mid, v_cp, v_src, v_desc, v_dev, v_ipc, v_time);

  SELECT to_jsonb(i) INTO ident FROM payment_identity i WHERE payment_id = v_pid;
  SELECT to_jsonb(m), m.is_gambling_flagged, m.mcc, m.license_status INTO merch, m_flag, m_mcc, m_lic
    FROM merchant_registry m WHERE merchant_id = v_mid;
  SELECT coalesce(jsonb_agg(to_jsonb(s) - 'payment_id'), '[]'),
         max(CASE severity WHEN 'HIGH' THEN '3HIGH' WHEN 'MEDIUM' THEN '2MEDIUM' ELSE '1LOW' END),
         max(category)
    INTO watch, w_max, w_cat
    FROM suspicious_accounts s WHERE s.account_ref = v_cp OR s.payment_id = v_pid;

  SELECT count(*), avg(amount),
         bool_or(device_id = v_dev),
         count(*) FILTER (WHERE t.merchant_id IN (SELECT merchant_id FROM merchant_registry WHERE is_gambling_flagged OR mcc = '7995')
                             OR t.counterparty_account IN (SELECT account_ref FROM suspicious_accounts WHERE category = 'GAMBLING_COLLECTOR')),
         count(*) FILTER (WHERE transaction_time > v_time - interval '1 hour')
    INTO h_cnt, h_avg, h_dev_known, h_gmb, h_1h
    FROM payment_transactions t
   WHERE payment_id = v_pid AND transaction_id <> v_tx
     AND transaction_time < v_time AND transaction_time > v_time - interval '90 days';

  hist := jsonb_build_object(
    'transactions_90d', h_cnt,
    'avg_amount_90d', round(coalesce(h_avg, 0)),
    'max_amount_90d', (SELECT max(amount) FROM payment_transactions WHERE payment_id = v_pid AND transaction_id <> v_tx),
    'known_devices', (SELECT coalesce(jsonb_agg(DISTINCT device_id), '[]') FROM payment_transactions WHERE payment_id = v_pid AND transaction_id <> v_tx AND device_id IS NOT NULL),
    'countries_seen', (SELECT coalesce(jsonb_agg(DISTINCT ip_country), '[]') FROM payment_transactions WHERE payment_id = v_pid AND transaction_id <> v_tx AND ip_country IS NOT NULL),
    'gambling_related_90d', h_gmb,
    'night_transactions_90d', (SELECT count(*) FROM payment_transactions WHERE payment_id = v_pid AND transaction_id <> v_tx
                                 AND extract(hour FROM transaction_time AT TIME ZONE 'Asia/Jakarta') BETWEEN 0 AND 4),
    'transactions_last_1h', h_1h);

  SELECT coalesce(jsonb_agg(r ORDER BY r->>'transaction_time' DESC), '[]') INTO recent FROM (
    SELECT jsonb_build_object('transaction_id', transaction_id, 'amount', amount, 'channel', channel, 'merchant_id', merchant_id,
                              'counterparty_account', counterparty_account, 'description', description,
                              'transaction_time', to_char(transaction_time AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM-DD"T"HH24:MI')) r
      FROM payment_transactions WHERE payment_id = v_pid AND transaction_id <> v_tx
     ORDER BY transaction_time DESC LIMIT 8) x;

  -- Deterministic rules. Weights are additive; rule_score = min(100, sum).
  hr := extract(hour FROM v_time AT TIME ZONE 'Asia/Jakarta');
  IF w_max IS NOT NULL THEN
    sig := sig || jsonb_build_object('code', CASE WHEN w_cat = 'GAMBLING_COLLECTOR' THEN 'WATCHLIST_GAMBLING_COLLECTOR' ELSE 'WATCHLIST_HIT' END,
      'category', CASE WHEN w_cat = 'GAMBLING_COLLECTOR' THEN 'GAMBLING' ELSE 'FRAUD' END,
      'severity', substr(w_max, 2),
      'weight', CASE substr(w_max, 1, 1) WHEN '3' THEN 40 WHEN '2' THEN 25 ELSE 10 END,
      'description', 'Counterparty or payer is on the suspicious-accounts watchlist (' || substr(w_max, 2) || ' severity, ' || w_cat || ')');
  END IF;
  IF coalesce(m_flag, false) OR m_mcc = '7995' THEN
    sig := sig || jsonb_build_object('code', 'GAMBLING_MERCHANT', 'category', 'GAMBLING', 'weight', 40,
      'description', 'Merchant is flagged as gambling / MCC 7995 (' || coalesce(m_lic, '?') || ')');
  ELSIF m_lic IN ('UNLICENSED','REVOKED','UNREGISTERED') THEN
    sig := sig || jsonb_build_object('code', 'UNLICENSED_MERCHANT', 'category', 'FRAUD', 'weight', 15,
      'description', 'Merchant license status is ' || m_lic);
  END IF;
  IF v_desc ~* '(slot|gacor|judi|togel|casino|kasino|betting|taruhan|maxwin|jackpot|depo\M|chip)' THEN
    sig := sig || jsonb_build_object('code', 'GAMBLING_KEYWORDS', 'category', 'GAMBLING', 'weight', 20,
      'description', 'Description contains online-gambling vocabulary');
  END IF;
  IF h_gmb >= 3 THEN
    sig := sig || jsonb_build_object('code', 'GAMBLING_HISTORY', 'category', 'GAMBLING', 'weight', 15,
      'description', h_gmb || ' gambling-related payments in the last 90 days');
  END IF;
  IF v_desc ~* '(urgent|segera|verifikasi|verification|hadiah|prize|refund|otp|blokir|undian)' THEN
    sig := sig || jsonb_build_object('code', 'SOCIAL_ENGINEERING_KEYWORDS', 'category', 'FRAUD', 'weight', 10,
      'description', 'Description matches common scam / social-engineering wording');
  END IF;
  IF h_cnt >= 3 AND v_amt > 10 * h_avg THEN
    sig := sig || jsonb_build_object('code', 'AMOUNT_SPIKE', 'category', 'FRAUD', 'weight', 25,
      'description', 'Amount is ' || round(v_amt / h_avg) || 'x the 90-day average');
  ELSIF h_cnt >= 3 AND v_amt > 5 * h_avg THEN
    sig := sig || jsonb_build_object('code', 'AMOUNT_SPIKE', 'category', 'FRAUD', 'weight', 15,
      'description', 'Amount is ' || round(v_amt / h_avg) || 'x the 90-day average');
  END IF;
  IF v_amt >= 50000000 THEN
    sig := sig || jsonb_build_object('code', 'HIGH_VALUE', 'category', 'FRAUD', 'weight', 10, 'description', 'Amount is at least IDR 50,000,000');
  END IF;
  IF h_cnt >= 3 AND v_dev IS NOT NULL AND NOT coalesce(h_dev_known, false) THEN
    sig := sig || jsonb_build_object('code', 'NEW_DEVICE', 'category', 'FRAUD', 'weight', 10, 'description', 'Device never seen for this payer');
  END IF;
  IF ident IS NOT NULL AND v_ipc IS NOT NULL AND v_ipc <> ident->>'home_country' THEN
    sig := sig || jsonb_build_object('code', 'GEO_MISMATCH', 'category', 'FRAUD', 'weight', 15,
      'description', 'IP country ' || v_ipc || ' differs from home country ' || (ident->>'home_country'));
  END IF;
  IF hr BETWEEN 0 AND 4 THEN
    sig := sig || jsonb_build_object('code', 'ODD_HOURS', 'category', 'FRAUD', 'weight', 5, 'description', 'Initiated between 00:00 and 04:59 WIB');
  END IF;
  IF h_1h >= 5 THEN
    sig := sig || jsonb_build_object('code', 'VELOCITY_1H', 'category', 'FRAUD', 'weight', 15, 'description', h_1h || ' payments in the previous hour');
  END IF;
  IF ident IS NULL THEN
    sig := sig || jsonb_build_object('code', 'UNKNOWN_PAYER', 'category', 'DATA', 'weight', 0, 'description', 'payment_id not found in payment_identity');
  END IF;
  IF v_mid IS NULL AND v_cp IS NULL THEN
    sig := sig || jsonb_build_object('code', 'NO_BENEFICIARY', 'category', 'DATA', 'weight', 0, 'description', 'Neither merchant_id nor counterparty_account supplied');
  ELSIF v_mid IS NOT NULL AND merch IS NULL THEN
    sig := sig || jsonb_build_object('code', 'UNKNOWN_MERCHANT', 'category', 'DATA', 'weight', 0, 'description', 'merchant_id not in merchant_registry');
  END IF;

  INSERT INTO risk_indicators (transaction_id, source, indicator_code, category, weight, description)
  SELECT v_tx, 'RULE', s->>'code', s->>'category', (s->>'weight')::int, s->>'description' FROM jsonb_array_elements(sig) s;

  -- Occurrence / repeat-pattern evidence for the source account (used by the SNAP pattern guard in pi_decide).
  IF v_src IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE (v_cp IS NOT NULL AND t.counterparty_account = v_cp) OR (v_mid IS NOT NULL AND t.merchant_id = v_mid)),
           count(*) FILTER (WHERE t.transaction_time > v_time - interval '24 hours'),
           min(t.transaction_time) FILTER (WHERE (v_cp IS NOT NULL AND t.counterparty_account = v_cp) OR (v_mid IS NOT NULL AND t.merchant_id = v_mid))
      INTO p_rep, p_vel, p_first
      FROM payment_transactions t
     WHERE t.source_account = v_src AND t.transaction_id <> v_tx
       AND t.transaction_time > v_time - interval '30 days' AND t.transaction_time <= v_time;
    SELECT count(*) INTO p_flag FROM payment_transactions t JOIN decision_logs d USING (transaction_id)
     WHERE t.source_account = v_src AND t.transaction_id <> v_tx AND d.agent_status <> 'SEED'
       AND d.final_classification IN ('POTENTIAL_FRAUD','POTENTIAL_ILLEGAL_GAMBLING') AND d.created_at > now() - interval '30 days';
    p_conf := p_rep >= 1 OR p_vel >= 3 OR p_flag >= 1 OR coalesce(h_gmb, 0) >= 3;
    pat := jsonb_build_object(
      'source_account', v_src, 'beneficiary', coalesce(v_cp, v_mid),
      'occurrence', p_rep + 1,
      'same_beneficiary_30d', p_rep, 'first_seen', p_first,
      'source_transactions_24h', p_vel, 'prior_flagged_30d', p_flag, 'payer_gambling_90d', coalesce(h_gmb, 0),
      'confirmed', p_conf,
      'reasons', to_jsonb(array_remove(ARRAY[
          CASE WHEN p_rep >= 1 THEN 'REPEAT_BENEFICIARY: ' || (p_rep + 1) || ' transfers to the same beneficiary in 30 days' END,
          CASE WHEN p_vel >= 3 THEN 'VELOCITY_24H: ' || p_vel || ' earlier transfers from this source account in 24 hours' END,
          CASE WHEN p_flag >= 1 THEN 'PRIOR_FLAGGED: ' || p_flag || ' earlier fraud/gambling decisions on this source account' END,
          CASE WHEN coalesce(h_gmb, 0) >= 3 THEN 'GAMBLING_HISTORY: ' || h_gmb || ' gambling payments by this payer in 90 days' END], NULL)),
      'policy', 'A single occurrence without a repeated pattern is not classified as fraud or gambling.');
  END IF;

  IF v_snap IS NOT NULL THEN
    INSERT INTO snap_requests (partner_reference_no, transaction_id, partner_id, external_id, channel_id, payment_id, source_account,
                               beneficiary_account, amount, currency, request, pattern)
    VALUES (upper(v_snap->>'partner_reference_no'), v_tx, v_snap->>'partner_id', v_snap->>'external_id', v_snap->>'channel_id',
            v_pid, v_src, v_cp, v_amt, v_cur, coalesce(v_snap->'request', '{}'), pat);
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'transaction_id', v_tx,
    'agent_input', jsonb_build_object(
      'case_id', v_tx,
      'transaction', jsonb_build_object('transaction_id', v_tx, 'payment_id', v_pid, 'amount', v_amt, 'currency', v_cur,
          'channel', v_ch, 'merchant_id', v_mid, 'counterparty_account', v_cp, 'description', v_desc,
          'device_id', v_dev, 'ip_country', v_ipc,
          'transaction_time_wib', to_char(v_time AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM-DD"T"HH24:MI')),
      'payer_profile', coalesce(ident, 'null'::jsonb),
      'merchant', coalesce(merch, 'null'::jsonb),
      'watchlist_hits', watch,
      'history_summary', hist,
      'recent_transactions', recent,
      'rule_signals', sig,
      'pattern', coalesce(pat, 'null'::jsonb),
      'data_completeness', jsonb_build_object(
          'payer_known', ident IS NOT NULL,
          'beneficiary_known', merch IS NOT NULL OR (v_cp IS NOT NULL),
          'history_available', h_cnt > 0,
          'description_present', v_desc IS NOT NULL)));
END $$;

CREATE OR REPLACE FUNCTION pi_decide(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_tx text := p->>'transaction_id';
  ai jsonb := CASE WHEN jsonb_typeof(p->'ai') = 'object' THEN p->'ai' END;
  t payment_transactions;
  ai_cls text; ai_score int; ai_conf numeric; ai_act text; ai_expl text; ai_ind jsonb;
  ai_ok boolean;
  rule_score int; g int; f int; high_watch boolean; payer_known boolean; benef boolean;
  rule_cls text; cls text; score int; act text; override boolean := false;
  indicators jsonb; expl text; d_id bigint; ref text; resp jsonb; body text;
  snap snap_requests; guarded boolean := false; g_cls text; g_score int; method text;
BEGIN
  SELECT * INTO t FROM payment_transactions WHERE transaction_id = v_tx;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'unknown transaction_id'); END IF;
  SELECT * INTO snap FROM snap_requests WHERE transaction_id = v_tx;   -- after the FOUND check: SELECT INTO resets FOUND
  IF EXISTS (SELECT 1 FROM decision_logs WHERE transaction_id = v_tx) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'transaction already decided');
  END IF;

  ai_cls := upper(ai->>'classification');
  IF ai_cls NOT IN ('LEGITIMATE','POTENTIAL_FRAUD','POTENTIAL_ILLEGAL_GAMBLING','INSUFFICIENT_DATA') THEN ai_cls := NULL; END IF;
  ai_ok := ai_cls IS NOT NULL;
  -- clamp only real values: greatest()/least() ignore NULL and would turn "no AI score" into 0
  BEGIN ai_score := round((ai->>'risk_score')::numeric)::int; EXCEPTION WHEN others THEN ai_score := NULL; END;
  IF ai_score IS NOT NULL THEN ai_score := least(100, greatest(0, ai_score)); END IF;
  BEGIN ai_conf := (ai->>'confidence')::numeric; EXCEPTION WHEN others THEN ai_conf := NULL; END;
  IF ai_conf > 1 THEN ai_conf := ai_conf / 100; END IF;
  IF ai_conf IS NOT NULL THEN ai_conf := least(1, greatest(0, ai_conf)); END IF;
  ai_act  := upper(ai->>'recommended_action');
  ai_expl := left(ai->>'explanation', 2000);
  ai_ind  := CASE WHEN jsonb_typeof(ai->'detected_indicators') = 'array' THEN ai->'detected_indicators' ELSE '[]' END;

  SELECT least(100, coalesce(sum(weight), 0)),
         coalesce(sum(weight) FILTER (WHERE category = 'GAMBLING'), 0),
         coalesce(sum(weight) FILTER (WHERE category = 'FRAUD'), 0),
         bool_or(indicator_code = 'WATCHLIST_HIT' AND weight >= 40),
         NOT bool_or(indicator_code = 'UNKNOWN_PAYER'),
         NOT bool_or(indicator_code IN ('NO_BENEFICIARY','UNKNOWN_MERCHANT'))
    INTO rule_score, g, f, high_watch, payer_known, benef
    FROM risk_indicators WHERE transaction_id = v_tx AND source = 'RULE';
  high_watch := coalesce(high_watch, false); payer_known := coalesce(payer_known, true); benef := coalesce(benef, true);

  rule_cls := CASE WHEN g >= 40 AND g >= f THEN 'POTENTIAL_ILLEGAL_GAMBLING'
                   WHEN f >= 40 THEN 'POTENTIAL_FRAUD' END;

  -- 1. Strong deterministic evidence overrides a missing / benign AI verdict.
  IF rule_cls IS NOT NULL AND (NOT ai_ok OR ai_cls IN ('LEGITIMATE','INSUFFICIENT_DATA')) THEN
    cls := rule_cls; override := ai_ok;
    score := greatest(rule_score, coalesce(ai_score, 0));
  -- 2. Without a known payer and beneficiary we never auto-approve.
  ELSIF NOT payer_known OR NOT benef OR NOT ai_ok OR ai_cls = 'INSUFFICIENT_DATA' THEN
    cls := 'INSUFFICIENT_DATA';
    score := greatest(rule_score, coalesce(ai_score, 0));
  -- 3. Otherwise trust the AI class, blend the scores 60/40.
  ELSE
    cls := ai_cls;
    score := round(0.6 * coalesce(ai_score, rule_score) + 0.4 * rule_score);
  END IF;

  -- 4. SNAP pattern guard: one occurrence is not a pattern. Without repeat evidence a fraud/gambling verdict
  --    becomes REVIEW (strong rule evidence: watchlist / rule score >= 40) or APPROVE with monitoring (soft signals only).
  method := CASE WHEN snap.snap_id IS NOT NULL THEN 'AI_RULES_PATTERN_GUARD' ELSE 'AI_RULES_HYBRID' END;
  IF snap.snap_id IS NOT NULL AND NOT coalesce((snap.pattern->>'confirmed')::boolean, false)
     AND cls IN ('POTENTIAL_FRAUD','POTENTIAL_ILLEGAL_GAMBLING') THEN
    guarded := true; g_cls := cls; g_score := score;
    IF rule_score >= 40 OR high_watch THEN cls := 'INSUFFICIENT_DATA'; score := least(score, 59);
    ELSE cls := 'LEGITIMATE'; score := least(score, 29); END IF;
  END IF;

  act := CASE
    WHEN cls = 'INSUFFICIENT_DATA' THEN 'REVIEW'
    WHEN cls = 'LEGITIMATE' AND score < 30 THEN 'APPROVE'
    WHEN cls = 'LEGITIMATE' THEN 'REVIEW'
    WHEN score >= 85 AND high_watch THEN 'BLOCK'      -- proposal only; needs a human
    WHEN score >= 60 THEN 'FLAG'
    ELSE 'REVIEW' END;

  SELECT coalesce(jsonb_agg(DISTINCT x), '[]') INTO indicators FROM (
    SELECT indicator_code AS x FROM risk_indicators WHERE transaction_id = v_tx AND source = 'RULE' AND category <> 'DATA'
    UNION SELECT upper(regexp_replace(e, '[^A-Za-z0-9]+', '_', 'g')) FROM jsonb_array_elements_text(ai_ind) e) s;

  INSERT INTO risk_indicators (transaction_id, source, indicator_code, category, weight, description)
  SELECT v_tx, 'AI', left(upper(regexp_replace(e, '[^A-Za-z0-9]+', '_', 'g')), 60),
         CASE WHEN cls = 'POTENTIAL_ILLEGAL_GAMBLING' THEN 'GAMBLING' WHEN cls = 'INSUFFICIENT_DATA' THEN 'DATA' ELSE 'FRAUD' END,
         0, 'Reported by AI agent: ' || e
    FROM jsonb_array_elements_text(ai_ind) e;

  expl := coalesce(ai_expl, 'AI agent unavailable: ' || coalesce(p->>'agent_error', 'no valid verdict returned') || '.')
          || CASE WHEN override THEN ' [Rule override: deterministic evidence (' || rule_cls || ', rule score ' || rule_score || ') outweighed the AI verdict ' || ai_cls || '.]' ELSE '' END
          || CASE WHEN guarded THEN ' [Pattern guard: first occurrence of this transfer from source account ' || snap.source_account
                  || ' (no repeat beneficiary, velocity or prior flags in 30 days). The combined verdict ' || g_cls || ' (score ' || g_score
                  || ') is not confirmed by a pattern, so it is not classified as fraud: '
                  || CASE WHEN cls = 'INSUFFICIENT_DATA' THEN 'held for analyst review.' ELSE 'approved with monitoring.' END || ']'
                  WHEN snap.snap_id IS NOT NULL AND coalesce((snap.pattern->>'confirmed')::boolean, false) THEN
                  ' [Pattern confirmed: ' || coalesce((SELECT string_agg(x, '; ') FROM jsonb_array_elements_text(snap.pattern->'reasons') x), '-') || '.]'
                  ELSE '' END;
  IF guarded THEN indicators := indicators || '["FIRST_OCCURRENCE"]'::jsonb; END IF;

  INSERT INTO decision_logs (transaction_id, agent_status, ai_classification, ai_risk_score, ai_confidence, ai_recommended_action,
      ai_explanation, rule_score, final_classification, final_risk_score, recommended_action, rule_override,
      detected_indicators, explanation, requires_human_approval, approval_status, agent_raw)
  VALUES (v_tx, CASE WHEN ai_ok THEN 'OK' ELSE 'AGENT_ERROR' END, ai_cls, ai_score, ai_conf, ai_act, ai_expl, rule_score,
      cls, score, act, override, indicators, expl, act = 'BLOCK', CASE WHEN act = 'BLOCK' THEN 'PENDING' ELSE 'NOT_REQUIRED' END,
      p - 'transaction_id')
  RETURNING decision_id INTO d_id;

  ref := 'INV-' || to_char(now() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD') || '-' || lpad(d_id::text, 5, '0');

  UPDATE payment_transactions SET status = CASE act WHEN 'APPROVE' THEN 'APPROVED' WHEN 'FLAG' THEN 'FLAGGED'
      WHEN 'REVIEW' THEN 'UNDER_REVIEW' ELSE 'BLOCK_PENDING_APPROVAL' END WHERE transaction_id = v_tx;

  body := '🚨 PAYMENT INTELLIGENCE ALERT' || chr(10) ||
          'Ref: ' || ref || chr(10) ||
          'Transaction: ' || v_tx || chr(10) ||
          'Classification: ' || cls || chr(10) ||
          'Amount: ' || t.currency || ' ' || to_char(t.amount, 'FM999,999,999,999,990') || chr(10) ||
          'Risk score: ' || score || '/100' || chr(10) ||
          'Indicators: ' || coalesce((SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(indicators) x), '-') || chr(10) ||
          'Action: ' || act || CASE WHEN act = 'BLOCK' THEN ' (pending human approval)' ELSE ' (analyst review)' END;

  resp := jsonb_build_object(
    'ok', true,
    'transaction_id', v_tx,
    'investigation_ref', ref,
    'classification', cls,
    'risk_score', score,
    'confidence', ai_conf,
    'detected_indicators', indicators,
    'explanation', expl,
    'recommended_action', act,
    'requires_human_approval', act = 'BLOCK',
    'approval_status', CASE WHEN act = 'BLOCK' THEN 'PENDING' ELSE 'NOT_REQUIRED' END,
    'transaction_status', (SELECT status FROM payment_transactions WHERE transaction_id = v_tx),
    'ai', jsonb_build_object('status', CASE WHEN ai_ok THEN 'OK' ELSE 'AGENT_ERROR' END, 'classification', ai_cls,
                             'risk_score', ai_score, 'recommended_action', ai_act),
    'rules', jsonb_build_object('rule_score', rule_score, 'override', override),
    'decision_method', method,
    'pattern', CASE WHEN snap.snap_id IS NOT NULL THEN snap.pattern || jsonb_build_object('guard_applied', guarded, 'unguarded_classification', g_cls, 'unguarded_risk_score', g_score) END,
    'notify', cls IN ('POTENTIAL_FRAUD','POTENTIAL_ILLEGAL_GAMBLING'),
    'whatsapp_body', body,
    'notification', jsonb_build_object('status', CASE WHEN cls IN ('POTENTIAL_FRAUD','POTENTIAL_ILLEGAL_GAMBLING') THEN 'PENDING' ELSE 'NOT_REQUIRED' END));

  UPDATE decision_logs SET investigation_ref = ref, response = resp - 'whatsapp_body' WHERE decision_id = d_id;
  IF snap.snap_id IS NOT NULL THEN
    UPDATE snap_requests SET status = 'DECIDED', decided_at = now(), decision_method = method, classification = cls,
           recommended_action = act, risk_score = score, investigation_ref = ref,
           pattern = resp->'pattern',
           response_code = CASE act WHEN 'APPROVE' THEN '2001700' WHEN 'BLOCK' THEN '4031703' ELSE '2021700' END,
           response_message = CASE act WHEN 'APPROVE' THEN 'Successful' WHEN 'BLOCK' THEN 'Suspected Fraud' ELSE 'Request In Progress' END
     WHERE snap_id = snap.snap_id;
  END IF;
  RETURN resp;
END $$;

CREATE OR REPLACE FUNCTION pi_transactions(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'items', coalesce(jsonb_agg(r ORDER BY r->>'created_at' DESC), '[]')) FROM (
    SELECT jsonb_build_object('transaction_id', t.transaction_id, 'payment_id', t.payment_id, 'amount', t.amount, 'currency', t.currency,
           'channel', t.channel, 'merchant_id', t.merchant_id, 'counterparty_account', t.counterparty_account, 'source_account', t.source_account, 'status', t.status,
           'transaction_time', t.transaction_time, 'created_at', coalesce(d.created_at, t.created_at),
           'investigation_ref', d.investigation_ref, 'classification', d.final_classification, 'risk_score', d.final_risk_score,
           'action', d.recommended_action, 'approval_status', d.approval_status, 'live', coalesce(d.agent_status <> 'SEED', t.source = 'API'),
           'description', t.description,
           'explanation', CASE WHEN nullif(p->>'payment_id', '') IS NOT NULL THEN d.explanation END,
           'indicators', CASE WHEN nullif(p->>'payment_id', '') IS NOT NULL THEN d.detected_indicators END,
           'ai', CASE WHEN nullif(p->>'payment_id', '') IS NOT NULL AND d.decision_id IS NOT NULL THEN jsonb_build_object('status', d.agent_status,
                 'classification', d.ai_classification, 'risk_score', d.ai_risk_score, 'confidence', d.ai_confidence, 'recommended_action', d.ai_recommended_action) END,
           'rule_score', d.rule_score,
           'snap', CASE WHEN s.snap_id IS NOT NULL THEN jsonb_build_object('partner_reference_no', s.partner_reference_no, 'external_id', s.external_id,
                 'partner_id', s.partner_id, 'status', s.status, 'response_code', s.response_code, 'response_message', s.response_message,
                 'decision_method', s.decision_method, 'pattern', s.pattern, 'received_at', s.received_at, 'decided_at', s.decided_at) END) r
      FROM payment_transactions t
      LEFT JOIN LATERAL (SELECT * FROM decision_logs WHERE transaction_id = t.transaction_id ORDER BY created_at DESC LIMIT 1) d ON true
      LEFT JOIN snap_requests s ON s.transaction_id = t.transaction_id
     WHERE (d.decision_id IS NOT NULL OR t.source = 'API')
       AND (nullif(p->>'classification', '') IS NULL OR d.final_classification = p->>'classification')
       AND (nullif(p->>'search', '') IS NULL OR t.transaction_id ILIKE '%' || (p->>'search') || '%' OR t.payment_id ILIKE '%' || (p->>'search') || '%'
            OR t.source_account ILIKE '%' || (p->>'search') || '%' OR t.counterparty_account ILIKE '%' || (p->>'search') || '%')
       AND (nullif(p->>'account', '') IS NULL OR upper(p->>'account') IN (t.source_account, t.counterparty_account))
       AND (nullif(p->>'payment_id', '') IS NULL OR t.payment_id = upper(trim(p->>'payment_id')))
       AND (nullif(p->>'source_account', '') IS NULL OR t.source_account = upper(trim(p->>'source_account')))
     ORDER BY coalesce(d.created_at, t.created_at) DESC
     LIMIT least(coalesce(nullif(p->>'limit', '')::int, 50), 200)) x;
$$;
