#!/usr/bin/env bash
# After a publish: commit the pins that the published images were built from,
# with a CHANGELOG.md entry, back to main. If the push is refused (branch
# protection), push a branch and open a pull request instead.
#
# Pin files of an image are committed only if every variant of that image was
# published; pins/packages.env and pins/tools.env when any image was.
#
# Usage: scripts/commit-pins.sh <results-dir>
#   <results-dir>/pins/       refreshed pins (artifact "pins")
#   <results-dir>/candidates/ lock files under locks/<image>/ (artifact "candidates")
#   <results-dir>/published/published.tsv
set -euo pipefail
. "$(dirname "$0")/lib.sh"

res="$1"
published="$res/published/published.tsv"
[ -s "$published" ] || { log "nothing was published"; exit 0; }

cp "$res/pins/packages.env" "$res/pins/tools.env" "$ROOT/pins/"
done_images=(); held=()
for image in $IMAGES; do
  want="$(variants "$image" | wc -l | tr -d ' ')"
  got="$(awk -F'\t' -v i="$image" '$1==i' "$published" | wc -l | tr -d ' ')"
  if [ "$got" = "$want" ]; then
    cp "$res/pins/$image.txt" "$ROOT/pins/$image.txt"
    if [ -d "$res/candidates/locks/$image" ]; then
      mkdir -p "$ROOT/images/$image/locks"
      cp "$res/candidates/locks/$image/"*.json "$ROOT/images/$image/locks/"
    fi
    done_images+=("$image")
  else
    held+=("$image ($got of $want variants published)")
  fi
done

date="$(date -u +%Y-%m-%d)"
entry="$(mktemp)"
{
  echo "## $date"
  echo
  echo "Run: ${RUN_URL:-local}"
  echo
  echo "Published:"
  echo
  while IFS=$'\t' read -r image variant ref tags; do
    echo "- \`$image:$variant\` \`$ref\` (tags: $tags)"
  done < "$published"
  if [ ${#held[@]} -gt 0 ]; then
    echo; echo "Held back (pins not committed): ${held[*]}"
  fi
  if [ -s "$res/pins/CHANGES.md" ]; then
    echo; echo "Pin changes:"; echo; cat "$res/pins/CHANGES.md"
  fi
  echo
} > "$entry"
if [ -f "$ROOT/CHANGELOG.md" ]; then
  { head -2 "$ROOT/CHANGELOG.md"; cat "$entry"; tail -n +3 "$ROOT/CHANGELOG.md"; } > "$entry.full"
else
  { echo "# Changelog"; echo; cat "$entry"; } > "$entry.full"
fi
mv "$entry.full" "$ROOT/CHANGELOG.md"; rm -f "$entry"

cd "$ROOT"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add pins images/*/locks CHANGELOG.md
if git diff --cached --quiet; then log "no pin changes to commit"; exit 0; fi
summary="$([ -s "$res/pins/CHANGES.md" ] && sed 's/^- //' "$res/pins/CHANGES.md" | head -5 | paste -sd ';' - || echo "rebuild")"
git commit -q -m "nightly $date: ${done_images[*]:-no images}" -m "$summary" -m "Run: ${RUN_URL:-local}"
if git push -q origin HEAD:main 2>/dev/null; then
  log "pushed pins to main"
else
  branch="nightly/pins-$date-${GITHUB_RUN_ID:-local}"
  git push -q origin "HEAD:refs/heads/$branch"
  gh pr create --base main --head "$branch" --title "nightly $date: pins for published images" \
    --body "$(cat CHANGELOG.md | sed -n '3,/^## /p' | sed '$d')"
  log "main is protected; opened a pull request from $branch"
fi
