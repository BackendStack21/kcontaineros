#!/usr/bin/env bash
# Check the documentation's claims against real containers. From the repo root:
#
#   audit/claims/build.sh                 once: the helper image
#   audit/claims/claims.sh                every part
#   audit/claims/claims.sh c1-image       one part
#
# Needs the images kcontaineros, kcontaineros:sealed and kcos-audit.
cd "$(dirname "$0")/../.." || exit 1
. audit/claims/lib.sh
if [ $# -eq 0 ]; then set -- $(cd $HERE && ls c[0-9]*-*.sh | sed 's/\.sh$//'); : > "$RES"; fi
for part in "$@"; do . "$HERE/$part.sh"; done
summary
