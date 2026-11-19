#!/usr/bin/env bash
# Usage: twilio-content.sh get <HXsid> | list | create <json-file> | approval <HXsid> | send <HXsid> <variables-json>
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
auth() { curl_cfg user "${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}"; }
case "$1" in
  get) auth | curl -K - -sS "https://content.twilio.com/v1/Content/$2" | jq -c '{sid, friendly_name, language, variables, types, code, message}' ;;
  list) auth | curl -K - -sS "https://content.twilio.com/v1/Content?PageSize=50" | jq -c '.contents[]? | {sid, friendly_name, language, types:(.types|keys), body:(.types[]?.body // null), variables}' ;;
  create) auth | curl -K - -sS -X POST "https://content.twilio.com/v1/Content" -H 'Content-Type: application/json' --data-binary "@$2" | jq -c '{sid, friendly_name, code, message, status, more_info}' ;;
  send) auth | curl -K - -sS -X POST "https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json" \
          --data-urlencode "To=${TWILIO_WHATSAPP_TO}" --data-urlencode "From=${TWILIO_WHATSAPP_FROM}" \
          --data-urlencode "ContentSid=$2" --data-urlencode "ContentVariables=$3" | jq -c '{sid,status,error_code,code,message}' ;;
esac
