#!/usr/bin/env bash
# End-to-end test through the local proxy -> Boomi -> PostgreSQL (Neon) -> Agent Garden -> email alert (Send Notifications).
# Requires: proxy/run.sh running on 127.0.0.1:${PROXY_PORT:-8080}. Exit code = number of failed checks.
set -uo pipefail
API=http://127.0.0.1:${PROXY_PORT:-8080}/api
fail=0; ts=$(date +%Y%m%d%H%M%S)
post() { curl -sS --max-time 200 -H 'Content-Type: application/json' -d "$2" "$API/$1"; }
check() { # name json jq-expr
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then echo "  PASS $1"; else echo "  FAIL $1"; fail=$((fail+1)); fi; }
run() { # label expected-jq payload
  echo "== $1"; local t0=$SECONDS r; r=$(post analyze "$3")
  jq -c '{transaction_id,classification,risk_score,confidence,recommended_action,detected_indicators,ai:.ai,notification:{channel:.notification.channel,status:.notification.status,sid:.notification.message_sid,err:.notification.error_message}}' <<<"$r" 2>/dev/null || echo "  raw: ${r:0:400}"
  echo "  ($((SECONDS-t0))s)"; check "$1" "$r" "$2"; LAST="$r"; }

run "Legitimate -> APPROVE" '.classification=="LEGITIMATE" and .recommended_action=="APPROVE" and .notification.status=="NOT_REQUIRED" and .ai.status=="OK"' \
  "{\"transaction_id\":\"TX-E2E-$ts-L\",\"payment_id\":\"PID-TKN-7Q2M9A\",\"amount\":420000,\"channel\":\"QRIS\",\"merchant_id\":\"MRC-SMB001\",\"device_id\":\"DEV-A1-ANDROID\",\"ip_country\":\"ID\",\"description\":\"Belanja bulanan\",\"transaction_time\":\"$(date -u +%Y-%m-%dT05:00:00Z)\"}"
run "Fraud -> FLAG/REVIEW + alert" '.classification=="POTENTIAL_FRAUD" and (.recommended_action=="FLAG" or .recommended_action=="REVIEW") and (.notification.status == "SENT" or (.notification.message_sid // "" | test("^(SM|MM)")))' \
  "{\"transaction_id\":\"TX-E2E-$ts-F\",\"payment_id\":\"PID-TKN-2B6N8D\",\"amount\":18500000,\"channel\":\"BANK_TRANSFER\",\"counterparty_account\":\"ACC-SCAM-0099\",\"device_id\":\"DEV-NEW-9931\",\"ip_country\":\"KH\",\"description\":\"Transfer segera untuk verifikasi hadiah undian\"}"
run "Gambling -> FLAG/REVIEW + alert" '.classification=="POTENTIAL_ILLEGAL_GAMBLING" and (.recommended_action=="FLAG" or .recommended_action=="REVIEW") and (.notification.status == "SENT" or (.notification.message_sid // "" | test("^(SM|MM)")))' \
  "{\"transaction_id\":\"TX-E2E-$ts-G\",\"payment_id\":\"PID-TKN-9X3L5C\",\"amount\":500000,\"channel\":\"EWALLET\",\"merchant_id\":\"MRC-GCR088\",\"device_id\":\"DEV-C3-ANDROID\",\"ip_country\":\"ID\",\"description\":\"depo slot gacor maxwin\"}"
run "Insufficient data -> MANUAL REVIEW" '.classification=="INSUFFICIENT_DATA" and .recommended_action=="REVIEW" and .notification.status=="NOT_REQUIRED"' \
  "{\"transaction_id\":\"TX-E2E-$ts-I\",\"payment_id\":\"PID-TKN-ZZ00QX\",\"amount\":1250000,\"channel\":\"BANK_TRANSFER\"}"
echo "== Validation: raw NIK rejected"
r=$(post analyze "{\"transaction_id\":\"TX-E2E-$ts-N\",\"payment_id\":\"3201234567890123\",\"amount\":1000,\"channel\":\"QRIS\"}"); echo "  $(jq -c . <<<"$r" 2>/dev/null || echo "$r")"
check "NIK rejected" "$r" '.valid==false and (.errors|tostring|test("NIK"))'
echo "== Read API"
for a in dashboard alerts; do r=$(post query "{\"action\":\"$a\"}"); check "query $a" "$r" '.ok==true'; done
r=$(post query "{\"action\":\"investigation\",\"transaction_id\":\"TX-E2E-$ts-F\"}"); check "investigation of fraud case has AI + RULE indicators + notification" "$r" '.ok and ([.risk_indicators[].source]|index("AI")!=null and index("RULE")!=null) and (.notifications|length)>=1'
r=$(post query '{"action":"ingest","payload":"{}"}'); check "internal function not reachable from read API" "$r" '.ok==false'
echo "== AI Assistant (conversational agent, read-only tools)"
r=$(post assistant "{\"message\":\"Berapa transaksi POTENTIAL_FRAUD yang tercatat? Jawab singkat.\",\"history\":[]}"); echo "  $(jq -r '.reply // .error // "no reply"' <<<"$r" 2>/dev/null | head -c 300 | tr '\n' ' ')"
check "assistant answers" "$r" '.ok == true and (.reply | length) > 0'
echo "== SNAP Transfer Intrabank (SHA256withRSA signature + RSA-OAEP/AES-256-GCM body)"
snap() { node "$(dirname "$0")/../tools/snap_client.js" "$@"; }
SRC="9$ts"   # fresh source account each run -> the first transfer is a true first occurrence
sreq() { echo "{\"partnerReferenceNo\":\"$1\",\"amount\":{\"value\":\"18500000.00\",\"currency\":\"IDR\"},\"beneficiaryAccountNo\":\"ACC-SCAM-0099\",\"sourceAccountNo\":\"$SRC\",\"remark\":\"Transfer segera untuk verifikasi hadiah undian\",\"additionalInfo\":{\"paymentId\":\"PID-TKN-2B6N8D\",\"deviceId\":\"DEV-NEW-9931\",\"ipCountry\":\"KH\"}}"; }
SREQ=$(sreq "SNAP$ts")
r=$(snap "$SREQ"); echo "  1st: $(jq -c '{responseCode,signatureValid,cls:.response.additionalInfo.riskAssessment.classification,action:.response.additionalInfo.riskAssessment.recommendedAction,pattern:.response.additionalInfo.riskAssessment.pattern.confirmed}' <<<"$r" 2>/dev/null || echo "$r")"
check "SNAP signed+encrypted request analysed, response decrypts and signature verifies" "$r" '.signatureValid and (.responseCode|test("^(200|202|403)17")) and .response.partnerReferenceNo != null and .response.additionalInfo.riskAssessment.aiVerdict != null'
check "SNAP first occurrence is NOT fraud (pattern guard)" "$r" '.response.additionalInfo.riskAssessment as $a | ($a.classification != "POTENTIAL_FRAUD" and $a.classification != "POTENTIAL_ILLEGAL_GAMBLING") and $a.decisionMethod=="AI_RULES_PATTERN_GUARD" and $a.pattern.confirmed==false and $a.pattern.occurrence==1'
r=$(snap "$(sreq "SNAP$ts-2")"); echo "  2nd: $(jq -c '{responseCode,cls:.response.additionalInfo.riskAssessment.classification,action:.response.additionalInfo.riskAssessment.recommendedAction,reasons:.response.additionalInfo.riskAssessment.pattern.reasons}' <<<"$r" 2>/dev/null || echo "$r")"
check "SNAP repeat to same beneficiary -> pattern confirmed -> POTENTIAL_FRAUD" "$r" '.response.additionalInfo.riskAssessment as $a | $a.classification=="POTENTIAL_FRAUD" and $a.pattern.confirmed==true and $a.pattern.occurrence==2'
r=$(post query "{\"action\":\"transactions\",\"payment_id\":\"PID-TKN-2B6N8D\",\"source_account\":\"$SRC\"}")
check "lookup by payment ID + source account returns both stored SNAP requests" "$r" '.ok and (.items|length)==2 and all(.items[]; .snap.status=="DECIDED" and (.snap.response_code|test("17")) and .explanation != null)'
r=$(snap "$SREQ"); check "SNAP duplicate partnerReferenceNo -> 4091701" "$r" '.responseCode=="4091701"'
r=$(snap "{\"partnerReferenceNo\":\"SNAP$ts-T\"}" --tamper); check "SNAP tampered signature -> 4011700" "$r" '.responseCode=="4011700" and .responseMessage=="Unauthorized. Signature"'
r=$(post transfer "{\"partnerReferenceNo\":\"SNAPUI$ts\",\"amount\":{\"value\":\"500000.00\",\"currency\":\"IDR\"},\"beneficiaryAccountNo\":\"9990088123\",\"sourceAccountNo\":\"5550001234\",\"remark\":\"depo slot gacor maxwin\",\"additionalInfo\":{\"paymentId\":\"PID-TKN-9X3L5C\",\"merchantId\":\"MRC-GCR088\",\"ipCountry\":\"ID\"}}")
check "portal transfer page route (/api/transfer -> SNAP) returns AI decision + security trace" "$r" '.signatureValid and .response.additionalInfo.riskAssessment.aiVerdict.status=="OK" and .trace.request.headers["X-SIGNATURE"] != null'
r=$(post query '{"action":"transactions","account":"5550001234","limit":200}')
check "source account searchable (SNAP sourceAccountNo stored)" "$r" ".ok and ([.items[] | select(.transaction_id==\"TX-SNAPUI$ts\" and .source_account==\"5550001234\")] | length) == 1"
echo; echo "Failed checks: $fail"; exit $fail
