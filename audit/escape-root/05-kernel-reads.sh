#!/bin/bash
# What root under init can still read of the host kernel's root-only files
# in a privileged container, next to what uid 1000 gets. Nothing is written.
# Run from the repo root after build.sh.
. "$(dirname "$0")/lib.sh"
CMD='b=/bb/busybox
for f in /proc/slabinfo /proc/vmallocinfo /proc/timer_list /proc/keys /proc/kpagecount /proc/kcore /proc/kmsg; do
  echo "$f: mode $($b stat -c %a $f), $($b head -c 65536 $f 2>/dev/null | $b wc -c) of the first 65536 bytes readable"
done
echo "-- /proc/slabinfo, lines 1-4:"; $b head -4 /proc/slabinfo 2>&1 | $b cut -c1-100
echo "-- /proc/timer_list: timers that name a process of the host or of another container (first 6 distinct):"
$b grep -oE ", [A-Za-z0-9_:./-]+/[0-9]+$" /proc/timer_list 2>&1 | $b sort -u | $b head -6
echo "-- processes visible in /proc of this container: $($b ls -d /proc/[0-9]* | $b wc -l)"
echo "-- /proc/keys:"; $b head -3 /proc/keys 2>&1 | $b cut -c1-100'
section "root under init, privileged"
init $BB sh -c "$CMD"
section "uid 1000 under init, privileged (an ordinary user)"
timeout 120 docker run --rm $PLAT $PRIV --user 1000:1000 "$IMG" $BB sh -c "$CMD" 2>&1
