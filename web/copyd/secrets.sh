#!/bin/bash
# Puts every secret Auto-Copy on the server needs straight into Vercel and Railway:
#   desk-copy-api's AWS access key           -> Vercel production (COPY_AWS_*)
#   desk-copyd's AWS access key              -> Railway service copyd (COPYD_AWS_*)
#   COPY_TOKEN_KEY, the same on both sides
#   the worker's KV, CRON_SECRET and DESK_API -> copyd (notifications go out through the API,
#   which holds the APNs key, so copyd needs none)
# Safe to run again: whatever is already in place is left alone. An AWS user whose key isn't
# stored where it belongs has that key replaced, since its secret can't be read back. The token
# key is only made while copyd has none, which is before anyone has turned server copying on.
# Nothing is printed; temporary files are readable only by you and removed on exit.
# Run: bash web/copyd/secrets.sh   (needs aws login --profile desk, vercel and railway logged in)
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
P="--profile desk"
SERVICE=copyd
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

vercel env ls production > "$TMP/vercel-names.txt" 2>/dev/null
railway variables --service "$SERVICE" --json > "$TMP/copyd-vars.json"
railway variables --service desk-worker --json > "$TMP/worker.json"
has_vercel() { grep -qE "^[[:space:]]*$1[[:space:]]" "$TMP/vercel-names.txt"; }
has_railway() { jq -e --arg k "$1" 'has($k)' "$TMP/copyd-vars.json" >/dev/null; }

vercel_set() { # name value
  vercel env rm "$1" production --yes >/dev/null 2>&1 || true
  printf %s "$2" | vercel env add "$1" production >/dev/null 2>&1
  echo "  Vercel production: $1"
}

fresh_key() { # user file
  for id in $(aws iam list-access-keys $P --user-name "$1" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key $P --user-name "$1" --access-key-id "$id"
    echo "  replaced an earlier $1 key whose secret was never stored"
  done
  aws iam create-access-key $P --user-name "$1" --output json > "$2"
}

TOKEN_KEY=""
has_railway COPY_TOKEN_KEY || TOKEN_KEY=$(openssl rand -base64 32)

echo "desk-copy-api -> Vercel"
if has_vercel COPY_AWS_ACCESS_KEY_ID && has_vercel COPY_AWS_SECRET_ACCESS_KEY; then
  echo "  access key already set"
else
  fresh_key desk-copy-api "$TMP/api.json"
  vercel_set COPY_AWS_ACCESS_KEY_ID "$(jq -r .AccessKey.AccessKeyId "$TMP/api.json")"
  vercel_set COPY_AWS_SECRET_ACCESS_KEY "$(jq -r .AccessKey.SecretAccessKey "$TMP/api.json")"
fi
has_vercel COPY_AWS_REGION || vercel_set COPY_AWS_REGION eu-north-1
[ -z "$TOKEN_KEY" ] || vercel_set COPY_TOKEN_KEY "$TOKEN_KEY"

echo "desk-copyd -> Railway ($SERVICE)"
args=(
  --set "COPY_AWS_REGION=eu-north-1"
  --set "KV_REST_API_URL=$(jq -r .KV_REST_API_URL "$TMP/worker.json")"
  --set "KV_REST_API_TOKEN=$(jq -r .KV_REST_API_TOKEN "$TMP/worker.json")"
  --set "CRON_SECRET=$(jq -r .CRON_SECRET "$TMP/worker.json")"
  --set "DESK_API=$(jq -r .DESK_API "$TMP/worker.json")"
)
if ! has_railway COPYD_AWS_ACCESS_KEY_ID; then
  fresh_key desk-copyd "$TMP/copyd.json"
  args+=(--set "COPYD_AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId "$TMP/copyd.json")")
  args+=(--set "COPYD_AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey "$TMP/copyd.json")")
fi
[ -z "$TOKEN_KEY" ] || args+=(--set "COPY_TOKEN_KEY=$TOKEN_KEY")
railway variables --service "$SERVICE" --skip-deploys "${args[@]}" >/dev/null
railway variables --service "$SERVICE" --json | jq -r 'keys | map(select(startswith("RAILWAY") | not)) | "  Railway copyd: " + join(", ")'
for u in desk-copy-api desk-copyd; do echo "  $u access keys: $(aws iam list-access-keys $P --user-name $u --query 'length(AccessKeyMetadata)' --output text)"; done
echo "Done."
