#!/bin/sh
# Build inputs: pinning, network use, dependencies. Run from the repo root.
# Uses the pinned rust image from the Dockerfile in throwaway containers with
# the repository mounted read-only; nothing in the repo is written.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
RUST=$(sed -n 's/^FROM .* \(rust:[^ ]*\) AS toolchain$/\1/p' Dockerfile)
echo "== FROM lines (every base image should carry @sha256:)"
grep -n '^FROM' Dockerfile examples/hello-http/Dockerfile
echo "== images referenced by the test runner"
grep -nE "busybox:|alpine|FROM " test/e2e.sh test/suite.sh | cut -c1-200
echo "== rust-toolchain.toml vs Dockerfile tag"
grep -n channel rust-toolchain.toml; echo "Dockerfile: $RUST"
echo "== Cargo: dependencies"
grep -n -A3 'dependencies' Cargo.toml examples/hello-http/Cargo.toml || echo "no [dependencies] table with entries"
echo "-- Cargo.lock packages:"; grep -c '^\[\[package\]\]' Cargo.lock examples/hello-http/Cargo.lock
echo "== --locked on every cargo build"
grep -n 'cargo build' Dockerfile examples/hello-http/Dockerfile
echo "== anything that fetches at build time"
grep -nE 'rustup|apk|curl|wget|git clone|npm|npx|pip' Dockerfile examples/hello-http/Dockerfile Makefile tools/* | cut -c1-200

run() { timeout 300 docker run --rm --platform linux/arm64 "$@"; }
echo "== inside the pinned toolchain image, WITHOUT network"
run --network none -v "$root:/repo:ro" "$RUST" sh -c '
  echo "rustc: $(rustc -V)"; echo "cargo: $(cargo -V)"
  echo "toolchains: $(rustup toolchain list | tr "\n" " ")"
  echo "installed targets before: $(rustup target list --installed | tr "\n" " ")"
  echo "-- rustup target add aarch64-unknown-none (offline):"
  rustup target add aarch64-unknown-none 2>&1 | tail -3; echo "   rc=$?"
'
echo "== the same with network: what does rustup fetch, and is it verified against anything in the repo?"
run -v "$root:/repo:ro" "$RUST" sh -c '
  rustup -v target add aarch64-unknown-none 2>&1 | grep -iE "download|http|sha|install" | head -12
  echo "installed targets after: $(rustup target list --installed | tr "\n" " ")"
  ls /usr/local/rustup/toolchains/
  mkdir /src && cd /repo && cp -r Cargo.toml Cargo.lock rust-toolchain.toml .cargo src /src/ && cd /src
  echo "-- is the downloaded archive checked against a hash that is inside the digest-pinned image?"
  grep -n -B3 "340bd5041d8360ce263ae5f377008766e057b4c4178740cde07fefd2df62c269" /usr/local/rustup/toolchains/*/lib/rustlib/multirust-channel-manifest.toml | head -8
  echo "-- cargo metadata --offline --locked: packages / dependency edges"
  cargo metadata --format-version 1 --offline --locked > /tmp/m.json 2>/tmp/m.err; echo "   rc=$? stderr: $(cat /tmp/m.err)"
  grep -o "\"name\":\"[a-z_-]*\",\"version\":\"[0-9.]*\"" /tmp/m.json | sort | uniq -c
  grep -o "\"dependencies\":\[[^]]*\]" /tmp/m.json; grep -o "\"deps\":\[[^]]*\]" /tmp/m.json
  echo "-- cargo tree:"; cargo tree --offline --locked 2>&1 | head
  echo "-- cargo build --release --locked --offline (all three feature sets that use this target):"
  cargo build --release --locked --offline 2>&1 | tail -2
  sha256sum target/aarch64-unknown-none/release/kcontaineros; wc -c < target/aarch64-unknown-none/release/kcontaineros
  cargo build --release --locked --offline --no-default-features 2>&1 | tail -1
  sha256sum target/aarch64-unknown-none/release/kcontaineros; wc -c < target/aarch64-unknown-none/release/kcontaineros
  echo "-- extern crate / build.rs / proc-macro / include in sources:"
  grep -nE "extern crate|include(_bytes|_str)?!|#\[link|build *=|proc-macro" -r src Cargo.toml | head
  ls build.rs 2>&1 | head -1
  find /usr/local/rustup/toolchains -path "*aarch64-unknown-none*" -name "libcore*.rlib" -exec sha256sum {} \;
  find /usr/local/rustup/toolchains -path "*aarch64-unknown-none*" -name "liballoc*.rlib" -exec sha256sum {} \;
  find /usr/local/rustup/toolchains -path "*aarch64-unknown-none*" -name "libcompiler_builtins*.rlib" -exec sha256sum {} \;
'
echo "== what happens when rust-toolchain.toml names a version the image does not have (offline, so nothing is fetched)"
run --network none -v "$root:/repo:ro" "$RUST" sh -c '
  mkdir /src && cd /repo && cp -r Cargo.toml Cargo.lock .cargo src /src/ && cd /src
  printf "[toolchain]\nchannel = \"1.99.0\"\ntargets = [\"aarch64-unknown-none\"]\n" > rust-toolchain.toml
  cargo build --release --locked 2>&1 | head -5; echo "   rc=$?"'
