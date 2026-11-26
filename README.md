# base-images

Container base images that ForkLaunch builds on [Wolfi](https://github.com/wolfi-dev/os),
rebuilt every night and published to public ECR only when AWS ECR basic scanning
reports 0 findings.

| Image | Variants | Contents |
|---|---|---|
| `node` | runtime, `-dev` | Node.js 24 and 26, compiled here from the nodejs.org source release |
| `bun` | runtime, `-dev` | Bun (Wolfi's package) |
| `rust` | runtime, `dev` | Runtime libraries for Rust services; `dev` adds the Rust toolchain |
| `platform-toolchain` | one | The tools the ForkLaunch platform worker needs (see below) |

Every image is built for `linux/amd64` and `linux/arm64`, and every image has an SPDX SBOM.

Registry: `public.ecr.aws/e6h0t2z8` (the registry's default alias, until the
`forklaunch` alias is approved; `PUBLIC_REGISTRY_ALIAS` in [`config.env`](config.env)).

## Tags

`YYYYMMDD` is the UTC date of the run that published the image.

| Image | Tags |
|---|---|
| `node` | `24`, `24.22`, `24.22.3`, `24-YYYYMMDD`; the same with `-dev` (`24-dev`, `24.22.3-dev`, `24-dev-YYYYMMDD`); likewise for `26` |
| `bun` | `latest`, `1`, `1.4`, `1.4.5`, `1-YYYYMMDD`; `dev`, `1-dev`, `1.4-dev`, `1.4.5-dev`, `1-dev-YYYYMMDD` |
| `rust` | runtime: `latest`, `YYYYMMDD`; toolchain: `dev`, `1.100-dev`, `1.100.0-dev`, `dev-YYYYMMDD` |
| `platform-toolchain` | `latest`, `YYYYMMDD` |

Version tags move to each night's rebuild. A rebuild can change the image even
when the version tag does not, because Wolfi packages get security fixes.
[`CHANGELOG.md`](CHANGELOG.md) records every published digest.

## Pin by digest

Use a digest in anything you ship, and let a bot or a person move it:

```sh
crane digest public.ecr.aws/e6h0t2z8/node:24
# or
docker buildx imagetools inspect public.ecr.aws/e6h0t2z8/node:24 --format '{{json .Manifest.Digest}}'
```

```dockerfile
FROM public.ecr.aws/e6h0t2z8/node:24-dev@sha256:<digest> AS build
FROM public.ecr.aws/e6h0t2z8/node:24@sha256:<digest>
```

The digest is the multi-arch index, so one pin covers both architectures. The
tag in front of `@` is ignored when pulling and only documents what you pinned.

## What is in each image

All images start from Wolfi's `wolfi-base` package (glibc, BusyBox, apk-tools)
and `ca-certificates-bundle`, and set
`PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.

**node** (runtime): `nodejs-<major>`, `curl`, Docker Hub's
`docker-entrypoint.sh` (so `docker run <image> app.js` runs `node app.js`).
User `node`, uid/gid 1000, home `/home/node`; the image runs as `node`.
`NODE_VERSION` is set as in the official image.

**node -dev**: runtime plus npm (and corepack on 24; Node 25 and later do not
bundle it), pnpm, Node headers (`npm_config_nodedir=/usr`, so node-gyp does not
download them), python3, make, gcc/g++ (`build-base`), git. Runs as root.

**bun** (runtime): `bun` (with `bunx`), `libstdc++`, `curl`. User `bun`,
uid/gid 1000, home `/home/bun`; runs as `bun`. Entrypoint `bun`.
**bun -dev**: plus git, python3, make, g++. Runs as root.

**rust** (runtime): `curl`, `libgcc`, and OpenSSL 3.6's `libssl.so.3` and
`libcrypto.so.3` (Wolfi's default OpenSSL is 4.0; binaries built on Debian or in
`rust:dev` link against 3.x). Users `nonroot` (65532, the default) and `app` (1000).
**rust dev**: plus the Rust toolchain (`rust-1.N`, with cargo), pkg-config,
OpenSSL 3.6 headers, gcc, make, perl, cmake, git. `CARGO_HOME=/usr/local/cargo`. Runs as root.

**platform-toolchain**: Node 26 with npm, headers and pnpm, Bun, Docker CLI
with buildx and compose, Pulumi with its Node.js language host, AWS CLI v2,
git, ripgrep, unzip, xz, iptables, iproute2, libnl3 and protobuf (headers and
`protoc`, for nsjail), the Rust toolchain and rust-analyzer, build-base,
pkg-config, OpenSSL 3.6 and libcurl headers, cmake, perl, the shared libraries
and DejaVu fonts Playwright's `chrome-headless-shell` needs, and the Codex CLI.
Runs as root. Platform-specific pieces (nsjail itself, BuildKit, the ForkLaunch
CLI, tsgo, the Playwright browser, the RDS CA bundle, the platform's older Bun
pin) stay in the platform's own Dockerfile.

## Packages built here

Some packages come from this repository instead of Wolfi, served from a signed
apk repository:

| Package | Source | Verification |
|---|---|---|
| `nodejs-24`, `nodejs-26` (+ `-npm`, `-dev`, `-oci-entrypoint`) | compiled from `node-vX.Y.Z.tar.xz` on nodejs.org | sha256 from `SHASUMS256.txt`, whose signature is checked against the Node release keys ([`keys/nodejs-release-keys.kbx`](keys/), from [nodejs/release-keys](https://github.com/nodejs/release-keys) `gpg-only-active-keys` at 481637f) |
| `pnpm` | npm registry tarball | sha512 integrity from the registry |
| `codex` | GitHub release (static musl build) | sha256 digest GitHub records for the asset |
| `bun` (fallback only) | official release zip | sha256 from the release's `SHASUMS256.txt`, cross-checked with GitHub's digest |

Wolfi moved non-latest Node 22 builds to Chainguard's paid repository in
August 2026. Building Node here means the images do not depend on Wolfi
keeping Node majors free. Node is built the way nodejs.org builds its release
binaries (bundled OpenSSL, ICU, libuv and so on). The package keeps upstream's
name and version (`nodejs-24` `24.22.3`), so scanners compare it with Wolfi's
advisory data for that exact version. `-rN` is this repository's build number.

The Bun fallback runs only when Wolfi has not packaged the newest Bun release
(`BUN_SOURCE` in [`pins/packages.env`](pins/packages.env)).

Repository: `https://forklaunch-apk.s3.us-east-1.amazonaws.com/os`, signing key
[`keys/forklaunch-melange.rsa.pub`](keys/forklaunch-melange.rsa.pub) (also at
`.../os/forklaunch-melange.rsa.pub`). The images already trust it, so
downstream Dockerfiles can add more of these packages:

```dockerfile
USER root
RUN apk add --no-cache 'nodejs-24-npm@forklaunch'
```

Our packages share names with Wolfi's (`nodejs-24`, `pnpm`, `codex`), so the
repository is tagged `@forklaunch` and every image asks for them with that tag.
Without the tag, apk installs Wolfi's build.

### The apk bucket is public on purpose

`forklaunch-apk` (us-east-1) serves the repository over HTTPS from its regular
S3 endpoint. Its bucket policy grants anonymous `s3:GetObject` on `os/*` only;
nothing else in the bucket is readable, listing is not public, and requests
without TLS are denied. Block Public Access is set to
`BlockPublicAcls=true, IgnorePublicAcls=true, BlockPublicPolicy=false,
RestrictPublicBuckets=false`: ACLs can never grant access (object ownership is
`BucketOwnerEnforced`), and only that policy can. The bucket is tagged
`public-exception=base-images-apk-repo`. It holds only signed packages built
from public sources, the public key, and the indexes. Only the CI role can write
to it.

## Pins

Everything an image is built from is pinned, and
[`scripts/refresh-pins.sh`](scripts/refresh-pins.sh) moves the pins:

| File | Holds | Refreshed nightly |
|---|---|---|
| `pins/<image>.txt` | every Wolfi package the image asks for, `name=version-rN` | newest build present on both architectures |
| `images/<image>/locks/<variant>.lock.json` | the resolved closure (every package, version and checksum), from `apko lock` | regenerated at build time |
| `pins/packages.env` | Node versions and tarball sha256, pnpm, codex, Bun fallback, epochs | Node (newest patch per major), Bun; pnpm and codex by hand |
| `pins/tools.env` | melange, apko, Grype and crane images by digest | current `:latest` digest |

The Rust stream follows Wolfi: the refresh picks the newest `rust-1.N` package
built for both architectures.

## Nightly pipeline and the gate

[`.github/workflows/nightly.yml`](.github/workflows/nightly.yml) runs daily at
08:23 UTC and on `workflow_dispatch`:

1. **pins**: refresh every pin; the list of changes becomes the changelog.
2. **packages**: melange builds our packages natively on x86_64 and aarch64
   runners, one job per package and architecture. A package is built only if its
   exact `name-version-rN.apk` is not already published, so Node is compiled once
   per release (about 2 to 3 hours on a 4-core runner).
3. **apk-index**: uploads new packages, then merges and re-signs `APKINDEX.tar.gz`.
4. **images**: renders and pins each apko config, resolves the closure with
   `apko lock`, and `apko publish`es a multi-arch candidate to the private
   repository `base-images-staging/<image>` with tag `<variant>-<run>-<attempt>`.
5. **gate**: for every architecture of every candidate, waits for the ECR basic
   scan (scan on push) and reads its findings. A candidate passes only if every
   scan is `COMPLETE` with **0 findings at every severity, including LOW,
   INFORMATIONAL and UNDEFINED**. A scan that fails, times out, or reports the
   image as unsupported holds the image back. Grype scans the same digests; by
   default its results are reported and not enforced (`grype_gate` input:
   `report`, `fixable`, or `all`). Grype also reads language packages (Go modules
   inside the Docker CLI, npm's bundled modules), which ECR basic scanning does
   not, so it usually reports more.
6. **smoke**: on both architectures: `node -e` and a native addon built with
   node-gyp against the packaged headers, `bun -e`, a tiny Rust binary built in
   `rust:dev` and run on `rust` as uid 65532, `--version` of every
   platform-toolchain tool, and Playwright's `chrome-headless-shell` rendering a page.
7. **publish**: candidates that passed the gate and both smoke runs are copied
   by digest to public ECR (`crane copy`, so the public image is the one that was
   scanned), their tags moved, and their SBOMs copied along.
8. **commit**: pins and lock files of published images, plus a
   `CHANGELOG.md` entry with every digest, are committed to `main` (or proposed
   in a pull request if `main` refuses the push).
9. **report**: if anything was held back or a job failed, an issue labelled
   `nightly-gate` is opened, or refreshed if one is open, with the findings.
   A fully green run closes it.

A held-back image keeps its previous public tags, so nothing downstream changes
until it passes again.

AWS access is GitHub OIDC only: the workflow assumes
`arn:aws:iam::038774803424:role/forklaunch-base-images-ci`, whose trust policy
accepts only tokens for `main` of this repository (scheduled runs and
dispatches from `main`; pull requests and other branches get a different
subject). The repository uses GitHub's immutable subject claims, so the subject
it matches is `repo:forklaunch@169505310/base-images@1473769631:ref:refs/heads/main`,
the ID-qualified form of `repo:forklaunch/base-images:ref:refs/heads/main`. Its policy reaches the four public repositories,
the staging repositories, the apk bucket's `os/` prefix and the signing key
secret, and nothing else. See [`infra/`](infra/) for the policies and the
idempotent `bootstrap.sh` that created everything.

The melange private key is in Secrets Manager
(`base-images/melange-signing-key`, us-east-1). Its resource policy denies
`GetSecretValue` to every principal except the CI role.

## Bump or roll back

- **New Node patch, Bun, Rust or Wolfi build**: nothing to do; the nightly run picks it up.
- **pnpm or codex**: edit `PNPM_*` / `CODEX_*` in `pins/packages.env` (version
  and checksum; the comments say where each checksum comes from), then run the
  workflow.
- **A recipe change without a new upstream version**: bump the package's
  `*_EPOCH` in `pins/packages.env`.
- **Another Node major**: add it to `NODE_MAJORS`, add `NODE_<major>_VERSION`,
  `_SHA256` and `_EPOCH`, and create the public tags' first run with
  `workflow_dispatch`.
- **Node release keys rotated**: refresh `keys/nodejs-release-keys.kbx` from
  nodejs/release-keys. Until then the signature check fails and the run opens an issue.
- **Roll back a tag**: point it at an earlier digest from `CHANGELOG.md`:
  ```sh
  crane tag public.ecr.aws/e6h0t2z8/node@sha256:<old-digest> 24
  ```
  Then pin consumers to that digest, because the next nightly run moves the tag
  again if a newer build passes. To stop that, run the workflow with
  `publish: false` until the fix lands, or revert the pin commit.

## Building locally

Requires Docker (melange runs privileged in a container), bash, jq, curl,
gpgv and the AWS CLI. Build one architecture into the local daemon and smoke-test it:

```sh
SIGNING_KEY=path/to/test.rsa WORK=$PWD/.work scripts/build-packages.sh aarch64 pnpm
LOCAL=1 ARCH_ONLY=aarch64 APK_REPO_OVERRIDE=$PWD/.work/packages scripts/build-images.sh bun
scripts/smoke.sh aarch64
```

Local builds use a key you generate (`melange keygen`); the published
repository's key never leaves Secrets Manager. With `APK_REPO_OVERRIDE`, also
set `APK_KEY_PATH` to your test key's `.pub`.
