#!/bin/bash
# Two things around the filter rather than in it:
#  1. what a process entered with `docker exec` is under;
#  2. what init does when a filter installed before it (here: a Docker
#     seccomp profile) answers its "already locked down?" question with yes.
# Needs the images built by run.sh.
set -u
cd "$(dirname "$0")"
P="--platform linux/arm64"
I=kcos-audit-seccomp-probe
c=kcos-audit-seccomp-x$$
trap 'docker rm -f $c >/dev/null 2>&1' EXIT
STATUS='NoNewPrivs|Seccomp|CapEff'

echo "== docker exec into a container running under init (root, --privileged, seccomp=unconfined)"
timeout 120 docker run -d --rm $P --name $c --privileged --security-opt seccomp=unconfined $I /bb/busybox sleep 100 > /dev/null
echo "-- the command init started:"
timeout 60 docker exec $c /bb/busybox sh -c "/bb/busybox grep -E '$STATUS' /proc/7/status"
echo "-- docker exec of a kContainerOS utility (cat):"
timeout 60 docker exec $c cat /proc/self/status | grep -E "$STATUS"
echo "-- docker exec of another program (busybox):"
timeout 60 docker exec $c /bb/busybox grep -E "$STATUS" /proc/self/status
echo "-- docker exec of the probe (not a kContainerOS program), memfd_create with a null name: errno 14 is the kernel's answer, errno 1 the filter's"
timeout 60 docker exec $c /bb/sysprobe raw 279
docker rm -f $c > /dev/null 2>&1

echo
echo "== init under a Docker seccomp profile that answers prctl(0x4b434f46) with errno 114 (helpers/ealready.json)"
echo "-- without the profile:"
timeout 120 docker run --rm $P --name $c $I /bb/busybox sh -c \
    "/bb/busybox grep -E '$STATUS' /proc/self/status; /bb/sysprobe raw 279; /bb/busybox cp /bb/busybox /tmp/busybox && /tmp/busybox echo 'A COPY OF BUSYBOX IN /tmp WAS STARTED'"
echo "-- with the profile:"
timeout 120 docker run --rm $P --name $c --security-opt seccomp=helpers/ealready.json $I /bb/busybox sh -c \
    "/bb/busybox grep -E '$STATUS' /proc/self/status; /bb/sysprobe raw 279; /bb/busybox cp /bb/busybox /tmp/busybox && /tmp/busybox echo 'A COPY OF BUSYBOX IN /tmp WAS STARTED'"
