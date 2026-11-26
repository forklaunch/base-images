## node
Node.js runtime on Wolfi. Node is compiled by ForkLaunch from the nodejs.org source release (checksum and release-key signature verified) and packaged as `nodejs-<major>` with its true upstream version. Tags: `24`, `24.x.y`, `26`, `26.x.y`, dated `<major>-YYYYMMDD`, and `-dev` variants for build stages. Runs as `node` (uid 1000).
## bun
Bun runtime on Wolfi. Tags: `1`, `1.x.y`, dated `1-YYYYMMDD`, and `-dev` variants. Runs as `bun` (uid 1000).
## rust
Runtime for Rust services on Wolfi (glibc, libgcc, OpenSSL 3 libssl, CA bundle, curl), plus `-dev` with the Rust toolchain. Runs as `nonroot` (65532); an `app` user (1000) exists too.
## platform-toolchain
Toolchain base for the ForkLaunch platform worker: Node 26, pnpm, Bun, Docker CLI with buildx and compose, Pulumi, AWS CLI v2, Rust, git, ripgrep, iptables, iproute2, Chromium shell libraries and fonts, Codex CLI.
## end
