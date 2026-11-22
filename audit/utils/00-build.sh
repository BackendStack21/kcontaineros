#!/usr/bin/env bash
# Builds the static helper and the image kcos-audit-utils-img = kcos-audit +
# /bb/h. Run once before the others. The compiler comes from rust:1-alpine
# when that image is present (it ships gcc and musl-dev, so nothing is
# downloaded), otherwise from alpine with `apk add gcc musl-dev`.
set -e
cd "$(dirname "$0")/helper"
if [ ! -x h ]; then
  if docker image inspect rust:1-alpine >/dev/null 2>&1; then
    timeout 600 docker run --rm --platform linux/arm64 -v "$PWD":/src rust:1-alpine \
      gcc -static -O1 -o /src/h /src/h.c
  else
    timeout 600 docker run --rm --platform linux/arm64 -v "$PWD":/src alpine sh -c \
      'apk add --no-cache gcc musl-dev >/dev/null && gcc -static -O1 -o /src/h /src/h.c'
  fi
fi
timeout 300 docker build --platform linux/arm64 -q -t kcos-audit-utils-img .
