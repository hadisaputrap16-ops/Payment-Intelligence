#!/usr/bin/env bash
# Starts the local demo server. Boomi listener credentials come from the workspace .env and are
# passed only to the server process's environment (never to the browser, argv or logs).
set -euo pipefail
source /home/hadisaputra/.claude/plugins/cache/anthropic-plugin-directory/boomi-integration/1.0.64-566c90f75bea/skills/boomi-integration/scripts/boomi-common.sh
cd /home/hadisaputra/boomi-projects && load_env
PI_BOOMI_BASE_URL="$SERVER_BASE_URL" PI_BOOMI_USER="$SERVER_USERNAME" PI_BOOMI_TOKEN="$SERVER_TOKEN" PROXY_PORT="${PROXY_PORT:-8080}" \
  exec python3 -I payment-intelligence/proxy/server.py
