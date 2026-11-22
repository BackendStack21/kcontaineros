#!/bin/bash
# A nested init (not PID 1) signals the command's process group again and
# again while it stops the leftovers (stop_leftovers -> signal_leftovers:
# kill(-child, sig)), although the command has been reaped by then. If the
# group is empty, its number is free: a new process that gets the command's
# old PID and becomes a group leader is in "the command's process group".
#
# Here the outer PID 1 is a busybox shell without init. It starts init with a
# command that leaves one stubborn orphan in another session, cycles the PID
# counter round to the command's PID (4194304 forks: several minutes), lets
# the command exit, and one second later starts a process group leader of
# its own. That process is no descendant of init.
#   WRAP=0 skips the cycling: the control, in which the bystander lives.
cd "$(dirname "$0")"; . ./lib.sh
N=kcos-audit-init-reuse-$$
trap 'docker rm -f $N >/dev/null 2>&1' EXIT INT TERM
run() {
timeout -k 5 -s KILL 2400 docker run --rm --name $N $P --memory 256m -e WRAP=$1 --entrypoint /bb/busybox $IMG sh -c '
    /bb/busybox mkfifo /tmp/go /tmp/tick
    /bb/kh wrap 400 >/dev/null     # PIDs below 300 are never handed out again
    /sbin/init -- /bb/busybox sh -c "echo \$\$ > /tmp/cpid; /bb/kh stubborn 3000 setsid; read x < /tmp/go; exit 5" &
    initpid=$!
    read -t 1 x <> /tmp/tick
    read C < /tmp/cpid
    echo "init is $initpid, its command is $C"
    # The newest PID has to become the last free one below the command: the
    # one before init, since init sits right below its command.
    [ $C = $((initpid+1)) ] || echo "unexpected: the command is not init+1"
    [ "$WRAP" = 1 ] && /bb/kh wrap $initpid
    echo x > /tmp/go               # the command exits; init reaps it and starts its 2 s wait
    read -t 1 x <> /tmp/tick
    /bb/kh leader 5 &              # a bystander: child of this shell, own process group
    wait $!; echo "bystander ended with status $?"
    wait $initpid; echo "init ended with status $?"'
}
if [ "${WRAP:-1}" = 1 ]; then
    out=$(run 1 2>&1); echo "$out" | sed 's/^/   /'
    ok "a bystander that got the command's old PID is not signalled by init" "leader: survived
bystander ended with status 0" "$(echo "$out" | grep -E 'survived|bystander')"
fi
out=$(run 0 2>&1); echo "$out" | sed 's/^/   /'
ok "control (no PID reuse): the bystander lives" "leader: survived
bystander ended with status 0" "$(echo "$out" | grep -E 'survived|bystander')"
summary
