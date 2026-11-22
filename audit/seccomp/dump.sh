#!/bin/bash
# Read the seccomp filters the kernel holds for processes of running
# kContainerOS containers (PTRACE_SECCOMP_GET_FILTER from a privileged helper
# that shares the target's PID namespace). Writes out/filter-*.txt.
# Needs the images built by run.sh.
set -u
cd "$(dirname "$0")"
D="timeout 120 docker"
P="--platform linux/arm64"
mkdir -p out

dump() { # dump NAME OUTFILE: every process in the container's PID namespace
    local pids
    pids=$($D run --rm $P --pid "container:$1" --entrypoint /bin/sh kcos-audit-seccomp-dump -c \
        'for p in /proc/[0-9]*; do p=${p#/proc/}; [ "$p" != "$$" ] && grep -q . /proc/$p/cmdline 2>/dev/null && [ "$(cat /proc/$p/comm)" != sh ] && echo $p; done' | sort -n | tr '\n' ' ')
    {
        for p in $pids; do
            echo "# pid $p: $($D run --rm $P --pid "container:$1" --entrypoint /bin/sh kcos-audit-seccomp-dump -c "tr '\\0' ' ' < /proc/$p/cmdline; grep -E '^(Seccomp|Seccomp_filters|NoNewPrivs|CapEff|Uid):' /proc/$p/status | tr '\\n\\t' '  '")"
        done
        $D run --rm $P --privileged --security-opt seccomp=unconfined --pid "container:$1" \
            kcos-audit-seccomp-dump /dumpfilter $pids
    } > "out/$2" 2>&1
    echo "out/$2: $(grep -c ' len ' "out/$2") filter(s) read from pids: $pids"
}

start() { # start NAME docker-run-args...: detached, removed on exit
    local name=$1; shift
    $D run -d --rm $P --name "$name" "$@" > /dev/null || echo "could not start $name"
}

n=kcos-audit-seccomp-t$$
trap '$D rm -f $n-a $n-b $n-c $n-d $n-e >/dev/null 2>&1' EXIT

# a: release image + busybox, root, privileged, Docker's filter off. PID 1 is init, its child is busybox.
start $n-a --privileged --security-opt seccomp=unconfined kcos-audit /bb/busybox sleep 100
# b: the release image as shipped (user nobody, Docker's default filter on top): init, sh, sleep applet.
start $n-b kcontaineros sh -c 'sleep 100 && true'
# c: the sealed image (init only) with busybox added.
start $n-c --security-opt seccomp=unconfined kcos-audit-seccomp-sealed /bb/busybox sleep 100
# d: no init: the kContainerOS shell as entrypoint, which locks itself down (probe KCOS only).
start $n-d --security-opt seccomp=unconfined --entrypoint /bin/sh kcontaineros -c 'sleep 100 && true'
# e: init, then a shell entered with docker exec (outside init).
start $n-e --security-opt seccomp=unconfined kcontaineros sh -c 'sleep 100 && true'
$D exec -d $n-e sh -c 'sleep 99 && true'
sleep 1
dump $n-a filter-init-root-privileged.txt
dump $n-b filter-release-nobody-dockerdefault.txt
dump $n-c filter-sealed.txt
dump $n-d filter-shell-noinit.txt
dump $n-e filter-init-plus-exec.txt
