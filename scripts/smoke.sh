#!/usr/bin/env bash
# Smoke-test candidate images on this machine's architecture.
#
# Reads "<image> <variant> <ref>" lines from a candidates file (default
# $WORK/candidates.tsv) and runs each variant's checks with
# `docker run --platform linux/<arch>`. Results go to $WORK/smoke/<arch>.tsv
# as "<image> <variant> <arch> pass|fail".
#
# Usage: scripts/smoke.sh <arch> [candidates-file]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

arch="$1"; list="${2:-$WORK/candidates.tsv}"
platform="linux/$(oci_arch "$arch")"
out="$WORK/smoke"; mkdir -p "$out"
results="$out/$arch.tsv"; : > "$results"
scratch="$WORK/smoke-work-$arch"; rm -rf "$scratch"; mkdir -p "$scratch"

ref_of() { awk -F'\t' -v i="$1" -v v="$2" '$1==i && $2==v {print $3}' "$list" | head -1; }
run() { docker run --rm --platform "$platform" "$@"; }
# Checks never abort the run: a failed check sets FAILED and the next one runs.
FAILED=0
fail() { log "  FAIL $*"; FAILED=1; }
expect() { # expect <description> <expected> <actual>
  if [ "$2" = "$3" ]; then log "  ok   $1: $3"; else fail "$1: expected '$2', got '$3'"; fi
}
check() { # check <description> <command...>
  if "${@:2}"; then log "  ok   $1"; else fail "$1"; fi
}

test_node() { # ref major dev?
  local ref="$1" major="$2" dev="$3" v="NODE_${2}_VERSION"
  local want="${!v}"
  expect "node --version" "v$want" "$(run "$ref" node --version)"
  expect "node -e (via entrypoint)" "ok $want" "$(run "$ref" -e 'console.log("ok", process.versions.node)')"
  expect "NODE_VERSION env" "$want" "$(run --entrypoint /bin/sh "$ref" -c 'echo $NODE_VERSION')"
  expect "node user" "node 1000:1000 /home/node" "$(run --entrypoint /bin/sh "$ref" -c 'echo "$(id -un node) $(id -u node):$(id -g node) $(awk -F: "\$1==\"node\"{print \$6}" /etc/passwd)"')"
  expect "apk package" "nodejs-$major-$want" "$(run --entrypoint /bin/sh "$ref" -c "apk info -e nodejs-$major >/dev/null && apk info nodejs-$major 2>/dev/null | head -1 | sed 's/-r[0-9]* description:\$//; s/ description:\$//'")"
  expect "TLS to nodejs.org" "200" "$(run "$ref" node -e 'fetch("https://nodejs.org/dist/index.json").then(r=>console.log(r.status)).catch(e=>{console.log(String(e));process.exit(1)})')"
  check "curl" run --entrypoint /bin/sh "$ref" -c 'curl --version | head -1 >&2'
  if [ "$dev" = 1 ]; then
    expect "default user" "root" "$(run --entrypoint /bin/sh "$ref" -c 'id -un')"
    expect "pnpm --version" "$PNPM_VERSION" "$(run --entrypoint pnpm "$ref" --version)"
    check "npm, python3, g++, make, git" run --entrypoint /bin/sh "$ref" -c '{ npm --version && python3 --version && g++ --version | head -1 && make --version | head -1 && git --version; } >&2'
    # A native addon, built against the packaged headers (no header download).
    mkdir -p "$scratch/addon-$major"
    cat > "$scratch/addon-$major/binding.gyp" <<'EOF'
{ "targets": [ { "target_name": "hello", "sources": [ "hello.cc" ] } ] }
EOF
    cat > "$scratch/addon-$major/hello.cc" <<'EOF'
#include <node_api.h>
static napi_value Hello(napi_env env, napi_callback_info info) {
  napi_value s; napi_create_string_utf8(env, "addon ok", NAPI_AUTO_LENGTH, &s); return s;
}
static napi_value Init(napi_env env, napi_value exports) {
  napi_value fn; napi_create_function(env, nullptr, 0, Hello, nullptr, &fn);
  napi_set_named_property(env, exports, "hello", fn); return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
EOF
    expect "native addon via node-gyp" "addon ok" "$(run -v "$scratch/addon-$major:/src" -w /src --entrypoint /bin/sh "$ref" -c \
      'node /usr/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js rebuild >/tmp/gyp.log 2>&1 || { cat /tmp/gyp.log >&2; exit 1; }; node -e "console.log(require(\"./build/Release/hello.node\").hello())"; rm -rf build')"
  else
    expect "default user" "node" "$(run --entrypoint /bin/sh "$ref" -c 'id -un')"
  fi
}

test_bun() { # ref dev?
  local ref="$1" dev="$2" want; want="$(bun_version)"
  expect "bun -e" "$want" "$(run "$ref" -e 'console.log(Bun.version)')"
  expect "bunx" "$want" "$(run --entrypoint bunx "$ref" --bun bun --version)"
  expect "bun user" "bun 1000:1000 /home/bun" "$(run --entrypoint /bin/sh "$ref" -c 'echo "$(id -un bun) $(id -u bun):$(id -g bun) $(awk -F: "\$1==\"bun\"{print \$6}" /etc/passwd)"')"
  expect "TLS" "200" "$(run "$ref" -e 'const r = await fetch("https://bun.sh"); console.log(r.status)')"
  if [ "$dev" = 1 ]; then
    expect "default user" "root" "$(run --entrypoint /bin/sh "$ref" -c 'id -un')"
    check "git, python3, g++, make" run --entrypoint /bin/sh "$ref" -c '{ git --version && python3 --version && g++ --version | head -1 && make --version | head -1; } >&2'
  else
    expect "default user" "bun" "$(run --entrypoint /bin/sh "$ref" -c 'id -un')"
  fi
}

test_rust() { # runtime-ref dev-ref
  local rt="$1" dev="$2" want; want="$(rust_version)"
  expect "rustc --version" "rustc $want" "$(run "$dev" rustc --version | cut -d' ' -f1-2)"
  check "cargo, openssl pc, cmake, perl, gcc" run "$dev" /bin/sh -c '{ cargo --version && pkg-config --modversion openssl && cmake --version | head -1 && perl -e "print qq(perl ok\n)" && gcc --version | head -1; } >&2'
  rm -rf "$scratch/rust"; mkdir -p "$scratch/rust"
  check "cargo build of a tiny binary" run -v "$scratch/rust:/src" -w /src "$dev" /bin/sh -c '
      cargo new --quiet hello && cd hello &&
      printf "fn main() { println!(\"hello from rust {}\", std::env::consts::ARCH); }\n" > src/main.rs &&
      cargo build --quiet --release && cp target/release/hello /src/hello-bin && chmod 755 /src/hello-bin && rm -rf target >&2'
  expect "tiny binary on runtime" "hello from rust $( [ "$arch" = x86_64 ] && echo x86_64 || echo aarch64)" \
    "$(run -v "$scratch/rust:/bin-in:ro" --entrypoint /bin-in/hello-bin "$rt")"
  expect "runtime user" "65532" "$(run --entrypoint /bin/sh "$rt" -c 'id -u')"
  expect "app user" "app 1000 /home/app" "$(run --entrypoint /bin/sh "$rt" -c 'echo "$(id -un app) $(id -u app) $(awk -F: "\$1==\"app\"{print \$6}" /etc/passwd)"')"
  check "libssl.so.3, libcrypto.so.3, curl" run --entrypoint /bin/sh "$rt" -c 'test -e /usr/lib/libssl.so.3 && test -e /usr/lib/libcrypto.so.3 && curl --version | head -1 >&2'
  expect "dev default user" "root" "$(run --entrypoint /bin/sh "$dev" -c 'id -un')"
}

test_toolchain() { # ref
  local ref="$1" v="NODE_${PLATFORM_NODE_MAJOR}_VERSION"
  check "every tool answers --version" run "$ref" bash -euo pipefail -c '
    for c in "node --version" "npm --version" "pnpm --version" "bun --version" "bunx --version" \
             "docker --version" "docker buildx version" "docker compose version" \
             "pulumi version" "aws --version" "git --version" "rg --version" "unzip -v" \
             "iptables --version" "ip -V" "cargo --version" "rustc --version" "rust-analyzer --version" \
             "codex --version" "cmake --version" "perl -v" "pkg-config --version" "protoc --version" \
             "curl --version"; do
      out="$($c 2>&1)" || { echo "FAILED: $c: $out" >&2; exit 1; }
      printf "%-24s %s\n" "$c" "$(printf "%s\n" "$out" | grep -m1 -v "^[[:space:]]*$")" >&2
    done
    fc-list | grep -qi dejavu && echo "fonts: dejavu present" >&2'
  expect "node" "v${!v}" "$(run "$ref" node --version)"
  expect "pnpm" "$PNPM_VERSION" "$(run "$ref" pnpm --version)"
  expect "codex" "codex-cli $CODEX_VERSION" "$(run "$ref" codex --version)"
  expect "bun" "$(bun_version)" "$(run "$ref" bun --version)"
  # The Playwright headless shell the platform installs must find every library.
  expect "chrome-headless-shell libraries" "ok" "$(run "$ref" bash -c '
    export PLAYWRIGHT_BROWSERS_PATH=/tmp/pw
    npx --yes playwright-core@'"${PLAYWRIGHT_VERSION:-1.65.0}"' install --only-shell chromium >/tmp/pw.log 2>&1 || { tail -20 /tmp/pw.log >&2; exit 1; }
    shell="$(find /tmp/pw -type f -name chrome-headless-shell | head -1)"
    ld="$(ls /lib/ld-linux-*.so.* | head -1)"   # Wolfi ships no ldd; the loader lists instead
    missing="$("$ld" --list "$shell" | grep "not found" || true)"
    [ -z "$missing" ] || { echo "$missing" >&2; exit 1; }
    "$shell" --headless --no-sandbox --disable-gpu --dump-dom "data:text/html,<p>ok</p>" 2>/dev/null | grep -q "<p>ok</p>" && echo ok')"
}

status=0
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$arch" "$3" >> "$results"; [ "$3" = pass ] || status=1; }
# Run one test function and record pass/fail from FAILED.
t() { local image="$1" variant="$2"; shift 2; FAILED=0; "$@" || FAILED=1
  if [ $FAILED = 0 ]; then record "$image" "$variant" pass; else record "$image" "$variant" fail; fi; }

while IFS=$'\t' read -r image variant ref; do
  [ -n "$image" ] || continue
  log "== $image:$variant ($platform) $ref"
  case "$image:$variant" in
    node:*-dev) t "$image" "$variant" test_node "$ref" "${variant%%-*}" 1 ;;
    node:*)     t "$image" "$variant" test_node "$ref" "$variant" 0 ;;
    bun:dev)    t "$image" "$variant" test_bun "$ref" 1 ;;
    bun:*)      t "$image" "$variant" test_bun "$ref" 0 ;;
    rust:runtime)
      dev_ref="$(ref_of rust dev)"
      [ -n "$dev_ref" ] || { log "rust:runtime needs rust:dev in the same list"; record rust runtime fail; continue; }
      t rust runtime test_rust "$ref" "$dev_ref"
      record rust dev "$(awk -F'\t' '$1=="rust" && $2=="runtime" {print $4}' "$results" | tail -1)" ;;
    rust:dev) ;; # tested together with rust:runtime
    platform-toolchain:*) t "$image" "$variant" test_toolchain "$ref" ;;
  esac
done < "$list"

rm -rf "$scratch"
cat "$results" >&2
exit $status
