-- 003: store the payer's source account (SNAP sourceAccountNo) and make accounts searchable.
-- Run once in the Neon SQL Editor (database neondb). Idempotent.
--  * payment_transactions.source_account (+ indexes on source_account and counterparty_account)
--  * pi_ingest validates and stores p.source_account
--  * pi_transactions returns source_account; 'search' also matches source/counterparty account; new exact filter 'account'
--  * pi_investigation's recent_transactions include source_account
ALTER TABLE payment_transactions ADD COLUMN IF NOT EXISTS source_account text;
CREATE INDEX IF NOT EXISTS ix_tx_source_account ON payment_transactions (source_account);
CREATE INDEX IF NOT EXISTS ix_tx_counterparty ON payment_transactions (counterparty_account);

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
      'data_completeness', jsonb_build_object(
          'payer_known', ident IS NOT NULL,
          'beneficiary_known', merch IS NOT NULL OR (v_cp IS NOT NULL),
          'history_available', h_cnt > 0,
          'description_present', v_desc IS NOT NULL)));
END $$;

CREATE OR REPLACE FUNCTION pi_transactions(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'items', coalesce(jsonb_agg(r ORDER BY r->>'created_at' DESC), '[]')) FROM (
    SELECT jsonb_build_object('transaction_id', t.transaction_id, 'payment_id', t.payment_id, 'amount', t.amount, 'currency', t.currency,
           'channel', t.channel, 'merchant_id', t.merchant_id, 'counterparty_account', t.counterparty_account, 'source_account', t.source_account, 'status', t.status,
           'transaction_time', t.transaction_time, 'created_at', coalesce(d.created_at, t.created_at),
           'investigation_ref', d.investigation_ref, 'classification', d.final_classification, 'risk_score', d.final_risk_score,
           'action', d.recommended_action, 'approval_status', d.approval_status, 'live', coalesce(d.agent_status <> 'SEED', t.source = 'API')) r
      FROM payment_transactions t
      LEFT JOIN LATERAL (SELECT * FROM decision_logs WHERE transaction_id = t.transaction_id ORDER BY created_at DESC LIMIT 1) d ON true
     WHERE (d.decision_id IS NOT NULL OR t.source = 'API')
       AND (nullif(p->>'classification', '') IS NULL OR d.final_classification = p->>'classification')
       AND (nullif(p->>'search', '') IS NULL OR t.transaction_id ILIKE '%' || (p->>'search') || '%' OR t.payment_id ILIKE '%' || (p->>'search') || '%'
            OR t.source_account ILIKE '%' || (p->>'search') || '%' OR t.counterparty_account ILIKE '%' || (p->>'search') || '%')
       AND (nullif(p->>'account', '') IS NULL OR upper(p->>'account') IN (t.source_account, t.counterparty_account))
     ORDER BY coalesce(d.created_at, t.created_at) DESC
     LIMIT least(coalesce(nullif(p->>'limit', '')::int, 50), 200)) x;
$$;

CREATE OR REPLACE FUNCTION pi_investigation(p jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE t payment_transactions; v_tx text;
BEGIN
  v_tx := coalesce(nullif(p->>'transaction_id', ''),
                   (SELECT transaction_id FROM decision_logs WHERE investigation_ref = p->>'investigation_ref'));
  SELECT * INTO t FROM payment_transactions WHERE transaction_id = upper(v_tx);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'transaction not found'); END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'transaction', to_jsonb(t),
    'payer_profile', (SELECT to_jsonb(i) FROM payment_identity i WHERE payment_id = t.payment_id),
    'merchant', (SELECT to_jsonb(m) FROM merchant_registry m WHERE merchant_id = t.merchant_id),
    'watchlist_hits', (SELECT coalesce(jsonb_agg(to_jsonb(s) - 'payment_id'), '[]') FROM suspicious_accounts s
                        WHERE s.account_ref = t.counterparty_account OR s.payment_id = t.payment_id),
    'history', (SELECT jsonb_build_object('transactions_90d', count(*), 'avg_amount_90d', round(coalesce(avg(amount), 0)),
                       'max_amount_90d', max(amount)) FROM payment_transactions
                 WHERE payment_id = t.payment_id AND transaction_id <> t.transaction_id AND transaction_time > t.transaction_time - interval '90 days'),
    'recent_transactions', (SELECT coalesce(jsonb_agg(r), '[]') FROM (SELECT transaction_id, amount, channel, merchant_id, counterparty_account,
                       source_account, description, transaction_time FROM payment_transactions WHERE payment_id = t.payment_id AND transaction_id <> t.transaction_id
                       ORDER BY transaction_time DESC LIMIT 10) r),
    'risk_indicators', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.source DESC, r.weight DESC), '[]') FROM risk_indicators r WHERE transaction_id = t.transaction_id),
    'decisions', (SELECT coalesce(jsonb_agg((to_jsonb(d) - 'agent_raw' - 'response') ORDER BY d.created_at DESC), '[]') FROM decision_logs d WHERE transaction_id = t.transaction_id),
    'notifications', (SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.sent_at DESC), '[]') FROM notification_logs n WHERE transaction_id = t.transaction_id));
END $$;
