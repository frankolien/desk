#!/bin/bash
# Ships copyd to its own Railway service, `copyd`, in Amsterdam (Perpl answers US addresses with
# 451). It stages what copyd needs, with the Dockerfile's CMD set to copyd, and uploads that.
# The region is the service's own setting (railway service scale --service copyd eu-west=1
# us-west=0, done 16 Oct 2026); Railway ignored railway.copyd.json for this service. Run from
# anywhere.
set -euo pipefail
WEB="$(cd "$(dirname "$0")/.." && pwd)"
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp "$WEB/package.json" "$WEB/package-lock.json" "$WEB/Dockerfile" "$STAGE/"
cp -R "$WEB/api" "$WEB/worker" "$WEB/copyd" "$STAGE/"
cp "$WEB/railway.copyd.json" "$STAGE/railway.json"
# Railway no longer reads railway.json for new services, so the start command lives in the image.
sed -i '' 's|^CMD .*|CMD ["node", "copyd/index.mjs"]|' "$STAGE/Dockerfile"
grep -q 'copyd/index.mjs' "$STAGE/Dockerfile"
PROJECT=$(cd "$WEB" && railway status --json | jq -r .id) # the link lives in web/
cd "$STAGE"
railway up --project "$PROJECT" --environment production --service copyd --detach
