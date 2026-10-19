#!/bin/bash
# The any-chain send's one-time setup (docs/any-chain-send.md). Re-runnable.
#   1. Builds DeskSend with forge.
#   2. Deploys it from Desk's spot copy key (alias/desk-spot-copy, which pays every send's gas)
#      at the pinned deterministic address; skipped once it is there.
# Nothing else to configure: the API and copyd pin the address in code. Set SEND_CONTRACT on
# Vercel and Railway only to point them somewhere else.
# Run: bash web/copyd/send-setup.sh   (needs aws login --profile desk, forge)
set -euo pipefail
cd "$(dirname "$0")/.."
P="--profile desk"
REGION=eu-north-1
ALIAS=alias/desk-spot-copy

(cd ../contracts && forge build --silent)
eval "$(aws configure export-credentials $P --format env)"
export AWS_REGION=$REGION
address=$(node copyd/send-deploy.mjs "$ALIAS" ../contracts/out/DeskSend.sol/DeskSend.json)
echo "DeskSend is at $address on Monad."
