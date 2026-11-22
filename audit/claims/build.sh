#!/usr/bin/env bash
# Build the helper image kcos-audit-claims-img (kcos-audit + /bb/sc) and kcos-audit-claims-nnp. From the repo root.
cd "$(dirname "$0")/helper" || exit 1
timeout 600 docker build --platform linux/arm64 --target img -t kcos-audit-claims-img . &&
timeout 600 docker build --platform linux/arm64 --target nnp -t kcos-audit-claims-nnp .
