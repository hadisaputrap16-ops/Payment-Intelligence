-- 002: email alert channel (Boomi 'Send Notifications') alongside WhatsApp.
-- Run once in the Neon SQL Editor (database neondb). Idempotent: only CREATE OR REPLACE FUNCTION.
--  * pi_log_notification stores p.channel (EMAIL | WHATSAPP, default WHATSAPP) and returns it; the recipient arrives pre-masked
--    for email, the phone-number masking regex leaves it unchanged.
--  * pi_dashboard counts email alerts (status SENT, no message SID) as sent.
--  * pi_alerts returns the channel.

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
       'alerts_sent', (SELECT count(*) FROM notification_logs WHERE message_sid IS NOT NULL),
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
