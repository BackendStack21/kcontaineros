#!/usr/bin/env bash
# Reruns the whole utils audit. From the repo root: audit/utils/run-all.sh
# Needs the images kcontaineros and kcos-audit (release image + busybox at
# /bb, USER 0, ENV KCOS_EXEC=/bb), Docker on linux/arm64, bash, python3 and
# GNU timeout. Takes about 20 minutes. Results go to audit/utils/out/.
# Set KEEP=1 to keep the image kcos-audit-utils-img afterwards.
cd "$(dirname "$0")"
./00-build.sh || exit 1
for s in 01-options.sh 02-diff.sh 03-terminal.sh 04-safety.sh 05-dispatch.sh 06-ls.sh; do
  echo; echo "################ $s"; ./$s > "out/${s%.sh}.txt" 2>&1; tail -n 400 "out/${s%.sh}.txt"
done
[ -n "$KEEP" ] || docker rmi kcos-audit-utils-img >/dev/null
docker ps -a --filter name=kcos-audit-utils --format '{{.Names}}'   # nothing should be left
