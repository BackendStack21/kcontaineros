#!/bin/bash
# Builds the helper image, runs every script of the track into results/,
# and removes the image again. Run from the repo root:
#   bash audit/escape-root/run-all.sh
here=$(cd "$(dirname "$0")" && pwd)
bash "$here/build.sh" >/dev/null 2>&1 || { echo "build failed: run $here/build.sh to see why"; exit 1; }
mkdir -p "$here/results"
for s in 01-syscalls 02-files 03-init 04-extras 05-kernel-reads; do
    echo "running $s"
    bash "$here/$s.sh" > "$here/results/$s.txt" 2>&1
done
docker rmi kcos-audit-escape-root-img >/dev/null 2>&1
docker ps -a --filter name=kcos-audit-escape-root- --format '{{.Names}}'
echo "results in $here/results"
