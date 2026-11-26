#!/usr/bin/env bash
# The publish gate. For every candidate in $WORK/candidates.tsv and every
# architecture in its index:
#   1. wait for ECR basic scanning (scan on push) to finish on the staging repo
#   2. read the findings; the gate requires 0 at every severity, including
#      LOW, INFORMATIONAL and UNDEFINED
#   3. run Grype against the same digest (reported; see GRYPE_GATE)
#
# Writes:
#   $WORK/gate/results.tsv   image variant arch digest ecr-status ecr-total ecr-counts grype-total grype-fixable
#   $WORK/gate/passed.tsv    candidates that passed (same format as candidates.tsv)
#   $WORK/gate/summary.md    a Markdown table plus every finding, for the job summary and the issue
# Exits 0 when every candidate passed, 1 otherwise (passed.tsv still lists the ones that did).
#
#   GRYPE_GATE   report (default): Grype results are shown, not enforced
#                fixable: also fail a candidate on any Grype match with a fix available
#                all: also fail on any Grype match
#   SCAN_TIMEOUT seconds to wait for each ECR scan (default 1800)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

gate="$WORK/gate"
rm -rf "$gate"; mkdir -p "$gate/findings" "$WORK/grype-db"
: > "$gate/results.tsv"; : > "$gate/passed.tsv"
grype_gate="${GRYPE_GATE:-report}"
timeout="${SCAN_TIMEOUT:-1800}"

ecr() { aws ecr --region "$AWS_REGION" "$@"; }

wait_for_scan() { # repo digest -> prints final status
  local repo="$1" digest="$2" start status started=0
  start="$(date +%s)"
  while :; do
    status="$(ecr describe-image-scan-findings --repository-name "$repo" --image-id "imageDigest=$digest" \
      --query 'imageScanStatus.status' --output text 2>/dev/null || echo MISSING)"
    case "$status" in
      COMPLETE|FAILED|UNSUPPORTED_IMAGE|FINDINGS_UNAVAILABLE) echo "$status"; return;;
      MISSING)
        # Scan on push normally starts within seconds; start one if it did not.
        if [ $started = 0 ] && [ $(( $(date +%s) - start )) -gt 120 ]; then
          ecr start-image-scan --repository-name "$repo" --image-id "imageDigest=$digest" >/dev/null 2>&1 || true
          started=1
        fi;;
    esac
    if [ $(( $(date +%s) - start )) -gt "$timeout" ]; then echo TIMEOUT; return; fi
    sleep 15
  done
}

all_passed=1
while IFS=$'\t' read -r image variant ref; do
  [ -n "$image" ] || continue
  repo="$STAGING_PREFIX/$image"
  index_digest="${ref##*@}"
  manifest="$(ecr batch-get-image --repository-name "$repo" --image-ids "imageDigest=$index_digest" \
    --accepted-media-types application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json \
    --query 'images[0].imageManifest' --output text)"
  candidate_ok=1
  while IFS=$'\t' read -r os_arch digest; do
    arch="${os_arch#linux/}"
    status="$(wait_for_scan "$repo" "$digest")"
    total=-1; counts="{}"
    if [ "$status" = COMPLETE ]; then
      ecr describe-image-scan-findings --repository-name "$repo" --image-id "imageDigest=$digest" \
        --output json > "$gate/findings/$image-$variant-$arch.ecr.json"
      counts="$(jq -c '.imageScanFindings.findingSeverityCounts // {}' "$gate/findings/$image-$variant-$arch.ecr.json")"
      total="$(jq '[.[]] | add // 0' <<<"$counts")"
      # Every finding, not only the first page.
      ecr describe-image-scan-findings --repository-name "$repo" --image-id "imageDigest=$digest" \
        --query 'imageScanFindings.findings[].[severity,name,attributes[?key==`package_name`]|[0].value,attributes[?key==`package_version`]|[0].value]' \
        --output text > "$gate/findings/$image-$variant-$arch.ecr.txt" || true
    fi

    # Grype, against the same per-architecture digest.
    grype_total=-1; grype_fixable=-1
    if (cd "$WORK" && TOOL_ENV="GRYPE_DB_CACHE_DIR=$WORK/grype-db GRYPE_CHECK_FOR_APP_UPDATE=false" \
          tool "$GRYPE_IMAGE" "registry:${ref%@*}@$digest" -o json --file "$gate/findings/$image-$variant-$arch.grype.json" -q); then
      grype_total="$(jq '.matches | length' "$gate/findings/$image-$variant-$arch.grype.json")"
      grype_fixable="$(jq '[.matches[] | select(.vulnerability.fix.state == "fixed")] | length' "$gate/findings/$image-$variant-$arch.grype.json")"
      jq -r '.matches[] | [.vulnerability.severity, .vulnerability.id, .artifact.name, .artifact.version, (.vulnerability.fix.versions | join(","))] | @tsv' \
        "$gate/findings/$image-$variant-$arch.grype.json" | sort -u > "$gate/findings/$image-$variant-$arch.grype.txt"
    fi

    ok=1
    [ "$status" = COMPLETE ] && [ "$total" = 0 ] || ok=0
    case "$grype_gate" in
      fixable) [ "$grype_fixable" = 0 ] || ok=0;;
      all) [ "$grype_total" = 0 ] || ok=0;;
    esac
    [ $ok = 1 ] || candidate_ok=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$image" "$variant" "$arch" "$digest" "$status" "$total" "$counts" \
      "$grype_total" "$grype_fixable" >> "$gate/results.tsv"
    log "$image:$variant $arch: ECR $status total=$total $counts; Grype $grype_total ($grype_fixable fixable)"
  done < <(jq -r '.manifests[] | select(.platform.os == "linux") | [.platform.os + "/" + .platform.architecture, .digest] | @tsv' <<<"$manifest")
  if [ $candidate_ok = 1 ]; then
    printf '%s\t%s\t%s\n' "$image" "$variant" "$ref" >> "$gate/passed.tsv"
  else
    all_passed=0
  fi
done < "$WORK/candidates.tsv"

# Summary.
{
  echo "| image | variant | arch | ECR scan | ECR findings | Grype matches (fixable) | gate |"
  echo "|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r image variant arch digest status total counts gt gf; do
    if grep -q "^$image	$variant	" "$gate/passed.tsv"; then g=pass; else g=FAIL; fi
    echo "| $image | $variant | $arch | $status | $total $( [ "$counts" = '{}' ] || echo "$counts") | $gt ($gf) | $g |"
  done < "$gate/results.tsv"
  echo
  echo "Gate: ECR basic scan COMPLETE with 0 findings at every severity on every architecture. Grype mode: \`$grype_gate\`."
  for f in "$gate"/findings/*.ecr.txt; do
    [ -s "$f" ] || continue
    echo; echo "### ECR findings: $(basename "$f" .ecr.txt)"; echo '```'; sort -u "$f"; echo '```'
  done
  for f in "$gate"/findings/*.grype.txt; do
    [ -s "$f" ] || continue
    echo; echo "<details><summary>Grype: $(basename "$f" .grype.txt) ($(wc -l < "$f" | tr -d ' ') matches)</summary>"; echo; echo '```'
    head -200 "$f"; echo '```'; echo "</details>"
  done
} > "$gate/summary.md"
cat "$gate/summary.md" >&2

[ $all_passed = 1 ]
