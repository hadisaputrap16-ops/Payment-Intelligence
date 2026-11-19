#!/usr/bin/env bash
# Publishes the live demo (portal + proxy) to a Hugging Face Docker Space.
#   HF_TOKEN=<write token> bash tools/deploy-hf-space.sh <hf-user>/<space-name>
# Only the files the container needs are pushed; secrets are set in the Space settings, never here.
set -euo pipefail
SPACE="${1:?usage: HF_TOKEN=... $0 <hf-user>/<space-name>}"
: "${HF_TOKEN:?set HF_TOKEN to a Hugging Face write token}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/proxy" "$WORK/tools"
cp -r "$ROOT/frontend" "$WORK/frontend"
cp "$ROOT/Dockerfile" "$WORK/Dockerfile"
cp "$ROOT/proxy/server.py" "$WORK/proxy/server.py"
cp "$ROOT/tools/snap_client.js" "$WORK/tools/snap_client.js"
cp "$ROOT/tools/hf-space-README.md" "$WORK/README.md"

cd "$WORK"
git init -q -b main
git -c user.name="deploy" -c user.email="deploy@localhost" add -A
git -c user.name="deploy" -c user.email="deploy@localhost" commit -q -m "Deploy from payment-intelligence $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
# Token goes in a one-off header, not in the remote URL or any config file.
AUTH=$(printf 'user:%s' "$HF_TOKEN" | base64 -w0)
git -c http.extraHeader="Authorization: Basic $AUTH" push -f "https://huggingface.co/spaces/$SPACE" main
echo "Pushed. Build log: https://huggingface.co/spaces/$SPACE  ·  App: https://${SPACE/\//-}.hf.space"
