#!/bin/bash
# Puts every secret Auto-Copy on the server needs straight into Vercel and Railway, once:
#   desk-copy-api's AWS access key and the token key -> Vercel production
#   desk-copyd's AWS access key, the token key, and the worker's Redis, CRON_SECRET and
#   DESK_API plus Vercel's APNs settings -> the Railway service copyd
# Nothing is printed; the temporary files are readable only by you and removed on exit. It
# refuses to run if either AWS user already has an access key, so it never makes a second.
# Run: bash web/copyd/secrets.sh   (needs aws login --profile desk, vercel and railway logged in)
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
P="--profile desk"
SERVICE=copyd
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

for u in desk-copy-api desk-copyd; do
  n=$(aws iam list-access-keys $P --user-name $u --query 'length(AccessKeyMetadata)' --output text)
  [ "$n" = "0" ] || { echo "$u already has $n access key(s); not making another. Remove them first if this is a re-run."; exit 1; }
done

vercel_set() { # name value
  vercel env rm "$1" production --yes >/dev/null 2>&1 || true
  printf %s "$2" | vercel env add "$1" production >/dev/null
  echo "  Vercel production: $1"
}

TOKEN_KEY=$(openssl rand -base64 32)

echo "desk-copy-api -> Vercel"
aws iam create-access-key $P --user-name desk-copy-api --output json > "$TMP/api.json"
vercel_set COPY_AWS_ACCESS_KEY_ID "$(jq -r .AccessKey.AccessKeyId "$TMP/api.json")"
vercel_set COPY_AWS_SECRET_ACCESS_KEY "$(jq -r .AccessKey.SecretAccessKey "$TMP/api.json")"
vercel_set COPY_AWS_REGION eu-north-1
vercel_set COPY_TOKEN_KEY "$TOKEN_KEY"

echo "desk-copyd -> Railway ($SERVICE)"
aws iam create-access-key $P --user-name desk-copyd --output json > "$TMP/copyd.json"
railway variables --service desk-worker --json > "$TMP/worker.json"
vercel env pull "$TMP/vercel.env" --environment production --yes >/dev/null 2>&1
get_env() { python3 -c "
import sys
for line in open(sys.argv[1]):
    k, _, v = line.rstrip('\n').partition('=')
    if k == sys.argv[2]:
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] == '\"': v = bytes(v[1:-1], 'utf-8').decode('unicode_escape')
        print(v, end='')
" "$TMP/vercel.env" "$1"; }
for k in APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC APNS_PRIVATE_KEY; do [ -n "$(get_env $k)" ] || { echo "Vercel production has no $k"; exit 1; }; done

railway variables --service "$SERVICE" --skip-deploys \
  --set "COPYD_AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId "$TMP/copyd.json")" \
  --set "COPYD_AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey "$TMP/copyd.json")" \
  --set "COPY_AWS_REGION=eu-north-1" \
  --set "COPY_TOKEN_KEY=$TOKEN_KEY" \
  --set "KV_REST_API_URL=$(jq -r .KV_REST_API_URL "$TMP/worker.json")" \
  --set "KV_REST_API_TOKEN=$(jq -r .KV_REST_API_TOKEN "$TMP/worker.json")" \
  --set "CRON_SECRET=$(jq -r .CRON_SECRET "$TMP/worker.json")" \
  --set "DESK_API=$(jq -r .DESK_API "$TMP/worker.json")" \
  --set "APNS_KEY_ID=$(get_env APNS_KEY_ID)" \
  --set "APNS_TEAM_ID=$(get_env APNS_TEAM_ID)" \
  --set "APNS_TOPIC=$(get_env APNS_TOPIC)" \
  --set "APNS_PRIVATE_KEY=$(get_env APNS_PRIVATE_KEY)" >/dev/null
railway variables --service "$SERVICE" --json | jq -r 'keys | map(select(startswith("RAILWAY") | not)) | "  Railway copyd: " + join(", ")'
for u in desk-copy-api desk-copyd; do echo "  $u access keys: $(aws iam list-access-keys $P --user-name $u --query 'length(AccessKeyMetadata)' --output text)"; done
echo "Done."
