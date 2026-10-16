#!/bin/bash
# Applies api.json and copyd.json as new default versions of the two policies setup.sh made, for
# the account the desk profile signs in to. AWS keeps up to five versions; the oldest spare one is
# dropped first when full, so the version before this one stays to roll back to.
set -euo pipefail
cd "$(dirname "$0")"
P="--profile ${AWS_PROFILE:-desk}"
REGION="${1:-eu-north-1}"
ACCOUNT_ID="$(aws sts get-caller-identity $P --query Account --output text)"
render() { sed "s/\${ACCOUNT_ID}/$ACCOUNT_ID/g; s/\${REGION}/$REGION/g" "$1"; }
for pair in "DeskCopyApiKms api.json" "DeskCopydKms copyd.json"; do
  set -- $pair
  ARN="arn:aws:iam::$ACCOUNT_ID:policy/$1"
  versions=$(aws iam list-policy-versions $P --policy-arn "$ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
  if [ "$(aws iam list-policy-versions $P --policy-arn "$ARN" --query 'length(Versions)')" -ge 5 ]; then
    aws iam delete-policy-version $P --policy-arn "$ARN" --version-id "$(echo $versions | tr ' ' '\n' | sort -V | head -1)"
  fi
  v=$(aws iam create-policy-version $P --policy-arn "$ARN" --policy-document "$(render "$2")" --set-as-default --query PolicyVersion.VersionId --output text)
  echo "$1: now $v"
done
