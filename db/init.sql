-- PAYMENT INTELLIGENCE – AI Powered Financial Crime Detection
-- Schema, seed data and the deterministic decision engine.
-- All identities are SIMULATED tokenized Payment IDs (PID-TKN-...). No real NIK or personal data.
-- Boomi calls exactly one entry point: pi_dispatch(fn, payload_json) -> json text.

\connect payment_intelligence
SET client_min_messages = warning;
SET TIME ZONE 'Asia/Jakarta';

-- ───────────────────────────── TABLES ─────────────────────────────

CREATE TABLE payment_identity (
  payment_id          text PRIMARY KEY CHECK (payment_id ~ '^PID-TKN-[A-Z0-9]{4,32}$'),
  holder_alias        text NOT NULL,              -- pseudonym, never a real name
  segment             text NOT NULL,              -- RETAIL / STUDENT / SME_OWNER / SENIOR / CORPORATE
  kyc_level           text NOT NULL CHECK (kyc_level IN ('BASIC','STANDARD','ENHANCED')),
  home_country        char(2) NOT NULL DEFAULT 'ID',
  home_city           text,
  account_opened_on   date NOT NULL,
  typical_monthly_idr numeric(18,2),
  risk_tier           text NOT NULL DEFAULT 'LOW' CHECK (risk_tier IN ('LOW','MEDIUM','HIGH'))
);

CREATE TABLE merchant_registry (
  merchant_id          text PRIMARY KEY CHECK (merchant_id ~ '^MRC-[A-Z0-9]{3,20}$'),
  merchant_name        text NOT NULL,
  mcc                  char(4) NOT NULL,
  category             text NOT NULL,
  country              char(2) NOT NULL DEFAULT 'ID',
  license_status       text NOT NULL CHECK (license_status IN ('LICENSED','UNLICENSED','REVOKED','UNREGISTERED')),
  is_gambling_flagged  boolean NOT NULL DEFAULT false,
  registered_on        date
);

CREATE TABLE suspicious_accounts (
  account_ref  text PRIMARY KEY,
  payment_id   text REFERENCES payment_identity(payment_id),
  category     text NOT NULL CHECK (category IN ('MONEY_MULE','SCAM','GAMBLING_COLLECTOR','ACCOUNT_TAKEOVER')),
  severity     text NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH')),
  reason       text NOT NULL,
  source       text NOT NULL,
  listed_on    date NOT NULL
);

CREATE TABLE payment_transactions (
  transaction_id        text PRIMARY KEY,
  payment_id            text NOT NULL,             -- may be unknown to payment_identity (insufficient data case)
  amount                numeric(18,2) NOT NULL CHECK (amount > 0),
  currency              char(3) NOT NULL DEFAULT 'IDR',
  channel               text NOT NULL,
  merchant_id           text,
  counterparty_account  text,
  source_account        text,                      -- payer's own account (SNAP sourceAccountNo), optional
  description           text,
  device_id             text,
  ip_country            char(2),
  transaction_time      timestamptz NOT NULL,
  status                text NOT NULL DEFAULT 'RECEIVED'
                        CHECK (status IN ('HISTORICAL','RECEIVED','APPROVED','FLAGGED','UNDER_REVIEW','BLOCK_PENDING_APPROVAL','BLOCKED','RELEASED')),
  source                text NOT NULL DEFAULT 'API',  -- SEED or API
  created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_tx_payer_time ON payment_transactions (payment_id, transaction_time DESC);
CREATE INDEX ix_tx_created ON payment_transactions (created_at DESC);
CREATE INDEX ix_tx_source_account ON payment_transactions (source_account);
CREATE INDEX ix_tx_counterparty ON payment_transactions (counterparty_account);

CREATE TABLE risk_indicators (
  id              bigserial PRIMARY KEY,
  transaction_id  text NOT NULL REFERENCES payment_transactions(transaction_id),
  source          text NOT NULL CHECK (source IN ('RULE','AI')),
  indicator_code  text NOT NULL,
  category        text NOT NULL CHECK (category IN ('FRAUD','GAMBLING','DATA')),
  weight          int  NOT NULL DEFAULT 0,
  description     text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_ri_tx ON risk_indicators (transaction_id);

CREATE TABLE decision_logs (
  decision_id              bigserial PRIMARY KEY,
  transaction_id           text NOT NULL REFERENCES payment_transactions(transaction_id),
  investigation_ref        text UNIQUE,
  agent_status             text NOT NULL,          -- OK / AGENT_ERROR / SEED
  ai_classification        text,
  ai_risk_score            int,
  ai_confidence            numeric(4,3),
  ai_recommended_action    text,
  ai_explanation           text,
  rule_score               int NOT NULL,
  final_classification     text NOT NULL CHECK (final_classification IN ('LEGITIMATE','POTENTIAL_FRAUD','POTENTIAL_ILLEGAL_GAMBLING','INSUFFICIENT_DATA')),
  final_risk_score         int NOT NULL CHECK (final_risk_score BETWEEN 0 AND 100),
  recommended_action       text NOT NULL CHECK (recommended_action IN ('APPROVE','FLAG','REVIEW','BLOCK')),
  rule_override            boolean NOT NULL DEFAULT false,
  detected_indicators      jsonb NOT NULL DEFAULT '[]',
  explanation              text,
  requires_human_approval  boolean NOT NULL DEFAULT false,
  approval_status          text NOT NULL DEFAULT 'NOT_REQUIRED' CHECK (approval_status IN ('NOT_REQUIRED','PENDING','APPROVED','REJECTED')),
  approved_by              text,
  approval_note            text,
  approved_at              timestamptz,
  agent_raw                jsonb,
  response                 jsonb,
  created_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_dl_tx ON decision_logs (transaction_id, created_at DESC);

CREATE TABLE notification_logs (
  notification_id   bigserial PRIMARY KEY,
  transaction_id    text NOT NULL REFERENCES payment_transactions(transaction_id),
  decision_id       bigint REFERENCES decision_logs(decision_id),
  investigation_ref text,
  channel           text NOT NULL DEFAULT 'WHATSAPP',
  recipient_masked  text,
  message_sid       text,
  delivery_status   text NOT NULL,                 -- Twilio status (queued/sent/delivered/read/failed/undelivered) or SEND_FAILED
  http_status       int,
  attempt_count     int NOT NULL DEFAULT 1,
  error_code        text,
  error_message     text,
  message_body      text,
  sent_at           timestamptz NOT NULL DEFAULT now(),
  status_updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_nl_sent ON notification_logs (sent_at DESC);

-- Every SNAP Transfer Intrabank request that passed signature + decryption, stored before the decision is made.
CREATE TABLE snap_requests (
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
CREATE INDEX ix_snap_payer ON snap_requests (payment_id, source_account, received_at DESC);

-- ───────────────────────────── SEED DATA ─────────────────────────────

INSERT INTO payment_identity VALUES
 ('PID-TKN-7Q2M9A','Nasabah #0012','RETAIL','STANDARD','ID','Bandung','2019-03-14',  9500000,'LOW'),
 ('PID-TKN-2B6N8D','Nasabah #0047','SENIOR','STANDARD','ID','Yogyakarta','2015-07-02', 6000000,'LOW'),
 ('PID-TKN-9X3L5C','Nasabah #0103','STUDENT','BASIC','ID','Jakarta Timur','2024-01-20', 2500000,'MEDIUM'),
 ('PID-TKN-4K8P1Z','Nasabah #0158','SME_OWNER','ENHANCED','ID','Surabaya','2017-11-09',85000000,'LOW'),
 ('PID-TKN-5H1R7T','Nasabah #0231','RETAIL','BASIC','ID','Medan','2025-06-30', 4000000,'HIGH'),
 ('PID-TKN-3C7V2W','Nasabah #0276','CORPORATE','ENHANCED','ID','Jakarta Selatan','2012-02-17',950000000,'LOW'),
 ('PID-TKN-8M4T6Q','Nasabah #0318','RETAIL','STANDARD','ID','Semarang','2020-09-05', 12000000,'LOW'),
 ('PID-TKN-6D9J3K','Nasabah #0342','STUDENT','BASIC','ID','Makassar','2025-02-11', 1800000,'MEDIUM'),
 ('PID-TKN-1F5G8H','Nasabah #0399','RETAIL','STANDARD','ID','Denpasar','2018-05-23', 15000000,'LOW'),
 ('PID-TKN-0P2Y4U','Nasabah #0420','SENIOR','STANDARD','ID','Malang','2010-12-01', 7000000,'LOW'),
 ('PID-TKN-7E3S1A','Nasabah #0466','SME_OWNER','STANDARD','ID','Palembang','2021-08-16', 40000000,'MEDIUM'),
 ('PID-TKN-2W8X5Z','Nasabah #0501','RETAIL','BASIC','ID','Pontianak','2025-10-03', 3000000,'MEDIUM');

INSERT INTO merchant_registry VALUES
 ('MRC-SMB001','Toko Sembako Makmur','5411','Grocery','ID','LICENSED',false,'2016-04-01'),
 ('MRC-KOP002','Kopi Nusantara Kedai','5814','Food & Beverage','ID','LICENSED',false,'2019-08-12'),
 ('MRC-LST003','Listrik Prabayar Biller','4900','Utilities','ID','LICENSED',false,'2014-01-15'),
 ('MRC-TKT004','TiketKita Travel','4722','Travel','ID','LICENSED',false,'2018-03-30'),
 ('MRC-ELK005','Elektronik Jaya Abadi','5732','Electronics','ID','LICENSED',false,'2015-10-20'),
 ('MRC-KLN006','Klinik Sehat Sentosa','8062','Healthcare','ID','LICENSED',false,'2013-06-06'),
 ('MRC-PLS007','Pulsa Cepat Agen','4814','Telco top-up','ID','LICENSED',false,'2022-02-02'),
 ('MRC-GCR088','Gacor88 Top Up Center','7995','Online games top-up','KH','UNLICENSED',true,'2025-05-05'),
 ('MRC-LSW777','Lucky Spin Wallet','7995','Digital wallet reseller','PH','REVOKED',true,'2024-09-09'),
 ('MRC-CRX010','Crypto Swap Kilat','6051','Crypto exchange','SG','UNREGISTERED',false,'2025-08-18'),
 ('MRC-GAM011','Arena Game Voucher','5816','Digital game vouchers','ID','LICENSED',false,'2020-11-11'),
 ('MRC-FSH012','Butik Batik Lestari','5651','Fashion','ID','LICENSED',false,'2017-07-07');

INSERT INTO suspicious_accounts VALUES
 ('ACC-MULE-0001',NULL,'MONEY_MULE','HIGH','Linked to 14 phishing victim reports in 30 days; funds dispersed within minutes','Internal FIU watchlist (simulated)','2026-09-18'),
 ('ACC-SCAM-0099',NULL,'SCAM','MEDIUM','Reported in 3 fake-courier / APK scam complaints','Customer complaint desk (simulated)','2026-10-21'),
 ('ACC-GMB-0420',NULL,'GAMBLING_COLLECTOR','HIGH','Collector account for online slot deposits, many small inbound transfers from students','Payment-pattern analytics (simulated)','2026-08-02'),
 ('ACC-GMB-0777',NULL,'GAMBLING_COLLECTOR','MEDIUM','Receives round-amount QRIS deposits late at night','Payment-pattern analytics (simulated)','2026-10-30'),
 ('ACC-ATO-5150','PID-TKN-5H1R7T','ACCOUNT_TAKEOVER','MEDIUM','Password reset + new device + SIM swap reported','Fraud operations (simulated)','2026-11-01');

-- Historical transactions: 90 days of deterministic, realistic behaviour per payer.
SELECT setseed(0.42);
WITH profile(payment_id, n, base_amt, merchants, device, night_share) AS (VALUES
  ('PID-TKN-7Q2M9A', 45,  350000, ARRAY['MRC-SMB001','MRC-KOP002','MRC-LST003','MRC-FSH012'], 'DEV-A1-ANDROID', 0.02),
  ('PID-TKN-2B6N8D', 30,  220000, ARRAY['MRC-SMB001','MRC-KLN006','MRC-LST003'],             'DEV-B7-IPHONE',  0.00),
  ('PID-TKN-9X3L5C', 40,   75000, ARRAY['MRC-PLS007','MRC-GAM011','MRC-KOP002'],             'DEV-C3-ANDROID', 0.45),
  ('PID-TKN-4K8P1Z', 60, 4500000, ARRAY['MRC-SMB001','MRC-ELK005','MRC-TKT004'],             'DEV-D4-LAPTOP',  0.05),
  ('PID-TKN-5H1R7T', 20,  180000, ARRAY['MRC-SMB001','MRC-PLS007'],                          'DEV-E5-ANDROID', 0.10),
  ('PID-TKN-3C7V2W', 35,25000000, ARRAY['MRC-ELK005','MRC-TKT004'],                          'DEV-F6-SERVER',  0.00),
  ('PID-TKN-8M4T6Q', 38,  500000, ARRAY['MRC-SMB001','MRC-KOP002','MRC-FSH012','MRC-TKT004'],'DEV-G7-IPHONE',  0.03),
  ('PID-TKN-6D9J3K', 25,   60000, ARRAY['MRC-PLS007','MRC-GAM011'],                          'DEV-H8-ANDROID', 0.35),
  ('PID-TKN-1F5G8H', 42,  650000, ARRAY['MRC-SMB001','MRC-KOP002','MRC-TKT004','MRC-KLN006'],'DEV-I9-IPHONE',  0.04),
  ('PID-TKN-0P2Y4U', 22,  300000, ARRAY['MRC-SMB001','MRC-KLN006','MRC-LST003'],             'DEV-J1-ANDROID', 0.00),
  ('PID-TKN-7E3S1A', 50, 2800000, ARRAY['MRC-SMB001','MRC-ELK005','MRC-PLS007'],             'DEV-K2-LAPTOP',  0.06)
)
INSERT INTO payment_transactions (transaction_id, payment_id, amount, currency, channel, merchant_id, counterparty_account,
                                  description, device_id, ip_country, transaction_time, status, source)
SELECT 'TX-H' || substr(p.payment_id, 9) || '-' || lpad(g::text, 3, '0'),
       p.payment_id,
       round((p.base_amt * (0.4 + random() * 1.4))::numeric, -3),
       'IDR',
       (ARRAY['QRIS','EWALLET','BANK_TRANSFER','CARD','VIRTUAL_ACCOUNT'])[1 + floor(random() * 5)::int],
       p.merchants[1 + floor(random() * array_length(p.merchants, 1))::int],
       NULL,
       (ARRAY['Belanja harian','Pembayaran','Top up','Tagihan bulanan','Pembelian'])[1 + floor(random() * 5)::int],
       p.device, 'ID',
       date_trunc('day', now()) - (random() * 90 || ' days')::interval
         + CASE WHEN random() < p.night_share THEN interval '1 hour' * (random() * 3)
                ELSE interval '1 hour' * (8 + random() * 13) END,
       'HISTORICAL', 'SEED'
FROM profile p, generate_series(1, p.n) g;

-- Scenario history: the student payer has repeated late-night transfers to a gambling collector.
INSERT INTO payment_transactions (transaction_id, payment_id, amount, currency, channel, merchant_id, counterparty_account,
                                  description, device_id, ip_country, transaction_time, status, source)
SELECT 'TX-HGMB-' || lpad(g::text, 3, '0'), 'PID-TKN-9X3L5C', (ARRAY[50000,100000,150000,200000,250000])[1 + (g % 5)],
       'IDR', 'BANK_TRANSFER', NULL, 'ACC-GMB-0420', 'depo', 'DEV-C3-ANDROID', 'ID',
       date_trunc('day', now()) - (g * 3 || ' days')::interval + interval '23 hours 30 minutes', 'HISTORICAL', 'SEED'
FROM generate_series(1, 8) g;

-- Seeded past decisions (labelled agent_status='SEED') so the dashboard has a 14-day trend on day one.
WITH picked AS (
  SELECT transaction_id, amount, row_number() OVER (ORDER BY transaction_id) rn
  FROM payment_transactions WHERE source = 'SEED' AND transaction_time > now() - interval '14 days'
), labelled AS (
  SELECT transaction_id, rn,
         CASE WHEN rn % 11 = 0 THEN 'POTENTIAL_FRAUD'
              WHEN rn % 13 = 0 THEN 'POTENTIAL_ILLEGAL_GAMBLING'
              WHEN rn % 17 = 0 THEN 'INSUFFICIENT_DATA'
              ELSE 'LEGITIMATE' END AS cls
  FROM picked
)
INSERT INTO decision_logs (transaction_id, investigation_ref, agent_status, ai_classification, ai_risk_score, ai_confidence,
                           rule_score, final_classification, final_risk_score, recommended_action, detected_indicators,
                           explanation, created_at)
SELECT l.transaction_id, 'INV-SEED-' || lpad(l.rn::text, 5, '0'), 'SEED', l.cls,
       CASE l.cls WHEN 'LEGITIMATE' THEN 5 + l.rn % 20 WHEN 'INSUFFICIENT_DATA' THEN 40 ELSE 62 + l.rn % 25 END,
       0.800, CASE l.cls WHEN 'LEGITIMATE' THEN 5 ELSE 45 END, l.cls,
       CASE l.cls WHEN 'LEGITIMATE' THEN 5 + l.rn % 20 WHEN 'INSUFFICIENT_DATA' THEN 40 ELSE 62 + l.rn % 25 END,
       CASE l.cls WHEN 'LEGITIMATE' THEN 'APPROVE' WHEN 'INSUFFICIENT_DATA' THEN 'REVIEW' ELSE 'FLAG' END,
       CASE l.cls WHEN 'POTENTIAL_FRAUD' THEN '["AMOUNT_SPIKE","NEW_DEVICE"]'::jsonb
                  WHEN 'POTENTIAL_ILLEGAL_GAMBLING' THEN '["GAMBLING_KEYWORDS","ODD_HOURS"]'::jsonb
                  ELSE '[]'::jsonb END,
       'Seeded historical decision (demo baseline data).',
       t.transaction_time + interval '2 seconds'
FROM labelled l JOIN payment_transactions t USING (transaction_id);

-- ───────────────────────────── ENGINE ─────────────────────────────

-- Validate the request, store it, assemble context from all tables, evaluate deterministic rules.
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

-- Combine the AI verdict with deterministic rules. Never blocks: BLOCK only creates a PENDING human approval.
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

-- Record the outcome of the Twilio call and return the decision with its notification attached.
CREATE OR REPLACE FUNCTION pi_log_notification(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d decision_logs; n notification_logs; body text;
BEGIN
  SELECT * INTO d FROM decision_logs WHERE transaction_id = p->>'transaction_id' ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'no decision for transaction'); END IF;
  body := p->>'message_body';
  INSERT INTO notification_logs (transaction_id, decision_id, investigation_ref, channel, recipient_masked, message_sid, delivery_status,
                                 http_status, attempt_count, error_code, error_message, message_body)
  VALUES (d.transaction_id, d.decision_id, d.investigation_ref, upper(coalesce(nullif(p->>'channel', ''), 'WHATSAPP')),
          regexp_replace(coalesce(p->>'to', ''), '(\+\d{2})\d+(\d{4})$', '\1******\2'),
          nullif(p->>'message_sid', ''),
          coalesce(nullif(p->>'delivery_status', ''), 'SEND_FAILED'),
          nullif(p->>'http_status', '')::int,
          coalesce(nullif(p->>'attempt_count', '')::int, 1),
          nullif(p->>'error_code', ''), left(nullif(p->>'error_message', ''), 1000), body)
  RETURNING * INTO n;
  RETURN d.response || jsonb_build_object('notification', jsonb_build_object(
    'channel', n.channel, 'status', n.delivery_status, 'message_sid', n.message_sid, 'recipient', n.recipient_masked,
    'attempts', n.attempt_count, 'error_code', n.error_code, 'error_message', n.error_message, 'sent_at', n.sent_at));
END $$;

CREATE OR REPLACE FUNCTION pi_dashboard(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH latest AS (
    SELECT DISTINCT ON (transaction_id) * FROM decision_logs ORDER BY transaction_id, created_at DESC
  )
  SELECT jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'totals', jsonb_build_object(
       'transactions', (SELECT count(*) FROM payment_transactions),
       'analyzed', (SELECT count(*) FROM latest),
       'analyzed_live', (SELECT count(*) FROM latest WHERE agent_status <> 'SEED'),
       'total_amount_idr', (SELECT coalesce(sum(amount), 0) FROM payment_transactions),
       'avg_risk_score', (SELECT round(avg(final_risk_score), 1) FROM latest),
       'alerts_sent', (SELECT count(*) FROM notification_logs WHERE message_sid IS NOT NULL OR delivery_status = 'SENT'),
       'alerts_failed', (SELECT count(*) FROM notification_logs WHERE delivery_status IN ('SEND_FAILED','failed','undelivered')),
       'pending_approvals', (SELECT count(*) FROM latest WHERE approval_status = 'PENDING')),
    'by_classification', (SELECT coalesce(jsonb_object_agg(final_classification, c), '{}') FROM
                           (SELECT final_classification, count(*) c FROM latest GROUP BY 1) x),
    'by_action', (SELECT coalesce(jsonb_object_agg(recommended_action, c), '{}') FROM
                   (SELECT recommended_action, count(*) c FROM latest GROUP BY 1) x),
    'amount_at_risk_idr', (SELECT jsonb_build_object(
                     'fraud', coalesce(sum(t.amount) FILTER (WHERE l.final_classification = 'POTENTIAL_FRAUD'), 0),
                     'gambling', coalesce(sum(t.amount) FILTER (WHERE l.final_classification = 'POTENTIAL_ILLEGAL_GAMBLING'), 0))
                   FROM latest l JOIN payment_transactions t USING (transaction_id)),
    'trend_14d', (SELECT coalesce(jsonb_agg(d ORDER BY d->>'day'), '[]') FROM (
        SELECT jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'),
          'LEGITIMATE', count(*) FILTER (WHERE final_classification = 'LEGITIMATE'),
          'POTENTIAL_FRAUD', count(*) FILTER (WHERE final_classification = 'POTENTIAL_FRAUD'),
          'POTENTIAL_ILLEGAL_GAMBLING', count(*) FILTER (WHERE final_classification = 'POTENTIAL_ILLEGAL_GAMBLING'),
          'INSUFFICIENT_DATA', count(*) FILTER (WHERE final_classification = 'INSUFFICIENT_DATA'),
          'avg_risk', round(avg(final_risk_score), 1)) d
        FROM generate_series(date_trunc('day', now()) - interval '13 days', date_trunc('day', now()), interval '1 day') day
        LEFT JOIN latest l ON date_trunc('day', l.created_at) = day
        GROUP BY day) x),
    'top_indicators', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', code, 'count', c) ORDER BY c DESC), '[]') FROM
                        (SELECT e AS code, count(*) c FROM latest, jsonb_array_elements_text(detected_indicators) e
                          GROUP BY 1 ORDER BY 2 DESC LIMIT 8) x),
    'recent', (SELECT coalesce(jsonb_agg(r ORDER BY r->>'created_at' DESC), '[]') FROM (
        SELECT jsonb_build_object('transaction_id', l.transaction_id, 'investigation_ref', l.investigation_ref,
               'classification', l.final_classification, 'risk_score', l.final_risk_score, 'action', l.recommended_action,
               'amount', t.amount, 'created_at', l.created_at, 'live', l.agent_status <> 'SEED') r
          FROM latest l JOIN payment_transactions t USING (transaction_id) ORDER BY l.created_at DESC LIMIT 10) x));
$$;

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

CREATE OR REPLACE FUNCTION pi_alerts(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true,
    'stats', (SELECT coalesce(jsonb_object_agg(delivery_status, c), '{}') FROM (SELECT delivery_status, count(*) c FROM notification_logs GROUP BY 1) x),
    'items', (SELECT coalesce(jsonb_agg(r ORDER BY r->>'sent_at' DESC), '[]') FROM (
       SELECT jsonb_build_object('notification_id', n.notification_id, 'channel', n.channel, 'transaction_id', n.transaction_id,
              'investigation_ref', n.investigation_ref, 'recipient', n.recipient_masked, 'message_sid', n.message_sid,
              'status', n.delivery_status, 'http_status', n.http_status, 'attempts', n.attempt_count, 'error_code', n.error_code,
              'error_message', n.error_message, 'body', n.message_body, 'sent_at', n.sent_at, 'status_updated_at', n.status_updated_at,
              'classification', d.final_classification, 'risk_score', d.final_risk_score) r
         FROM notification_logs n LEFT JOIN decision_logs d USING (decision_id)
        ORDER BY n.sent_at DESC LIMIT 100) x));
$$;

-- Human-in-the-loop: only a named reviewer can turn a BLOCK proposal into an actual block.
CREATE OR REPLACE FUNCTION pi_approve(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d decision_logs; v_rev text := nullif(trim(p->>'reviewer'), ''); v_dec text := upper(p->>'decision');
BEGIN
  IF v_rev IS NULL OR length(v_rev) > 80 THEN RETURN jsonb_build_object('ok', false, 'error', 'reviewer name is required'); END IF;
  IF v_dec NOT IN ('CONFIRM_BLOCK','RELEASE') THEN RETURN jsonb_build_object('ok', false, 'error', 'decision must be CONFIRM_BLOCK or RELEASE'); END IF;
  SELECT * INTO d FROM decision_logs WHERE transaction_id = upper(p->>'transaction_id') ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR d.approval_status <> 'PENDING' THEN RETURN jsonb_build_object('ok', false, 'error', 'no pending block approval for this transaction'); END IF;
  UPDATE decision_logs SET approval_status = CASE v_dec WHEN 'CONFIRM_BLOCK' THEN 'APPROVED' ELSE 'REJECTED' END,
         approved_by = v_rev, approval_note = left(p->>'note', 500), approved_at = now()
   WHERE decision_id = d.decision_id;
  UPDATE payment_transactions SET status = CASE v_dec WHEN 'CONFIRM_BLOCK' THEN 'BLOCKED' ELSE 'RELEASED' END
   WHERE transaction_id = d.transaction_id;
  RETURN jsonb_build_object('ok', true, 'transaction_id', d.transaction_id, 'investigation_ref', d.investigation_ref,
         'approval_status', CASE v_dec WHEN 'CONFIRM_BLOCK' THEN 'APPROVED' ELSE 'REJECTED' END,
         'transaction_status', CASE v_dec WHEN 'CONFIRM_BLOCK' THEN 'BLOCKED' ELSE 'RELEASED' END, 'reviewer', v_rev);
END $$;

CREATE OR REPLACE FUNCTION pi_pending_notifications(p jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('ok', true, 'items', coalesce(jsonb_agg(jsonb_build_object('message_sid', message_sid)), '[]'))
    FROM (SELECT message_sid FROM notification_logs
           WHERE message_sid IS NOT NULL AND delivery_status IN ('accepted','queued','sending','sent')
             AND sent_at > now() - interval '3 days' ORDER BY sent_at DESC LIMIT 20) x;
$$;

CREATE OR REPLACE FUNCTION pi_update_notification(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
  WITH u AS (
    UPDATE notification_logs SET delivery_status = coalesce(nullif(p->>'status', ''), delivery_status),
           error_code = coalesce(nullif(p->>'error_code', ''), error_code),
           error_message = coalesce(nullif(p->>'error_message', ''), error_message), status_updated_at = now()
     WHERE message_sid = p->>'message_sid' RETURNING message_sid, delivery_status)
  SELECT jsonb_build_object('ok', true, 'updated', (SELECT coalesce(jsonb_agg(to_jsonb(u)), '[]') FROM u));
$$;

-- Single entry point for Boomi. Unknown names are rejected; errors never leak stack traces.
CREATE OR REPLACE FUNCTION pi_dispatch(fn text, payload text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE p jsonb;
BEGIN
  BEGIN p := coalesce(nullif(payload, ''), '{}')::jsonb;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'valid', false, 'error', 'payload is not valid JSON')::text; END;
  RETURN (CASE fn
    WHEN 'ingest'                THEN pi_ingest(p)
    WHEN 'decide'                THEN pi_decide(p)
    WHEN 'log_notification'      THEN pi_log_notification(p)
    WHEN 'dashboard'             THEN pi_dashboard(p)
    WHEN 'transactions'          THEN pi_transactions(p)
    WHEN 'investigation'         THEN pi_investigation(p)
    WHEN 'alerts'                THEN pi_alerts(p)
    WHEN 'approve'               THEN pi_approve(p)
    WHEN 'pending_notifications' THEN pi_pending_notifications(p)
    WHEN 'update_notification'   THEN pi_update_notification(p)
    ELSE jsonb_build_object('ok', false, 'error', 'unknown function') END)::text;
EXCEPTION WHEN others THEN
  RAISE WARNING 'pi_dispatch(%) failed: % %', fn, SQLSTATE, SQLERRM;
  RETURN jsonb_build_object('ok', false, 'valid', false, 'error', 'database error ' || SQLSTATE)::text;
END $$;
