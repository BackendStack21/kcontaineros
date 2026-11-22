#!/bin/sh
# Builds the two audit images this track uses. Run from the repo root:
#   sh audit/memory/build.sh
# Needs: images kcos-audit and kcontaineros:sealed, and rust:1-alpine (gcc).
set -e
cd "$(dirname "$0")/helper"
timeout 600 docker build --platform linux/arm64 --target full   -t kcos-audit-memory-img    .
timeout 600 docker build --platform linux/arm64 --target sealed -t kcos-audit-memory-sealed .
