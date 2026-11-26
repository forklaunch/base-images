#!/usr/bin/env bash
# One-time AWS setup for the base-images pipeline. Idempotent: rerunning it
# only creates what is missing and re-applies the policies in this directory.
#
# Creates, in account $AWS_ACCOUNT_ID:
#   - the GitHub OIDC identity provider (token.actions.githubusercontent.com)
#   - IAM role forklaunch-base-images-ci (trust: trust-policy.json, inline policy: role-policy.json)
#   - public ECR repositories: node, bun, rust, platform-toolchain
#   - private ECR repositories base-images-staging/<image> (scan on push, keep ~10 images)
#   - S3 bucket $APK_BUCKET for the apk repository (public read of $APK_REPO_PATH/* only)
#   - Secrets Manager secret $SIGNING_KEY_SECRET_ID (the melange private key), readable only by the role
#
# Usage: infra/bootstrap.sh [path-to-melange-private-key]
#   The key is only uploaded when the secret has no value yet.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
set -a; . "$root/config.env"; set +a
key_file="${1:-}"

render() { sed -e "s/@@ACCOUNT@@/$AWS_ACCOUNT_ID/g" -e "s/@@REGION@@/$AWS_REGION/g" \
  -e "s/@@BUCKET@@/$APK_BUCKET/g" -e "s#@@APK_REPO_PATH@@#$APK_REPO_PATH#g" "$1"; }

oidc_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" >/dev/null 2>&1; then
  echo "creating OIDC provider"
  # AWS no longer checks the thumbprint for this provider (it trusts the CA
  # chain), but the API still requires one value.
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
fi

role_name="${CI_ROLE_ARN##*/}"
if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
  echo "creating role $role_name"
  aws iam create-role --role-name "$role_name" \
    --description "GitHub Actions for forklaunch/base-images (main only)" \
    --max-session-duration 21600 \
    --assume-role-policy-document "$(render "$here/trust-policy.json")" >/dev/null
else
  aws iam update-assume-role-policy --role-name "$role_name" \
    --policy-document "$(render "$here/trust-policy.json")"
fi
aws iam put-role-policy --role-name "$role_name" --policy-name base-images \
  --policy-document "$(render "$here/role-policy.json")"

for image in $IMAGES; do
  if ! aws ecr-public describe-repositories --region us-east-1 --repository-names "$image" >/dev/null 2>&1; then
    echo "creating public ECR repository $image"
    aws ecr-public create-repository --region us-east-1 --repository-name "$image" >/dev/null
  fi
  about="$(sed -n "/^## $image\$/,/^## /p" "$here/catalog.md" | sed '1d;$d')"
  aws ecr-public put-repository-catalog-data --region us-east-1 --repository-name "$image" \
    --catalog-data "$(jq -n --arg about "$about" --arg image "$image" '{
      description: ("ForkLaunch " + $image + " base image on Wolfi, rebuilt nightly, published only at 0 ECR findings"),
      architectures: ["x86-64", "ARM 64"],
      operatingSystems: ["Linux"],
      aboutText: $about,
      usageText: "See https://github.com/forklaunch/base-images#readme for tags and how to pin by digest."
    }')" >/dev/null

  staging="$STAGING_PREFIX/$image"
  if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$staging" >/dev/null 2>&1; then
    echo "creating private ECR repository $staging"
    aws ecr create-repository --region "$AWS_REGION" --repository-name "$staging" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE \
      --encryption-configuration encryptionType=AES256 >/dev/null
  fi
  aws ecr put-image-scanning-configuration --region "$AWS_REGION" --repository-name "$staging" \
    --image-scanning-configuration scanOnPush=true >/dev/null
  aws ecr put-lifecycle-policy --region "$AWS_REGION" --repository-name "$staging" \
    --lifecycle-policy-text "file://$here/staging-lifecycle.json" >/dev/null
done

if ! aws s3api head-bucket --bucket "$APK_BUCKET" >/dev/null 2>&1; then
  echo "creating bucket $APK_BUCKET"
  if [ "$AWS_REGION" = us-east-1 ]; then
    aws s3api create-bucket --bucket "$APK_BUCKET" --region us-east-1 >/dev/null
  else
    aws s3api create-bucket --bucket "$APK_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
fi
# ACLs stay disabled and blocked; only the bucket policy may grant public read.
aws s3api put-bucket-ownership-controls --bucket "$APK_BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-public-access-block --bucket "$APK_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-encryption --bucket "$APK_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-versioning --bucket "$APK_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket "$APK_BUCKET" \
  --lifecycle-configuration "file://$here/apk-bucket-lifecycle.json"
aws s3api put-bucket-policy --bucket "$APK_BUCKET" --policy "$(render "$here/apk-bucket-policy.json")"
aws s3api put-bucket-tagging --bucket "$APK_BUCKET" --tagging \
  'TagSet=[{Key=purpose,Value=public-apk-repository},{Key=public-exception,Value=base-images-apk-repo},{Key=repo,Value=forklaunch/base-images}]'

if ! aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$SIGNING_KEY_SECRET_ID" >/dev/null 2>&1; then
  [ -n "$key_file" ] || { echo "secret $SIGNING_KEY_SECRET_ID is missing: pass the private key path" >&2; exit 1; }
  echo "creating secret $SIGNING_KEY_SECRET_ID"
  aws secretsmanager create-secret --region "$AWS_REGION" --name "$SIGNING_KEY_SECRET_ID" \
    --description "melange signing key for the forklaunch apk repository (forklaunch/base-images)" \
    --secret-string "file://$key_file" >/dev/null
fi
aws secretsmanager put-resource-policy --region "$AWS_REGION" --secret-id "$SIGNING_KEY_SECRET_ID" \
  --block-public-policy --resource-policy "$(render "$here/signing-key-secret-policy.json")" >/dev/null

echo "done"
