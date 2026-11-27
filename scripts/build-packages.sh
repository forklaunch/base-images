#!/usr/bin/env bash
# Build this repository's packages for one architecture with melange.
# scripts/publish-packages.sh then uploads them with a merged, signed APKINDEX.
#
# A package is built only when its exact file (<name>-<version>-r<epoch>.apk)
# is not in the repository yet, so a Node build happens once per release.
#
# Usage: scripts/build-packages.sh <arch> [package...]
#   package       nodejs-24, nodejs-26, node-docker-entrypoint, pnpm, codex, bun (default: all)
#   SIGNING_KEY   path to the melange private key (required)
#   FORCE=1       rebuild even if the package is already published
#   LOCAL_INDEX=1 also write a signed APKINDEX of everything in $WORK/packages/<arch>
#                 (for local apko builds with APK_REPO_OVERRIDE)
# Built files are listed in $WORK/packages/<arch>/built.txt.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

arch="$1"; shift
[ -n "${SIGNING_KEY:-}" ] && [ -f "$SIGNING_KEY" ] || die "SIGNING_KEY must point at the melange private key"

out="$WORK/packages"
gen="$WORK/recipes"
mkdir -p "$out/$arch" "$gen" "$WORK/melange-cache"
key_dir="$WORK/keys"
mkdir -p "$key_dir"
# melange names the index signature after the key file, so the private key
# must carry the public key's name minus ".pub".
cp "$SIGNING_KEY" "$key_dir/${APK_KEY_NAME%.pub}"
chmod 600 "$key_dir/${APK_KEY_NAME%.pub}"
trap 'rm -f "$key_dir/${APK_KEY_NAME%.pub}"' EXIT

published() { curl -fsSI --retry 2 "$APK_REPO_URL/$arch/$1" >/dev/null 2>&1; }

all=()
for m in $NODE_MAJORS; do all+=("nodejs-$m"); done
all+=(node-docker-entrypoint pnpm codex)
[ "$BUN_SOURCE" = forklaunch ] && all+=(bun)
targets=("$@"); [ ${#targets[@]} -gt 0 ] || targets=("${all[@]}")

built=()
for name in "${targets[@]}"; do
  case "$name" in
    nodejs-*)
      m="${name#nodejs-}"; v="NODE_${m}_VERSION"; s="NODE_${m}_SHA256"; e="NODE_${m}_EPOCH"
      version="${!v}"; epoch="${!e}"; template=nodejs.yaml.in
      vars=("NODE_MAJOR=$m" "NODE_VERSION=$version" "NODE_SHA256=${!s}" "NODE_EPOCH=$epoch") ;;
    node-docker-entrypoint) version="$NODE_ENTRYPOINT_VERSION"; epoch="$NODE_ENTRYPOINT_EPOCH"
      template=node-docker-entrypoint.yaml.in; vars=("$ROOT/pins/packages.env") ;;
    pnpm) version="$PNPM_VERSION"; epoch="$PNPM_EPOCH"; template=pnpm.yaml.in; vars=("$ROOT/pins/packages.env") ;;
    codex) version="$CODEX_VERSION"; epoch="$CODEX_EPOCH"; template=codex.yaml.in; vars=("$ROOT/pins/packages.env") ;;
    bun)
      [ "$BUN_SOURCE" = forklaunch ] || { log "bun comes from Wolfi (BUN_SOURCE=wolfi); skipping"; continue; }
      version="$BUN_VERSION"; epoch="$BUN_EPOCH"; template=bun.yaml.in; vars=("$ROOT/pins/packages.env") ;;
    *) die "unknown package $name" ;;
  esac
  file="$name-$version-r$epoch.apk"
  if [ "${FORCE:-0}" != 1 ] && published "$file"; then
    log "$arch: $file already published"
    continue
  fi
  if [[ "$name" == nodejs-* ]]; then
    # Re-check the signed checksum list right before building.
    sha="$("$ROOT/scripts/verify-node.sh" "$version")"
    [ "$sha" = "${!s}" ] || die "$name: signed SHASUMS256.txt says $sha, pins say ${!s}"
  fi
  "$ROOT/scripts/render.sh" "$ROOT/packages/$template" "$gen/$name.yaml" "${vars[@]}"
  log "$arch: building $file"
  (cd "$WORK" && TOOL_PRIVILEGED=1 tool "$MELANGE_IMAGE" build "$gen/$name.yaml" \
      --arch "$arch" \
      --signing-key "$key_dir/${APK_KEY_NAME%.pub}" \
      --repository-append "$WOLFI_REPO_URL" \
      --keyring-append "$WOLFI_KEY_URL" \
      --namespace forklaunch \
      --license Apache-2.0 \
      --git-repo-url https://github.com/forklaunch/base-images \
      --generate-index=false \
      --out-dir "$out" \
      --cache-dir "$WORK/melange-cache" \
      --workspace-dir "$WORK/melange-workspace-$name")
  rm -rf "$WORK/melange-workspace-$name"
  [ -f "$out/$arch/$file" ] || die "melange did not produce $out/$arch/$file"
  # The package and its subpackages (nodejs-24-npm, -dev, ...).
  for f in "$out/$arch/$name"-*"$version-r$epoch.apk"; do built+=("$(basename "$f")"); done
done

touch "$out/$arch/built.txt"
for f in "${built[@]+"${built[@]}"}"; do echo "$f" >> "$out/$arch/built.txt"; done
log "$arch: built ${built[*]+"${built[*]}"}"
if [ "${LOCAL_INDEX:-0}" = 1 ]; then
  (cd "$WORK" && TOOL_PRIVILEGED=1 tool "$MELANGE_IMAGE" index --arch "$arch" \
     --signing-key "$key_dir/${APK_KEY_NAME%.pub}" --output "$out/$arch/APKINDEX.tar.gz" "$out/$arch"/*.apk)
fi
