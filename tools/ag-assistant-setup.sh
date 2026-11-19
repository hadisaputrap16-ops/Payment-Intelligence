#!/usr/bin/env bash
# Creates the read-only OpenAPI tools + the conversational "Payment Intelligence Assistant" agent in Agent Garden,
# then packages and deploys it. Tool basic-auth = the shared web server listener creds from .env (SERVER_USERNAME/SERVER_TOKEN);
# they are written only to a 0600 temp file for the API call and deleted right after. Prints ids/status only.
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
AG=payment-intelligence/tools/ag.sh
D=active-development/agentstudio-pi/assistant
R=active-development/agentstudio-pi/responses
ENV_ID="${AG_ENV_ID:-c93176d0-ffa4-4f55-b404-1043058551ec}"   # Agent Garden environment of the Risk Analyst agent
umask 077; TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
tools='[]'
for t in get_dashboard_summary search_transactions get_investigation list_alerts; do
  jq --arg u "$SERVER_USERNAME" --arg p "$SERVER_TOKEN" '. + {authentication:{type:"basic_auth", config:{username:$u, password:$p}}}' "$D/tool_$t.json" > "$TMP"
  bash $AG POST /tools/openapi "$TMP" "asst_create_$t" >/dev/null
  id=$(jq -r '.data.id // empty' "$R/asst_create_$t.json")
  [ -n "$id" ] || { echo "FAIL create $t: $(jq -c '{message,detail}' "$R/asst_create_$t.json" | cut -c1-300)"; exit 1; }
  bash $AG POST "/tools/openapi/$id/install" "" "asst_install_$t" >/dev/null
  echo "tool $t $id installed=$(jq -r '.success' "$R/asst_install_$t.json")"
  tools=$(jq -c --arg id "$id" --arg n "$t" '. + [{id:$id, type:"OpenAPI", name:$n, requires_approval:false, response_passthrough:false}]' <<<"$tools")
done
rm -f "$TMP"
jq --argjson tl "$tools" '.tasks[0].tools = $tl' "$D/agent.json" > "$D/agent_with_tools.json"
bash $AG POST /agents "$D/agent_with_tools.json" asst_create_agent >/dev/null
AID=$(jq -r '.data.id // empty' "$R/asst_create_agent.json")
[ -n "$AID" ] || { echo "FAIL create agent: $(jq -c '{message,detail}' "$R/asst_create_agent.json" | cut -c1-400)"; exit 1; }
echo "agent $AID"
echo '{}' > "$D/empty.json"
bash $AG POST "/agents/$AID/packages" "$D/empty.json" asst_package >/dev/null
PID=$(jq -r '.data.package_id // empty' "$R/asst_package.json")
[ -n "$PID" ] || { echo "FAIL package: $(jq -c '{message,detail}' "$R/asst_package.json" | cut -c1-300)"; exit 1; }
jq -n --arg p "$PID" --arg e "$ENV_ID" '{package_id:$p, environment_id:$e}' > "$D/deploy.json"
bash $AG POST "/agents/$AID/deployments" "$D/deploy.json" asst_deploy >/dev/null
jq -c '{success, message, deployment_id:.data.deployment_id, status:.data.deployment_status, detail}' "$R/asst_deploy.json" | cut -c1-300
