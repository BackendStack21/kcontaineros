#!/bin/sh
# Build the audit image kcos-audit-landlock-img from kcos-audit (must exist).
set -eu
cd "$(dirname "$0")/helper"
timeout 600 docker build --platform linux/arm64 -q -t kcos-audit-landlock-img . 
