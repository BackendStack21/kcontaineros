#!/bin/bash
# Call system calls from a static helper (helpers/sysprobe.c) under init and,
# as the control, without init; both as root with --privileged and Docker's
# own filter off. Then check every answer against the interpreter's verdict
# for the filter read from the kernel. Needs the images built by run.sh and
# the dumps written by dump.sh.
set -u
cd "$(dirname "$0")"
N=0
D=run
run() { # every container is named kcos-audit-seccomp-p-PID-N and removed if the client is cut off
    N=$((N + 1))
    local name=kcos-audit-seccomp-p-$$-$N
    timeout 120 docker run --rm --platform linux/arm64 --name "$name" "$@"
    local rc=$?
    [ $rc -ge 124 ] && docker rm -f "$name" > /dev/null 2>&1
    return $rc
}
PRIV="--privileged --security-opt seccomp=unconfined"
I=kcos-audit-seccomp-probe
S=kcos-audit-seccomp-sealed

echo "== sample of calls, harmless arguments: init vs no init (root, --privileged, seccomp=unconfined)"
$D $PRIV $I /bb/sysprobe safe > out/probe-init.txt 2>&1
$D $PRIV --entrypoint /bb/sysprobe $I safe > out/probe-control.txt 2>&1
python3 bpf.py compare out/probe-init.txt out/probe-control.txt | tee out/compare.txt | tail -5

echo "== the same sample under the sealed image's init, and under init as nobody with Docker's default filter left on"
$D $PRIV $S /bb/sysprobe safe > out/probe-sealed.txt 2>&1
python3 bpf.py compare out/probe-sealed.txt out/probe-control.txt | tee out/compare-sealed.txt | tail -5
$D --user 65534:65534 $I /bb/sysprobe safe > out/probe-nobody.txt 2>&1
python3 bpf.py compare out/probe-nobody.txt out/probe-control.txt | tee out/compare-nobody.txt | tail -5

echo "== AF_VSOCK, under init only (never opened without init)"
$D $PRIV $I /bb/sysprobe initonly > out/probe-initonly.txt 2>&1
python3 bpf.py compare out/probe-initonly.txt | tee out/compare-initonly.txt | grep -v '^$'

echo "== every number 0..1100 the interpreter says is refused whatever the arguments, called under init with zero arguments"
refused=$(python3 bpf.py refused)
$D $PRIV $I /bb/sysprobe raw $refused > out/probe-raw.txt 2>&1
python3 bpf.py compare out/probe-raw.txt | tee out/compare-raw.txt | tail -5

echo "== further filters added by the process itself cannot make a refused call run"
$D $PRIV $I /bb/sysprobe stack 2>&1 | tee out/stack-init.txt
$D $PRIV $I /bb/sysprobe stack-errno0 2>&1 | tee out/stack-errno0-init.txt
echo "-- control, no init:"
$D $PRIV --entrypoint /bb/sysprobe $I stack 2>&1 | tee out/stack-control.txt
$D $PRIV --entrypoint /bb/sysprobe $I stack-errno0 2>&1 | tee out/stack-errno0-control.txt

echo "== execveat on files outside the program directories (Landlock's part; the filter lets execveat through)"
echo "-- under init, root"
$D $I /bb/sysprobe execveat 2>&1 | tee out/execveat-init.txt
echo "-- control, no init, root"
$D --entrypoint /bb/sysprobe $I execveat 2>&1 | tee out/execveat-control.txt

echo "== another process's memory through /proc/PID/mem"
for who in "65534:65534" "0:0"; do
    echo "-- under init, user $who"
    $D --user $who $I /bb/sysprobe mem 2>&1 | tee out/mem-init-${who%%:*}.txt
    echo "-- control, no init, user $who"
    $D --user $who --entrypoint /bb/sysprobe $I mem 2>&1 | tee out/mem-control-${who%%:*}.txt
done
echo "-- under init, root, --privileged, seccomp=unconfined"
$D $PRIV $I /bb/sysprobe mem 2>&1 | tee out/mem-init-0-privileged.txt
