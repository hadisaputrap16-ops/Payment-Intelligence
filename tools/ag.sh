#!/usr/bin/env bash
# Usage: ag.sh METHOD PATH [json_body_file] [out_name]
# Calls the Boomi Agent Garden Design API with the platform API token from the workspace .env.
# Credentials go to curl through a config on stdin, so they never appear in argv or output.
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
METHOD="$1"; PATH_="$2"; BODY="${3:-}"; NAME="${4:-last}"
OUT=/home/hadisaputra/boomi-projects/active-development/agentstudio-pi/responses
URL="https://ai-agent-garden.datalake-prod.boomi.com/design/api/v1/${BOOMI_ACCOUNT_ID}${PATH_}"
args=(-sS -o "$OUT/$NAME.json" -w '%{http_code}' -X "$METHOD" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data-binary "@$BODY")
code=$(curl_cfg user "BOOMI_TOKEN.${BOOMI_USERNAME}:${BOOMI_API_TOKEN}" | curl -K - "${args[@]}" "$URL")
echo "HTTP $code $METHOD $PATH_ -> $OUT/$NAME.json"
