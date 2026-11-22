#!/bin/bash
# Goal: reach from the workload under init into what runs outside it
# (docker exec sessions, other containers with --pid host), and check the
# limits the README states against what a container does.
. "$(dirname "$0")/lib.sh"
trap cleanup_names EXIT
PROBE='kp openw /proc/$P/mem; kp openr /proc/$P/mem; ls /proc/$P/root/ >/dev/null 2>&1; echo "root=$?"; cat /proc/$P/environ >/dev/null 2>&1; echo "environ=$?"; readlink /proc/$P/fd/0 >/dev/null 2>&1; echo "fd=$?"; readlink /proc/$P/cwd >/dev/null 2>&1; echo "cwd=$?"; cat /proc/$P/maps >/dev/null 2>&1; echo "maps=$?"; /proc/$P/root/tmp/evil 2>&1; echo "exec-through-root=$?"; kill -0 $P; echo "signal=$?"'

echo "## a docker exec session (outside Landlock) seen from the workload under init, same user"
c=$T-exec-$$
docker run -d --platform linux/arm64 $NOBODY --name $c $IMG sh -c 'cp /opt/evil /tmp/evil; chmod 755 /tmp/evil; while [ ! -e /tmp/go ]; do sleep 0.2; done; P=$(cat /tmp/pid); '"$PROBE"'; echo DONE; while [ ! -e /tmp/go2 ]; do sleep 0.2; done; kp tiocsti /dev/pts/0; sleep 60' >/dev/null
sleep 1
timeout 30 docker exec -d $NOBODY $c busybox sh -c 'echo $$ > /tmp/pid; exec sleep 4242'
sleep 1
timeout 30 docker exec $NOBODY $c busybox touch /tmp/go
sleep 2
with=$(docker logs $c 2>&1)
ctl=$(timeout 30 docker exec $NOBODY $c busybox sh -c 'P=$(cat /tmp/pid); '"$PROBE" 2>&1)
show "$with"; echo "    control (the same probes from a second exec session):"; show "$ctl"
n=$(echo "$with" | grep -cE 'errno 13|^(root|environ|fd|cwd|maps)=1$')
if [ "$n" = 7 ] && echo "$with" | grep -q 'exec-through-root=126' && echo "$ctl" | grep -q 'O_WRONLY|O_APPEND: ok' && echo "$ctl" | grep -q 'EVIL-BINARY-RAN'; then
  ok "the workload cannot open the memory, root, environ, descriptors, cwd or maps of an exec session, nor start a program through it (control: an exec session can)"
else bad "the workload under init reached into a docker exec session ($n of 7 refused)"; fi
echo "$with" | grep -q 'signal=0' && note "the workload can signal an exec session of the same user (plain UID rule)"
echo "  what a docker exec session is:"
e=$(timeout 30 docker exec $NOBODY $c /bin/cat /proc/self/status | grep -E 'NoNewPrivs|Seccomp:|CapEff'); show "$e"
r=$(timeout 30 docker exec -u 0 $c /bin/cat /proc/self/status | grep -E 'NoNewPrivs|Seccomp:|CapEff'); echo "    as root:"; show "$r"
x=$(timeout 30 docker exec $NOBODY $c /bin/sh -c '/tmp/evil' 2>&1); show "$x"
if echo "$e" | grep -q 'NoNewPrivs:.1' && echo "$e" | grep -q 'Seccomp:.2' && echo "$x" | grep -q EVIL-BINARY-RAN && ! echo "$r" | grep -q 'CapEff:.0000000000000000'; then
  ok "as documented: an exec'd shell/utility has no_new_privs and the filter, keeps capabilities, and is not under the run-or-write rule"; else bad "docker exec differs from the README"; fi
echo "  the terminal of an exec session (docker exec -t, same user), from the workload: push a '#' into its input"
timeout 30 docker exec -dt $NOBODY $c /bin/sh
sleep 1
timeout 30 docker exec $NOBODY $c busybox touch /tmp/go2
sleep 2
x=$(docker logs $c 2>&1 | sed -n '/^DONE$/,$p' | sed 1d); show "$x"
y=$(timeout 30 docker exec $NOBODY $c busybox sh -c 'kp tiocsti /dev/pts/0' 2>&1); echo "    control (a second exec session, not its controlling terminal either):"; show "$y"
if echo "$x" | grep -q 'TIOCSTI: errno'; then ok "the workload cannot push input into an exec session's terminal (TIOCSTI refused; the kernel's rule, not init's: the control is refused too)"
elif echo "$x" | grep -q 'TIOCSTI: ok'; then bad "the workload under init typed into a docker exec session that is outside Landlock"; else note "TIOCSTI probe did not run"; fi
echo "$x" | grep -q 'open terminal: ok' && note "the workload can open an exec session's terminal of the same user (read what is typed, write to the screen): UID rule, the device is in /dev/pts"
docker rm -f $c >/dev/null

echo "## --pid host: another container's process of the same user"
v=$T-victim-$$
docker run -d --platform linux/arm64 $NOBODY --name $v $CTL $IMG sleep 4243 >/dev/null
sleep 1
A='P=$(pgrep -f "sleep 4243" | head -1); echo "victim pid $P"; cp /opt/evil /tmp/evil; '"$PROBE"
with=$($D $NOBODY --pid host $IMG sh -c "$A" 2>&1); ctl=$($D $NOBODY --pid host $CTL $IMG sh -c "$A" 2>&1)
docker rm -f $v >/dev/null
show "$with"; echo "    control:"; show "$ctl"
n=$(echo "$with" | grep -cE 'errno 13|^(root|environ|fd|cwd|maps)=1$')
if [ "$n" = 7 ] && echo "$ctl" | grep -q 'root=0'; then ok "--pid host: under init the workload cannot open another container's process (control: it can)"; else bad "--pid host: reached another container's process ($n of 7 refused)"; fi

echo "## documented limit: processes of the same user under init can open each other's memory"
out=$($D $NOBODY $IMG sh -c 'sleep 5 & kp openw /proc/$!/mem' 2>&1); show "$out"
echo "$out" | grep -q ': ok' && note "confirmed as documented (open for writing succeeds, nothing was written)"

echo "## documented limit: no Landlock (simulated: Docker's filter answers the three Landlock calls with ENOSYS / EPERM)"
for e in 38 1; do
  f="$HERE/out/no-landlock-$e.json"
  echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["landlock_create_ruleset","landlock_add_rule","landlock_restrict_self"],"action":"SCMP_ACT_ERRNO","errnoRet":'$e'}]}' > "$f"
  out=$($D $NOBODY --security-opt seccomp="$f" $IMG sh -c 'cp /opt/evil /tmp/evil; chmod 755 /tmp/evil; /tmp/evil; echo "exec=$?"; kp memfd' 2>&1); show "$out"
  if echo "$out" | grep -q 'warning: Landlock is unavailable' && echo "$out" | grep -q EVIL-BINARY-RAN && echo "$out" | grep -q 'memfd_create: errno 1'; then
    ok "errno $e: init warns, the run-or-write rule is off, the filter is still on (as documented)"; else bad "errno $e: behaviour without Landlock differs from the README"; fi
done

echo "## Landlock cannot be set up for another reason: a low soft limit on open files (--ulimit nofile=N:1024)"
for n in 3 8 16 20 24; do
  out=$($D $NOBODY --ulimit nofile=$n:1024 $IMG sh -c 'ulimit -n 1024; cp /opt/evil /tmp/evil; chmod 755 /tmp/evil; /tmp/evil; echo "exec=$?"' 2>&1)
  echo "  nofile=$n:1024 -> $(echo "$out" | tr '\n' '|' | cut -c1-160)"
  if echo "$out" | grep -q EVIL-BINARY-RAN; then bad "nofile=$n:1024: init started the command without the run-or-write rule"
  elif echo "$out" | grep -q 'exec=126'; then ok "nofile=$n:1024: the run-or-write rule is in force"
  else note "nofile=$n:1024: the runtime itself cannot start a container with so few descriptors, so init never runs short of them"; fi
done

echo "## documented limit: noexec on writable directories 'to stop files there being mapped as code'"
out=$($D --tmpfs /work:uid=65534,gid=65534,mode=0700 $SEALED sh -c 'cp /opt/payload.bin /work/p; kp mapexec /work/p; kp anonexec /work/p' 2>&1); show "$out"
if echo "$out" | grep -q 'mmap PROT_EXEC of file: errno 1' && echo "$out" | grep -q 'RUNTIME-CODE-RAN'; then
  note "noexec stops mmap(PROT_EXEC) of the file, but the same bytes read into anonymous memory and made executable run all the same: noexec does not stop code written at run time from running inside a process that can be made to load it"; fi
echo "## the binary under other names (execve with a chosen argv[0])"
out=$($D $SEALED kp argv0 /sbin/init sh -c 'echo SHELL-IN-SEALED' 2>&1); show "$out"
echo "$out" | grep -q SHELL-IN-SEALED && bad "the sealed binary acts as a shell when called sh" || ok "sealed: called as 'sh' it is still init (it looks for a command named -c)"
out=$($D $NOBODY $IMG sh -c 'kp argc0 /bin/kcontaineros; echo "status=$?"; kp argv0 /bin/kcontaineros "" ; echo "status=$?"; kp argv0 /bin/kcontaineros init; echo "status=$?"' 2>&1 </dev/null); show "$out"
echo "$out" | grep -q 'internal error' && bad "the binary panics on an unusual argv" || ok "empty argv, empty argv[0] and a bare 'init' do not crash the binary"
summary
