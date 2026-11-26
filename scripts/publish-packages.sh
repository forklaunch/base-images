#!/usr/bin/env bash
# Upload the packages built for one architecture (every .apk under
# $WORK/packages/<arch> listed in built.txt files) to the apk repository, with
# the published APKINDEX merged and re-signed. Packages go up before the index,
# so the index never names a file that is not there yet.
#
# Usage: scripts/publish-packages.sh <arch>
#   SIGNING_KEY   path to the melange private key (required)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

arch="$1"
[ -n "${SIGNING_KEY:-}" ] && [ -f "$SIGNING_KEY" ] || die "SIGNING_KEY must point at the melange private key"
dir="$WORK/packages/$arch"
mkdir -p "$dir"
apks=()
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$dir/$f" ] && apks+=("$dir/$f")
done < <(cat "$dir"/built*.txt 2>/dev/null | sort -u)
if [ ${#apks[@]} = 0 ]; then log "$arch: no new packages"; exit 0; fi

key_dir="$WORK/keys"; mkdir -p "$key_dir"
key="$key_dir/${APK_KEY_NAME%.pub}"
cp "$SIGNING_KEY" "$key"; chmod 600 "$key"
trap 'rm -f "$key"' EXIT

index="$dir/APKINDEX.tar.gz"; rm -f "$index"
merge=()
if curl -fsSL --retry 3 "$APK_REPO_URL/$arch/APKINDEX.tar.gz" -o "$dir/APKINDEX.published.tar.gz"; then
  merge=(--merge --source "$dir/APKINDEX.published.tar.gz")
else
  log "$arch: no published index yet; starting a new one"
fi
(cd "$WORK" && TOOL_PRIVILEGED=1 tool "$MELANGE_IMAGE" index --arch "$arch" ${merge[@]+"${merge[@]}"} \
    --signing-key "$key" --output "$index" "${apks[@]}")

for f in "${apks[@]}"; do
  aws s3 cp --only-show-errors "$f" "s3://$APK_BUCKET/$APK_REPO_PATH/$arch/$(basename "$f")" \
    --content-type application/octet-stream --cache-control "public, max-age=31536000, immutable"
done
aws s3 cp --only-show-errors "$index" "s3://$APK_BUCKET/$APK_REPO_PATH/$arch/APKINDEX.tar.gz" \
  --content-type application/gzip --cache-control "no-cache"
aws s3 cp --only-show-errors "$ROOT/keys/$APK_KEY_NAME" "s3://$APK_BUCKET/$APK_REPO_PATH/$APK_KEY_NAME" \
  --content-type text/plain --cache-control "max-age=300"
for f in "${apks[@]}"; do log "$arch: published $(basename "$f")"; done
