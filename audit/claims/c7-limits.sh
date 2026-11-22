# The stated limits ("What this does not give you"), each run to see that it is as the README says and no worse,
# the hardening claims that need a running process, and the remaining rows of the features table.
echo "== limits, hardening, Docker options"
BIOPT=()
claim L001 "R/I: static PIE: the kernel loads it at a random address on every start; code, data, stack and heap are all randomised"
maps() { R --user 0 "$IMG" sh -c 'X=1; cat /proc/self/maps' | awk '/kcontaineros/ && !c {c=$1} /\[stack\]/ {s=$1} /\[heap\]/ {h=$1} $6=="" && !a {a=$1} END{print "code=" c, "stack=" s, "anon=" a}'; }
m1=$(maps); m2=$(maps); m3=$(maps)
echo "        $m1"; echo "        $m2"; echo "        $m3"
v "three starts of cat: code, stack and first anonymous mapping at three different addresses each" "3 3 3" \
  "$(printf '%s\n%s\n%s\n' "$m1" "$m2" "$m3" | awk '{c[$1]=1; s[$2]=1; a[$3]=1} END{print length(c), length(s), length(a)}')"
claim L002 "R/I: read-only after start (RELRO); no segment is both writable and executable, and the stack is not executable"
v "permissions of the binary's mappings and of the stack in a running process; mappings that are w and x" "r--p r-xp r--p|stack rw-p|wx: 0" \
  "$(R "$IMG" cat /proc/self/maps | awk '/kcontaineros/{printf "%s ", $2} /\[stack\]/{s=$2} $2 ~ /w.*x|wx/{n++} END{printf "|stack %s|wx: %d", s, n+0}' | sed 's/ |/|/')"
claim L003 "R/I (limit): a process can still map bytes into its own memory as executable code and jump to them; mount writable directories noexec (Docker's --tmpfs does by default) to stop files there being mapped as code"
t "anonymous memory mapped rwx, code written and called, under init" 0 "execmem: 42" -- R "$A" /bb/sc execmem
t "a file in /tmp (the image's own, not noexec) mapped PROT_EXEC under init" 0 "mmap-exec ok" -- R "$A" /bb/busybox sh -c '/bb/busybox cp /bb/sc /tmp/f; /bb/sc fileexec /tmp/f'
t "the same on a --tmpfs /tmp: refused" 0 "mmap-exec errno=1" -- R --tmpfs /tmp "$A" /bb/busybox sh -c '/bb/busybox cp /bb/sc /tmp/f; /bb/sc fileexec /tmp/f'
t "such code cannot become a new program: execve of the file is refused" 0 "126" -- R "$A" /bb/busybox sh -c '/bb/busybox cp /bb/sc /tmp/f; /tmp/f 172 2>/dev/null; echo $?'
claim L004 "R/I (limit): the rules go by where things are mounted when init starts: a device node outside /dev (--device /dev/x:/data/x) is an ordinary file"
t "--device /dev/zero:/data/x, unnamed: opens for reading and writing under init" 0 $'r=0\nw=0' -- \
  R "${NOBODY[@]}" --device /dev/zero:/data/x "$A" /bb/busybox sh -c '(true < /data/x) 2>/dev/null; echo "r=$?"; (true >> /data/x) 2>/dev/null; echo "w=$?"'
claim L005 "R/I (limit): one volume mounted both inside a program directory and somewhere writable can be written through the second path and run through the first"
docker volume rm -f kcos-audit-claims-v2 >/dev/null 2>&1
# Landlock rules attach to the directory itself, and both mounts show the same one: the volume is writable through
# both paths (the README says through the second), and runnable through the first only.
t "volume at /usr/local/vol and at /data: a program written to /data runs from /usr/local/vol, not from /data" 0 $'hello from prog args=[] uid=0\nrun-via-data=126\nwrite-via-usr=0' -- \
  R --user 0 -v kcos-audit-claims-v2:/usr/local/vol -v kcos-audit-claims-v2:/data "$A" /bb/busybox sh -c '/bb/busybox cp /bb/sc /data/prog && /usr/local/vol/prog; /data/prog 2>/dev/null; echo "run-via-data=$?"; (: > /usr/local/vol/f) 2>/dev/null; echo "write-via-usr=$?"'
docker volume rm -f kcos-audit-claims-v2 >/dev/null 2>&1
claim L006 "R/I (limit): root can still change the permissions and timestamps of files it owns, in program directories too; it cannot change what is in them"
sum=$(R --entrypoint /bb/busybox "$A" sha256sum /bin/kcontaineros | cut -c1-64)
t "root under init: chmod and touch of /bb/probe succeed, the content and the directory listing stay" 0 "chmod=0 utimes=0 mode=-rwsrwxrwx year=2001 write=1 same" -- \
  R --user 0 "$A" /bb/busybox sh -c 'B=/bb/busybox; a=$($B sha256sum /bb/probe); $B chmod 4777 /bb/probe; c=$?; $B touch -d "2001-01-01 00:00:00" /bb/probe; u=$?; (echo x >> /bb/probe) 2>/dev/null; w=$?; echo "chmod=$c utimes=$u mode=$($B ls -l /bb/probe | $B cut -c1-10) year=$($B date -r /bb/probe +%Y) write=$w $([ "$a" = "$($B sha256sum /bb/probe)" ] && echo same)"'
t "  the setuid bit root set that way grants nothing (no_new_privs): euid of the setuid copy run by nobody" 0 "ret=65534" -- R "${NOBODY[@]}" kcos-audit-claims-nnp /usr/local/bin/suid-sc 175
claim L007 "R/I (limit): host directories shared by Docker Desktop can be read but not written to, and programs in them cannot be started; when /dev holds more than the standard entries they cannot be read either"
share=$(cd "$OUT" && pwd)/share; rm -rf "$share"; mkdir -p "$share"; echo host-file > "$share/readme"
docker rm -f kcos-audit-claims-ex >/dev/null 2>&1; docker create "${P[@]}" --name kcos-audit-claims-ex "$A" >/dev/null
docker cp -q kcos-audit-claims-ex:/bb/sc "$share/prog"; docker rm kcos-audit-claims-ex >/dev/null
BM=(--user 0 -v "$share:/host" -e KCOS_EXEC=/bb:/host)
t "bind mount of a macOS directory at /host under init, as root: read, write, run" 0 $'host-file\nwrite=1\nexec=126' -- \
  R "${BM[@]}" "$A" /bb/busybox sh -c '/bb/busybox cat /host/readme; (echo x > /host/new) 2>/dev/null; echo "write=$?"; /host/prog 2>/dev/null; echo "exec=$?"'
t "  with an unnamed --device: not readable either" 0 "read=1" -- R "${BM[@]}" --device /dev/zero:/dev/kz "$A" /bb/busybox sh -c '(/bb/busybox cat /host/readme) >/dev/null 2>&1; echo "read=$?"'
tc "without init the directory is writable and the program in it starts" 0 $'write=0\nhello from prog args=[] uid=0' -- R --user 0 -v "$share:/host" --entrypoint /bb/busybox "$A" sh -c 'echo x > /host/new; echo "write=$?"; /host/prog'
rm -rf "$share"
claim L008 "R/I (limit): processes of the same user can write each other's memory through /proc/PID/mem unless the host enables Yama"
t "nobody under init opens a sibling's /proc/PID/mem for writing (opened and closed, nothing written); not PID 1's" 0 $'sibling=0\npid1=1' -- \
  R "${NOBODY[@]}" "$A" /bb/busybox sh -c '/bb/busybox sleep 5 & (true >> /proc/$!/mem) 2>/dev/null; echo "sibling=$?"; (true >> /proc/1/mem) 2>/dev/null; echo "pid1=$?"; kill $!'
t "root under init cannot (no write in /proc)" 0 "sibling=1" -- R --user 0 "$A" /bb/busybox sh -c '/bb/busybox sleep 5 & (true >> /proc/$!/mem) 2>/dev/null; echo "sibling=$?"; kill $!'
claim L009 "R/I (limit): the shell will interpret a script from anywhere, including one written to /tmp; it cannot be executed directly"
t "a script written to /tmp: run through sh, then directly" 0 $'interpreted\nsh: /tmp/s: permission denied\nrc=126' -- R "$IMG" sh -c 'exec 2>&1; echo "echo interpreted" > /tmp/s; chmod 755 /tmp/s; sh /tmp/s; /tmp/s; echo "rc=$?"'
claim L010 "R/I (limit): on kernels without Landlock init prints a warning and the run-or-write rule is not enforced; everything else is; if the filter cannot be installed, init refuses to start"
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["landlock_create_ruleset"],"action":"SCMP_ACT_ERRNO","errnoRet":38}]}' > "$OUT/no-landlock.json"
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["landlock_restrict_self"],"action":"SCMP_ACT_ERRNO","errnoRet":1}]}' > "$OUT/no-restrict.json"
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["landlock_add_rule"],"action":"SCMP_ACT_ERRNO","errnoRet":1}]}' > "$OUT/no-addrule.json"
echo '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["seccomp"],"action":"SCMP_ACT_ERRNO","errnoRet":1}]}' > "$OUT/no-seccomp.json"
t "Landlock answered ENOSYS by a Docker seccomp profile: warning, a program from /tmp runs, the rest holds" 0 \
  $'kcontaineros: warning: Landlock is unavailable, so programs can be run from any path\nhello from prog args=[] uid=0\nCapEff:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2\nerrno=1' -- \
  R --user 0 --security-opt "seccomp=$OUT/no-landlock.json" "$A" /bb/busybox sh -c '/bb/busybox cp /bb/sc /tmp/prog; /tmp/prog; /bb/busybox grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/self/status; /bb/sc 279 s:x 0' 
t "landlock_restrict_self failing: the same warning" 0 $'kcontaineros: warning: Landlock is unavailable, so programs can be run from any path\nhi' -- \
  R --security-opt "seccomp=$OUT/no-restrict.json" "$IMG" echo hi
t "landlock_add_rule failing (a rule that cannot be added grants nothing): nothing can be run" 126 "kcontaineros: echo: permission denied" -- \
  R --security-opt "seccomp=$OUT/no-addrule.json" "$IMG" echo hi
t "the seccomp call refused: init does not start the command" 125 "kcontaineros: cannot install the system call filter" -- \
  R --security-opt "seccomp=$OUT/no-seccomp.json" "$IMG" echo hi
rm -f "$OUT"/no-*.json
claim L011 "R/I (limit): started as non-root, init cannot empty the capability bounding set; with no_new_privs nothing can draw on it"
t "nobody: bounding set left as Docker gave it, the other sets empty" 0 $'CapInh:\t0000000000000000\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000\nCapBnd:\t00000000a80425fb\nCapAmb:\t0000000000000000' -- \
  R "${NOBODY[@]}" "$A" /bb/busybox grep -E '^Cap' /proc/self/status
t "  a binary with file capabilities within that set still gets none" 0 $'CapPrm:\t0000000000000000\nCapEff:\t0000000000000000' -- \
  R "${NOBODY[@]}" kcos-audit-claims-nnp /usr/local/bin/capdir/busybox grep -E '^Cap(Prm|Eff)' /proc/self/status
claim L012 "R: Docker options --read-only, --cap-drop ALL, --user, --security-opt no-new-privileges, --memory 8m work together"
t "all five at once" 0 $'sh: /tmp/f: read-only file system\nUid:\t1234\t1234\t1234\t1234\nCapEff:\t0000000000000000\nNoNewPrivs:\t1' -- \
  R --read-only --cap-drop ALL --user 1234:5678 --security-opt no-new-privileges --memory 8m "$A" /bb/busybox sh -c 'sh -c "echo x > /tmp/f" 2>&1; /bb/busybox grep -E "^(Uid|CapEff|NoNewPrivs):" /proc/self/status'
claim L013 "R: users: root and nobody in /etc/passwd; no adduser; CA certificates, timezone data, /etc/services, a package manager: not there"
t "/etc/passwd; the other files and tools" 0 $'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false\nmissing: /etc/ssl /etc/services /usr/share/zoneinfo /bin/adduser /sbin/apk /usr/bin/apt /lib ' -- \
  R --entrypoint /bb/busybox "$A" sh -c '/bin/cat /etc/passwd; echo "missing: $(for f in /etc/ssl /etc/services /usr/share/zoneinfo /bin/adduser /sbin/apk /usr/bin/apt /lib; do [ -e $f ] || /bb/busybox printf "%s " $f; done)"'
claim L014 "R: init: supervising or restarting several services: no; one command, use the shell's & and wait for more"
t "two background commands and wait under init; the container ends when the script does" 0 $'a\nb\ndone' -- R "$IMG" sh -c 'sh -c "sleep 0.2; echo b" & echo a & wait; echo done'
