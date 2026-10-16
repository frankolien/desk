#!/bin/bash
# Puts a new HyperSync token in place, read from the clipboard so it is never typed or shown:
#   the new token          -> HYPERSYNC_TOKEN on Railway desk-worker and Vercel production
#   the token it replaces  -> HYPERSYNC_INDEX_TOKEN on desk-worker, so the trader index keeps a
#                             budget of its own and the new plan's requests go to alerts
# Copy the new token in Envio first, then: bash tools/hypersync-token.sh
set -euo pipefail
umask 077
cd "$(dirname "$0")/../web"
NEW=$(pbpaste | tr -d '[:space:]')
[ ${#NEW} -ge 16 ] || { echo "Copy the new HyperSync token in Envio first."; exit 1; }
OLD=$(railway variables --service desk-worker --json | jq -r '.HYPERSYNC_TOKEN // empty')
[ "$OLD" != "$NEW" ] || { echo "That is already the token in use."; exit 1; }
args=(--set "HYPERSYNC_TOKEN=$NEW")
[ -z "$OLD" ] || args+=(--set "HYPERSYNC_INDEX_TOKEN=$OLD")
railway variables --service desk-worker "${args[@]}" >/dev/null
echo "  Railway desk-worker: HYPERSYNC_TOKEN (new)${OLD:+, HYPERSYNC_INDEX_TOKEN (the old one)}; the worker restarts"
vercel env rm HYPERSYNC_TOKEN production --yes >/dev/null 2>&1 || true
printf %s "$NEW" | vercel env add HYPERSYNC_TOKEN production >/dev/null 2>&1
echo "  Vercel production: HYPERSYNC_TOKEN (new; takes effect on the next deploy)"
printf '' | pbcopy
echo "Done. Clipboard cleared."
