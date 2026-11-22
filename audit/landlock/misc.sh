#!/bin/sh
# Remaining attacks on the run-or-write rule, and the documented limits as observed.
# Run from the repo root after build.sh.
IMG=kcos-audit-landlock-img
here=$(cd "$(dirname "$0")" && pwd)
L=/bb/lp
r() { timeout 120 docker run --rm --platform linux/arm64 "$@"; }
trap 'docker volume rm -f kcos-audit-landlock-mv kcos-audit-landlock-mv2 >/dev/null 2>&1; docker rmi -f kcos-audit-landlock-sealed >/dev/null 2>&1' EXIT

echo "== M1. a hard link, made in the image, between a program directory (/app/bin/lp) and a writable one (/w/hardlp); root under init"
r -u 0:0 -e KCOS_EXEC=/bb:/app/bin $IMG /bb/busybox sh -c '
  echo "before: $('$L' stat /app/bin/lp) size=$(/bb/busybox wc -c < /app/bin/lp)"
  echo "append one byte through /w/hardlp: $('$L' append1 /w/hardlp)"
  echo "after:  $('$L' stat /app/bin/lp) size=$(/bb/busybox wc -c < /app/bin/lp); /w/hardlp size=$(/bb/busybox wc -c < /w/hardlp)"
  echo "exec /app/bin/lp=$('$L' exec /app/bin/lp)  exec /w/hardlp=$('$L' exec /w/hardlp)"
  echo "new hard link at run time: program -> /tmp: $('$L' link /app/bin/lp /tmp/h1); through /proc/self/fd: $('$L' linkfd /app/bin/lp /tmp/h2); /tmp file -> program dir: $('$L' link /w/lp /app/bin/h3)"'

echo "== M2. O_RDONLY|O_TRUNC on a program file (truncation without a write descriptor), root under init, then control"
r -u 0:0 $IMG /bb/busybox sh -c 'echo "init:    $('$L' open rt /bb/kv) size=$(/bb/busybox wc -c < /bb/kv)"'
r -u 0:0 --entrypoint /bb/busybox $IMG sh -c 'echo "control: $('$L' open rt /bb/kv) size=$(/bb/busybox wc -c < /bb/kv)"'

echo "== M3. mounts over and inside program directories (root, KCOS_EXEC=/bb:/app/bin)"
r -u 0:0 --entrypoint /bb/busybox -v kcos-audit-landlock-mv:/v $IMG sh -c 'cp /bb/lp /v/lp; chmod 777 /v /v/lp' 
echo "-- volume mounted over /app/bin (holds lp):"
r -u 0:0 -e KCOS_EXEC=/bb:/app/bin -v kcos-audit-landlock-mv:/app/bin $IMG /bb/busybox sh -c 'echo "   exec=$('$L' exec /app/bin/lp) create=$('$L' open c /app/bin/n) write=$('$L' open w /app/bin/lp) unlink=$('$L' unlink /app/bin/lp)"'
echo "-- tmpfs (exec) mounted over /app/bin: empty, and nothing can be put there"
r -u 0:0 -e KCOS_EXEC=/bb:/app/bin --tmpfs /app/bin:exec,mode=1777 $IMG /bb/busybox sh -c 'echo "   create=$('$L' open c /app/bin/n) copy=$('$L' copy /bb/lp /app/bin/lp) rename-in=$('$L' copy /bb/lp /tmp/x >/dev/null; '$L' rename /tmp/x /app/bin/x)"'
echo "-- DOCUMENTED LIMIT, as observed: the same volume at /app/bin and at /data"
r -u 0:0 -e KCOS_EXEC=/bb:/app/bin -v kcos-audit-landlock-mv:/app/bin -v kcos-audit-landlock-mv:/data $IMG /bb/busybox sh -c 'echo "   copy to /data/new=$('$L' copy /bb/lp /data/new) exec /data/new=$('$L' exec /data/new) exec /app/bin/new=$('$L' exec /app/bin/new)"'
echo "-- the same volume at /data and at /data2 (both writable): no program directory involved"
r -u 0:0 -v kcos-audit-landlock-mv:/data2 -v kcos-audit-landlock-mv:/data $IMG /bb/busybox sh -c 'echo "   exec /data/lp=$('$L' exec /data/lp) exec /data2/lp=$('$L' exec /data2/lp)"'

echo "== M4. DOCUMENTED LIMIT, as observed: a host directory shared by Docker Desktop (read-only bind of audit/landlock/helper)"
for p in "" --privileged; do
r -u 0:0 $p -v "$here/helper:/hostshare:ro" -v "$here/helper:/usr/hostshare:ro" $IMG /bb/busybox sh -c 'echo "   '"${p:-default}"': read /hostshare/lp.c=$('$L' read /hostshare/lp.c) list=$('$L' open d /hostshare) read /usr/hostshare/lp.c=$('$L' read /usr/hostshare/lp.c) fstype=$(/bb/busybox awk "\$5==\"/hostshare\"{print \$(NF-2)}" /proc/self/mountinfo)"'
done

echo "== M5. the shell and other interpreters run code from writable places (DOCUMENTED), as nobody under init"
r $IMG /bb/busybox sh -c 'echo "echo ran-from-tmp" > /tmp/s; /bin/sh /tmp/s; '$L' exec /tmp/s'

echo "== M6. the sealed image: same rules (kcontaineros:sealed + /bb from the audit image)"
printf 'FROM kcontaineros:sealed\nCOPY --from=kcos-audit-landlock-img /bb /bb\nUSER 0\nENV KCOS_EXEC=/bb\n' | timeout 300 docker build --platform linux/arm64 -q -t kcos-audit-landlock-sealed - >/dev/null
for u in 0:0 65534:65534; do
r -u $u --tmpfs /tmp:exec,mode=1777 kcos-audit-landlock-sealed /bb/busybox sh -c '
  '$L' copy /bb/lp /tmp/c >/dev/null; '$L' copy /bb/lp /dev/shm/c >/dev/null
  echo "   uid $(/bb/busybox id -u): top level: $(/bb/busybox ls / | /bb/busybox tr "\n" " ")"
  echo "     exec /bb/lp=$('$L' exec /bb/lp) /tmp/c=$('$L' exec /tmp/c) /dev/shm/c=$('$L' exec /dev/shm/c) memfd=$('$L' memfd) tmpfile=$('$L' tmpfileexec /tmp /bb/lp)"
  echo "     create: /=$('$L' open c /n) /bb=$('$L' open c /bb/n) /usr/local/bin=$('$L' open c /usr/local/bin/n) /etc=$('$L' open c /etc/n) /run=$('$L' open c /run/n) /var=$('$L' open c /var/n) /tmp=$('$L' open c /tmp/n) /dev=$('$L' open c /dev/n) /dev/shm=$('$L' open c /dev/shm/n)"
  echo "     write /bb/kv=$('$L' open w /bb/kv) /proc/self/comm=$('$L' open a /proc/self/comm) /dev/null=$('$L' open w /dev/null)"'
done
r -u 0:0 --privileged kcos-audit-landlock-sealed /bb/busybox sh -c 'echo "   privileged root: /dev/rtc0 read=$('$L' open r /dev/rtc0) write=$('$L' open w /dev/rtc0) mode3=$('$L' open 3 /dev/rtc0) RTC_RD_TIME=$('$L' ioctl 3 /dev/rtc0 80247009); /proc/sys append=$('$L' open a /proc/sys/kernel/hostname)"'

echo "== M7. the release image itself (kcontaineros, user nobody, its own tools): what the README shows"
r kcontaineros sh -c 'echo x > /tmp/f && echo "write /tmp ok"; cp /bin/kcontaineros /tmp/k && chmod 755 /tmp/k; /tmp/k true; echo "exec of the copy: status $?"; echo y > /bin/n; echo "write /bin: status $?"; mkdir /new; echo "mkdir /new: status $?"' 2>&1
