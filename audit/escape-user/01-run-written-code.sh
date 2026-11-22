#!/bin/bash
# Goal: start a program that was written at run time, as the default user,
# in every realistic configuration. 44 routes per configuration (see
# inside/exec-routes.sh), each configuration once under init and once
# without it (the control).
. "$(dirname "$0")/lib.sh"
trap cleanup_names EXIT
ROUTES=$(cat "$HERE/inside/exec-routes.sh")
MARK='EVIL-BINARY-RAN|KP-HELLO|SCRIPT-RAN|NOSHEBANG-RAN'
V=$T-vol-$$
docker volume create $V >/dev/null
# hand the volume to nobody, as a directory prepared in an image would
$D $CTL -v $V:/data $IMG chown 65534:65534 /data

run_cfg() {   # NAME W IMAGE docker-args...
  local name=$1 w=$2 image=$3; shift 3
  echo "## $name (W=$w)"
  local with ctl
  with=$($D "$@" -e W=$w $image sh -c "$ROUTES" 2>&1)
  local c=$CTL; [ $image = $THIRD ] && c="--entrypoint /app/bin/busybox"
  ctl=$($D "$@" -e W=$w $c $image sh -c "$ROUTES" 2>&1)
  local a b setup
  a=$(echo "$with" | sed '/^--- documented/,$d' | grep -cE "$MARK")
  b=$(echo "$ctl"  | sed '/^--- documented/,$d' | grep -cE "$MARK")
  setup=$(echo "$with" | grep -c 'SETUP FAILED')
  echo "  routes that started a run-time program: with init $a, control $b"
  if [ "$setup" != 0 ]; then note "could not write to $w under init (nothing to run)"; show "$(echo "$with" | head -3)"
  elif [ "$a" = 0 ] && [ "$b" -gt 0 ]; then ok "$name: no route starts a written program; the control starts $b"
  elif [ "$a" = 0 ]; then note "$name: nothing started, but the control started nothing either (W is mounted noexec)"
  else bad "$name: a written program was started under init"; show "$(echo "$with" | grep -E "$MARK")"; fi
  # the write side: nothing may appear in a program directory
  if echo "$with" | grep -E '^\[(hardlink-into-bb|rename-into-bb|copy-into-bb|copy-into-usr|symlink-into-bb|overwrite-tool|append-tool|unlink-tool|mkdir-in-bb|rename-tool)\] status=0' ; then
     bad "$name: a program directory was modified under init"; fi
  [ -n "${VERBOSE:-}" ] && { show "$with"; echo "    control:"; show "$ctl"; }
  echo "$with" > "$HERE/out/exec-$name.init.txt"; echo "$ctl" > "$HERE/out/exec-$name.control.txt"
}

run_cfg plain            /tmp      $IMG $NOBODY
run_cfg var-tmp          /var/tmp  $IMG $NOBODY
run_cfg dev-shm          /dev/shm  $IMG $NOBODY
run_cfg dev-shm-exec     /dev/shm  $IMG $NOBODY --tmpfs /dev/shm:exec,mode=1777
run_cfg volume           /data     $IMG $NOBODY -v $V:/data
run_cfg tmpfs-exec       /scratch  $IMG $NOBODY --tmpfs /scratch:uid=65534,gid=65534,mode=0700,exec
run_cfg read-only        /tmp      $IMG $NOBODY --read-only --tmpfs /tmp:exec
run_cfg ipc-host-pid-host-net-host /tmp $IMG $NOBODY --ipc host --pid host --network host
run_cfg ports-device     /tmp      $IMG $NOBODY -p 127.0.0.1::80 --device /dev/fuse -e KCOS_DEV=/dev/fuse
run_cfg cap-add-all-privileged /tmp $IMG $NOBODY --privileged --cap-add ALL
run_cfg root-privileged  /tmp      $IMG -u 0:0 --privileged
run_cfg docker-init      /tmp      $IMG $NOBODY --init
run_cfg seccomp-apparmor-unconfined /tmp $IMG $NOBODY --security-opt seccomp=unconfined --security-opt apparmor=unconfined
run_cfg other-uid        /tmp      $IMG -u 1000:1000
run_cfg third-party      /data     $THIRD -e B=/app/bin
run_cfg sealed-agent-recipe /work  $SEALED -i --read-only --network none --ipc none --memory 512m --pids-limit 128 --tmpfs /work:uid=65534,gid=65534,mode=0700
run_cfg sealed-tmpfs-exec /work    $SEALED --read-only --tmpfs /work:uid=65534,gid=65534,mode=0700,exec

# The release image itself, with nothing but its own tools: the program
# arrives on standard input (the download), is written, made executable, run.
echo "## release image, built-in tools only: cat > /tmp/evil; chmod; run"
S='cat > /tmp/evil; chmod 755 /tmp/evil; /tmp/evil; echo "direct=$?"; env /tmp/evil; echo "env=$?"; PATH=/tmp; evil; /bin/echo "path=$?"'
with=$(timeout 120 docker run -i --rm --platform linux/arm64 kcontaineros sh -c "$S" < "$HERE/out/evil" 2>&1)
ctl=$(timeout 120 docker run -i --rm --platform linux/arm64 --entrypoint /bin/sh kcontaineros -c "$S" < "$HERE/out/evil" 2>&1)
show "$with"; echo "    control:"; show "$ctl"
if ! echo "$with" | grep -q EVIL-BINARY-RAN && [ "$(echo "$ctl" | grep -c EVIL-BINARY-RAN)" = 3 ]; then ok "release image: a downloaded program is not started (control: started 3 times)"; else bad "release image: downloaded program started"; fi
summary
