#!/bin/bash
# System calls, capabilities, identities, sockets and IPC: the same helper
# under init and without it. Prints both, side by side where they differ.
# Run from the repo root after build.sh.
. "$(dirname "$0")/lib.sh"
out=$(mktemp -d)
for group in caps sys ns ids ipc socks; do
    section "$group: under init"
    if [ $group = socks ]; then init /aud/esc socks vsock | tee $out/$group.init
    else init /aud/esc $group | tee $out/$group.init; fi
    section "$group: control (no init)"
    # AF_VSOCK is never opened in the control run.
    ctl /aud/esc $group | tee $out/$group.ctl
    section "$group: lines that differ (init | control)"
    diff --side-by-side --suppress-common-lines -W 200 $out/$group.init $out/$group.ctl
done
section "file capabilities and setuid on a program (as root, and as uid 1000)"
echo "-- under init, root (the bounding set is empty, so a file that demands capabilities cannot be started at all):"; init /aud/esc-fcaps caps | grep -E 'Cap(Prm|Eff|Bnd)|Uid|not permitted'
echo "-- under init, uid 1000:"; timeout 120 docker run --rm $PLAT $PRIV --user 1000:1000 "$IMG" /aud/esc-fcaps caps 2>&1 | grep -E 'Cap(Prm|Eff|Bnd)|Uid'
echo "-- under init, uid 1000, setuid-root copy:"; timeout 120 docker run --rm $PLAT $PRIV --user 1000:1000 "$IMG" /aud/esc-suid caps 2>&1 | grep -E 'Cap(Prm|Eff|Bnd)|Uid'
echo "-- control, uid 1000 (file capabilities are honoured):"; timeout 120 docker run --rm $PLAT $PRIV --user 1000:1000 --entrypoint /aud/esc-fcaps "$IMG" caps 2>&1 | grep -E 'Cap(Prm|Eff|Bnd)|Uid'
echo "-- control, uid 1000, setuid-root copy:"; timeout 120 docker run --rm $PLAT $PRIV --user 1000:1000 --entrypoint /aud/esc-suid "$IMG" caps 2>&1 | grep -E 'Cap(Prm|Eff|Bnd)|Uid'
section "root started without CAP_SETPCAP (every other capability, not --privileged, which ignores --cap-drop): the bounding set stays, nothing can draw on it"
NOPCAP="--cap-add ALL --cap-drop SETPCAP --security-opt seccomp=unconfined --security-opt apparmor=unconfined"
timeout 120 docker run --rm $PLAT $NOPCAP "$IMG" /aud/esc caps 2>&1 | grep -E 'Cap|bounding|capset|AMBIENT'
echo "-- a program with file capabilities, same container options:"
timeout 120 docker run --rm $PLAT $NOPCAP "$IMG" /aud/esc-fcaps caps 2>&1 | grep -E 'CapEff|not permitted'
echo "-- kernel files, same container options:"
timeout 120 docker run --rm $PLAT $NOPCAP "$IMG" /aud/esc wr /proc/sys/kernel/hostname /proc/self/oom_score_adj 2>&1
rm -rf $out
