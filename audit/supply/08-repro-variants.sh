#!/bin/sh
# Reproducibility beyond "same machine, same minute": the same sources built
# (1) in another directory, (2) with another umask and dirty file modes/mtimes,
# (3) by the amd64 variant of the pinned compiler image (cross-compiling under
# emulation), each compared with the release binary and rootfs listing.
# Throwaway containers only; the repo is mounted read-only. Run from the repo root.
# Variants 1-3 run WITHOUT network in the toolchain stage of the Dockerfile
# (tagged kcos-audit-supply-toolchain from the build cache), which also shows
# that cargo itself fetches nothing. Variant 4 has to pull the amd64 image.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
RUST=$(sed -n 's/^FROM .* \(rust:[^ ]*\) AS toolchain$/\1/p' Dockerfile)
want=$(python3 -c "
import sys; sys.path.insert(0, '$here')
from lib import *
print(sha(embedded_binary()))")
docker image inspect kcos-audit-supply-toolchain >/dev/null 2>&1 || \
  timeout 600 docker build -q --platform linux/arm64 --target toolchain -t kcos-audit-supply-toolchain . >/dev/null
TC=kcos-audit-supply-toolchain
echo "reference (docs/index.html == release image): $want"
build='
  set -e
  rustup target list --installed | grep -q aarch64-unknown-none || rustup target add aarch64-unknown-none >/dev/null 2>&1
  umask $UM
  mkdir -p $DIR && cd /repo && cp -r Cargo.toml Cargo.lock rust-toolchain.toml .cargo src rootfs tools $DIR/ && cd $DIR
  if [ -n "$DIRTY" ]; then chmod -R go-rwx rootfs; chmod 600 rootfs/etc/*; touch rootfs/etc/passwd; fi
  cargo build --release --locked >/dev/null 2>&1
  echo "host=$(uname -m) dir=$DIR umask=$UM dirty=${DIRTY:-no}"
  echo "binary  $(sha256sum < target/aarch64-unknown-none/release/kcontaineros | cut -d" " -f1)"
  tools/mkrootfs.sh target/aarch64-unknown-none/release/kcontaineros /rootfs
  # listing with modes, owners, mtimes, link targets and contents: what the layer is made of
  cd /rootfs && echo "rootfs  $(find . | sort | while read -r f; do stat -c "%n %a %u:%g %Y %F" "$f"; [ -L "$f" ] && readlink "$f"; [ -f "$f" ] && [ ! -L "$f" ] && sha256sum < "$f"; done | sha256sum | cut -d" " -f1)"
'
echo "== 1. as the Dockerfile does it (umask 022, arm64 compiler; /src2 because /src exists in the stage)"
timeout 300 docker run --rm --platform linux/arm64 --network none -v "$root:/repo:ro" -e DIR=/src2 -e UM=022 -e DIRTY= "$TC" sh -c "$build"
echo "== 2. another directory"
timeout 300 docker run --rm --platform linux/arm64 --network none -v "$root:/repo:ro" -e DIR=/somewhere/else/entirely -e UM=022 -e DIRTY= "$TC" sh -c "$build"
echo "== 3. umask 077, source modes and mtimes disturbed"
timeout 300 docker run --rm --platform linux/arm64 --network none -v "$root:/repo:ro" -e DIR=/src3 -e UM=077 -e DIRTY=1 "$TC" sh -c "$build"
echo "== 4. amd64 variant of the same pinned image (what FROM --platform=\$BUILDPLATFORM selects on an x86 build host), emulated"
timeout 900 docker run --rm --platform linux/amd64 -v "$root:/repo:ro" -e DIR=/src -e UM=022 -e DIRTY= "$RUST" sh -c "$build" 2>&1 | grep -v 'WARNING: The requested image'
