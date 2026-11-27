#!/usr/bin/env bash
# Copy candidates that passed the gate and the smoke tests from the private
# staging repositories to public ECR, then point the public tags at them.
# `oras cp -r` copies by digest, with the per-architecture images and the SBOM
# referrers, so the public image is byte-for-byte the one that was scanned and
# tested.
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
  oras cp -r "$ref" "$dst:$(tr ' ' ',' <<<"$tags")" >&2
  for t in $tags; do
    got="$(oras resolve "$dst:$t")"
    [ "$got" = "$digest" ] || die "$image:$variant: $dst:$t resolves to $got, expected $digest"
  done
  printf '%s\t%s\t%s\t%s\n' "$image" "$variant" "$dst@$digest" "$tags" >> "$published"
done < "$list"
cat "$published" >&2
