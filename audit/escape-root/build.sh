#!/bin/bash
# Builds kcos-audit-escape-root-img from kcos-audit. Run from the repo root.
set -eu
cd "$(dirname "$0")"
timeout 600 docker build --platform linux/arm64 -t kcos-audit-escape-root-img -f Dockerfile .
