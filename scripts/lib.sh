# Shared helpers. Source from scripts: . "$(dirname "$0")/lib.sh"
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck source=/dev/null
. "$ROOT/config.env"
# shellcheck source=/dev/null
. "$ROOT/pins/packages.env"
# shellcheck source=/dev/null
. "$ROOT/pins/tools.env"
set +a
# Local testing: build fewer Node majors than the pins name.
NODE_MAJORS="${NODE_MAJORS_OVERRIDE:-$NODE_MAJORS}"
PLATFORM_NODE_MAJOR="${PLATFORM_NODE_MAJOR_OVERRIDE:-$PLATFORM_NODE_MAJOR}"

# Work directory for downloads, rendered configs and build output. CI sets it
# to a runner temp dir; locally it defaults to ./.work (git-ignored).
WORK="${WORK:-$ROOT/.work}"
mkdir -p "$WORK"

# Run a pinned tool image with the repository and work directory mounted at
# the same paths, so file arguments mean the same thing inside and out.
#   tool <image> [args...]            runs as the calling user
#   TOOL_PRIVILEGED=1 tool ...        runs as root with --privileged (melange)
tool() {
  local image="$1"; shift
  local args=(--rm -v "$ROOT:$ROOT" -w "$PWD")
  case "$WORK" in "$ROOT"/*) ;; *) args+=(-v "$WORK:$WORK");; esac
  if [ "${TOOL_PRIVILEGED:-0}" = 1 ]; then
    args+=(--privileged)
  else
    args+=(--user "$(id -u):$(id -g)" -e HOME="$WORK/home")
    mkdir -p "$WORK/home"
  fi
  local dc="${DOCKER_CONFIG:-$HOME/.docker}"
  if [ -f "$dc/config.json" ]; then args+=(-v "$dc:/run/docker-config:ro" -e DOCKER_CONFIG=/run/docker-config); fi
  for e in ${TOOL_ENV:-}; do args+=(-e "$e"); done
  docker run "${args[@]}" "$image" "$@"
}

# oras with the mounted Docker credentials.
oras() {
  local cfg=(); [ -f "${DOCKER_CONFIG:-$HOME/.docker}/config.json" ] && cfg=(--registry-config /run/docker-config/config.json)
  tool "$ORAS_IMAGE" "$@" ${cfg[@]+"${cfg[@]}"}
}

# "<apk-arch>\t<digest>" for each linux image in an index.
index_platforms() {
  oras manifest fetch "$1" | jq -r '.manifests[] | select(.platform.os=="linux")
    | [(if .platform.architecture=="amd64" then "x86_64" elif .platform.architecture=="arm64" then "aarch64" else .platform.architecture end), .digest] | @tsv'
}

# Attach an SPDX SBOM to an image as an OCI referrer.
attach_sbom() { # ref file
  [ -s "$2" ] || die "missing SBOM $2"
  (cd "$(dirname "$2")" && oras attach --artifact-type application/spdx+json "$1" "$(basename "$2"):application/spdx+json" >/dev/null)
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# apk architecture name -> OCI platform architecture.
oci_arch() { case "$1" in x86_64) echo amd64;; aarch64) echo arm64;; *) die "unknown arch $1";; esac; }

# --- Wolfi index -----------------------------------------------------------

# Download Wolfi's APKINDEX for both architectures (once per run) and build a
# "name version" table of every version present.
wolfi_index() {
  local arch
  for arch in $ARCHES; do
    if [ ! -s "$WORK/wolfi/$arch/versions" ]; then
      mkdir -p "$WORK/wolfi/$arch"
      curl -fsSL --retry 3 "$WOLFI_REPO_URL/$arch/APKINDEX.tar.gz" | tar -xzf - -C "$WORK/wolfi/$arch" APKINDEX
      awk '/^P:/{n=substr($0,3)} /^V:/{print n, substr($0,3)}' "$WORK/wolfi/$arch/APKINDEX" > "$WORK/wolfi/$arch/versions"
    fi
  done
}

# Newest version of a Wolfi package that exists on every architecture in
# $ARCHES. Prints nothing if there is none.
wolfi_newest() {
  local pkg="$1" arch first=1 tmp
  wolfi_index
  tmp="$(mktemp)"
  for arch in $ARCHES; do
    awk -v p="$pkg" '$1==p{print $2}' "$WORK/wolfi/$arch/versions" | sort -u > "$tmp.$arch"
    if [ $first = 1 ]; then cp "$tmp.$arch" "$tmp"; first=0
    else comm -12 "$tmp" "$tmp.$arch" > "$tmp.n"; mv "$tmp.n" "$tmp"; fi
    rm -f "$tmp.$arch"
  done
  sort -V "$tmp" | tail -1
  rm -f "$tmp"
}

# Newest Wolfi "rust-1.N" stream present on every architecture, e.g. "1.100".
wolfi_newest_rust_stream() {
  wolfi_index
  local streams arch
  streams="$(awk '$1 ~ /^rust-1\.[0-9]+$/ {print substr($1,6)}' "$WORK/wolfi/x86_64/versions" | sort -uV)"
  for s in $(echo "$streams" | sort -rV); do
    local ok=1
    for arch in $ARCHES; do
      grep -q "^rust-$s " "$WORK/wolfi/$arch/versions" || ok=0
    done
    [ $ok = 1 ] && { echo "$s"; return; }
  done
}

# --- Pins ------------------------------------------------------------------

# Upstream version string of a package version ("24.22.3-r0" -> "24.22.3").
upstream_of() { echo "${1%-r*}"; }

# Pins for packages built here, as "name=version-rN" lines.
own_pins() {
  local m v e
  for m in $NODE_MAJORS; do
    v="NODE_${m}_VERSION"; e="NODE_${m}_EPOCH"
    for sub in "" -npm -dev; do
      echo "nodejs-$m$sub=${!v}-r${!e}"
    done
  done
  echo "node-docker-entrypoint=$NODE_ENTRYPOINT_VERSION-r$NODE_ENTRYPOINT_EPOCH"
  echo "pnpm=$PNPM_VERSION-r$PNPM_EPOCH"
  echo "codex=$CODEX_VERSION-r$CODEX_EPOCH"
  if [ "$BUN_SOURCE" = forklaunch ]; then echo "bun=$BUN_VERSION-r$BUN_EPOCH"; fi
}

# Version pinned for package $2 in image $1: from our own pins when $3 is
# "@forklaunch", otherwise from pins/<image>.txt (Wolfi).
pin_of() {
  local image="$1" pkg="$2" tag="${3:-}" line
  if [ "$tag" = "@forklaunch" ]; then
    line="$(own_pins | awk -F= -v p="$pkg" '$1==p' || true)"
  else
    line="$(awk -F= -v p="$pkg" '$1==p' "$ROOT/pins/$image.txt" 2>/dev/null || true)"
  fi
  [ -n "$line" ] && echo "${line#*=}"
}

# Rewrite every package entry of a rendered apko config to name=version[@tag]
# from the pins. Fails on a package with no pin.
pin_apko_config() {
  local image="$1" file="$2" out="$3" missing=0 line pkg tag ver
  : > "$out"
  local in_packages=0
  local re_head='^  packages: *$' re_item='^    - ([A-Za-z0-9][A-Za-z0-9._+-]*)(@[a-z]+)? *$' re_indent='^    '
  while IFS= read -r line; do
    if [[ "$line" =~ $re_head ]]; then in_packages=1; echo "$line" >> "$out"; continue; fi
    if [ $in_packages = 1 ] && [[ "$line" =~ $re_item ]]; then
      pkg="${BASH_REMATCH[1]}"; tag="${BASH_REMATCH[2]}"
      ver="$(pin_of "$image" "$pkg" "$tag" || true)"
      if [ -z "$ver" ]; then log "no pin for $pkg (image $image)"; missing=1; fi
      echo "    - $pkg=$ver$tag" >> "$out"
      continue
    fi
    if [ $in_packages = 1 ] && [[ ! "$line" =~ $re_indent ]]; then in_packages=0; fi
    echo "$line" >> "$out"
  done < "$file"
  [ $missing = 0 ] || die "unpinned packages in $file"
}

# --- Images and variants ---------------------------------------------------

rust_stream() { sed -n 's/^rust-\(1\.[0-9]*\)=.*/\1/p' "$ROOT/pins/rust.txt"; }
rust_version() { upstream_of "$(pin_of rust "rust-$(rust_stream)")"; }
bun_version() {
  if [ "$BUN_SOURCE" = forklaunch ]; then echo "$BUN_VERSION"; else upstream_of "$(pin_of bun bun)"; fi
}
bun_package() { if [ "$BUN_SOURCE" = forklaunch ]; then echo bun@forklaunch; else echo bun; fi; }

# Variants of an image, one per line: "<variant> <template>".
variants() {
  case "$1" in
    node)
      for m in $NODE_MAJORS; do echo "$m runtime.apko.yaml.in"; echo "$m-dev dev.apko.yaml.in"; done ;;
    bun|rust)
      echo "runtime runtime.apko.yaml.in"; echo "dev dev.apko.yaml.in" ;;
    platform-toolchain)
      echo "latest image.apko.yaml.in" ;;
    *) die "unknown image $1" ;;
  esac
}

# Template variables of a variant, as KEY=value lines.
variant_vars() {
  local image="$1" variant="$2" major v
  case "$image" in
    node)
      major="${variant%%-*}"; v="NODE_${major}_VERSION"
      echo "NODE_MAJOR=$major"; echo "NODE_VERSION=${!v}"; echo "PNPM_VERSION=$PNPM_VERSION" ;;
    bun)
      echo "BUN_VERSION=$(bun_version)"; echo "BUN_PACKAGE=$(bun_package)" ;;
    rust)
      echo "RUST_MINOR=$(rust_stream)"; echo "RUST_VERSION=$(rust_version)" ;;
    platform-toolchain)
      v="NODE_${PLATFORM_NODE_MAJOR}_VERSION"
      echo "NODE_MAJOR=$PLATFORM_NODE_MAJOR"; echo "NODE_VERSION=${!v}"
      echo "PNPM_VERSION=$PNPM_VERSION"; echo "BUN_VERSION=$(bun_version)"; echo "BUN_PACKAGE=$(bun_package)"
      echo "RUST_MINOR=$(sed -n 's/^rust-\(1\.[0-9]*\)=.*/\1/p' "$ROOT/pins/platform-toolchain.txt")"
      echo "RUST_VERSION=$(upstream_of "$(sed -n 's/^rust-1\.[0-9]*=\(.*\)/\1/p' "$ROOT/pins/platform-toolchain.txt")")" ;;
  esac
}

# Public tags for a variant. $3 is the date stamp (YYYYMMDD).
variant_tags() {
  local image="$1" variant="$2" date="$3" ver minor suffix=""
  case "$image" in
    node)
      local major="${variant%%-*}" v="NODE_${variant%%-*}_VERSION"
      ver="${!v}"; minor="${ver%.*}"
      [ "$variant" != "$major" ] && suffix="-dev"
      echo "$major$suffix $minor$suffix $ver$suffix $major$suffix-$date" ;;
    bun)
      ver="$(bun_version)"; minor="${ver%.*}"
      if [ "$variant" = dev ]; then echo "dev 1-dev $minor-dev $ver-dev 1-dev-$date"
      else echo "latest 1 $minor $ver 1-$date"; fi ;;
    rust)
      ver="$(rust_version)"; minor="${ver%.*}"
      if [ "$variant" = dev ]; then echo "dev $minor-dev $ver-dev dev-$date"
      else echo "latest $date"; fi ;;
    platform-toolchain)
      echo "latest $date" ;;
  esac
}

# Render, pin and write the apko config for one variant. Prints its path.
# APK_REPO_URL / APK_KEY can be overridden for local builds.
render_variant() {
  local image="$1" variant="$2" template="$3" dir="$WORK/apko/$image"
  mkdir -p "$dir"
  local vars=()
  while IFS= read -r kv; do vars+=("$kv"); done < <(variant_vars "$image" "$variant")
  "$ROOT/scripts/render.sh" "$ROOT/images/$image/$template" "$dir/$variant.unpinned.yaml" \
    "WOLFI_REPO_URL=$WOLFI_REPO_URL" "WOLFI_KEY=$WOLFI_KEY_URL" \
    "APK_REPO_URL=${APK_REPO_OVERRIDE:-$APK_REPO_URL}" "APK_KEY=${APK_KEY_PATH:-$ROOT/keys/$APK_KEY_NAME}" \
    "GIT_SHA=${GITHUB_SHA:-$(git -C "$ROOT" rev-parse --verify -q HEAD 2>/dev/null || echo unknown)}" \
    "${vars[@]}" || die "render failed for $image:$variant"
  pin_apko_config "$image" "$dir/$variant.unpinned.yaml" "$dir/$variant.yaml" || die "pinning failed for $image:$variant"
  echo "$dir/$variant.yaml"
}
