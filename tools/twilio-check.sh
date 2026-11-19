#!/usr/bin/env bash
# Verifies Twilio credentials and the WhatsApp sender/recipient format. Prints masked values only.
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
mask() { sed -E 's/(\+[0-9]{2})[0-9]+([0-9]{4})$/\1******\2/' <<<"$1"; }
[[ "$TWILIO_ACCOUNT_SID" =~ ^AC[0-9a-f]{32}$ ]] && echo "SID format: ok" || echo "SID format: UNEXPECTED"
echo "FROM: $(mask "$TWILIO_WHATSAPP_FROM")  sandbox=$([[ $TWILIO_WHATSAPP_FROM == whatsapp:+14155238886 ]] && echo yes || echo no)"
echo "TO:   $(mask "$TWILIO_WHATSAPP_TO")  whatsapp-prefixed=$([[ $TWILIO_WHATSAPP_TO == whatsapp:+* ]] && echo yes || echo no)"
out=$(curl_cfg user "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" | curl -K - -sS -w '\n%{http_code}' "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}.json")
code=${out##*$'\n'}; body=${out%$'\n'*}
echo "Twilio auth HTTP $code | $(jq -c '{status,type,message}' <<<"$body")"
