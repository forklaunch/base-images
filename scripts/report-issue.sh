#!/usr/bin/env bash
# Keep one GitHub issue (label "nightly-gate") in step with the nightly run:
# open or refresh it when an image was held back or a job failed, close it
# when everything passed and was published.
#
# Usage: scripts/report-issue.sh <results-dir>
#   JOB_RESULTS  "job=result ..." from the workflow
#   RUN_URL      link to the run
set -euo pipefail
. "$(dirname "$0")/lib.sh"

res="$1"
label="nightly-gate"
title="Nightly gate: images held back"
cands="$res/candidates/candidates.tsv"
passed="$res/gate/passed.tsv"
published="$res/published/published.tsv"

failed_jobs="$(tr ' ' '\n' <<<"${JOB_RESULTS:-}" | grep -E '=(failure|cancelled)$' || true)"
n_cands="$( [ -f "$cands" ] && wc -l < "$cands" | tr -d ' ' || echo 0)"
n_pub="$( [ -f "$published" ] && wc -l < "$published" | tr -d ' ' || echo 0)"

body="$(mktemp)"
{
  echo "Run: ${RUN_URL:-local}"
  echo
  echo "Jobs: \`${JOB_RESULTS:-unknown}\`"
  echo
  echo "Candidates: $n_cands, published: $n_pub."
  if [ -f "$cands" ]; then
    echo; echo "Held back:"; echo
    while IFS=$'\t' read -r image variant ref; do
      if ! { [ -f "$published" ] && awk -F'\t' -v i="$image" -v v="$variant" '$1==i&&$2==v{f=1} END{exit !f}' "$published"; }; then
        why="smoke test"
        if ! { [ -f "$passed" ] && awk -F'\t' -v i="$image" -v v="$variant" '$1==i&&$2==v{f=1} END{exit !f}' "$passed"; }; then why="scan gate"; fi
        echo "- \`$image:$variant\` ($why) \`$ref\`"
      fi
    done < "$cands"
  fi
  for f in "$res"/smoke-*/*.tsv; do
    [ -f "$f" ] || continue
    echo; echo "Smoke ($(basename "$f" .tsv)):"; echo '```'; cat "$f"; echo '```'
  done
  if [ -f "$res/gate/summary.md" ]; then echo; cat "$res/gate/summary.md"; fi
} > "$body"
# GitHub caps issue bodies at 65536 characters.
head -c 60000 "$body" > "$body.cut"

gh label create "$label" --color B60205 --description "Nightly base-image gate held images back" --force >/dev/null 2>&1 || true
existing="$(gh issue list --label "$label" --state open --json number -q '.[0].number' || true)"

if [ -z "$failed_jobs" ] && [ "$n_cands" -gt 0 ] && [ "$n_cands" = "$n_pub" ]; then
  if [ -n "$existing" ]; then
    gh issue close "$existing" --comment "Every image passed and was published in ${RUN_URL:-this run}."
  fi
  log "all candidates published; nothing to report"
  exit 0
fi
if [ "${PUBLISH_DISABLED:-0}" = 1 ] && [ -z "$failed_jobs" ]; then log "publish disabled for this run"; exit 0; fi

if [ -n "$existing" ]; then
  gh issue edit "$existing" --body-file "$body.cut" >/dev/null
  gh issue comment "$existing" --body "Still failing in ${RUN_URL:-this run} (body refreshed)." >/dev/null
  log "refreshed issue #$existing"
else
  gh issue create --title "$title" --label "$label" --body-file "$body.cut"
fi
rm -f "$body" "$body.cut"
