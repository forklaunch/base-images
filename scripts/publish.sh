#!/usr/bin/env bash
# Copy candidates that passed the gate and the smoke tests from the private
# staging repositories to public ECR, then point the public tags at them.
# `oras cp -r` copies by digest, with the per-architecture images and the SBOM
# referrers, so the public image is byte-for-byte the one that was scanned and
# tested. Needs the AWS CLI with ecr-public:DescribeImages to check the tags.
#
# Usage: scripts/publish.sh <release.tsv>
#   DATE_TAG   date stamp for dated tags (default: today, UTC, YYYYMMDD)
#   DRY_RUN=1  print what would be copied
# Writes $WORK/published.tsv: <image> <variant> <public-ref@digest> <tags>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

list="$1"
date_tag="${DATE_TAG:-$(date -u +%Y%m%d)}"
published="$WORK/published.tsv"; : > "$published"

while IFS=$'\t' read -r image variant ref; do
  [ -n "$image" ] || continue
  digest="${ref##*@}"
  dst="$PUBLIC_REGISTRY/$image"
  tags="$(variant_tags "$image" "$variant" "$date_tag")"
  log "$image:$variant: $ref -> $dst ($tags)"
  [ "${DRY_RUN:-0}" = 1 ] && continue
  # One copy per tag, always from the staging digest. `oras cp` with several
  # tags pushes the first and then re-reads it from public.ecr.aws to apply the
  # rest; that read can be a cached copy of the previous image, which moved the
  # other tags back to yesterday's digest. Only the first copy needs -r (the
  # architectures and SBOM referrers); later ones just put the index under a tag.
  r=-r
  for t in $tags; do
    # ECR Public sometimes loses a chunked blob upload ("blob upload unknown").
    # Upload one blob at a time and retry; a retry re-sends only what is missing.
    n=0
    until oras cp $r --concurrency 1 "$ref" "$dst:$t" >&2; do
      n=$((n+1)); [ "$n" -lt 4 ] || die "$image:$variant: oras cp to $dst:$t failed $n times"
      log "$image:$variant: oras cp to $dst:$t failed, retry $n in $((n*20))s"; sleep $((n*20))
    done
    r=
  done
  # Check against the registry API, not public.ecr.aws, whose tag reads can be
  # served from a cache for a while after a tag moves.
  have="$(aws ecr-public describe-images --region us-east-1 --repository-name "$image" \
      --image-ids imageDigest="$digest" --query 'imageDetails[0].imageTags' --output text)"
  for t in $tags; do
    grep -qxF -- "$t" <<<"$(tr '\t' '\n' <<<"$have")" || die "$image:$variant: tag $t is not on $digest in ECR Public (tags there: $have)"
  done
  printf '%s\t%s\t%s\t%s\n' "$image" "$variant" "$dst@$digest" "$tags" >> "$published"
done < "$list"
cat "$published" >&2
