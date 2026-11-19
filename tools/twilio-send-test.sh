#!/usr/bin/env bash
# Sends one test WhatsApp message with the same form encoding the Boomi flow uses. Prints sid/status/error only.
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
curl_cfg user "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" | curl -K - -sS -X POST "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "To=${TWILIO_WHATSAPP_TO}" --data-urlencode "From=${TWILIO_WHATSAPP_FROM}" \
  --data-urlencode "Body=Payment Intelligence connectivity test (direct API)" | jq -c '{sid,status,error_code,code,message}'
