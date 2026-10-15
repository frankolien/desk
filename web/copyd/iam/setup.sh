#!/bin/bash
# Creates Desk's two copy-trading identities in the AWS account the `desk` profile signs in to.
#   desk-copy-api  (Vercel /api/copy): creates, tags, names and retires Desk Ed25519 keys; never signs
#   desk-copyd     (Railway copyd):    signs with Desk keys and reads their public keys; nothing else
# Neither gets a password or access keys here; those are made at deploy time and go straight into
# the host's environment. Run once per account: bash web/copyd/iam/setup.sh [region]
set -euo pipefail
cd "$(dirname "$0")"
P="--profile ${AWS_PROFILE:-desk}"
REGION="${1:-eu-north-1}"
ACCOUNT_ID="$(aws sts get-caller-identity $P --query Account --output text)"
echo "Account $ACCOUNT_ID, region $REGION"
render() { sed "s/\${ACCOUNT_ID}/$ACCOUNT_ID/g; s/\${REGION}/$REGION/g" "$1"; }
make() { # user policy description file
  aws iam create-policy $P --policy-name "$2" --description "$3" --policy-document "$(render "$4")" --query Policy.Arn --output text
  aws iam create-user $P --user-name "$1" --tags Key=desk:purpose,Value=auto-copy --query User.Arn --output text
  aws iam attach-user-policy $P --user-name "$1" --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$2"
}
make desk-copy-api DeskCopyApiKms "Desk Auto-Copy API: create and retire Desk Ed25519 trading keys in KMS; never sign" api.json
make desk-copyd DeskCopydKms "Desk copy engine: sign with Desk Ed25519 trading keys only" copyd.json
for u in desk-copy-api desk-copyd; do
  echo "$u: $(aws iam list-attached-user-policies $P --user-name $u --query 'AttachedPolicies[].PolicyName' --output text), access keys: $(aws iam list-access-keys $P --user-name $u --query 'length(AccessKeyMetadata)')"
done
