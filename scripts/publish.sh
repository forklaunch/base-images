#!/usr/bin/env bash
# Copy candidates that passed the gate and the smoke tests from the private
# staging repositories to public ECR, then point the public tags at them.
# The copy is by digest, so the public image is byte-for-byte the one that
# was scanned and tested. SBOM attachments (cosign-style sha256-<digest>.sbom
# tags written by apko) are copied along.
#
# Usage: scripts/publish.sh <passed.tsv>
#   DATE_TAG   date stamp for dated tags (default: today, UTC, YYYYMMDD)
#   DRY_RUN=1  print what would be copied
# Writes $WORK/published.tsv: <image> <variant> <public-ref@digest> <tags>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

list="$1"
date_tag="${DATE_TAG:-$(date -u +%Y%m%d)}"
published="$WORK/published.tsv"; : > "$published"
crane() { (cd "$WORK" && tool "$CRANE_IMAGE" "$@"); }

while IFS=$'\t' read -r image variant ref; do
  [ -n "$image" ] || continue
  digest="${ref##*@}"
  dst="$PUBLIC_REGISTRY/$image"
  tags="$(variant_tags "$image" "$variant" "$date_tag")"
  log "$image:$variant: $ref -> $dst ($tags)"
  if [ "${DRY_RUN:-0}" = 1 ]; then continue; fi
  first="${tags%% *}"
  crane copy "$ref" "$dst:$first"
  for t in ${tags#"$first"}; do crane tag "$dst:$first" "$t"; done
  got="$(crane digest "$dst:$first")"
  [ "$got" = "$digest" ] || die "$image:$variant: public digest $got differs from staged $digest"

  # SBOM attachments for the index and each per-architecture image.
  src_repo="${ref%@*}"
  staged_tags="$(crane ls "$src_repo")"
  for d in "$digest" $(crane manifest "$ref" | jq -r '.manifests[].digest'); do
    t="sha256-${d#sha256:}.sbom"
    if grep -qx "$t" <<<"$staged_tags"; then crane copy "$src_repo:$t" "$dst:$t"; fi
  done
  printf '%s\t%s\t%s\t%s\n' "$image" "$variant" "$dst@$digest" "$tags" >> "$published"
done < "$list"
cat "$published" >&2
