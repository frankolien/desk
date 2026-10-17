#!/bin/bash
# Spot Auto-Copy's one-time setup (docs/spot-copy.md). Re-runnable: each step is skipped once done.
#   1. Desk's spot copy key in KMS: secp256k1, alias/desk-spot-copy, tagged desk:purpose=spot-copy.
#   2. desk-copyd's policy (iam/copyd.json) lets copyd sign digests with that key, nothing else.
#   3. Waits for MON on the key (it pays every copy's gas; ~0.05 MON a copy).
#   4. Deploys DeskCopyHook from that key (spot-deploy.mjs).
#   5. Sets Railway copyd's SPOT_KEY_ID, SPOT_HOOK, COPY_FEE_BPS, and Vercel's SPOT_FEE_RECIPIENT
#      and COPY_FEE_BPS (the fee goes to FEE_TO, in AUSD).
# Run: FEE_TO=0xYourTreasury bash web/copyd/spot-setup.sh
#      (needs aws login --profile desk, forge, vercel and railway logged in)
set -euo pipefail
cd "$(dirname "$0")/.."
P="--profile desk"
REGION=eu-north-1
ALIAS=alias/desk-spot-copy
FEE_BPS="${FEE_BPS:-50}"
if [ -n "${FEE_TO:-}" ] && ! [[ "$FEE_TO" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "FEE_TO must be a 0x address (42 characters), not \"$FEE_TO\"."
  exit 1
fi

key=$(aws kms describe-key $P --region $REGION --key-id $ALIAS --query KeyMetadata.KeyId --output text 2>/dev/null || true)
if [ -z "$key" ] || [ "$key" = "None" ]; then
  key=$(aws kms create-key $P --region $REGION --key-spec ECC_SECG_P256K1 --key-usage SIGN_VERIFY \
    --description "Desk spot Auto-Copy key: sends copies for wallets that registered it behind DeskCopyHook" \
    --tags TagKey=desk:purpose,TagValue=spot-copy --query KeyMetadata.KeyId --output text)
  aws kms create-alias $P --region $REGION --alias-name $ALIAS --target-key-id "$key"
  echo "Made the spot copy key ($key)."
fi

bash copyd/iam/update.sh $REGION

eval "$(aws configure export-credentials $P --format env)"
export AWS_REGION=$REGION
address=$(node --input-type=module -e "
  import { KMSClient } from '@aws-sdk/client-kms';
  import { kmsAccount } from './copyd/spot-chain.mjs';
  const a = await kmsAccount({ client: new KMSClient({ region: '$REGION' }), keyId: '$ALIAS' });
  console.log(a.address);")
echo "Desk's spot copy key: $address"

balance=$(cast balance "$address" --rpc-url https://rpc.monad.xyz)
if [ "$balance" -lt 2000000000000000000 ]; then
  echo "It holds $(cast from-wei "$balance") MON. Send it 20 MON (it pays the gas for every copy), then run this again."
  exit 0
fi

(cd ../contracts && { [ -d lib/forge-std ] || forge install foundry-rs/forge-std --no-git >/dev/null; } && forge build -q)
hook=$(node copyd/spot-deploy.mjs $ALIAS ../contracts/out/DeskCopyHook.sol/DeskCopyHook.json)
echo "DeskCopyHook: $hook"

railway variables --service copyd --skip-deploys --set "SPOT_KEY_ID=$ALIAS" --set "SPOT_HOOK=$hook" --set "COPY_FEE_BPS=$FEE_BPS" >/dev/null
if [ -n "${FEE_TO:-}" ]; then
  for pair in "SPOT_FEE_RECIPIENT $FEE_TO" "COPY_FEE_BPS $FEE_BPS"; do
    set -- $pair
    vercel env rm "$1" production --yes >/dev/null 2>&1 || true
    printf %s "$2" | vercel env add "$1" production >/dev/null 2>&1
  done
  echo "Copies take ${FEE_BPS} bps in AUSD to $FEE_TO."
else
  echo "No FEE_TO given: copies carry no fee until you run this again with one."
fi
echo "Done. Redeploy copyd (copyd/deploy.sh) and Vercel for them to take effect."
