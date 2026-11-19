#!/usr/bin/env bash
# Regenerates process XML. WhatsApp numbers and the Twilio Account SID are handed to the generator via its environment only.
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
# Email alert recipient: ALERT_EMAIL_TO from .env, else the 'to' default of the "Send Mail Notification" operation (Agent Studio Processes).
OP=active-development/connector-action/Send_Mail_Notification_AgentStudio.xml
ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-$( [ -f "$OP" ] && grep -oE '<MailSendAction[^>]*' "$OP" | grep -oE ' to="[^"]*"' | head -1 | cut -d'"' -f2 )}"
[ -n "$ALERT_EMAIL_TO" ] || echo "WARN: no email recipient (set ALERT_EMAIL_TO); email alert sub-process not generated" >&2
ALERT_EMAIL_TO="$ALERT_EMAIL_TO" WA_TO="$TWILIO_WHATSAPP_TO" WA_FROM="$TWILIO_WHATSAPP_FROM" WA_CONTENT_SID="${TWILIO_CONTENT_SID:-}" TW_ACCOUNT="$TWILIO_ACCOUNT_SID" \
  python3 -I payment-intelligence/tools/gen_processes.py payment-intelligence/tools/ids.json active-development/process
