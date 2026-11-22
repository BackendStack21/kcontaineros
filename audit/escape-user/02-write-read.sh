#!/bin/bash
# Goal: write where the README says the default user cannot, read what it
# says cannot be read. Every refusal has its control without init.
. "$(dirname "$0")/lib.sh"
trap cleanup_names EXIT
SWEEP=$(cat "$HERE/inside/writable.sh")
RECIPE="-i --read-only --network none --ipc none --memory 512m --pids-limit 128 --tmpfs /work:uid=65534,gid=65534,mode=0700"

sweep() {  # NAME EXPECTED(space separated dirs) IMAGE args...
  local name=$1 want=$2 image=$3; shift 3
  local got; got=$($D "$@" $image sh -c "$SWEEP" 2>&1)
  local dirs; dirs=$(echo "$got" | sed -n 's/^WRITABLE //p' | sort | tr '\n' ' ' | sed 's/ $//')
  echo "## writable directories, $name: [$dirs]"
  if ! echo "$got" | grep -q SWEEP-DONE; then bad "$name: sweep did not finish"; show "$got"
  elif [ "$dirs" = "$want" ]; then ok "$name: exactly [$want]"
  else bad "$name: expected [$want], found [$dirs]"; fi
}
sweep "plain run, nobody"            "/dev/shm /tmp /var/tmp"  $IMG $NOBODY
sweep "plain run, nobody, control"   "/dev/mqueue /dev/shm /tmp /var/tmp" $IMG $NOBODY $CTL
sweep "--read-only --tmpfs /tmp"     "/dev/shm /tmp"           $IMG $NOBODY --read-only --tmpfs /tmp
sweep "--ipc none"                   "/tmp /var/tmp"           $IMG $NOBODY --ipc none
sweep "agent recipe (sealed)"        "/work"                   $SEALED $RECIPE
sweep "agent recipe (sealed), control" "/dev/mqueue /work"                 $SEALED $RECIPE $CTL
sweep "sealed, plain run"            "/dev/shm"                $SEALED
sweep "third-party image"            "/data /dev/shm /tmp /var/tmp" $THIRD
sweep "third-party image, control"   "/app /app/bin /data /dev/mqueue /dev/shm /tmp /var/tmp" $THIRD --entrypoint /app/bin/busybox

echo "## agent recipe: 'can write its working files to /work and nowhere else'"
out=$($D $RECIPE $SEALED sh -c 'kp mq; kp sysvshm' 2>&1); show "$out"
if echo "$out" | grep -q 'mq_receive after reopen: "stored outside /work"'; then
  note "a named POSIX message queue holds data outside /work under the recipe (kernel memory, gone with the container)"; fi
if echo "$out" | grep -q 'shm after reattach: "stored outside /work"'; then
  note "a keyed SysV shared memory segment holds data outside /work under the recipe (same)"; fi

echo "## third-party image: a program directory owned by the default user"
P='cd /; echo x > /app/bin/new; echo "create=$?"; echo x >> /app/bin/kp; echo "append=$?"; rm /app/bin/kp; echo "rm=$?"; mkdir /app/newdir; echo "mkdir-in-top=$?"; chmod 700 /app/bin/evilmode 2>/dev/null; chmod 0500 /app/bin/kp; echo "chmod=$?"; stat -c %a /app/bin/kp; touch -d "2001-01-01 00:00:00" /app/bin/kp; echo "touch=$?"; stat -c %y /app/bin/kp'
with=$($D $THIRD busybox sh -c "$P" 2>&1); ctl=$($D --entrypoint /app/bin/busybox $THIRD sh -c "$P" 2>&1)
show "$with"; echo "    control:"; show "$ctl"
if echo "$with" | grep -q 'create=1' && echo "$with" | grep -q 'append=1' && echo "$with" | grep -q 'rm=1' && echo "$with" | grep -q 'mkdir-in-top=1' \
   && echo "$ctl" | grep -q 'create=0' && echo "$ctl" | grep -q 'rm=0'; then ok "contents of a program directory owned by nobody cannot be changed (control: can)"; else bad "program directory owned by nobody was changed under init"; fi
if echo "$with" | grep -q 'chmod=0' && echo "$with" | grep -q '^500$'; then note "the owner (nobody, not only root as the README words it) can change mode and timestamps of program files"; fi

echo "## a volume mounted inside a program directory is not writable"
V=$T-vol2-$$; docker volume create $V >/dev/null
$D $CTL -v $V:/usr/local/share/x $IMG chown 65534:65534 /usr/local/share/x
P='echo x > /usr/local/share/x/f; echo "write=$?"'
with=$($D $NOBODY -v $V:/usr/local/share/x $IMG sh -c "$P" 2>&1); ctl=$($D $NOBODY $CTL -v $V:/usr/local/share/x $IMG sh -c "$P" 2>&1)
show "$with"; echo "    control:"; show "$ctl"
if echo "$with" | grep -q 'write=1' && echo "$ctl" | grep -q 'write=0'; then ok "volume inside /usr is read-only under init (control: writable)"; else bad "volume inside /usr"; fi

echo "## KCOS_EXEC entries that are ignored: 'The top-level directory of an ignored entry is not writable all the same.'"
ign=""
for e in /tmp/ /tmp/. /var/../tmp //tmp tmp /tmp/nonexistent /tmp; do
  out=$($D $NOBODY -e KCOS_EXEC=$e $IMG sh -c 'echo x > /tmp/f; echo "write-to-/tmp=$?"' 2>&1)
  echo "  KCOS_EXEC=$e -> $(echo "$out" | tr '\n' '|')"
  case $e in
    /tmp|/tmp/nonexistent) echo "$out" | grep -q 'write-to-/tmp=1' && ok "KCOS_EXEC=$e: /tmp is not writable" || bad "KCOS_EXEC=$e: /tmp writable";;
    *) if echo "$out" | grep -q 'ignored' && echo "$out" | grep -q 'write-to-/tmp=0'; then ign="$ign $e"; else ok "KCOS_EXEC=$e: /tmp not writable"; fi;;
  esac
done
[ -n "$ign" ] && bad "entries ignored as 'not a plain absolute path' leave their top-level directory writable, contrary to the README:$ign"

echo "## devices: --device /dev/fuse without and with KCOS_DEV (open only, nothing is written)"
P='ls -l /dev/fuse; kp openr /dev/fuse; kp openw /dev/fuse'
a=$($D $NOBODY --device /dev/fuse $IMG sh -c "$P" 2>&1); b=$($D $NOBODY --device /dev/fuse -e KCOS_DEV=/dev/fuse $IMG sh -c "$P" 2>&1); c=$($D $NOBODY $CTL --device /dev/fuse $IMG sh -c "$P" 2>&1)
show "$a"; echo "    named:"; show "$b"; echo "    control:"; show "$c"
if [ "$(echo "$a" | grep -c 'errno 13')" = 2 ] && [ "$(echo "$b" | grep -c ': ok')" = 2 ] && [ "$(echo "$c" | grep -c ': ok')" = 2 ]; then ok "an unnamed device cannot be opened, a named one can (control: can)"; else bad "device rule"; fi
echo "  device mapped outside /dev (documented limit: 'an ordinary file')"
a=$($D $NOBODY --device /dev/fuse:/tmp/fuse $IMG sh -c 'kp openr /tmp/fuse; kp openw /tmp/fuse' 2>&1); show "$a"
echo "$a" | grep -q ': ok' && note "documented limit confirmed: a device mapped to /tmp/fuse opens under init"

echo "## PID 1 is opaque to the default user"
P='cat /proc/1/environ >/dev/null; echo "environ=$?"; kp openr /proc/1/mem; ls /proc/1/fd >/dev/null; echo "fd=$?"; cat /proc/1/maps > /dev/null; echo "maps=$?"; readlink /proc/1/exe; echo "exe=$?"; ls /proc/1/root/ >/dev/null; echo "root=$?"; ls /proc/1/cwd/ >/dev/null; echo "cwd=$?"; cat /proc/1/auxv >/dev/null; echo "auxv=$?"; cat /proc/1/stack >/dev/null; echo "stack=$?"; cat /proc/1/io > /dev/null; echo "io=$?"'
with=$($D $NOBODY -e SECRET=s3cret $IMG sh -c "$P" 2>&1); ctl=$($D $NOBODY -e SECRET=s3cret $CTL $IMG sh -c "$P" 2>&1)
show "$with"; echo "    control (PID 1 is the shell itself):"; show "$ctl"
n=$(echo "$with" | grep -cE '^(environ|fd|maps|exe|root|cwd|auxv|io)=1$')
if [ "$n" = 8 ] && echo "$with" | grep -q 'O_RDONLY: errno 13' && echo "$ctl" | grep -q 'environ=0'; then ok "environ, mem, fd, maps, exe, root, cwd, auxv, io of PID 1 are refused (control: readable)"; else bad "PID 1 opacity: $n of 8 refused"; fi

echo "## host directory shared by Docker Desktop (bind mount of audit/escape-user/share)"
P='cd /; cat /host/hello.txt; echo "read=$?"; echo x > /host/kcos-audit-escape-user-written; echo "write=$?"; /host/evil; echo "exec=$?"; rm -f /host/kcos-audit-escape-user-written'
with=$($D $NOBODY -v "$HERE/share:/host" $IMG sh -c "$P" 2>&1); ctl=$($D $NOBODY $CTL -v "$HERE/share:/host" $IMG sh -c "$P" 2>&1)
show "$with"; echo "    control:"; show "$ctl"
if echo "$with" | grep -q 'read=0' && echo "$with" | grep -q 'write=1' && echo "$with" | grep -q 'exec=126'; then ok "host share: readable, not writable, programs do not start (as documented)"; else bad "host share behaves differently from the README"; fi
with=$($D $NOBODY -v "$HERE/share:/usr/local/bin/host" $IMG sh -c 'cd /; /usr/local/bin/host/evil; echo "exec=$?"' 2>&1); show "$with"
echo "$with" | grep -q EVIL-BINARY-RAN && note "host share mounted inside a program directory: programs start (it is in a program directory)" || note "host share mounted inside /usr/local/bin: programs still do not start"
with=$($D $NOBODY --device /dev/fuse -v "$HERE/share:/host" $IMG sh -c 'cat /host/hello.txt; echo "read=$?"' 2>&1); show "$with"
echo "$with" | grep -q 'read=1' && note "documented limit confirmed: with an unnamed --device the host share cannot be read either"
rm -f "$HERE/share/kcos-audit-escape-user-written"
summary
