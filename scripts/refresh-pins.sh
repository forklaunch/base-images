#!/usr/bin/env bash
# Move every pin to the newest upstream release:
#   - Node: newest patch of each major in NODE_MAJORS (nodejs.org index), with
#     SHASUMS256.txt signature-checked against keys/nodejs-release-keys.kbx
#   - Bun: Wolfi's package if Wolfi carries the newest upstream release,
#     otherwise our repackaging of the official release (BUN_SOURCE)
#   - Rust: newest rust-1.N stream Wolfi builds on both architectures
#   - every other Wolfi package in pins/<image>.txt: newest build present on
#     both architectures
#   - build tool images in pins/tools.env: current :latest digest
#   - Pulumi: newest release, sha256 from its checksums file checked against
#     GitHub's asset digest
#   - pnpm: newest stable release (no higher than the registry's `latest` tag)
#     that is at least MIN_RELEASE_AGE_MINUTES old; sha512 of the wrapper and
#     of both native-binary tarballs from the registry, checked against npm's
#     signed publish attestation and against the downloaded bytes
# The docker-node entrypoint is pinned by hand and not touched.
#
# Writes a short changelog of what moved to $WORK/pins-changes.md (empty if
# nothing did). Usage: scripts/refresh-pins.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

changes="$WORK/pins-changes.md"
: > "$changes"
note() { echo "- $*" >> "$changes"; log "$*"; }

set_env() { # set_env <file> <KEY> <value>
  local file="$1" key="$2" value="$3" old
  old="$(sed -n "s/^$key=//p" "$file")"
  [ "$old" = "$value" ] && return 0
  if grep -q "^$key=" "$file"; then
    sed -i.bak "s|^$key=.*|$key=$value|" "$file" && rm -f "$file.bak"
  else
    echo "$key=$value" >> "$file"
  fi
}

# GitHub API calls are authenticated when a token is available (rate limits).
gh_api() { if [ -n "${GH_TOKEN:-}" ]; then curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" "$@"; else curl -fsSL --retry 3 "$@"; fi; }

# --- Node -------------------------------------------------------------------
pk="$ROOT/pins/packages.env"
index="$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json)"
for major in $NODE_MAJORS; do
  latest="$(jq -r --arg m "v$major." '[.[] | select(.version | startswith($m))][0].version' <<<"$index")"
  [ -n "$latest" ] && [ "$latest" != null ] || die "no Node $major release in the nodejs.org index"
  latest="${latest#v}"
  cur_var="NODE_${major}_VERSION"; current="${!cur_var}"
  sha="$("$ROOT/scripts/verify-node.sh" "$latest")"
  if [ "$latest" != "$current" ]; then
    note "nodejs-$major: $current -> $latest"
    set_env "$pk" "NODE_${major}_VERSION" "$latest"
    set_env "$pk" "NODE_${major}_SHA256" "$sha"
    set_env "$pk" "NODE_${major}_EPOCH" 0
  else
    sha_var="NODE_${major}_SHA256"
    [ "$sha" = "${!sha_var}" ] || die "Node $latest: signed SHASUMS256.txt says $sha, pins say ${!sha_var}"
  fi
done

# --- Wolfi package pins -------------------------------------------------------
rust_stream_new="$(wolfi_newest_rust_stream)"
[ -n "$rust_stream_new" ] || die "no rust-1.N stream found in Wolfi"
for pins in "$ROOT"/pins/*.txt; do
  image="$(basename "$pins" .txt)"
  tmp="$(mktemp)"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) echo "$line" >> "$tmp"; continue;; esac
    pkg="${line%%=*}"; old="${line#*=}"
    if [[ "$pkg" =~ ^rust-1\.[0-9]+$ ]]; then pkg="rust-$rust_stream_new"; fi
    new="$(wolfi_newest "$pkg")"
    [ -n "$new" ] || die "$image: $pkg has no build present on all of: $ARCHES"
    if [ "${line%%=*}=$old" != "$pkg=$new" ]; then note "$image: ${line%%=*} $old -> $pkg $new"; fi
    echo "$pkg=$new" >> "$tmp"
  done < "$pins"
  mv "$tmp" "$pins"
done

# --- Bun ----------------------------------------------------------------------
bun_upstream="$(gh_api https://api.github.com/repos/oven-sh/bun/releases/latest | jq -r .tag_name)"
bun_upstream="${bun_upstream#bun-v}"
bun_wolfi="$(upstream_of "$(pin_of bun bun)")"
if [ "$bun_wolfi" = "$bun_upstream" ]; then
  if [ "$BUN_SOURCE" != wolfi ]; then note "bun: back to Wolfi's package ($bun_wolfi)"; fi
  set_env "$pk" BUN_SOURCE wolfi
  set_env "$pk" BUN_VERSION "$bun_upstream"
else
  log "Wolfi bun is $bun_wolfi, upstream is $bun_upstream: using our repackaged release"
  shas="$(curl -fsSL --retry 3 "https://github.com/oven-sh/bun/releases/download/bun-v$bun_upstream/SHASUMS256.txt")"
  assets="$(gh_api "https://api.github.com/repos/oven-sh/bun/releases/tags/bun-v$bun_upstream")"
  for pair in x86_64:bun-linux-x64.zip aarch64:bun-linux-aarch64.zip; do
    arch="${pair%%:*}"; asset="${pair#*:}"
    sum="$(awk -v a="$asset" '$2==a{print $1}' <<<"$shas")"
    gh_sum="$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .digest' <<<"$assets")"
    [ -n "$sum" ] && [ "sha256:$sum" = "$gh_sum" ] || die "bun $bun_upstream $asset: SHASUMS256.txt ($sum) and GitHub digest ($gh_sum) disagree"
    set_env "$pk" "BUN_SHA256_$(echo "$arch" | tr a-z A-Z)" "$sum"
  done
  if [ "$BUN_SOURCE" != forklaunch ] || [ "$BUN_VERSION" != "$bun_upstream" ]; then
    note "bun: $BUN_VERSION -> $bun_upstream (repackaged official release; Wolfi has $bun_wolfi)"
    set_env "$pk" BUN_EPOCH 0
  fi
  set_env "$pk" BUN_SOURCE forklaunch
  set_env "$pk" BUN_VERSION "$bun_upstream"
fi

# --- Pulumi ---------------------------------------------------------------------
pulumi_latest="$(gh_api https://api.github.com/repos/pulumi/pulumi/releases/latest | jq -r .tag_name)"
pulumi_latest="${pulumi_latest#v}"
if [ "$pulumi_latest" != "$PULUMI_VERSION" ]; then
  sums="$(curl -fsSL --retry 3 "https://github.com/pulumi/pulumi/releases/download/v$pulumi_latest/pulumi-$pulumi_latest-checksums.txt")"
  assets="$(gh_api "https://api.github.com/repos/pulumi/pulumi/releases/tags/v$pulumi_latest")"
  for pair in X86_64:linux-x64 AARCH64:linux-arm64; do
    asset="pulumi-v$pulumi_latest-${pair#*:}.tar.gz"
    sum="$(awk -v a="$asset" '$2==a{print $1}' <<<"$sums")"
    gh_sum="$(jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .digest' <<<"$assets")"
    [ -n "$sum" ] && [ "sha256:$sum" = "$gh_sum" ] || die "pulumi $pulumi_latest $asset: checksums file ($sum) and GitHub digest ($gh_sum) disagree"
    set_env "$pk" "PULUMI_SHA256_${pair%%:*}" "$sum"
  done
  note "pulumi: $PULUMI_VERSION -> $pulumi_latest"
  set_env "$pk" PULUMI_VERSION "$pulumi_latest"
  set_env "$pk" PULUMI_EPOCH 0
fi

# --- pnpm -----------------------------------------------------------------------
# The newest stable release that is no higher than the registry's `latest` tag
# (pnpm publishes to `next` first) and at least MIN_RELEASE_AGE_MINUTES old, the
# same window the ForkLaunch app workspaces give pnpm (minimumReleaseAge: 1440).
# Never moves backwards. Since pnpm 12 the program is a native binary in
# @pnpm/exe.linux-<cpu>, so three tarballs are pinned (packages/pnpm.yaml.in).
npm_hex() { # sha512-<base64> -> hex
  case "$1" in sha512-?*) ;; *) return 1;; esac
  printf '%s' "${1#sha512-}" | base64 -d | od -An -v -tx1 | tr -d ' \n'
}
# npm_checked_sha512 <package> <version>: the tarball's sha512 (hex), only when
# the registry's integrity value, npm's signed publish attestation and the
# downloaded tarball all agree.
npm_checked_sha512() {
  local pkg="$1" ver="$2" meta hex att att_hex tgz got
  meta="$(curl -fsSL --retry 3 "https://registry.npmjs.org/$pkg/$ver")" || die "$pkg@$ver: not in the npm registry"
  hex="$(npm_hex "$(jq -r .dist.integrity <<<"$meta")")" || die "$pkg@$ver: registry integrity is not sha512"
  # The attestations endpoint now and then answers with a body that has no
  # publish attestation in it; ask again before treating that as a mismatch.
  local try
  for try in 1 2 3 4; do
    att="$(curl -fsSL --retry 3 "https://registry.npmjs.org/-/npm/v1/attestations/$pkg@$ver")" || die "$pkg@$ver: no npm publish attestation"
    att_hex="$(jq -r --arg p "pkg:npm/${pkg/#@/%40}@$ver" '[.attestations[]
        | select(.predicateType == "https://github.com/npm/attestation/tree/main/specs/publish/v0.1")
        | .bundle.dsseEnvelope.payload | @base64d | fromjson | .subject[]
        | select(.name == $p) | .digest.sha512][0] // ""' <<<"$att")"
    [ "$att_hex" = "$hex" ] && break
    [ "$try" -lt 4 ] && { log "$pkg@$ver: attestation read $try did not match, retrying"; sleep $((try*10)); }
  done
  [ -n "$hex" ] && [ "$att_hex" = "$hex" ] || die "$pkg@$ver: registry integrity ($hex) and publish attestation ($att_hex) disagree"
  tgz="$(mktemp)"
  curl -fsSL --retry 3 -o "$tgz" "$(jq -r .dist.tarball <<<"$meta")" || { rm -f "$tgz"; die "$pkg@$ver: tarball download failed"; }
  got="$( { sha512sum "$tgz" 2>/dev/null || shasum -a 512 "$tgz"; } | awk '{print $1}')"
  rm -f "$tgz"
  [ "$got" = "$hex" ] || die "$pkg@$ver: downloaded tarball hashes to $got, registry says $hex"
  echo "$hex"
}
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }

pnpm_doc="$(curl -fsSL --retry 3 https://registry.npmjs.org/pnpm)"
pnpm_tag="$(jq -r '."dist-tags".latest' <<<"$pnpm_doc")"
pnpm_cutoff=$(( $(date -u +%s) - MIN_RELEASE_AGE_MINUTES * 60 ))
pnpm_new=""
while IFS= read -r v; do
  ver_le "$v" "$pnpm_tag" && pnpm_new="$v"
done < <(jq -r --argjson cutoff "$pnpm_cutoff" '.time | to_entries[]
    | select(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | select((.value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) <= $cutoff)
    | .key' <<<"$pnpm_doc" | sort -V)
[ -n "$pnpm_new" ] || die "pnpm: no stable release at least $MIN_RELEASE_AGE_MINUTES minutes old"
if ! ver_le "$PNPM_VERSION" "$pnpm_new"; then
  log "pnpm: newest eligible release $pnpm_new is older than the pin $PNPM_VERSION; keeping the pin"
  pnpm_new="$PNPM_VERSION"
fi
[ "$pnpm_new" = "$pnpm_tag" ] || log "pnpm: registry latest is $pnpm_tag; newest release past the ${MIN_RELEASE_AGE_MINUTES}-minute age floor is $pnpm_new"
pnpm_sha="$(npm_checked_sha512 pnpm "$pnpm_new")"
pnpm_x64="$(npm_checked_sha512 @pnpm/exe.linux-x64 "$pnpm_new")"
pnpm_arm64="$(npm_checked_sha512 @pnpm/exe.linux-arm64 "$pnpm_new")"
if [ "$pnpm_new" != "$PNPM_VERSION" ]; then
  note "pnpm: $PNPM_VERSION -> $pnpm_new"
  set_env "$pk" PNPM_VERSION "$pnpm_new"
  set_env "$pk" PNPM_EPOCH 0
elif [ "$pnpm_sha" != "$PNPM_SHA512" ] || [ "$pnpm_x64" != "${PNPM_EXE_SHA512_X86_64:-}" ] || [ "$pnpm_arm64" != "${PNPM_EXE_SHA512_AARCH64:-}" ]; then
  die "pnpm $pnpm_new: registry checksums differ from the pins (npm tarballs are immutable; check pins/packages.env)"
fi
set_env "$pk" PNPM_SHA512 "$pnpm_sha"
set_env "$pk" PNPM_EXE_SHA512_X86_64 "$pnpm_x64"
set_env "$pk" PNPM_EXE_SHA512_AARCH64 "$pnpm_arm64"

# --- Tool images ----------------------------------------------------------------
tp="$ROOT/pins/tools.env"
for key in MELANGE_IMAGE APKO_IMAGE GRYPE_IMAGE; do
  ref="${!key}"; repo="${ref%@*}"
  digest="$(docker buildx imagetools inspect "$repo:latest" --format '{{json .Manifest.Digest}}' | tr -d '"')"
  [ -n "$digest" ] || die "could not resolve $repo:latest"
  if [ "$repo@$digest" != "$ref" ]; then
    note "tools: ${repo##*/} ${ref#*@} -> $digest"
    set_env "$tp" "$key" "$repo@$digest"
  fi
done

# oras: newest release tag, by digest.
oras_tag="$(gh_api https://api.github.com/repos/oras-project/oras/releases/latest | jq -r .tag_name)"
oras_digest="$(docker buildx imagetools inspect "ghcr.io/oras-project/oras:$oras_tag" --format '{{json .Manifest.Digest}}' | tr -d '"')"
[ -n "$oras_digest" ] || die "could not resolve ghcr.io/oras-project/oras:$oras_tag"
if [ "ghcr.io/oras-project/oras:$oras_tag@$oras_digest" != "$ORAS_IMAGE" ]; then
  note "tools: oras ${ORAS_IMAGE#*:} -> $oras_tag@$oras_digest"
  set_env "$tp" ORAS_IMAGE "ghcr.io/oras-project/oras:$oras_tag@$oras_digest"
fi

if [ -s "$changes" ]; then log "pins changed:"; cat "$changes" >&2; else log "pins unchanged"; fi
