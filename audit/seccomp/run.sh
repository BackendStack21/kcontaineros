#!/bin/bash
# Audit of the kContainerOS system call filter: the whole run.
#   audit/seccomp/run.sh          from the repository root; KEEP=1 keeps the helper images
# Needs: Docker on an arm64 host, images kcontaineros, kcontaineros:sealed,
# kcos-audit (release image + busybox in /bb, USER 0, KCOS_EXEC=/bb) and
# rust:1-alpine (for its gcc), python3, GNU timeout.
# Everything it creates is named kcos-audit-seccomp-*; results go to audit/seccomp/out/.
set -u
cd "$(dirname "$0")"
mkdir -p out
cleanup() {
    [ "${KEEP:-0}" = 1 ] && return
    docker rmi kcos-audit-seccomp-dump kcos-audit-seccomp-probe kcos-audit-seccomp-sealed > /dev/null 2>&1
}
trap cleanup EXIT

echo "### build helpers"
for t in dump probe sealed; do
    timeout 600 docker build -q --platform linux/arm64 -f helpers/Dockerfile.tools --target $t -t kcos-audit-seccomp-$t helpers > /dev/null || { echo "build of $t failed"; exit 1; }
done
timeout 60 docker run --rm --platform linux/arm64 --name kcos-audit-seccomp-names-$$ kcos-audit-seccomp-dump cat /syscalls.tsv > syscalls_musl.tsv
echo "syscall names: $(wc -l < syscalls_musl.tsv | tr -d ' ')"

echo "### (a) read the installed filters back from the kernel"
./dump.sh

echo "### (b)(c) interpret them"
for c in programs verify table args arch source claims docker; do
    echo "=== bpf.py $c"
    python3 bpf.py $c
done 2>&1 | tee out/static.txt | grep -E '^===|RESULT|distinct|numbers|claimed-refused|evaluations|refused by'

echo "### (d) call them"
./probe.sh 2>&1 | tee out/probe-run.txt

echo "### around the filter"
./extra.sh 2>&1 | tee out/extra.txt

echo "### left behind:"
docker ps -a --filter name=kcos-audit-seccomp --format '{{.Names}} {{.Status}}'
