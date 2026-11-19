#!/usr/bin/env bash
# Shows the latest inbound WhatsApp messages from TWILIO_WHATSAPP_TO to the sandbox (time + status only, bodies omitted).
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
q() { curl_cfg user "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}" | curl -K - -sS -G "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json" --data-urlencode "$1" --data-urlencode "PageSize=5"; }
echo "Inbound from recipient (to which sender):"; q "From=${TWILIO_WHATSAPP_TO}" | jq -r '.messages[] | "  \(.date_sent)  \(.direction)  \(.status)  to=...\(.to[-4:])"'
echo "Outbound to recipient:"; q "To=${TWILIO_WHATSAPP_TO}" | jq -r '.messages[] | "  \(.date_sent)  \(.status)  err=\(.error_code)"'
