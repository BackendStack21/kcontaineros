# The checks. Sourced by e2e.sh, which provides the helpers.
# shellcheck shell=bash disable=SC2016

APPLETS="cat chmod chown cp echo env false kill ln ls mkdir mv ps pwd rm sleep touch true uname"

# ---------------------------------------------------------------- image
echo "== image"
check "architecture is arm64" arm64 "$(docker image inspect -f '{{.Architecture}}' "$IMG")"
c=$(docker create "$IMG")
listing=$(docker export "$c" | tar -t | sed 's|/$||' \
  | grep -v -E '^(\.dockerenv|dev/.*|etc/(hostname|hosts|resolv\.conf|mtab)|cov.*)$' | LC_ALL=C sort | tr '\n' ' ')
want="bin"
for a in $APPLETS kcontaineros sh; do want="$want bin/$a"; done
want=$(printf '%s\n' $want | LC_ALL=C sort | tr '\n' ' ')
check "the image contains exactly these files" \
  "${want}dev etc etc/group etc/nsswitch.conf etc/os-release etc/passwd home proc root run sbin sbin/init sys tmp usr usr/bin usr/bin/env usr/local usr/local/bin var var/run var/tmp " \
  "$listing"
if [ -z "$COV" ]; then
  mkdir -p target
  docker cp -q "$c:/bin/kcontaineros" target/kcontaineros.bin
  check "binary is a static PIE with a non-executable stack and RELRO" \
    "type=pie interp=no execstack=no wx=no relro=yes" "$(python3 test/elf.py target/kcontaineros.bin)"
  check "at run time its code and constants are read-only" "r--p r-xp r--p" \
    "$(docker run --rm "${D[@]}" "$IMG" cat /proc/self/maps | awk '/kcontaineros/{printf "%s ", $2}' | sed 's/ $//')"
  size=$(docker image inspect -f '{{.Size}}' "$IMG")
  if [ "$size" -lt 250000 ]; then ok "image is under 250 kB ($size bytes)"; else ko "image is under 250 kB" "<250000" "$size"; fi
  size=$(wc -c < target/kcontaineros.bin | tr -d ' ')
  if [ "$size" -lt 100000 ]; then ok "binary is under 100 kB ($size bytes)"; else ko "binary is under 100 kB" "<100000" "$size"; fi
  docker build -q --no-cache --platform "$PLATFORM" -t "$REPRO" . >/dev/null 2>&1
  check "rebuilding from scratch gives the identical layer" \
    "$(docker image inspect -f '{{json .RootFS.Layers}}' "$IMG")" "$(docker image inspect -f '{{json .RootFS.Layers}}' "$REPRO")"
fi
docker rm "$c" >/dev/null
out=$(docker build --platform linux/amd64 . 2>&1); rc=$?
check "an amd64 build is refused" "nonzero supports linux/arm64 only" \
  "$([ $rc -ne 0 ] && echo nonzero) $(printf '%s' "$out" | grep -o 'supports linux/arm64 only' | head -1)"
if [ -z "$COV" ]; then
  base() { run -- sh -c 'cat /proc/self/maps' | awk '/kcontaineros/{print $1; exit}'; }
  a1=$(base); a2=$(base)
  if [ -n "$a1" ] && [ "$a1" != "$a2" ]; then ok "code is loaded at a different address each run"; else ko "code address is randomised" "two different addresses" "$a1 / $a2"; fi
fi
x "os-release" 0 'NAME="kContainerOS"' /bb/busybox head -1 /etc/os-release
x "passwd has root and nobody" 0 $'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false' cat /etc/passwd
x "nsswitch.conf resolves files first" 0 "hosts: files dns" /bb/busybox tail -1 /etc/nsswitch.conf
x "/tmp is sticky and world-writable, /root is private" 0 $'dr-x------ 0 0 root\ndrwxrwxrwt 0 0 tmp' \
  /bb/busybox sh -c 'ls -l / | /bb/busybox awk "\$5==\"root\"||\$5==\"tmp\"{print \$1,\$2,\$3,\$5}"'
x "/var/run points at /run" 0 "lrwxrwxrwx 0 0 6 run -> ../run" /bb/busybox sh -c 'ls -l /var | /bb/busybox grep run'
x "PATH" 0 "PATH=/usr/local/bin:/usr/bin:/bin:/sbin" /bb/busybox sh -c 'env | /bb/busybox grep ^PATH='

# ----------------------------------------------------------------- init
echo "== init"
expect "runs the command" 0 "hello" -- run -- echo hello
check "is PID 1 and the command is its child" $'  PID S COMMAND\n    1 S /sbin/init ps\n    N R ps' \
  "$(run -- ps | sed 's/^ *[0-9]* R ps$/    N R ps/')"
expect "passes the exit status through" 42 "" -- run -- sh -c 'exit 42'
expect "an empty command name exits 127" 127 "kcontaineros: : no such file or directory" -- run -- ""
expect "a missing command exits 127" 127 "kcontaineros: nope: no such file or directory" -- run -- nope
expect "a non-executable file exits 126" 126 "kcontaineros: /etc/passwd: permission denied" -- run -- /etc/passwd
expect "-- ends init's own arguments" 0 "dashdash" -- run -- -- echo dashdash
expect "with no command it runs /bin/sh" 0 "" -- run --entrypoint /sbin/init --
expect "PATH from the environment is used" 127 "kcontaineros: ls: no such file or directory" -- run -e PATH=/nonexistent -- ls
expect "an empty PATH entry means the current directory" 0 "from-cwd" -- run -e PATH= -w /bin -- echo from-cwd
expect "permission denied on PATH is reported as such" 126 "kcontaineros: passwd: permission denied" -- run -e PATH=/etc:/bin -- passwd
x "without PATH a default is used" 0 "default-path" /bb/busybox env -i /sbin/init echo default-path
x "kcontaineros init COMMAND" 0 "multi-call" kcontaineros init echo multi-call
long=$(python3 -c 'print("a/" * 3000, end="")')
expect "an over-long path is rejected" 126 "kcontaineros: $long: file name too long" -- run -- "$long"
long=$(python3 -c 'print("a" * 5000, end="")')
expect "an over-long name is not found" 127 "kcontaineros: $long: no such file or directory" -- run -- "$long"
expect "fork failure is reported" 1 "kcontaineros: fork: resource temporarily unavailable" -- run --pids-limit 1 -- true
expect "works under docker --init too" 0 "with-docker-init" -- run --init -- echo with-docker-init

c=$(start -- sleep 300)
t0=$(now_ms); docker stop -t 10 "$c" >/dev/null; t1=$(now_ms)
if [ $((t1 - t0)) -lt 3000 ]; then ok "docker stop is immediate ($((t1 - t0)) ms)"; else ko "docker stop is immediate" "<3000 ms" "$((t1 - t0)) ms"; fi
check "exit status shows the signal (128+15)" 143 "$(docker inspect -f '{{.State.ExitCode}}' "$c")"
c=$(start -- sleep 300)
docker kill -s INT "$c" >/dev/null
check "SIGINT is forwarded (128+2)" 130 "$(docker wait "$c")"

TRAPS='trap "echo got-HUP" HUP; trap "echo got-USR1" USR1; trap "echo got-QUIT" QUIT; trap "echo got-TERM; exit 0" TERM; echo ready; while :; do /bb/busybox sleep 0.1; done'
c=$(start -- /bb/busybox sh -c "$TRAPS"); sleep 1
for s in HUP USR1 QUIT; do docker kill -s $s "$c" >/dev/null; sleep 0.4; done
docker stop -t 10 "$c" >/dev/null
check "each signal reaches the command's own handler" $'ready\ngot-HUP\ngot-USR1\ngot-QUIT\ngot-TERM [exit 0]' \
  "$(docker logs "$c" 2>&1) [exit $(docker inspect -f '{{.State.ExitCode}}' "$c")]"
c=$(start -- sh -c "/bb/busybox sh -c '$TRAPS'"); sleep 1
docker stop -t 10 "$c" >/dev/null
check "shell-form commands still shut down gracefully" $'ready\ngot-TERM [exit 0]' \
  "$(docker logs "$c" 2>&1) [exit $(docker inspect -f '{{.State.ExitCode}}' "$c")]"

zombies() { docker exec "$1" ps | awk 'NR==1{h=$0} $2=="Z"{z++} END{print h " zombies=" z+0}'; }
c=$(start -- sh -c '/bb/busybox sh -c "sleep 1 &"; sleep 5; exit 4'); sleep 2.5
check "an orphan is adopted and reaped" "  PID S COMMAND zombies=0" "$(zombies "$c")"
expect "docker exec works" 0 "hi" -- docker exec "$c" echo hi
check "  and init still ends with the command's status" 4 "$(docker wait "$c")"
c=$(start --entrypoint /bin/sh -- -c '/bb/busybox sh -c "sleep 1 &"; sleep 30'); sleep 2.5
check "control: without init the same orphan stays a zombie" "  PID S COMMAND zombies=1" "$(zombies "$c")"
docker rm -f "$c" >/dev/null

t "nested init stops what its command left behind" 0 $'inner-done\nrc=0\nleft=1' \
  '/sbin/init sh -c "sleep 50 & sleep 51 & echo inner-done"; echo "rc=$?"; /bb/busybox pgrep -f "^sleep 5[01]$"; echo "left=$?"'
expect "init in a PID namespace whose /proc is not its own still stops its command's group" 0 $'inner-done\nrc=0' -- \
  run --privileged --user 0 --entrypoint /bb/busybox -- unshare -p -f /bin/sh -c '/sbin/init sh -c "sleep 50 & echo inner-done"; echo "rc=$?"'
t0=$(now_ms)
t "nested init kills leftovers that ignore SIGTERM" 0 $'rc=0\nleft=1' \
  '/sbin/init /bb/busybox sh -c "trap \"\" TERM; /bb/busybox sleep 60 & /bb/busybox sleep 0.3"; echo "rc=$?"; /bb/busybox pgrep -f "^/bb/busybox sleep 60$"; echo "left=$?"'
t1=$(now_ms)
if [ $((t1 - t0)) -ge 2000 ]; then ok "  after a grace period ($((t1 - t0)) ms)"; else ko "  after a grace period" ">=2000 ms" "$((t1 - t0)) ms"; fi
k "nested init survives being stopped and continued" 0 "rc=0" \
  '/sbin/init /bb/busybox sleep 1 & p=$!; sleep 0.3; /bin/kill -STOP $p; sleep 0.2; /bin/kill -CONT $p; wait $p; echo rc=$?'
k "init resumes a command stopped by Ctrl-Z's signal, and leaves SIGSTOP alone" 0 $'S\nT\nrc=0' \
  '/sbin/init /bb/busybox sleep 2 & p=$!; sleep 0.3; c=$(pgrep -P $p); /bin/kill -20 $c; sleep 0.3; cut -d" " -f3 /proc/$c/stat; /bin/kill -STOP $c; sleep 0.3; cut -d" " -f3 /proc/$c/stat; /bin/kill -CONT $c; wait $p; echo rc=$?'

expect "read-only, no capabilities, non-root, no-new-privileges, 8 MB" 0 \
  $'sh: /tmp/f: read-only file system\nUid:\t65534\t65534\t65534\t65534\nCapEff:\t0000000000000000\nNoNewPrivs:\t1' -- \
  run --read-only --cap-drop ALL --user 65534:65534 --security-opt no-new-privileges --memory 8m -- \
  /bb/busybox sh -c 'sh -c "echo x > /tmp/f" 2>&1; /bb/busybox grep -E "^(Uid|CapEff|NoNewPrivs):" /proc/self/status'

# ------------------------------------------------------------- lockdown
echo "== lockdown"
check "the default user is nobody" "65534 65534" \
  "$(docker run --rm "${D[@]}" "$IMG" cat /proc/self/status | awk '$1=="Uid:"||$1=="Gid:"{printf "%s ", $2}' | sed 's/ $//')"
STATUS='/bb/busybox grep -E "^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):" /proc/self/status'
LOCKED=$'CapInh:\t0000000000000000\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000\nCapBnd:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2'
# The strongest attacker Docker can hand over: root, every capability,
# all devices, and Docker's own system call filter switched off.
PRIV=(--privileged --user 0 --security-opt seccomp=unconfined)
expect "a command holds no capability and can gain none" 0 "$LOCKED" -- run -- /bb/busybox sh -c "$STATUS"
expect "  not even as root in a --privileged container" 0 "$LOCKED" -- run "${PRIV[@]}" -- /bb/busybox sh -c "$STATUS"
ATTACKS='unshare -U true; echo "rc=$?"
mount -t tmpfs none /tmp; echo "rc=$?"
hostname pwned; echo "rc=$?"
chroot / /bb/busybox true; echo "rc=$?"
setarch linux64 -R /bb/busybox true; echo "rc=$?"
echo x >> /etc/passwd; echo "rc=$?"
cat /proc/1/environ; echo "rc=$?"
cp /bb/busybox /tmp/busybox; /tmp/busybox echo PWNED; echo "rc=$?"
chmod 777 /usr/local/bin; cp /bb/busybox /usr/local/bin/tool; echo "rc=$?"
mv /tmp/busybox /bb/tool; echo "rc=$?"
mkdir /newdir; echo "rc=$?"
ln -s x /bb/newlink; echo "rc=$?"
truncate -s 0 /bb/probe; echo "rc=$?"
rm /bb/probe; echo "rc=$?"
true >> "$(find /sys/kernel -maxdepth 1 -type f -perm -200 | head -n 1)"; echo "rc=$?"'
expect "privileged root cannot reconfigure the kernel, leave its namespaces, change the image or run a new program" 0 \
"unshare: unshare(0x10000000): Operation not permitted
rc=1
mount: permission denied (are you root?)
rc=1
hostname: sethostname: Operation not permitted
rc=1
chroot: can't change root directory to '/': Operation not permitted
rc=1
linux64: personality(0x40000): Operation not permitted
rc=1
sh: line 5: can't create /etc/passwd: Permission denied
rc=1
cat: can't open '/proc/1/environ': Permission denied
rc=1
sh: line 7: /tmp/busybox: Permission denied
rc=126
cp: can't create '/usr/local/bin/tool': Permission denied
rc=1
mv: can't rename '/tmp/busybox': Permission denied
rc=1
mkdir: can't create directory '/newdir': Permission denied
rc=1
ln: /bb/newlink: Permission denied
rc=1
truncate: /bb/probe: open: Permission denied
rc=1
rm: can't remove '/bb/probe': Permission denied
rc=1
rc=1" -- run "${PRIV[@]}" -e PATH=/bb -- /bb/busybox sh -c "{ $ATTACKS
} 2>&1 | grep -v 'sys/kernel'"
expect "control: without init the same container allows them" 0 $'rc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nPWNED\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0' -- \
  run "${PRIV[@]}" -e PATH=/bb --entrypoint /bb/busybox -- sh -c "{ $ATTACKS
} 2>&1 | grep -a -E '^(rc=|PWNED)'"
PROBES="memfd_create memfd_secret process_vm_readv io_uring_setup bpf userfaultfd clone_newuser vsock socket clone3 newer_than_filter ptrace"
expect "system calls for running code from memory, reaching other processes and new kernel interfaces are refused" 0 \
  $'memfd_create: errno 1\nmemfd_secret: errno 1\nprocess_vm_readv: errno 1\nio_uring_setup: errno 1\nbpf: errno 1\nuserfaultfd: errno 1\nclone_newuser: errno 1\nvsock: errno 1\nsocket: allowed\nclone3: errno 38\nnewer_than_filter: errno 38\nptrace: errno 1' -- \
  run "${PRIV[@]}" -- /bb/probe $PROBES
# Every number on the filter's list, with arguments no kernel accepts: an
# answer of "not permitted" can then only be the filter's.
REFUSED=$(sed -n '/^const DENIED/,/^];/s/^ *\([0-9][0-9]*\),.*/raw:\1/p' src/lock.rs | tr '\n' ' ')
check "every system call on the filter's list is refused before the kernel looks at it" "$(echo $REFUSED | wc -w | tr -d ' ') errno 1" \
  "$(run "${PRIV[@]}" -- /bb/probe $REFUSED | cut -d' ' -f2- | sort | uniq -c | sed 's/^ *//')"
# The namespace flags of clone, in a combination the kernel calls invalid
# before it looks at anything else.
NS="clone:20000 clone:4000000 clone:8000000 clone:10000000 clone:20000000 clone:40000000 clone:2000000"
check "clone with any namespace flag is refused by the filter" "7 errno 1" \
  "$(run "${PRIV[@]}" -- /bb/probe $NS | cut -d' ' -f2- | sort | uniq -c | sed 's/^ *//')"
check "  control: without init the kernel calls each invalid" "7 errno 22" \
  "$(run "${PRIV[@]}" --entrypoint /bb/probe -- $NS | cut -d' ' -f2- | sort | uniq -c | sed 's/^ *//')"
# (Not vhangup, 58: it takes no arguments, so it would be carried out.)
check "  control: without init the kernel answers each of them something else" "0" \
  "$(run "${PRIV[@]}" --entrypoint /bb/probe -- ${REFUSED/raw:58 /} | grep -c ': errno 1$')"
# Without init none is refused with EPERM. Some fail for other reasons
# (bad arguments, not built into this kernel), so only those are pinned.
# The hypervisor socket is left out: a control need not open one for real.
check "control: without init the kernel accepts them" "memfd_create: allowed clone_newuser: allowed ptrace: allowed refused=0" \
  "$(run "${PRIV[@]}" --entrypoint /bb/probe -- ${PROBES/vsock /} | awk '/^(memfd_create|ptrace|clone_newuser):/{printf "%s ", $0} /errno 1$/{n++} END{print "refused=" n+0}')"
expect "the shell reports the refusal" 0 $'sh: /tmp/busybox: permission denied\nrc=126' -- \
  run -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'cp /bb/busybox /tmp/busybox; /tmp/busybox echo PWNED; echo "rc=$?"'
t "a shell started with docker exec cannot gain privileges either" 0 $'NoNewPrivs:\t1\nSeccomp:\t2' \
  '/bb/busybox grep -E "^(NoNewPrivs|Seccomp):" /proc/self/status'
long=$(python3 -c 'print("/" + "a" * 5000, end="")')
W='is not a directory (symbolic links are not followed): ignored'
expect "KCOS_EXEC names further directories; entries it cannot use are skipped with a warning" 0 \
  "kcontaineros: warning: KCOS_EXEC: relative is not a plain absolute path: ignored
kcontaineros: warning: KCOS_EXEC: /nonexistent $W
kcontaineros: warning: KCOS_EXEC: $long $W
allowed" -- \
  run -e "KCOS_EXEC=relative::/nonexistent:$long:/bb" -- /bb/busybox echo allowed
N='is not a plain absolute path: ignored'
expect "  / and paths with .. are not accepted as program directories, nor is anything in /dev" 126 \
  "kcontaineros: warning: KCOS_EXEC: / $N
kcontaineros: warning: KCOS_EXEC: /bb/../tmp $N
kcontaineros: warning: KCOS_EXEC: /bb/./ $N
kcontaineros: warning: KCOS_EXEC: /dev/shm cannot hold programs: ignored
sh: /tmp/busybox: permission denied" -- \
  run -e "KCOS_EXEC=/:/bb/../tmp:/bb/./:/dev/shm:/bb" -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'cp /bb/busybox /tmp/busybox; /tmp/busybox echo PWNED'
expect "  without it only the image's own directories qualify" 126 "kcontaineros: /bb/busybox: permission denied" -- \
  run -e KCOS_EXEC= -- /bb/busybox echo PWNED
expect "moving and linking between directories still work" 0 $'moved\nlinked' -- \
  run -- sh -c 'mkdir /tmp/a /tmp/b; echo moved > /tmp/a/f; mv /tmp/a/f /tmp/b; cat /tmp/b/f; echo linked > /tmp/a/g; ln /tmp/a/g /tmp/b/g; cat /tmp/b/g'
expect "nobody can listen on a port below 1024 without any capability" 0 "bound" -- \
  run --user 65534:65534 -- /bb/busybox sh -c '/bb/busybox httpd -p 80 -h /tmp 2>&1 && echo bound'
expect "nobody cannot change the image" 0 $'sh: /bin/kcontaineros: permission denied\nsh: /etc/passwd: permission denied\nsh: /usr/local/bin/x: permission denied' -- \
  run --user 65534:65534 -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'echo x > /bin/kcontaineros; echo x >> /etc/passwd; echo x > /usr/local/bin/x; true'
mkdir -p target
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["landlock_create_ruleset"],"action":"SCMP_ACT_ERRNO","errnoRet":38}]}' > target/no-landlock.json
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["seccomp"],"action":"SCMP_ACT_ERRNO","errnoRet":1}]}' > target/no-seccomp.json
expect "a kernel without Landlock gets a warning" 0 $'kcontaineros: warning: Landlock is unavailable, so programs can be run from any path\nhi' -- \
  run --security-opt "seccomp=target/no-landlock.json" -- echo hi
expect "without the system call filter nothing runs at all" 125 "kcontaineros: cannot install the system call filter" -- \
  run --security-opt "seccomp=target/no-seccomp.json" -- echo hi

if [ -z "$COV" ]; then
  echo "== sealed image"
  docker build -q --platform "$PLATFORM" --target sealed -t "$SEALED" . >/dev/null 2>&1 || ko "sealed image builds" success failure
  c=$(docker create "$SEALED" x)
  check "it contains init and nothing to run or write to" \
    "dev etc etc/group etc/nsswitch.conf etc/os-release etc/passwd proc run sbin sbin/init sys usr usr/bin usr/local usr/local/bin var var/run " \
    "$(docker export "$c" | tar -t | sed 's|/$||' | grep -v -E '^(\.dockerenv|dev/.*|etc/(hostname|hosts|resolv\.conf|mtab))$' | LC_ALL=C sort | tr '\n' ' ')"
  docker rm "$c" >/dev/null
  expect "there is no shell" 127 "kcontaineros: /bin/sh: no such file or directory" -- docker run --rm "$SEALED"
  docker build -q --platform "$PLATFORM" -t "$SEALED-test" - >/dev/null 2>&1 <<DOCKERFILE
FROM $BUSYBOX AS bb
FROM $SEALED
COPY --from=bb /bin/busybox /usr/local/bin/busybox
DOCKERFILE
  # Started as nobody, init cannot empty the bounding set (CapBnd), and need
  # not: with no_new_privs nothing can ever draw on it.
  expect "a static binary runs, as nobody, locked down" 0 "Uid:	65534	65534	65534	65534
${LOCKED/CapBnd:	0000000000000000
/}" -- docker run --rm "$SEALED-test" busybox grep -E "^(Uid|Cap(Inh|Prm|Eff|Amb)|NoNewPrivs|Seccomp):" /proc/self/status
  expect "the binary is init whatever it is called" 127 "kcontaineros: -c: no such file or directory" -- \
    docker run --rm "$SEALED-test" busybox sh -c 'exec -a sh /sbin/init -c "echo shell"'
  expect "no directory in the image is writable by nobody" 0 "" -- \
    docker run --rm "$SEALED-test" busybox find / -xdev -type d '(' -perm -0002 -o -user 65534 ')'
  size=$(docker image inspect -f '{{.Size}}' "$SEALED")
  if [ "$size" -lt 110000 ]; then ok "sealed image is about 100 kB ($size bytes)"; else ko "sealed image is about 100 kB" "<110000" "$size"; fi
fi

# ------------------------------------------------------------- terminal
echo "== terminal"
session=$(typed 'echo tty-ok\n' 'sleep 100\n' '\x03' 'echo "rc=$?"\n' '\x1a' 'echo after-ctrl-z\n' 'echo "open\n' 'quote"\n' 'exit 7\n' \
  -- docker run -it --rm "${D[@]}" "$TEST")
check "interactive shell: output, Ctrl-C, Ctrl-Z, multi-line quotes, exit status" \
  "tty-ok rc=130 after-ctrl-z open quote [exit 7] " \
  "$(printf '%s\n' "$session" | grep -x -E 'tty-ok|rc=130|after-ctrl-z|open|quote|\[exit 7\]' | tr '\n' ' ')"
check "  prompts: path and # for root, > for a continuation" "2" \
  "$(printf '%s\n' "$session" | grep -c -x -E '/ # echo tty-ok|> quote"')"
session=$(typed 'cd /tmp\n' '\x04' -- docker run -it --rm --user 65534:65534 "${D[@]}" "$TEST")
check "non-root prompt is \$, Ctrl-D ends the session" "/ \$ cd /tmp [exit 0] " \
  "$(printf '%s\n' "$session" | grep -x -E '/ \$ cd /tmp|\[exit 0\]' | tr '\n' ' ')"
session=$(typed 'echo start\n' '/sbin/init true\n' 'echo alive\n' 'exit\n' -- docker run -it --rm "${D[@]}" "$TEST")
check "nested init hands the terminal back" "start alive [exit 0] " \
  "$(printf '%s\n' "$session" | grep -x -E 'start|alive|\[exit 0\]' | tr '\n' ' ')"
bb 'mkdir -p /t/tty && touch "/t/tty/$(printf "a\033[31mb\302\233")"'
check "ls hides control characters on a terminal, 8-bit ones too" "a?[31mb??" "$(docker exec -t "$BENCH" ls /t/tty | tr -d '\r')"
check "ls -l does too" "-rw-r--r-- 0 0 0 a?[31mb??" "$(docker exec -t "$BENCH" ls -l /t/tty | tr -d '\r')"
check "  but not when piped" $'a\033[31mb\302\233' "$(docker exec "$BENCH" ls /t/tty)"
session=$(typed '\x1a' -- docker run -it --rm "${D[@]}" "$TEST" /bb/busybox sleep 3)
check "Ctrl-Z cannot freeze a foreground command" "[exit 0]" "$(printf '%s\n' "$session" | grep -o '\[exit .*\]')"

# ------------------------------------------------------------ multi-call
echo "== multi-call binary"
x "--version" 0 "kcontaineros 1.0.0" kcontaineros --version
x "-V" 0 "kcontaineros 1.0.0" kcontaineros -V
x "--list" 0 "init sh $APPLETS" /bb/busybox sh -c 'kcontaineros --list | /bb/busybox tr "\n" " " | /bb/busybox sed "s/ $//"'
USAGE=$'usage: kcontaineros init [--] COMMAND [ARGS...]\n       kcontaineros APPLET [ARGS...]\n       kcontaineros --list | --version'
x "--help" 0 "$USAGE" kcontaineros --help
x "-h" 0 "$USAGE" kcontaineros -h
x "no arguments prints the usage" 0 "$USAGE" kcontaineros
x "kcontaineros APPLET ARGS" 0 "via multi-call" kcontaineros echo via multi-call
x "kcontaineros sh -c" 0 "nested" kcontaineros sh -c 'echo nested'
t "a failed write of --version, --list or --help is an error" 0 $'1\n1\n1' \
  'kcontaineros --version > /dev/full; echo $?; kcontaineros --list > /dev/full; echo $?; kcontaineros --help > /dev/full; echo $?'
x "unknown applet" 127 "kcontaineros: nope: applet not found" kcontaineros nope
bb 'ln -s /bin/kcontaineros /t/strange'
x "unknown name through a symlink" 127 "kcontaineros: strange: applet not found" /t/strange
for a in $APPLETS sh; do
  x "/bin/$a is a link to the binary" 0 "kcontaineros" /bb/busybox readlink "/bin/$a"
done
x "/sbin/init is a link to the binary" 0 "../bin/kcontaineros" /bb/busybox readlink /sbin/init

# ------------------------------------------------------------- utilities
echo "== cat"
bb 'mkdir -p /t/cat && cd /t/cat && echo one > a && echo two > b && echo dash > ./-x'
t "files in order" 0 $'one\ntwo' 'cat /t/cat/a /t/cat/b'
expect_in "stdin by default" 0 "from stdin" "from stdin" -- docker exec -i "$BENCH" cat
expect_in "- means stdin" 0 $'one\nmid\ntwo' $'mid\n' -- docker exec -i "$BENCH" cat /t/cat/a - /t/cat/b
t "-- ends options, so -x is a file" 0 "dash" 'cd /t/cat; cat -- -x'
t "missing file, then carries on" 1 $'cat: /nope: no such file or directory\none' 'cat /nope /t/cat/a'
t "a directory" 1 "cat: /t/cat: is a directory" 'cat /t/cat'
t "a failed write is an error, named once and for what it is" 1 "cat: write error: no space left on device" 'cat /t/cat/a /t/cat/a > /dev/full'

echo "== echo, env, true, false"
t "echo joins with spaces" 0 "a b  c" 'echo a b " c"'
t "echo -n" 0 "no newline" 'echo -n no newline'
t "echo with nothing" 0 "" 'echo'
t "a failed write is an error" 0 "rc=1" 'echo hi > /dev/full; echo "rc=$?"'
big=$(python3 -c 'print("x" * 9000, end="")')
t "echo of more than one buffer" 0 "$big" 'echo "$1"' "$big"
x "env prints the environment" 0 "A=1" /bb/busybox env -i A=1 /bin/env
t "env NAME=VALUE COMMAND runs the command with it" 0 "bar2" 'env FOO=bar B=2 sh -c "echo \$FOO\$B"'
t "env replaces an existing variable" 0 "A=2" 'A=1 env A=2 | /bb/busybox grep ^A='
t "env -i starts from nothing" 0 "ONLY=this" 'env -i ONLY=this'
t "env with a missing command" 127 "env: nope: no such file or directory" 'env FOO=1 nope'
t "env with something that is not a program" 126 "env: /etc/passwd: permission denied" 'env /etc/passwd'
t "env to a full device fails" 1 "" 'env > /dev/full'
t "true" 0 "" 'true'
t "false" 1 "" 'false'

echo "== chmod"
bb 'mkdir -p /t/chmod && touch /t/chmod/f /t/chmod/g'
t "sets permission bits" 0 "-rwx------" 'chmod 700 /t/chmod/f; ls -l /t/chmod/f | /bb/busybox cut -d" " -f1'
t "setuid, setgid and sticky show in ls" 0 $'-rwsr-sr-t\n-rwSr-Sr-T' \
  'chmod 7755 /t/chmod/f; chmod 7644 /t/chmod/g; ls -l /t/chmod | /bb/busybox cut -d" " -f1'
t "usage" 1 "chmod: usage: chmod OCTAL FILE..." 'chmod 644'
t "rejects non-octal modes" 1 "chmod: invalid mode: u+x" 'chmod u+x /t/chmod/f'
t "rejects over-long modes" 1 "chmod: invalid mode: 77777" 'chmod 77777 /t/chmod/f'
t "rejects an empty mode" 1 "chmod: invalid mode: " 'chmod "" /t/chmod/f'
t "missing file" 1 "chmod: /nope: no such file or directory" 'chmod -- 644 /nope'

echo "== chown"
bb 'mkdir -p /t/chown && touch /t/chown/f /t/chown/g'
t "sets owner and group" 0 "-rw-r--r-- 65534 65534 0 /t/chown/f" 'chown 65534:65534 /t/chown/f; ls -l /t/chown/f'
t "owner alone leaves the group" 0 "-rw-r--r-- 1000 0 0 /t/chown/g" 'chown -- 1000 /t/chown/g; ls -l /t/chown/g'
t "usage" 1 "chown: usage: chown UID[:GID] FILE..." 'chown 0'
t "names are not accepted" 1 "chown: invalid owner: root" 'chown root /t/chown/f'
t "an ID that does not fit is rejected" 1 "chown: invalid owner: 0:4294967295" 'chown 0:4294967295 /t/chown/f'
t "an empty group is rejected" 1 "chown: invalid owner: 0:" 'chown 0: /t/chown/f'
t "missing file" 1 "chown: /nope: no such file or directory" 'chown 0:0 /nope'
tu "not allowed for someone else's file" 1 "chown: /t/chown/g: operation not permitted" 'chown 65534 /t/chown/g'

echo "== cp and mv"
bb 'mkdir -p /t/cp/dir && cd /t/cp && echo data > src && chmod 4755 src && ln src hard && ln -s src soft && mkfifo fifo'
t "copies content" 0 "data" 'cd /t/cp; cp src copy; cat copy'
t "copies permission bits but never setuid" 0 "-rwxr-xr-x" 'ls -l /t/cp/copy | /bb/busybox cut -d" " -f1'
t "into a directory" 0 $'copy\nsrc' 'cd /t/cp; cp src copy dir; ls dir'
t "refuses to copy a file onto itself" 0 $'cp: src: source and destination are the same file\ndata' 'cd /t/cp; cp src src; cat src'
t "  or onto a hard link or symlink to it" 0 \
  $'cp: src: source and destination are the same file\ncp: src: source and destination are the same file\ndata' \
  'cd /t/cp; cp src hard; cp src soft; cat src'
t "an empty destination is an error, not the root directory" 1 \
  $'cp: : no such file or directory\nmv: : no such file or directory\nls: /src: no such file or directory\nls: /copy: no such file or directory' \
  'cd /t/cp; cp src ""; mv copy ""; ls /src /copy'
t "a device can be a source" 0 "-rw-r--r-- 0 0 0 /t/cp/empty" 'cp /dev/null /t/cp/empty; ls -l /t/cp/empty'
t "usage" 1 "cp: usage: cp SRC... DST" 'cp onlyone'
t "several sources need a directory" 1 "cp: /t/cp/copy: not a directory" 'cp /t/cp/src /t/cp/hard /t/cp/copy'
t "missing source" 1 "cp: /nope: no such file or directory" 'cp /nope /t/cp/x'
t "a directory source" 1 "cp: /t/cp/dir: is a directory" 'cp /t/cp/dir /t/cp/x'
t "a FIFO source neither blocks nor copies" 1 "cp: /t/cp/fifo: invalid argument" 'cp /t/cp/fifo /t/cp/x'
t "unwritable destination, named in the message" 1 "cp: /nope/dir/x: no such file or directory" 'cp /t/cp/src /nope/dir/x'
t "a failed write is an error" 1 "cp: /dev/full: no space left on device" 'cp /t/cp/src /dev/full'
t "a failed read is an error" 1 "cp: /proc/self/mem: input/output error" 'cp /proc/self/mem /t/cp/mem'
t "-- ends options" 0 "data" 'cd /t/cp; cp -- src -dash; cat -- -dash'
t "mv renames" 0 $'moved\nrc=1' 'cd /t/cp; mv copy moved; ls moved; ls copy 2>/dev/null; echo "rc=$?"'
t "mv into a directory" 0 "moved" 'cd /t/cp; mv moved dir; ls dir | /bb/busybox grep moved'
t "mv of a missing file" 1 "mv: /nope: no such file or directory" 'mv /nope /t/cp/x'
t "mv usage" 1 "mv: usage: mv SRC... DST" 'mv'

echo "== kill"
k "default signal is TERM" 0 "rc=143" '/bb/busybox sleep 100 & /bin/kill $!; wait $! 2>/dev/null; echo rc=$?'
k "-9" 0 "rc=137" '/bb/busybox sleep 100 & /bin/kill -9 $!; wait $! 2>/dev/null; echo rc=$?'
for sig in HUP:129 KILL:137 USR1:138 USR2:140 TERM:143 SIGTERM:143; do
  k "-${sig%:*}" 0 "rc=${sig#*:}" "/bb/busybox sleep 100 & /bin/kill -${sig%:*} \$!; wait \$! 2>/dev/null; echo rc=\$?"
done
# A background job of a script ignores INT and QUIT, so these two get a
# process started on its own: there before, gone after.
for sig in INT QUIT; do
  docker exec -d "$BENCH" /bb/busybox sleep 777
  k "-$sig" 0 $'before=1\nafter=0' \
    "p=\$(pgrep -f '^/bb/busybox sleep 777\$'); echo before=\$(echo \$p | wc -w); /bin/kill -$sig \$p; sleep 0.3; echo after=\$(pgrep -f '^/bb/busybox sleep 777\$' | wc -l)"
done
k "-STOP then -CONT" 0 $'T\nS' \
  '/bb/busybox sleep 100 & p=$!; /bin/kill -STOP $p; /bb/busybox sleep 0.2; /bb/busybox cut -d" " -f3 /proc/$p/stat; /bin/kill -CONT $p; /bb/busybox sleep 0.2; /bb/busybox cut -d" " -f3 /proc/$p/stat; /bin/kill -9 $p'
k "-0 probes without signalling" 0 "rc=0" '/bb/busybox sleep 100 & /bin/kill -0 $!; echo rc=$?; /bin/kill -9 $!'
k "-- before the pids" 0 "rc=143" '/bb/busybox sleep 100 & /bin/kill -TERM -- $!; wait $! 2>/dev/null; echo rc=$?'
t "usage" 1 "kill: usage: kill [-SIGNAL] PID..." 'kill'
t "usage with only a signal" 1 "kill: usage: kill [-SIGNAL] PID..." 'kill -9'
t "unknown signal name" 1 "kill: invalid signal: -NOPE" 'kill -NOPE 1'
t "signal number out of range" 1 "kill: invalid signal: -65" 'kill -65 1'
t "signal number that would wrap to 9" 1 "kill: invalid signal: -4294967305" 'kill -4294967305 1'
t "no such process" 1 "kill: 4000000: no such process" 'kill 4000000'
t "pid 0 (the caller's group) is refused" 1 "kill: invalid pid: 0" 'kill 0'
t "pid -1 (everything) is refused" 1 "kill: invalid pid: -1" 'kill -9 -- -1'
t "a pid that would wrap to -1 is refused" 1 "kill: invalid pid: 4294967295" 'kill -9 4294967295'
t "a pid that would wrap to 1 is refused" 1 "kill: invalid pid: 4294967297" 'kill -0 4294967297'
t "a non-numeric pid" 1 "kill: invalid pid: abc" 'kill abc'

echo "== ln"
bb 'mkdir -p /t/ln && echo target > /t/ln/target'
t "-s makes a symlink" 0 "lrwxrwxrwx 0 0 6 sym -> target" 'cd /t/ln; ln -s target sym; ls -l | /bb/busybox grep sym'
t "without -s a hard link" 0 "target" 'cd /t/ln; ln target hard; cat hard'
t "usage" 1 "ln: usage: ln [-s] TARGET LINK" 'ln -s onlyone'
t "invalid option" 1 "ln: invalid option: -z" 'ln -z a b'
t "existing link name" 1 "ln: /t/ln/sym: file exists" 'ln -s x /t/ln/sym'

echo "== ls"
bb 'mkdir -p /t/ls/sub /t/ls/locked && cd /t/ls && echo 12345 > file && touch .hidden sub/inner locked/secret && ln -s file link && mkfifo pipe && chmod 444 locked'
t "names, sorted, hidden files left out" 0 $'file\nlink\nlocked\npipe\nsub' 'ls /t/ls'
t "-a shows hidden files" 0 $'.\n..\n.hidden\nfile\nlink\nlocked\npipe\nsub' 'ls -a /t/ls'
t "the current directory by default" 0 "inner" 'cd /t/ls/sub; ls'
t "-l: type, permissions, owner, size, link target" 0 \
  $'-rw-r--r-- 0 0 6 file\nlrwxrwxrwx 0 0 4 link -> file\nprw-r--r-- 0 0 0 pipe' \
  'ls -l /t/ls | /bb/busybox grep -v -E "sub|locked"'
t "-la combined" 0 "-rw-r--r-- 0 0 0 .hidden" 'ls -la /t/ls | /bb/busybox grep hidden'
t "a file operand" 0 $'/t/ls/file\n-rw-r--r-- 0 0 6 /t/ls/file' 'ls /t/ls/file; ls -l /t/ls/file'
t "several operands get headers" 0 $'/t/ls/sub:\ninner\n\n/t/ls/sub:\ninner' 'ls /t/ls/sub /t/ls/sub'
t "device and directory types" 0 $'crw-rw-rw-\ndrwxr-xr-x' \
  'ls -l /dev/null | /bb/busybox cut -c1-10; ls -l /t/ls | /bb/busybox grep sub | /bb/busybox cut -c1-10'
t "missing operand, then carries on" 1 $'ls: /nope: no such file or directory\n/t/ls/sub:\ninner' 'ls /nope /t/ls/sub'
t "invalid option" 1 "ls: invalid option: -z" 'ls -z'
t "-- ends options" 1 "ls: -l: no such file or directory" 'ls -- -l'
t "a symlink that leads nowhere is still listed" 0 $'/t/ls-dangling\nlrwxrwxrwx 0 0 8 /t/ls-dangling -> /nowhere' \
  'ln -s /nowhere /t/ls-dangling; ls /t/ls-dangling; ls -l /t/ls-dangling'
tu "-l where entries cannot be examined" 1 "ls: /t/ls/locked/secret: permission denied" 'ls -l /t/ls/locked'
t "a failed write is an error" 1 "" 'ls /t/ls > /dev/full'
bb 'mkdir -p /t/many && cd /t/many && i=0; while [ $i -lt 6000 ]; do : > f$i; i=$((i+1)); done'
t "a directory of 6000 entries" 0 "6000" 'ls /t/many | /bb/busybox wc -l'

echo "== mkdir"
t "creates a directory" 0 "drwxr-xr-x" 'mkdir /t/mk; ls -l /t | /bb/busybox grep " mk" | /bb/busybox cut -c1-10'
t "-p creates parents and accepts existing ones" 0 "c" 'mkdir -p /t/mk/a/b/c /t/mk/a; ls /t/mk/a/b'
t "existing directory without -p" 1 "mkdir: /t/mk: file exists" 'mkdir /t/mk'
t "missing parent without -p" 1 "mkdir: /t/nope/x: no such file or directory" 'mkdir /t/nope/x'
t "-p stops at a file in the way" 1 "mkdir: /etc/passwd: file exists" 'mkdir -p /etc/passwd/x/y'
t "-p does not accept a file where a directory should be" 1 "mkdir: /t/mk-plain: file exists" 'touch /t/mk-plain; mkdir -p /t/mk-plain'
t "missing operand" 1 "mkdir: missing operand" 'mkdir -p'
t "invalid option" 1 "mkdir: invalid option: -x" 'mkdir -x d'

echo "== ps"
k "lists processes with state and command line" 0 "S /sbin/init /bb/busybox sleep 86400" '/bin/ps | sed -n "s/^ *1 //p"'
k "a zombie shows as Z with its name in brackets" 0 "Z [true]" \
  'sh -c "/bb/true & exec sleep 0.5" & sleep 0.2; /bin/ps | awk "\$2==\"Z\"{print \$2, \$3}"; wait'
bb 'printf "#!/bb/busybox sh\nsleep 99\n" > "/t/$(printf "ev\033il)")"; chmod 755 /t/ev*'
k "control characters in a command line are replaced" 0 "S /bb/busybox sh /t/ev?il)" \
  '"/t/$(printf "ev\033il)")" 2>/dev/null & sleep 0.3; /bin/ps | sed -n "s/^ *[0-9]* \(S .*il)\)$/\1/p"; { pkill -f "^sleep 99\$"; wait; } 2>/dev/null'
t "a failed write is an error" 1 "" 'ps > /dev/full'
# Use up every descriptor the limit allows, then run COMMAND.
FILL=$(for fd in $(seq 3 31); do printf 'exec %s</etc/passwd\n' "$fd"; done)
expect "an unreadable /proc is reported" 1 "ps: /proc: too many open files" -- run --ulimit nofile=32 -- sh -c "$FILL
ps"

echo "== pwd"
t "prints the working directory" 0 "/t/ls/sub" 'cd /t/ls/sub; pwd'
t "a removed working directory" 1 "pwd: .: no such file or directory" 'mkdir /t/gone; cd /t/gone; rm -r /t/gone; pwd'

echo "== rm"
bb 'mkdir -p /t/rm/tree/a/b /t/rm/keep && cd /t/rm && touch f g tree/a/b/deep tree/a/x keep/precious && ln -s keep tree/link-to-keep && ln -s /t/rm/keep dirlink'
t "removes files" 0 "rc=1" 'rm /t/rm/f /t/rm/g; ls /t/rm/f 2>/dev/null; echo "rc=$?"'
t "missing file" 1 "rm: /t/rm/f: no such file or directory" 'rm /t/rm/f'
t "-f ignores missing files" 0 "" 'rm -f /t/rm/f'
t "-f with no operands" 0 "" 'rm -f'
t "missing operand" 1 "rm: missing operand" 'rm'
t "invalid option" 1 "rm: invalid option: -x" 'rm -x f'
t "a directory needs -r" 1 "rm: /t/rm/tree: is a directory" 'rm /t/rm/tree'
t "-r removes a tree but not what its symlinks point to" 0 $'ls: /t/rm/tree: no such file or directory\nprecious' \
  'rm -r /t/rm/tree; ls /t/rm/tree; ls /t/rm/keep'
t "a symlink to a directory is removed, not followed" 0 "precious" 'rm -rf /t/rm/dirlink; ls /t/rm/keep'
t "refuses / . and .." 0 $'rm: refusing to remove /\nrm: refusing to remove .\nrm: refusing to remove ..\nrm: refusing to remove /t/rm/..//\nprecious' \
  'cd /t/rm; rm -rf / . .. /t/rm/..//; ls keep'
bb 'mkdir -p /t/rm/u/guard/inner /t/rm/u/blind/x && touch /t/rm/u/guard/inner/file && chown -R 65534 /t/rm/u && chmod 555 /t/rm/u/guard/inner && chmod 311 /t/rm/u/blind'
tu "reports what it could not remove" 1 $'rm: /t/rm/u/guard/inner/file: permission denied' 'rm -r /t/rm/u/guard'
tu "a directory that cannot be listed" 1 "rm: /t/rm/u/blind: permission denied" 'rm -r /t/rm/u/blind'
bb 'cd /t/rm && i=0; while [ $i -lt 1500 ]; do mkdir d && cd d; i=$((i+1)); done'
t "a tree deeper than the longest path name" 0 "rc=1" 'rm -r /t/rm/d; ls /t/rm/d 2>/dev/null; echo "rc=$?"'

# Three trees of 1500 levels, hung below one another: no path used to build
# them is longer than a path may be.
bb 'cd /t/rm && for p in deep p2 p3; do mkdir $p && (cd $p && i=0; while [ $i -lt 1500 ]; do mkdir d && cd d; i=$((i+1)); done); done
    leaf=$(i=0; while [ $i -lt 1500 ]; do printf d/; i=$((i+1)); done); mv p3/d "p2/$leaf" && mv p2/d "deep/$leaf" && rmdir p2 p3'
k "a tree deeper than 4096 levels is refused, not a crash" 0 $'1\nrc=1' '/bin/rm -r /t/rm/deep 2>&1 | grep -c "directory tree too deep"; /bin/rm -r /t/rm/deep 2>/dev/null; echo rc=$?'

echo "== sleep"
t0=$(now_ms); t "fractions of a second" 0 "" 'sleep 0.3; sleep .2'; t1=$(now_ms)
if [ $((t1 - t0)) -ge 500 ]; then ok "  really sleeps ($((t1 - t0)) ms)"; else ko "  really sleeps" ">=500 ms" "$((t1 - t0)) ms"; fi
t "whole seconds and a trailing dot" 0 "" 'sleep 0; sleep 0.'
t "missing operand" 1 "sleep: usage: sleep SECONDS..." 'sleep'
t "not a number" 1 "sleep: invalid time interval: abc" 'sleep abc'
t "bad fraction" 1 "sleep: invalid time interval: 1.x" 'sleep 1.x'
t "overflowing number" 1 "sleep: invalid time interval: 99999999999999999999" 'sleep 99999999999999999999'
t "more seconds than the kernel accepts" 1 "sleep: 9223372036854775808: invalid argument" 'sleep 9223372036854775808'

echo "== touch"
t "creates an empty file" 0 "-rw-r--r-- 0 0 0 /t/touched" 'touch /t/touched; ls -l /t/touched'
k "updates the time of an existing file, keeping its content" 0 "2001 $(date +%Y) kept" \
  'echo kept > /t/old; touch -d "2001-01-01 00:00:00" /t/old; echo $(date -r /t/old +%Y) $(/bin/touch /t/old; date -r /t/old +%Y) $(cat /t/old)'
t "works on a directory" 0 "" 'touch /t'
t "missing parent directory" 1 "touch: /nope/f: no such file or directory" 'touch /nope/f'
t "missing operand" 1 "touch: missing file operand" 'touch'
t "-- ends options" 0 "-n" 'mkdir /t/touchdash; cd /t/touchdash; touch -- -n; ls'

echo "== uname"
t "system name by default and with -s" 0 $'Linux\nLinux' 'uname; uname -s'
t "-m" 0 "aarch64" 'uname -m'
k "-n, -r and -a agree with the kernel" 0 "ok" \
  '[ "$(/bin/uname -n)" = "$(/bb/busybox uname -n)" ] && [ "$(/bin/uname -r)" = "$(/bb/busybox uname -r)" ] && [ "$(/bin/uname -a)" = "$(/bb/busybox uname -s -n -r -v -m)" ] && echo ok'
t "invalid option" 1 "uname: invalid option: -z" 'uname -z'

# ---------------------------------------------------------------- shell
echo "== shell: scripts"
bb 'mkdir -p /t/redirect'
for f in test/cases/*.sh; do
  name=$(basename "$f" .sh)
  out=$(docker exec "$BENCH" "${MERGE[@]}" sh "/cases/$name.sh" a1 "a 2" c3 </dev/null); rc=$?
  check "$name.sh" "$(cat "test/cases/$name.out")" "$out
[rc $rc]"
done

echo "== shell: invocation"
t "-c with positional parameters" 0 "name|x y|z" 'sh -c "echo \"\$0|\$1|\$2\"" name "x y" z'
x "-e" 1 "a" sh -e -c 'echo a; false; echo b'
x "-x" 0 $'+ echo a\na' sh -x -c 'echo a'
x "-ex combined" 1 $'+ echo a\na\n+ false' sh -ex -c 'echo a; false; echo b'
x "-- ends options" 0 "a1" sh -- /cases/arg.sh a1
x "-c without a command" 2 "sh: -c requires an argument" sh -c
x "unknown option" 2 "sh: unsupported option: -q (only -e and -x)" sh -q
x "missing script file" 127 "sh: /nope.sh: no such file or directory" sh /nope.sh
x "a directory as script" 127 "sh: /t: is a directory" sh /t
bb 'printf "#!/bin/sh\necho \"shebang \$1\"\n" > /t/shebang && chmod 755 /t/shebang'
x "#!/bin/sh scripts run" 0 "shebang arg" /t/shebang arg
expect_in "commands on stdin" 0 $'one\ntwo' $'echo one\necho two\n' -- docker exec -i "$BENCH" sh
expect_in "stdin: status of the last command" 3 "" $'true\nsh -c "exit 3"' -- docker exec -i "$BENCH" sh
expect_in "stdin: a quoted string may span lines" 0 $'first\ntouch /t/INJECTED\nlast\nrc=1' \
  $'DATA="first\ntouch /t/INJECTED\nlast"\necho "$DATA"\nls /t/INJECTED 2>/dev/null\necho "rc=$?"\n' -- docker exec -i "$BENCH" sh
expect_in "stdin: so may a pipeline" 0 "piped" $'echo piped |\ncat\n' -- docker exec -i "$BENCH" sh
expect_in "stdin: an unfinished quote at the end is an error" 2 "sh: syntax error: unterminated single quote" \
  $'echo \'open\n' -- docker exec -i "$BENCH" sh
expect_in "stdin: a syntax error ends the script there" 2 $'before\nsh: syntax error: if, for, while, case, { } and ! are not supported' \
  $'echo before\nif false; then\necho BODY-RAN\nfi\necho after\n' -- docker exec -i "$BENCH" "${MERGE[@]}" sh
expect_in "stdin: && and || continue on the next line" 1 "" $'false &&\necho RAN-ANYWAY\n' -- docker exec -i "$BENCH" sh
expect_in "stdin: so does a backslash" 0 "one two" $'echo one \\\ntwo\n' -- docker exec -i "$BENCH" sh
expect_in "stdin: background jobs are reaped between lines" 1 "0" \
  $'true &\n/bb/busybox sleep 0.3\nps | /bb/busybox grep -c "Z \\[true\\]"\n' -- docker exec -i "$BENCH" sh
t "background jobs are reaped in scripts too" 1 "0" 'true & true & /bb/busybox sleep 0.3; ps | /bb/busybox grep -c "Z \[true\]"'

echo "== shell: nothing runs when the script has a syntax error"
# Each script would create /t/RAN first if it were run line by line.
syntax() {
  local name=$1 msg=$2 script=$3
  expect "$name" 2 "sh: syntax error: $msg
ran=no" -- docker exec "$BENCH" /bb/busybox sh -c '/bb/busybox rm -f /t/RAN; /bin/sh -c "$1" 2>&1; rc=$?; [ -e /t/RAN ] && echo ran=yes || echo ran=no; exit $rc' sh "touch /t/RAN
$script"
}
RESERVED='if, for, while, case, { } and ! are not supported'
syntax "if" "$RESERVED" $'if false; then\n  rm -r /t/keep\nfi'
syntax "then alone" "$RESERVED" 'then'
syntax "for" "$RESERVED" 'for x in a b; do echo $x; done'
syntax "while" "$RESERVED" 'while true; do echo; done'
syntax "case" "$RESERVED" 'case x in esac'
syntax "braces" "$RESERVED" '{ echo a; }'
syntax "negation" "$RESERVED" '! true'
syntax "a keyword after a pipe" "$RESERVED" 'echo x | while read l; do echo; done'
GLOB="globbing is not supported; quote \`*', \`?' and \`['"
syntax "glob *" "$GLOB" 'rm -f /t/*'
syntax "glob ?" "$GLOB" 'ls /t/a?c'
syntax "glob [" "$GLOB" 'rm -f /t/log.[0-9]'
syntax "&& at the end" "unexpected end of input after \`&&' or \`||'" 'cd /t &&'
syntax "|| before only a comment" "unexpected end of input after \`&&' or \`||'" 'false || # nothing'
syntax "backslash at the end" "unexpected end of input after \`\\'" 'echo end\'
syntax "tilde" "\`~' expansion is not supported; use \$HOME or quote it" 'cd ~/x'
syntax "command substitution" "command substitution is not supported" 'echo $(date)'
syntax "  in double quotes" "command substitution is not supported" 'echo "$(date)"'
syntax "backticks" "command substitution is not supported" 'echo `date`'
syntax "subshell" "subshells and functions are not supported" '(cd /tmp)'
syntax "function" "subshells and functions are not supported" 'f() { echo; }'
syntax "here-document" "here-documents are not supported" 'cat <<EOF'
syntax "unterminated single quote" "unterminated single quote" "echo 'open"
syntax "unterminated double quote" "unterminated double quote" 'echo "open'
syntax "unterminated \${" 'unterminated ${' 'echo ${X'
syntax "pipe at the end" "unexpected end of input after \`|'" 'echo x |'
syntax "pipe at the start" "unexpected \`|'" '| cat'
syntax "empty pipeline stage" "unexpected \`|'" 'echo a | | cat'
syntax "operator with nothing before it" "unexpected operator" '&& echo x'
syntax "a second operator" "unexpected operator" 'echo a | cat; & echo'
syntax "redirection without a target" "missing redirection target" 'echo >'
syntax "redirection fd too large" "file descriptor out of range" 'echo x 1024>/t/f'
syntax "redirection fd that would wrap" "file descriptor out of range" 'echo x 18446744073709551617>/t/f'
t "the same characters are fine when quoted" 0 "* ? [ ~ if (x) \`" 'echo "*" "?" "[" "~" "if" "(x)" "\`"'
t "and a keyword is only special as a command name" 0 "if then fi ~mid a~" 'echo if then fi \~mid a~'

echo "== shell: failures to start things"
t "exec in a pipeline" 0 "x" 'echo x | exec cat'
t "exit status of exec'd missing command" 127 "sh: /nope: no such file or directory" 'exec /nope'
t "exec with a redirection that cannot be opened ends the shell" 1 "sh: /nope/x: no such file or directory" 'exec > /nope/x; echo not-reached'
t "an empty command name" 0 $'sh: : not found\nrc=127' '""; echo "rc=$?"'
t "exit with a non-numeric status" 2 "sh: exit: abc: numeric argument required" 'exit abc; echo not-reached'
t "a redirection that cannot be opened stops only that command" 0 $'sh: /nope/f: no such file or directory\nrc=1\nnext' \
  'echo x > /nope/f; echo "rc=$?"; echo next'
expect "no descriptors left for a pipe" 0 $'sh: pipe: too many open files\nrc=1' -- \
  run --ulimit nofile=32 -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m "$FILL
echo a | cat; echo \"rc=\$?\"; exit"
FILL2=$(for fd in $(seq 3 29); do printf 'exec %s</etc/passwd\n' "$fd"; done)
expect "no descriptors left for the second pipe of three" 0 $'sh: pipe: too many open files\nrc=1' -- \
  run --ulimit nofile=32 -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m "$FILL2
echo a | cat | cat; echo \"rc=\$?\"; exit"
expect "a redirection to a descriptor above the limit" 0 $'sh: /tmp/f: bad file descriptor\nrc=1' -- \
  run --ulimit nofile=32 -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'echo a 40> /tmp/f; echo "rc=$?"'
expect "no processes left for a command" 0 $'sh: fork: resource temporarily unavailable\nrc=1' -- \
  run --pids-limit 3 -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'echo a | cat; echo "rc=$?"; true'
k "a pipeline started without stdin does not read its own output" 0 $'cat: -: bad file descriptor\ndone' \
  '/bin/sh -c "/bin/cat | /bin/cat; echo done" <&-'
expect "no descriptor left to move a pipe off stdin" 1 "sh: pipe: too many open files" -- \
  run --ulimit nofile=32 -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m "$FILL
exec 0<&- 1>&-
echo a | cat; exit"
k "a builtin's redirection that cannot be undone is refused" 0 $'sh: cannot redirect: invalid argument\nvisible' \
  'ulimit -n 10; /bin/sh -c ": > /dev/null; echo visible"'
t "pipelines work with stdin and stdout closed" 0 $'hi\nrc=0' 'exec 3>&1; exec 0<&- 1>&-; echo hi | cat >&3; echo "rc=$?" >&3'

# ------------------------------------------------- what the audit found
echo "== lockdown: devices, lists and limits"
DEVICE=(--device /dev/zero:/dev/kcos-test --user 65534:65534)
expect "a device that is not named cannot be driven by ioctl either, opened for neither reading nor writing" 0 "ioctl:/dev/kcos-test: errno 13" -- \
  run "${DEVICE[@]}" -- /bb/probe ioctl:/dev/kcos-test
expect "  named in KCOS_DEV it can" 0 "ioctl:/dev/kcos-test: errno 25" -- run "${DEVICE[@]}" -e KCOS_DEV=/dev/kcos-test -- /bb/probe ioctl:/dev/kcos-test
expect "  control: without init it can" 0 "ioctl:/dev/kcos-test: errno 25" -- run "${DEVICE[@]}" --entrypoint /bb/probe -- ioctl:/dev/kcos-test
SUBDIR=(--user 65534:65534 --device /dev/zero:/dev/kcos/named --device /dev/zero:/dev/kcos/other)
OPENS2='true < /dev/kcos/named; echo "named=$?"; true < /dev/kcos/other; echo "other=$?"'
expect "naming one device of a directory in /dev does not open the others in it" 0 $'sh: /dev/kcos/other: permission denied\nnamed=0\nother=1' -- \
  run "${SUBDIR[@]}" -e KCOS_DEV=/dev/kcos/named -- sh -c "$OPENS2"
expect "  control: without init both open" 0 $'named=0\nother=0' -- run "${SUBDIR[@]}" --entrypoint /bin/sh -- -c "$OPENS2"
CORE=(--user 65534:65534 --device /dev/zero:/dev/core)
expect "a device under the name of one of the usual links of /dev cannot be read" 0 $'sh: /dev/core: permission denied\nread=1' -- \
  run "${CORE[@]}" -- sh -c 'true < /dev/core; echo "read=$?"'
expect "  control: without init it can" 0 "read=0" -- run "${CORE[@]}" --entrypoint /bin/sh -- -c 'true < /dev/core; echo "read=$?"'
expect "a symbolic link named in KCOS_DEV is ignored with a warning" 0 \
  $'kcontaineros: warning: KCOS_DEV: /dev/stdout is not a device in /dev (symbolic links are not followed): ignored\nok' -- \
  run -e KCOS_DEV=/dev/stdout -- /bb/busybox echo ok
for entry in /tmp/ /tmp/. /tmp/../tmp //tmp; do
  expect "the directory of the ignored entry KCOS_EXEC=$entry is not writable all the same" 0 \
    "kcontaineros: warning: KCOS_EXEC: $entry is not a plain absolute path: ignored
sh: /tmp/f: permission denied
write=1" -- docker run --rm "${D[@]}" -e "KCOS_EXEC=$entry" "$IMG" sh -c 'echo x > /tmp/f; echo "write=$?"'
done
expect "a program cannot be run from /dev/shm, even where it is mounted to allow it" 0 $'sh: /dev/shm/busybox: permission denied\nrc=126' -- \
  run --tmpfs /dev/shm:exec -- sh -c 'cp /bb/busybox /dev/shm/busybox; /dev/shm/busybox echo PWNED; echo "rc=$?"'
expect "  control: without init it runs" 0 $'PWNED\nrc=0' -- \
  run --tmpfs /dev/shm:exec --entrypoint /bin/sh -- -c 'cp /bb/busybox /dev/shm/busybox; /dev/shm/busybox echo PWNED; echo "rc=$?"'
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["prctl"],"action":"SCMP_ACT_ERRNO","errnoRet":114,"args":[{"index":0,"value":1262702406,"op":"SCMP_CMP_EQ"}]}]}' > target/fake-probe.json
expect "PID 1 does not take another filter's word for it that the lockdown is in place" 0 $'NoNewPrivs:\t1\nSeccomp:\t2\nSeccomp_filters:\t2' -- \
  run --security-opt seccomp=target/fake-probe.json -- /bb/busybox grep -E '^(NoNewPrivs|Seccomp|Seccomp_filters):' /proc/self/status
expect "with Landlock there but no descriptor left to set it up, nothing runs" 125 "kcontaineros: cannot confine files: too many open files" -- \
  run --entrypoint /bb/busybox -- sh -c 'ulimit -n 3; exec /sbin/init echo PWNED'

echo "== init: stop signals"
c=$(start -- /bb/busybox sleep 30); sleep 0.5
docker kill -s TTIN "$c" >/dev/null; sleep 0.5
check "as PID 1, a command stopped by a forwarded SIGTTIN is resumed" "S" "$(docker exec "$c" /bb/busybox awk '{print $3}' /proc/7/stat 2>/dev/null || docker exec "$c" ps | awk '$3 ~ /sleep/ {print $2}')"
docker exec "$c" /bb/busybox sh -c 'kill -STOP $(/bb/busybox pgrep -x sleep)'; sleep 0.3
t0=$(now_ms); docker stop -t 10 "$c" >/dev/null; t1=$(now_ms)
if [ $((t1 - t0)) -lt 3000 ]; then ok "docker stop ends a command that is stopped ($((t1 - t0)) ms)"; else ko "docker stop ends a command that is stopped" "<3000 ms" "$((t1 - t0)) ms"; fi
check "  with the status of the signal" "143" "$(docker wait "$c")"
docker rm -f "$c" >/dev/null

echo "== shell and utilities: what is outside the subset is an error"
t "a line continuation inside a reserved word does not hide it" 2 "sh: syntax error: if, for, while, case, { } and ! are not supported" $'i\\\nf false\nt\\\nhen\necho BODY RUNS\nf\\\ni'
t "a line continuation inside a name or a descriptor number joins the word; none in single quotes or a comment" 0 $'2\nhi\nend\nab c\\\nd\nnot-a-comment-line' \
  $'A=1; AB=2; echo $A\\\nB; echo hi 2\\\n>/dev/null; echo end; echo "a\\\nb" \'c\\\nd\' # x\\\necho not-a-comment-line'
t "\$IFS is what fields are split on" 0 $'[a \t\nb]' 'echo "[a${IFS}b]"'
t "parameters the shell does not set are refused, not empty" 2 "sh: syntax error: \$LINENO, \$OPTIND, \$OPTARG and \$PS4 are not supported" 'echo ran; echo "$LINENO"'
t "set and export without operands are refused" 0 $'sh: set: listing variables is not supported; use `env\'\n2\nsh: export: listing variables is not supported; use `env\'\n2' \
  'sh -c "set; echo no"; echo $?; sh -c "export; echo no"; echo $?'
t "an empty command before ; is a syntax error" 0 $'sh: syntax error: unexpected operator\n2\nsh: syntax error: unexpected operator\n2\nsh: syntax error: unexpected operator\n2' \
  'sh -c "echo a ;; echo b"; echo $?; sh -c "; echo a"; echo $?; sh -c "true & ; echo a"; echo $?'
t "a comment or another redirection is not a redirection target" 0 $'sh: syntax error: missing redirection target\n2\nsh: syntax error: missing redirection target\n2' \
  'sh -c "echo x >#f"; echo $?; sh -c "echo x 2> 4>&1"; echo $?'
t "an assignment whose redirection fails is not made; one whose redirection works is" 0 $'sh: /nonexistent/f: no such file or directory\n[] 1\n[2]' \
  'X=1 </nonexistent/f; echo "[$X] $?"; X=2 >/dev/null; echo "[$X]"'
x "ls -a lists . and .. too" 0 $'.\n..\n.h\nv' sh -c 'mkdir /tmp/lsa; cd /tmp/lsa; touch .h v; ls -a; cd /; rm -r /tmp/lsa'
t "command exec is refused" 2 "sh: command: \`command exec' is not supported; write \`exec'" 'command exec >/t/o; echo visible'
t "without sh on PATH a script that ends by calling sh does not pile up in one process" 0 "inner" 'PATH=/nonexistent; sh -c "sh -c \"sh -c \\\"echo inner\\\"\""'
half=$(python3 -c 'print("dd/" * 700, end="")')
bb "for p in cdlong cdl2; do mkdir -p /t/\$p && (cd /t/\$p && i=0; while [ \$i -lt 700 ]; do mkdir dd && cd dd; i=\$((i+1)); done); done; mv /t/cdl2/dd /t/cdlong/$half"
t "cd to a place whose name is too long for \$PWD fails and stays where it was" 0 $'0\n1\nsame\n2110' \
  'cd /t/cdlong; cd "$1"; echo $?; A=$PWD; cd "$1" 2>/dev/null; echo $?; /bb/busybox test "$A" = "$PWD" && echo same; pwd | /bb/busybox wc -c' "$half"
# A shell that starts where no name fits: the directory it is in is moved
# below a long path first.
bb "mkdir -p /t/cdq/$(python3 -c 'print("a" * 200, end="")')"
k "a shell started in a place with no name that fits has no PWD, not a wrong one" 0 "[]" \
  "cd /t/cdq/a* && mv /t/cdq /t/cdlong/$(python3 -c 'print("dd/" * 1330, end="")')q && PWD=/lie exec /bin/sh -c 'echo \"[\$PWD]\"'"
bb 'mkdir "/t/esc$(printf "\033")[31mX"'
E=$(printf '\033')
session=$(typed 'cd "/t/esc${E}[31mX"\n' 'cd /\n' 'cd -\n' 'command -v "/t/esc${E}[31mX/../../bin/sh"\n' 'exit\n' -- docker exec -it -e "E=$E" "$BENCH" /bin/sh)
check "cd - and command -v mask control characters on a terminal" "/t/esc?[31mX /t/esc?[31mX/../../bin/sh " \
  "$(printf '%s\n' "$session" | tr -d '\r' | grep -x -F -e '/t/esc?[31mX' -e '/t/esc?[31mX/../../bin/sh' | tr '\n' ' ')"
expect "ls -l says so when it cannot read where a link points" 0 "1" -- run -- sh -c 'ls -l /proc/1/fd > /dev/null 2>&1; echo $?'
x "uname takes one option" 1 "uname: usage: uname [-a|-s|-n|-r|-m]" uname -s -n
x "chmod and chown need a file after --" 1 $'chmod: usage: chmod OCTAL FILE...\nchown: usage: chown UID[:GID] FILE...' sh -c 'chmod 644 --; chown 0 --'
bb 'cd /t && echo secret > ./-n'
x "cat and sleep have no options: -n is not read as a file" 1 $'cat: invalid option: -n\nsleep: invalid option: -1' sh -c 'cd /t; cat -n /etc/hostname; sleep -1'
bb 'cd /t && rm -rf rmslash && mkdir -p rmslash/d rmslash/keep && echo x > rmslash/keep/f && ln -s keep rmslash/l'
x "rm -r LINK/ does not go through the link; rm -r DIR/ removes the directory" 0 $'rm: /t/rmslash/l/: not a directory\n1\nkeep\nl' \
  sh -c 'rm -r /t/rmslash/l/; echo $?; rm -r /t/rmslash/d/; ls /t/rmslash'
k "mkdir -p under a umask without owner write still makes the whole path" 0 "dr-xr-xr-x" 'cd /t && rm -rf um && (umask 0222; /bin/mkdir -p um/a/b) && stat -c %A um/a/b; chmod -R 755 um'
bb 'mkdir -p /t/lsacc/in && ln -s /t/lsacc/in/x /t/lsacc/l && chmod 000 /t/lsacc/in'
expect "ls shows a link whose target it cannot look at" 0 "/t/lsacc/l" -- docker exec -u 65534:65534 "$BENCH" /bin/ls /t/lsacc/l
bb 'chmod 755 /t/lsacc/in'
session=$(typed 'env\n' 'exit\n' -- docker run -it --rm "${D[@]}" -e "ESC=a$(printf '\033')[31mb" "$TEST")
check "env masks control characters on a terminal" "ESC=a?[31mb" "$(printf '%s\n' "$session" | tr -d '\r' | grep '^ESC=')"


# ------------------------------------------------------- further checks
echo "== shell: further cases"
t "a comment after && or || does not unguard the next line" 0 "end" $'false && # only when it worked\necho BAD\ntrue || # fallback\nexit 9\necho end'
t "&& followed by ; is a syntax error" 2 "sh: syntax error: unexpected operator" 'false && ; echo RAN'
t "a comment may follow |" 0 "a" $'echo a | # into\ncat'
t "backticks inside double quotes are refused too" 2 "sh: syntax error: command substitution is not supported" 'echo "`id`"; echo after'
t '${VAR:?} is refused, not expanded to nothing' 2 'sh: syntax error: only ${NAME} and ${NAME:-default} are supported' 'X=; echo "rm -rf ${X:?}/"'
t '  and so are ${#VAR}, ${VAR%x} and ${}' 0 $'2\n2\n2' 'sh -c "echo \${#Z}" 2>/dev/null; echo $?; sh -c "echo \${Z%c}" 2>/dev/null; echo $?; sh -c "echo \${}" 2>/dev/null; echo $?'
t 'a default may hold expansions, nested ones too' 0 "/h/data c a b" 'H=/h; echo "${X:-$H/data}" "${A:-${B:-c}}" ${Z:-a b}'
t '  but no quotes' 2 'sh: syntax error: quotes and backslashes inside ${NAME:-default} are not supported' 'echo "${X:-"a b"}"'
t "a command that expands to nothing is a no-op, not a syntax error" 0 $'/\nst=0\nyes' 'cd /; F=pwd; $F | cat; false; $NOPE; echo "st=$?"; $NOPE && echo yes'
t "an assignment keeps the blanks of what it expands, and sees the one before it" 0 $'[  x   y  ]\n[1]' 'A="  x   y  "; B=$A; echo "[$B]"; A=1 B=$A; echo "[$B]"'
t "a redirection target is not split and rejoined" 0 "a  b" 'F="a  b"; echo hi > "/t/$F"; ls /t | /bb/busybox grep "^a"'
t "a && b & puts the whole list in the background" 0 $'early\nlate' 'sleep 0.3 && echo late & echo early; wait'
t '$! and wait PID give the status of a background command' 0 $'w=7\nw2=127' 'sh -c "exit 7" & wait $!; echo "w=$?"; wait 99999; echo "w2=$?"'
expect_in "a background command does not eat a script on stdin" 0 $'hidden1\nhidden2' $'cat &\necho hidden1\necho hidden2\nwait\n' -- docker exec -i "$BENCH" sh
t "builtins that are not implemented stop the script before it starts" 2 "sh: syntax error: trap, eval, read, \`.', return, local and similar builtins are not supported" 'echo start; trap "echo bye" EXIT'
t "  and at run time when the name was hidden in quotes" 2 "sh: eval: this builtin is not supported" '"eval" echo hi'
t "umask is a builtin" 0 $'0077\n-rw------- 0 0 2 /t/umask' 'umask 077; umask; echo s > /t/umask; ls -l /t/umask'
t "umask accepts octal only" 2 "sh: umask: u=rwx: only octal masks are supported" 'umask u=rwx'
t "cd sets PWD and OLDPWD" 0 "/tmp /" 'cd /; cd /tmp; echo $PWD $OLDPWD'
t "an assignment in front of cd does not outlive it" 0 "[]" 'FOO=bar cd /; echo "[$FOO]"'
x "sh -ec" 3 "a" sh -ec 'echo a; sh -c "exit 3"; echo b'
t 'text around an unquoted $@ joins its first and last field' 0 "ax yb" 'echo a$@b' x y
t "export refuses a name that is not one" 0 $'sh: export: A B=c: bad variable name\nrc=1' 'export "A B=c"; echo "rc=$?"'
t "IFS cannot be set" 2 "sh: syntax error: IFS is not supported: fields are split on whitespace" 'IFS=:; echo x'
x "a path through a file is not found (127), in the shell and in env" 0 $'sh: /etc/passwd/x: not a directory\n127\nenv: /etc/passwd/x: not a directory\n127' \
  /bb/busybox sh -c 'sh -c /etc/passwd/x; echo $?; env /etc/passwd/x; echo $?'

t 'export NAME=$VALUE keeps the value whole' 0 "MSG=hello world" 'X="hello world"; export MSG=$X; env | /bb/busybox grep ^MSG'
t '$@ inside a default is refused' 2 'sh: syntax error: $@ inside ${NAME:-default} is not supported' 'echo "${U:-$@}"'
deep=$(python3 -c 'print("echo " + "${a:-" * 100 + "x" + "}" * 100, end="")')
t 'defaults nested too deeply are refused' 2 'sh: syntax error: ${NAME:-default} is nested too deeply' "$deep"
t "~ after = or : in an assignment is refused like a leading one" 0 $'2\n2' 'sh -c "export P=~/bin" 2>/dev/null; echo $?; sh -c "Q=/x:~/b" 2>/dev/null; echo $?'
t "NAME=value after a word that expanded to nothing is a command, not an assignment" 0 $'sh: A=1: not found\nrc=127 A=' '$U A=1; echo "rc=$? A=$A"'
t "&> is refused" 2 "sh: syntax error: \`&>' is not supported; write \`>file 2>&1'" 'echo a &>/t/f'
t "\$'...' is refused" 2 "sh: syntax error: \$'...' quoting is not supported" "echo \$'a'"
t "a redirection that fails on a special builtin ends the script" 1 "sh: /nonexistent/x: no such file or directory" ': > /nonexistent/x; echo continued'
t "wait PID still knows a status after a plain wait and many other jobs" 0 "first=7" 'sh -c "exit 7" & F=$!; true & true & true & wait; wait $F; echo "first=$?"'
# (Once it is the command: before its exec the child is still the shell.)
t "background commands ignore SIGINT and SIGQUIT" 0 $'SigIgn:\t0000000000000006' \
  'sleep 2 & /bb/busybox sh -c "until /bb/busybox grep -q -x sleep /proc/\$1/comm; do :; done; /bb/busybox grep SigIgn /proc/\$1/status" wait $!'
x "options may follow -c" 1 "" sh -c -e 'false; echo a'
bb 'echo "echo hi \$1" > /t/noshebang; chmod 755 /t/noshebang'
t "an executable text file without #! runs as a script" 0 $'hi there\nhi again' '/t/noshebang there; PATH=/t noshebang again'
session=$(typed 'sleep 100 &\n' 'wait\n' '\x03' 'echo "rc=$?"\n' 'exec 3< /nonexistent\n' 'echo alive\n' 'exit\n' -- docker run -it --rm "${D[@]}" "$TEST")
check "at a prompt Ctrl-C ends wait, and a failed exec redirection keeps the shell" "rc=130 alive " \
  "$(printf '%s\n' "$session" | tr -d '\r' | grep -x -E 'rc=130|alive' | tr '\n' ' ')"

x 'set -- replaces the positional parameters' 0 "replaced a b c" sh -c 'set -- echo replaced "$@"; exec "$@"' sh a 'b c'
t "set with an option it does not have stops the script before it starts" 2 "sh: syntax error: set: only -e, -x and -- are supported" 'echo start; set -ue; false; echo wrong'
t "  and when it runs, if the option came from a variable" 2 "sh: unsupported option: -u (only -e and -x)" 'X=-u; set $X; echo wrong'
t "cd - goes back and says where" 0 $'/tmp\n/tmp' 'cd /tmp; cd /etc; cd -; echo $PWD'
expect "PWD is the working directory from the start, whatever the environment says" 0 "[/etc]" -- \
  run -w /etc -e PWD=/lies -- sh -c 'echo "[$PWD]"'
t "command -v finds builtins and programs; command runs one" 0 $'/bin/ls\ncd\n1\nhi' 'command -v ls; command -v cd; command -v nope; echo $?; command echo hi'
t "type is refused" 2 "sh: syntax error: trap, eval, read, \`.', return, local and similar builtins are not supported" 'type ls'
expect "wait does not wait for what a shell running as PID 1 adopted" 0 "done" -- \
  run --entrypoint /bb/busybox -- timeout 5 /bin/sh -c 'sh -c "sleep 30 &"; sleep 0.3 & wait; echo done'
t 'quotes next to an empty "$@" still make a field' 0 $'1\n0' 'sh -c "echo \$#" x "$@"""; sh -c "echo \$#" x "$@"'
t '${:-x} is refused' 2 'sh: syntax error: only ${NAME} and ${NAME:-default} are supported' 'echo ${:-x}'
t '~ at the start of a default is refused' 2 "sh: syntax error: \`~' expansion is not supported; use \$HOME or quote it" 'echo ${U:-~/x}'
expect_in "a backslash before CRLF continues the line" 0 $'a\nb\nc d' $'echo a && \\\r\n  echo b\r\necho c \\\r\n d\r\n' -- docker exec -i "$BENCH" sh
bb 'printf "#!/usr/bin/env sh\necho env-ok\n" > /t/envscript; chmod 755 /t/envscript; mkdir -p /t/pa/noshebang; { cat /etc/passwd; head -c 100 /bin/kcontaineros; } > /t/notext; chmod 755 /t/notext'
t "#!/usr/bin/env sh works" 0 "env-ok" '/t/envscript'
t "a script without #! is the file exec found, not a directory of that name earlier on PATH" 0 "hi x" 'PATH=/t/pa:/t noshebang x'
t "a file that is not text is not run as a script" 0 $'sh: /t/notext: exec format error\nrc=126' '/t/notext; echo "rc=$?"'

t "cd takes -P, -L and --; cd - needs an OLDPWD" 0 $'/tmp\n/\nsh: cd: OLDPWD is not set\n1' 'cd -P /tmp; pwd; cd -L -- /; pwd; unset OLDPWD; cd -; echo $?'
t "export and unset take -- and refuse other options" 0 $'[1]\n[]\nsh: export: -p: options are not supported\n2\nsh: unset: -f: options are not supported\n2' \
  'export -- A=1; echo "[$A]"; unset -v -- A; echo "[$A]"; sh -c "export -p; echo no"; echo $?; sh -c "unset -f x; echo no"; echo $?'
t "exec takes --" 0 "via-exec" 'exec -- echo via-exec'
t "wait refuses options and what is not a process ID" 0 $'sh: wait: -n: options are not supported\n2\nsh: wait: x: not a process ID\n2' 'wait -n; echo $?; wait x; echo $?'
t "command runs builtins as builtins, also in a pipeline; -v knows paths and applets without PATH" 0 \
  $'/tmp\n[1]\nhi\npiped\n/bin/ls\nls\n1\nsh: command: only `command -v NAME\' and `command NAME ARGS\' are supported\n2' \
  'command cd /tmp; pwd; command export A=1; echo "[$A]"; command command echo hi; command echo piped | cat; command -v /bin/ls; PATH=/nonexistent; command -v ls; command -v /etc; echo $?; command -p ls; echo $?'
t "umask refuses a mask that is too large" 2 "sh: umask: 7777: only octal masks are supported" 'umask 7777'
t '$- and $PPID' 0 $'e\n1' 'set -e; echo $-; sh -c "echo \$PPID" | /bb/busybox grep -c "^[0-9]"'
t "a backslash-newline may follow the dollar sign" 0 "/h" $'HOME=/h; echo $\\\nHOME'
t 'an assignment from $@ joins the parameters' 0 "[a b c]" 'A=$@; echo "[$A]"' a "b c"
t "a glob character in an unquoted default is refused" 2 "sh: syntax error: globbing is not supported; quote \`*', \`?' and \`['" 'echo ${X:-*}'
x "a NUL byte in a script is refused" 2 "sh: syntax error: NUL byte in the script" /bb/busybox sh -c 'printf "echo a\000b\n" | /bin/sh'
session=$(typed 'export -p\n' 'echo "rc=$?"\n' 'command sleep 30\n' '\x03' 'echo "c=$?"\n' 'cd /tmp; pwd\n' 'ls /aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' '\x04' -- docker run -it --rm "${D[@]}" "$TEST")
check "at a prompt a misused builtin does not end the shell, Ctrl-C reaches command, long messages are whole" "rc=2 c=130 /tmp 1 " \
  "$(printf '%s\n' "$session" | tr -d '\r' | grep -x -E 'rc=2|c=130|/tmp' | tr '\n' ' ')$(printf '%s\n' "$session" | tr -d '\r' | awk 'length($0) == 625 && /^ls: \/a+: file name too long$/ {n++} END {print n + 0}') "
session=$(typed 'sleep 0.3 &\n' 'wait\n' 'echo "w=$?"\n' 'sleep 30 &\n' 'wait $!\n' '\x03' 'echo "p=$?"\n' 'exec echo replaced\n' -- docker run -it --rm "${D[@]}" "$TEST")
check "at a prompt wait returns when the job is done, Ctrl-C ends wait PID, and exec replaces the shell" "w=0 p=130 replaced " \
  "$(printf '%s\n' "$session" | tr -d '\r' | grep -x -E 'w=0|p=130|replaced' | tr '\n' ' ')"
F='sh: fork: resource temporarily unavailable'
expect "a shell that cannot fork says so and goes on" 0 "$F
$F
rc=1" -- run --pids-limit 2 -- sh -c 'true && true & command true; echo "rc=$?"'
expect "  or stops, under set -e" 1 "$F" -- run --pids-limit 2 -- sh -c 'set -e; true && true & echo wrong'
name=$(python3 -c 'print("a" * 5000, end="")')
expect "a program directory below one that is missing, and a name too long to exist, are ignored" 0 \
  "kcontaineros: warning: KCOS_EXEC: /nonexistent/sub $W
kcontaineros: warning: KCOS_DEV: /dev/$name is not a device in /dev (symbolic links are not followed): ignored
ok" -- run -e KCOS_EXEC=/nonexistent/sub:/bb -e "KCOS_DEV=/dev/$name" -- /bb/busybox echo ok

echo "== utilities: further cases"
t "echo -e knows the other escapes, and -E turns them off again" 0 $'a\rb\a\b\e\f\v\\ \\x \\q\nx\\n' 'echo -e "a\rb\a\b\e\f\v\\\\ \x \q"; echo -eE "x\n"'
t "env takes -u NAME and --, and refuses other options" 0 $'A=\nenv: invalid option: -x\n1' 'A=1 env -u A -- sh -c "echo A=\$A"; env -x; echo $?'
t "mv refuses a source whose last part is . or .." 1 "mv: /t/cp/.: invalid argument" 'mv /t/cp/. /t'
t "sleep takes m, h and d" 0 "" 'sleep 0m 0h 0d'
bb "printf '%s\n' 'trap \"\" TERM' '/bb/busybox sleep 300 &' 'wait' > /t/daemon.sh"
k "a signal to nested init ends its patience with what is left" 0 $'rc=0\ngone' \
  '/sbin/init /bb/busybox sh -c "/bb/busybox setsid /bb/busybox sh /t/daemon.sh & /bb/busybox sleep 0.2" & p=$!; sleep 0.7; kill -USR1 $p; wait $p; echo rc=$?; sleep 0.3; pgrep -f "sleep 30[0]" || echo gone'
t "echo -e and its escapes" 0 $'a\tbAA\nq\n-x' 'echo -e "a\tb\x41\0101"; echo -ne "q\n"; echo -e "-x\c" ignored; echo'
t "sleep takes a trailing s" 0 "" 'sleep 0.1s'
x "sleep infinity sleeps until it is stopped" 143 "" /bb/busybox timeout 1 /bin/sleep infinity
t "chown and chmod reject options" 0 $'chown: invalid option: -R\nchmod: invalid option: -R' 'chown -R 1 /t; chmod -R 755 /t; true'
t "ps and pwd take no arguments" 0 $'ps: usage: ps\npwd: usage: pwd' 'ps -Z; pwd -x; true'
bb 'printf "echo crlf \\\\\r\n  ok\r\n" > /t/crlf.sh'
t "a script with CRLF line endings runs" 0 "crlf ok" 'sh /t/crlf.sh'
k "mv does not cross filesystems, and says so" 0 "mv: /t/f2: cross-device link" 'echo x > /t/f2; /bin/mv /t/f2 /dev/shm/f2; rm -f /t/f2' 
bb 'mkdir -p /t/sec /t/md/f && chmod 000 /t/sec && ln -s sec /t/lsec && echo x > /t/f'
tu "ls of a symlink to a directory it may not read is an error" 1 "ls: /t/lsec: permission denied" 'ls /t/lsec'
t "mv names the directory that is in the way" 1 "mv: /t/md/f: is a directory" 'mv /t/f /t/md/'
t "rm -f of an empty name is not an error" 0 "" "rm -f ''"
expect "mkdir -p DIR/ gives the last directory the mode the umask asks for" 0 "dr-------- 65534 65534 40 v1" -- \
  run --user 65534:65534 --tmpfs /w:mode=1777 -- sh -c 'umask 377; mkdir -p /w/v1/; ls -l /w'
session=$(typed '/bin/kill "$(printf "x\\\\033[41mY")"\n' 'exit\n' -- docker run -it --rm --entrypoint /bb/busybox "${D[@]}" "$TEST" sh)
check "every message to a terminal hides control characters" "kill: invalid pid: x?[41mY" "$(printf '%s\n' "$session" | tr -d '\r' | grep '^kill: ')"
bb 'mkdir -p /t/rv/a /t/rv/d && echo hi > /t/rv/a/f'
t "mv DIR/ DEST moves into the directory instead of replacing it" 0 "/t/rv/d/a/f" 'mv /t/rv/a/ /t/rv/d; ls /t/rv/d/a/f'
t "mv names the destination when that is what is missing" 1 "mv: /nonexistent/b: no such file or directory" 'mv /t/rv/d /nonexistent/b'
t "ln names the target when that is what is missing" 1 "ln: /t/rv/nope: no such file or directory" 'ln /t/rv/nope /t/rv/h2'
t "ls of a path through a file is an error" 1 "ls: /etc/passwd/nope: not a directory" 'ls /etc/passwd/nope'
t "ls -l survives an entry that vanishes while it works" 0 "" 'ls -l /proc/self/fd > /dev/null'
t "sleep adds its operands up and rejects what is not a number" 1 "sleep: invalid time interval: junk" 'sleep 0.1 0.1 && sleep 0 junk'
t "touch rejects options instead of creating files named after them" 1 "touch: invalid option: -c" 'touch -c /t/rv/zz'
t "cp and mv reject options" 0 $'cp: invalid option: -r\nmv: invalid option: -f' 'cp -r /t/rv /t/rv2; mv -f /t/rv /t/rv2; :'
expect "mkdir -p works under a umask that takes the owner's write bit" 0 "" -- \
  run --user 65534:65534 --tmpfs /w:mode=1777 -- sh -c 'umask 277; mkdir -p /w/m1/m2/m3'
bb 'mkdir -p /t/rw/ro/sub && touch /t/rw/ro/sub/file && chown -R 65534:65534 /t/rw && chmod 555 /t/rw/ro'
tu "rm -r empties a directory it cannot remove, and reports it once" 0 "rm: /t/rw/ro/sub: permission denied" 'rm -rf /t/rw; ls /t/rw/ro/sub'
typed_out=$(typed 'mkdir /w/esc && touch "/w/esc/$(printf "x\\033[41mY")" && chmod 444 /w/esc && /bin/ls -l /w/esc\n' 'exit\n' \
  -- docker run -it --rm --user 65534:65534 --tmpfs /w:mode=1777 -e "PATH=$BBPATH" --entrypoint /bb/busybox "${D[@]}" "$TEST" sh)
check "error messages on a terminal hide control characters as well" "ls: /w/esc/x?[41mY: permission denied" \
  "$(printf '%s\n' "$typed_out" | tr -d '\r' | grep '^ls: ')"

echo "== init and lockdown: further cases"
expect "init exits although SIGCHLD was inherited as ignored" 7 "" -- \
  run --entrypoint /bb/busybox -- timeout 20 /bb/busybox sh -c 'trap "" CHLD; exec /sbin/init /bin/sh -c "exit 7"'
k "nested init also stops what moved to another session" 0 $'rc=5\ngone' \
  'd=1000; /sbin/init /bb/busybox sh -c "/bb/busybox setsid /bb/busybox sleep $d & /bb/busybox sleep 0.3; exit 5"; echo rc=$?; sleep 0.3; pgrep -f "sleep 100[0]" || echo gone'
bb "printf '%s\n' 'trap \"\" TERM' '/bb/busybox sleep 300 &' 'wait' > /t/daemon.sh"
k "  and what that leaves behind when it is killed" 0 "gone" \
  '/sbin/init /bb/busybox sh -c "/bb/busybox setsid /bb/busybox sh /t/daemon.sh & /bb/busybox sleep 0.2"; sleep 0.2; pgrep -f "sleep 30[0]" || echo gone'
session=$(typed '/sbin/init /bb/busybox cat &\n' 'fg\n' 'hello\n' '\x04' 'echo after\n' 'exit\n' -- docker run -it --rm --entrypoint /bb/busybox "${D[@]}" "$TEST" sh)
check "init started in the background and then brought forward gets the terminal" "hello hello after " \
  "$(printf '%s\n' "$session" | tr -d '\r' | grep -x -E 'hello|after' | tr '\n' ' ')"
session=$(typed '/sbin/init /bb/busybox sleep 2 &\n' 'echo still-alive\n' 'exit\n' -- docker run -it --rm --entrypoint /bb/busybox "${D[@]}" "$TEST" sh)
check "init started as a background job leaves the terminal alone" "still-alive" "$(printf '%s\n' "$session" | tr -d '\r' | grep -x 'still-alive')"
expect "a top-level symlink into a program directory does not make it writable" 1 "sh: line 0: can't create /usr/lib/f: Permission denied" -- \
  run --entrypoint /bb/busybox --user 0 -- sh -c 'ln -s usr/lib /lib; mkdir -p /usr/lib; chmod 777 /usr/lib; exec /sbin/init /bb/busybox sh -c "echo x > /usr/lib/f"'
expect "a KCOS_EXEC entry that is a symlink is ignored, with a warning" 126 \
  $'kcontaineros: warning: KCOS_EXEC: /lnk is not a directory (symbolic links are not followed): ignored\nkcontaineros: /tmp/bbx: permission denied' -- \
  run --entrypoint /bb/busybox --user 0 -- sh -c 'ln -s tmp /lnk; cp /bb/busybox /tmp/bbx; KCOS_EXEC=/bb:/lnk exec /sbin/init /tmp/bbx echo ran'
# Opened for appending and never written to: were one of these to succeed,
# nothing on the host would change.
KERNEL_FILES='true >> /proc/sys/kernel/core_pattern; true >> /proc/sysrq-trigger; true >> /dev/kmsg; echo usable > /dev/null; echo usable > /dev/stdout; echo shm > /dev/shm/f'
expect "privileged root cannot open the kernel's files or the host's devices for writing" 0 \
  $'sh: /proc/sys/kernel/core_pattern: permission denied\nsh: /proc/sysrq-trigger: permission denied\nsh: /dev/kmsg: permission denied\nusable' -- \
  run --privileged --user 0 --security-opt seccomp=unconfined -- sh -c "$KERNEL_FILES"
expect "  control: without init it can" 0 "usable" -- \
  run --privileged --user 0 --security-opt seccomp=unconfined --entrypoint /bin/sh -- -c "$KERNEL_FILES"
# A device anyone may open by its permissions (0666), under a name of its own.
DEVICE=(--device /dev/zero:/dev/kcos-test --user 65534:65534)
OPENS='true >> /dev/kcos-test; echo "write=$?"; true < /dev/kcos-test; echo "read=$?"'
expect "a device passed in cannot be opened, for writing or for reading, whatever its permissions" 0 \
  $'sh: /dev/kcos-test: permission denied\nwrite=1\nsh: /dev/kcos-test: permission denied\nread=1' -- run "${DEVICE[@]}" -- sh -c "$OPENS"
expect "  control: without init it can" 0 $'write=0\nread=0' -- run "${DEVICE[@]}" --entrypoint /bin/sh -- -c "$OPENS"
expect "  nor when it is named in KCOS_DEV; entries that are no device are ignored with a warning" 0 \
  $'kcontaineros: warning: KCOS_DEV: relative is not a plain absolute path: ignored\nkcontaineros: warning: KCOS_DEV: /etc/passwd is not a device in /dev (symbolic links are not followed): ignored\nwrite=0\nread=0' -- \
  run "${DEVICE[@]}" -e KCOS_DEV=/dev/kcos-test:relative:/etc/passwd -- sh -c "$OPENS"
expect "with an unnamed device present, files elsewhere are still read" 0 "readable" -- \
  run "${DEVICE[@]}" -- sh -c 'cat /etc/os-release /proc/self/status > /dev/null && echo readable'
expect "message queues cannot be created; shared memory can" 0 $'sh: /dev/mqueue/q: permission denied\nmq=1\nshm=0' -- \
  docker run --rm "${D[@]}" "$IMG" sh -c 'true >> /dev/mqueue/q; echo "mq=$?"; true >> /dev/shm/f; echo "shm=$?"'
expect "run as the README has it for agent tools, /work is the only place to write" 0 \
  $'sh: /dev/shm/f: no such file or directory\nsh: /dev/mqueue/q: permission denied\nsh: /tmp/f: read-only file system\nwork=0' -- \
  docker run --rm -i --read-only --network none --ipc none --memory 512m --pids-limit 128 --tmpfs /work:uid=65534,gid=65534,mode=0700 "${D[@]}" "$IMG" \
  sh -c 'true >> /dev/shm/f; true >> /dev/mqueue/q; true >> /tmp/f; true >> /work/f; echo "work=$?"'
bb 'echo top > /topfile'
k "a file at the top level is writable like a directory there" 0 "more" \
  '/sbin/init /bb/busybox sh -c "echo more > /topfile && cat /topfile"'
k "os-release carries the version of the binary" 0 "1" 'v=$(/bin/kcontaineros --version); grep -c "^VERSION_ID=${v#kcontaineros }\$" /etc/os-release'
expect "nobody can write to the temporary directories of the image and nothing else in it" 0 $'/tmp\n/var/tmp' -- \
  docker run --rm --user 0 --entrypoint /bb/busybox "$TEST" sh -c '/bb/busybox find / -xdev "(" -perm -0002 -o -user 65534 -o -group 65534 ")" ! -type l | /bb/busybox grep -v "^/cov\$" | /bb/busybox sort'

echo "== memory"
bb 'i=0; while [ $i -lt 3000 ]; do echo "# padding padding padding padding padding padding"; i=$((i+1)); done > /t/big.sh; echo "echo big-script-ok" >> /t/big.sh'
x "a script larger than any size class" 0 "big-script-ok" sh /t/big.sh
bb 'dd if=/dev/zero of=/t/huge bs=1M count=16 2>/dev/null'
k "running out of memory is reported, not a crash" 0 $'kcontaineros: out of memory\nrc=101' 'ulimit -d 8192; /bin/sh /t/huge; echo rc=$?'
leak=$( { python3 -c 'print(("X=" + "a" * 118 + "\n") * 60000, end="")'; echo '/bb/busybox grep VmRSS /proc/$$/status'; } \
  | docker exec -i "$BENCH" sh | awk '{print $2}')
if [ -n "$leak" ] && [ "$leak" -lt 4096 ]; then ok "a long-lived shell reuses memory (RSS $leak kB after 60000 assignments)"; else ko "a long-lived shell reuses memory" "<4096 kB" "${leak:-no output} kB"; fi

# ------------------------------------------------------- real binaries
echo "== real binaries"
if ! log=$(docker build --platform "$PLATFORM" --build-arg "BASE=$IMG" -t "$HTTP" examples/hello-http 2>&1); then
  printf '%s\n' "$log" | tail -20; ko "example image builds" "success" "failure"
else
  ok "a Dockerfile with a shell-form RUN builds on the image"
  c=$(docker run -d --name "kcos-web-$ID" --label "$LABEL" "${D[@]}" -p 127.0.0.1::8080 "$HTTP")
  port=$(docker port "$c" 8080 | sed 's/.*://')
  body=""; for _ in $(seq 1 50); do body=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null) && break; sleep 0.2; done
  check "a Rust HTTP server answers" "Hello from kContainerOS" "$body"
  check "it runs under init" "/sbin/init hello-http" "$(docker exec "$c" ps | awk '$1==1{print $3" "$4}')"
  check "as an unprivileged user" "65534" "$(docker exec "$c" cat /proc/1/status | awk '$1=="Uid:"{print $2}')"
  check "the RUN layer is there" "ready" "$(docker exec "$c" cat /data/status)"
  t0=$(now_ms); docker stop -t 10 "$c" >/dev/null; t1=$(now_ms)
  if [ $((t1 - t0)) -lt 3000 ]; then ok "a server with no signal handling stops at once ($((t1 - t0)) ms)"; else ko "server stops at once" "<3000 ms" "$((t1 - t0)) ms"; fi
fi
c=$(start -p 127.0.0.1::8080 -- /bb/busybox sh -c 'mkdir -p /tmp/www && echo third-party-ok > /tmp/www/index.html && exec /bb/busybox httpd -f -p 8080 -h /tmp/www')
port=$(docker port "$c" 8080 | sed 's/.*://')
body=""; for _ in $(seq 1 50); do body=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/index.html" 2>/dev/null) && break; sleep 0.2; done
check "a third-party HTTP server (busybox httpd) answers" "third-party-ok" "$body"
docker stop -t 10 "$c" >/dev/null
