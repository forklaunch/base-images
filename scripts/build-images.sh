#!/usr/bin/env bash
# Assemble images with apko and push them as candidates to the private
# staging repositories.
#
# For each variant: render the apko config, pin every package
# (scripts/lib.sh pin_apko_config), resolve the full package closure with
# `apko lock` (written to images/<image>/locks/<variant>.lock.json), then
# `apko publish` with that lock file. apko writes an SPDX SBOM per
# architecture; they are kept under $WORK/sbom and pushed next to the image.
#
# Appends one line per candidate to $WORK/candidates.tsv:
#   <image> <variant> <staging-ref-with-digest>
#
# Usage: scripts/build-images.sh [image...]      (default: all images)
#   CANDIDATE_ID   suffix for staging tags (default: local-<timestamp>)
#   LOCAL=1        build into the local Docker daemon instead of pushing
#   ARCH_ONLY=x    build one architecture only (local testing)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

images=("$@"); [ ${#images[@]} -gt 0 ] || images=($IMAGES)
cid="${CANDIDATE_ID:-local-$(date -u +%Y%m%d%H%M%S)}"
candidates="$WORK/candidates.tsv"
touch "$candidates"
arch_args=()
[ -n "${ARCH_ONLY:-}" ] && arch_args=(--arch "$ARCH_ONLY")
# Reproducible layer timestamps: the commit time of the pins.
build_date="$(git -C "$ROOT" log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

for image in "${images[@]}"; do
  mkdir -p "$ROOT/images/$image/locks"
  while read -r variant template; do
    config="$(render_variant "$image" "$variant" "$template")" || die "could not render $image:$variant"
    lock="$ROOT/images/$image/locks/$variant.lock.json"
    log "$image:$variant: resolving packages"
    (cd "$WORK" && tool "$APKO_IMAGE" lock "$config" ${arch_args[@]+"${arch_args[@]}"} --output "$lock.tmp" \
       --cache-dir "$WORK/apko-cache")
    # Keep the lock file stable across runs that resolve the same packages.
    jq -S . "$lock.tmp" > "$lock" && rm -f "$lock.tmp"

    sbom_dir="$WORK/sbom/$image/$variant"
    rm -rf "$sbom_dir"; mkdir -p "$sbom_dir"
    staging="$STAGING_REGISTRY/$STAGING_PREFIX/$image:$variant-$cid"
    if [ "${LOCAL:-0}" = 1 ]; then
      log "$image:$variant: building into $WORK/oci/$image-$variant.tar"
      mkdir -p "$WORK/oci"
      (cd "$WORK" && tool "$APKO_IMAGE" build "$config" "fl-local/$image:$variant" "$WORK/oci/$image-$variant.tar" \
         ${arch_args[@]+"${arch_args[@]}"} --lockfile "$lock" --sbom-path "$sbom_dir" --build-date "$build_date" \
         --cache-dir "$WORK/apko-cache")
      docker load -q -i "$WORK/oci/$image-$variant.tar" >&2
      rm -f "$WORK/oci/$image-$variant.tar"
      printf '%s\t%s\t%s\n' "$image" "$variant" "fl-local/$image:$variant${ARCH_ONLY:+-$(oci_arch "$ARCH_ONLY")}" >> "$candidates"
      continue
    fi
    log "$image:$variant: publishing $staging"
    (cd "$WORK" && tool "$APKO_IMAGE" publish "$config" "$staging" \
       ${arch_args[@]+"${arch_args[@]}"} --lockfile "$lock" --sbom-path "$sbom_dir" --build-date "$build_date" \
       --cache-dir "$WORK/apko-cache" --image-refs "$sbom_dir/image-refs.txt")
    # apko lists the per-architecture images first and the index last.
    ref="$(grep "@sha256:" "$sbom_dir/image-refs.txt" | tail -1)"
    [[ "$ref" == *@sha256:* ]] || die "$image:$variant: apko did not report a digest ($ref)"
    repo="$STAGING_REGISTRY/$STAGING_PREFIX/$image"
    index_ref="$repo@${ref##*@}"

    # SBOMs go next to the images as OCI referrers (artifact type
    # application/spdx+json): the index SBOM on the index, each
    # architecture's SBOM on that architecture's image.
    attach_sbom "$index_ref" "$sbom_dir/sbom-index.spdx.json"
    while IFS=$'\t' read -r arch digest; do
      attach_sbom "$repo@$digest" "$sbom_dir/sbom-$arch.spdx.json"
    done < <(index_platforms "$index_ref")
    printf '%s\t%s\t%s\n' "$image" "$variant" "$index_ref" >> "$candidates"
  done < <(variants "$image")
done
