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
  "${want}dev etc etc/group etc/nsswitch.conf etc/os-release etc/passwd home proc root run sbin sbin/init sys tmp usr usr/bin usr/local usr/local/bin var var/run var/tmp " \
  "$listing"
if [ -z "$COV" ]; then
  mkdir -p target
  docker cp -q "$c:/bin/kcontaineros" target/kcontaineros.bin
  check "binary is a static PIE with a non-executable stack and RELRO" \
    "type=pie interp=no execstack=no wx=no relro=yes" "$(python3 test/elf.py target/kcontaineros.bin)"
  check "at run time its code and constants are read-only" "r--p r-xp r--p" \
    "$(docker run --rm "${D[@]}" "$IMG" cat /proc/self/maps | awk '/kcontaineros/{printf "%s ", $2}' | sed 's/ $//')"
  size=$(docker image inspect -f '{{.Size}}' "$IMG")
  if [ "$size" -lt 1000000 ]; then ok "image is under 1 MB ($size bytes)"; else ko "image is under 1 MB" "<1000000" "$size"; fi
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
expect "is PID 1 and the command is its child" 0 $'  PID S COMMAND\n    1 S /sbin/init ps\n    7 R ps' -- run -- ps
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
t0=$(now_ms)
t "nested init kills leftovers that ignore SIGTERM" 0 $'rc=0\nleft=1' \
  '/sbin/init /bb/busybox sh -c "trap \"\" TERM; /bb/busybox sleep 60 & /bb/busybox sleep 0.3"; echo "rc=$?"; /bb/busybox pgrep -f "^/bb/busybox sleep 60$"; echo "left=$?"'
t1=$(now_ms)
if [ $((t1 - t0)) -ge 2000 ]; then ok "  after a grace period ($((t1 - t0)) ms)"; else ko "  after a grace period" ">=2000 ms" "$((t1 - t0)) ms"; fi
k "nested init survives being stopped and continued" 0 "rc=0" \
  '/sbin/init /bb/busybox sleep 1 & p=$!; sleep 0.3; /bin/kill -STOP $p; sleep 0.2; /bin/kill -CONT $p; wait $p; echo rc=$?'
k "init resumes a command stopped by Ctrl-Z's signal, and leaves SIGSTOP alone" 0 $'S\nT\nrc=0' \
  '/sbin/init /bb/busybox sleep 2 & p=$!; sleep 0.3; c=$(pgrep -P $p); /bin/kill -20 $c; sleep 0.3; cut -d" " -f3 /proc/$c/stat; /bin/kill -STOP $c; sleep 0.3; cut -d" " -f3 /proc/$c/stat; /bin/kill -CONT $c; wait $p; echo rc=$?'
t "nested init gives up on processes that left its group" 0 "rc=0" \
  '/sbin/init /bb/busybox sh -c "/bb/busybox setsid /bb/busybox sleep 61 & /bb/busybox sleep 0.3"; echo "rc=$?"'
bb 'pkill -f "sleep 61"'

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
date -s 2001-01-01 >/dev/null; echo "rc=$?"
echo x >> /etc/passwd; echo "rc=$?"
cat /proc/1/environ; echo "rc=$?"
cp /bb/busybox /tmp/busybox; /tmp/busybox echo PWNED; echo "rc=$?"
chmod 777 /usr/local/bin; cp /bb/busybox /usr/local/bin/tool; echo "rc=$?"
mv /tmp/busybox /bb/tool; echo "rc=$?"
mkdir /newdir; echo "rc=$?"'
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
date: can't set date: Operation not permitted
rc=1
sh: line 6: can't create /etc/passwd: Permission denied
rc=1
cat: can't open '/proc/1/environ': Permission denied
rc=1
sh: line 8: /tmp/busybox: Permission denied
rc=126
cp: can't create '/usr/local/bin/tool': Permission denied
rc=1
mv: can't rename '/tmp/busybox': Permission denied
rc=1
mkdir: can't create directory '/newdir': Permission denied
rc=1" -- run "${PRIV[@]}" -e PATH=/bb -- /bb/busybox sh -c "{ $ATTACKS
} 2>&1"
expect "control: without init the same container allows them" 0 $'rc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nrc=0\nPWNED\nrc=0\nrc=0\nrc=0\nrc=0' -- \
  run "${PRIV[@]}" -e PATH=/bb --entrypoint /bb/busybox -- sh -c "{ $ATTACKS
} 2>&1 | grep -a -E '^(rc=|PWNED)'"
PROBES="memfd_create memfd_secret ptrace process_vm_readv io_uring_setup bpf userfaultfd clone_newuser clone3 newer_than_filter"
expect "system calls for running code from memory, reaching other processes and new kernel interfaces are refused" 0 \
  $'memfd_create: errno 1\nmemfd_secret: errno 1\nptrace: errno 1\nprocess_vm_readv: errno 1\nio_uring_setup: errno 1\nbpf: errno 1\nuserfaultfd: errno 1\nclone_newuser: errno 1\nclone3: errno 38\nnewer_than_filter: errno 38' -- \
  run "${PRIV[@]}" -- /bb/probe $PROBES
# Without init none is refused with EPERM. Some fail for other reasons
# (bad arguments, not built into this kernel), so only those are pinned.
check "control: without init the kernel accepts them" "memfd_create: allowed ptrace: allowed clone_newuser: allowed refused=0" \
  "$(run "${PRIV[@]}" --entrypoint /bb/probe -- $PROBES | awk '/^(memfd_create|ptrace|clone_newuser):/{printf "%s ", $0} /errno 1$/{n++} END{print "refused=" n+0}')"
expect "the shell reports the refusal" 0 $'sh: /tmp/busybox: permission denied\nrc=126' -- \
  run -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'cp /bb/busybox /tmp/busybox; /tmp/busybox echo PWNED; echo "rc=$?"'
t "a shell started with docker exec cannot gain privileges either" 0 $'NoNewPrivs:\t1\nSeccomp:\t2' \
  '/bb/busybox grep -E "^(NoNewPrivs|Seccomp):" /proc/self/status'
long=$(python3 -c 'print("/" + "a" * 5000, end="")')
expect "KCOS_EXEC names further directories; bad entries are skipped" 0 "allowed" -- \
  run -e "KCOS_EXEC=relative::/nonexistent:$long:/bb" -- /bb/busybox echo allowed
expect "  / and paths with .. are not accepted as program directories" 126 "sh: /tmp/busybox: permission denied" -- \
  run -e "KCOS_EXEC=/:/bb/../tmp:/bb/./:/bb" -- /bb/busybox sh -c 'exec /bin/sh -c "$1" 2>&1' m 'cp /bb/busybox /tmp/busybox; /tmp/busybox echo PWNED'
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
  if [ "$size" -lt 200000 ]; then ok "sealed image is under 200 kB ($size bytes)"; else ko "sealed image is under 200 kB" "<200000" "$size"; fi
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
x "--version" 0 "kcontaineros 0.1.0" kcontaineros --version
x "-V" 0 "kcontaineros 0.1.0" kcontaineros -V
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
t "a failed write is an error" 1 "cat: /t/cat/a: input/output error" 'cat /t/cat/a > /dev/full'

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
  $'cp: : no such file or directory\nmv: copy: no such file or directory\nls: /src: no such file or directory\nls: /copy: no such file or directory' \
  'cd /t/cp; cp src ""; mv copy ""; ls /src /copy'
t "a device can be a source" 0 "-rw-r--r-- 0 0 0 /t/cp/empty" 'cp /dev/null /t/cp/empty; ls -l /t/cp/empty'
t "usage" 1 "cp: usage: cp SRC... DST" 'cp onlyone'
t "several sources need a directory" 1 "cp: /t/cp/copy: not a directory" 'cp /t/cp/src /t/cp/hard /t/cp/copy'
t "missing source" 1 "cp: /nope: no such file or directory" 'cp /nope /t/cp/x'
t "a directory source" 1 "cp: /t/cp/dir: is a directory" 'cp /t/cp/dir /t/cp/x'
t "a FIFO source neither blocks nor copies" 1 "cp: /t/cp/fifo: invalid argument" 'cp /t/cp/fifo /t/cp/x'
t "unwritable destination, named in the message" 1 "cp: /nope/dir/x: no such file or directory" 'cp /t/cp/src /nope/dir/x'
t "a failed write is an error" 1 "cp: /dev/full: input/output error" 'cp /t/cp/src /dev/full'
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
t "-a shows hidden files" 0 $'.hidden\nfile\nlink\nlocked\npipe\nsub' 'ls -a /t/ls'
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
tu "reports what it could not remove" 1 $'rm: /t/rm/u/guard/inner/file: permission denied\nrm: /t/rm/u/guard/inner: directory not empty\nrm: /t/rm/u/guard: directory not empty' 'rm -r /t/rm/u/guard'
tu "a directory that cannot be listed" 1 "rm: /t/rm/u/blind: permission denied" 'rm -r /t/rm/u/blind'
bb 'cd /t/rm && i=0; while [ $i -lt 1500 ]; do mkdir d && cd d; i=$((i+1)); done'
t "a tree deeper than the longest path name" 0 "rc=1" 'rm -r /t/rm/d; ls /t/rm/d 2>/dev/null; echo "rc=$?"'

# Built with the shell under test: its cd is a plain chdir, with no limit
# on how long the full path gets.
python3 -c 'print("mkdir /t/rm/deep\ncd /t/rm/deep\n" + "mkdir d\ncd d\n" * 4200, end="")' | docker exec -i "$BENCH" sh
k "a tree deeper than 4096 levels is refused, not a crash" 0 $'1\nrc=1' '/bin/rm -r /t/rm/deep 2>&1 | grep -c "directory tree too deep"; /bin/rm -r /t/rm/deep 2>/dev/null; echo rc=$?'

echo "== sleep"
t0=$(now_ms); t "fractions of a second" 0 "" 'sleep 0.3; sleep .2'; t1=$(now_ms)
if [ $((t1 - t0)) -ge 500 ]; then ok "  really sleeps ($((t1 - t0)) ms)"; else ko "  really sleeps" ">=500 ms" "$((t1 - t0)) ms"; fi
t "whole seconds and a trailing dot" 0 "" 'sleep 0; sleep 0.'
t "missing operand" 1 "sleep: invalid time interval: " 'sleep'
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

# ---------------------------------------------------------------- memory
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
  c=$(docker run -d --name "kcos-web-$ID" "${D[@]}" -p 127.0.0.1::8080 "$HTTP")
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
