#!/bin/bash
# Ships copyd to its own Railway service, `copyd`, in Amsterdam (Perpl answers US addresses with
# 451). The worker's railway.json stays the folder's default, so this stages a copy of what copyd
# needs with railway.copyd.json as its railway.json, and uploads that. Run from anywhere.
set -euo pipefail
WEB="$(cd "$(dirname "$0")/.." && pwd)"
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp "$WEB/package.json" "$WEB/package-lock.json" "$WEB/Dockerfile" "$STAGE/"
cp -R "$WEB/api" "$WEB/worker" "$WEB/copyd" "$STAGE/"
cp "$WEB/railway.copyd.json" "$STAGE/railway.json"
cd "$WEB" # the Railway link lives here
railway up "$STAGE" --service copyd --environment production --detach
