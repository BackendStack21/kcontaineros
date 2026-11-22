# The Security table of the README (and the same rows on the page and in llms.txt),
# each against root in a --privileged container with Docker's filter off, with a control.
echo "== lockdown"
BIOPT=("${PRIV[@]}")
STATUS='/bb/busybox grep -E "^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):" /proc/self/status'
LOCKED=$'CapInh:\t0000000000000000\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000\nCapBnd:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2'

claim S001 "R/I/L: no capabilities: bounding, ambient and process sets emptied, even under --privileged; --cap-add has no effect"
t "privileged root: every set empty, no_new_privs 1, seccomp 2" 0 "$LOCKED" -- bi "$STATUS"
BIOPT=(--user 0 --cap-add ALL); t "--cap-add ALL: the same" 0 "$LOCKED" -- bi "$STATUS"; BIOPT=("${PRIV[@]}")
tc "without init the sets are full and nothing is locked" 0 "CapEff=full NoNewPrivs:0 Seccomp:0" -- \
  bc '/bb/busybox awk "/^CapEff/{printf \"CapEff=%s \", (\$2 ~ /^000001ffffffffff|^000003ffffffffff|^0000.ffffffffff/ ? \"full\" : \$2)} /^NoNewPrivs/{printf \"NoNewPrivs:%s \", \$2} /^Seccomp:/{print \"Seccomp:\" \$2}" /proc/self/status'
claim S002 "I (terminal session): docker run --rm --privileged --user 0 kcontaineros cat /proc/self/status | grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):'"
v "the session, character for character (tabs as on the page: one space)" \
  "CapInh: 0000000000000000|CapPrm: 0000000000000000|CapEff: 0000000000000000|CapBnd: 0000000000000000|CapAmb: 0000000000000000|NoNewPrivs: 1|Seccomp: 2|" \
  "$(R --privileged --user 0 "$IMG" cat /proc/self/status | grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):' | tr '\t' ' ' | tr '\n' '|')"
claim S003 "I (terminal session): docker run --rm --privileged --user 0 kcontaineros sh -c 'cp /bin/ls /tmp/ls; /tmp/ls; touch /usr/local/bin/x; mkdir /app'"
t "the session, character for character" 1 $'sh: /tmp/ls: permission denied\ntouch: /usr/local/bin/x: permission denied\nmkdir: /app: permission denied' -- \
  R --privileged --user 0 "$IMG" sh -c 'cp /bin/ls /tmp/ls; /tmp/ls; touch /usr/local/bin/x; mkdir /app'
tc "without init all of it works (ls lists /)" 0 "bin dev etc home proc root run sbin sys tmp usr var app-made" -- \
  R --privileged --user 0 --entrypoint /bin/sh "$IMG" -c 'cp /bin/ls /tmp/ls; /tmp/ls | /bin/kcontaineros sh -c "exec /tmp/ls /" | /bin/cat > /tmp/o; touch /usr/local/bin/x; mkdir /app && /tmp/ls / > /tmp/o2; echo bin dev etc home proc root run sbin sys tmp usr var app-made'

claim S004 "R/I/L: no_new_privs: setuid binaries and file capabilities grant nothing"
t "a setuid-root binary run by nobody keeps euid 65534; a binary with file capabilities gets none" 0 $'ret=65534\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000' -- \
  R "${NOBODY[@]}" kcos-audit-claims-nnp /bb/busybox sh -c '/usr/local/bin/suid-sc 175; /usr/local/bin/capdir/busybox grep -E "^Cap(Prm|Eff)" /proc/self/status'
tc "without init the same binaries are granted root and the capabilities" 0 $'ret=0\nCapPrm:\t0000000000000401\nCapEff:\t0000000000000401' -- \
  R "${NOBODY[@]}" --entrypoint /bb/busybox kcos-audit-claims-nnp sh -c '/usr/local/bin/suid-sc 175; /usr/local/bin/capdir/busybox grep -E "^Cap(Prm|Eff)" /proc/self/status'

claim S005 "R/I/L: programs are started only from the image's program directories; a binary dropped in /tmp or on a volume cannot be started"
docker volume rm -f kcos-audit-claims-v0 >/dev/null 2>&1
BIOPT=("${PRIV[@]}" -v kcos-audit-claims-v0:/vol --tmpfs /scratch:exec)
EXECS='B=/bb/busybox; for d in /tmp /var/tmp /vol /scratch /home /root /etc; do $B cp /bb/sc $d/prog 2>/dev/null || { echo "$d: cannot write there"; continue; }; $d/prog 172 >/dev/null 2>&1; echo "$d: exec rc=$?"; done; /bb/sc 172 >/dev/null; echo "/bb: exec rc=$?"'
t "privileged root: copies of a static binary in every writable place do not start" 0 \
  $'/tmp: exec rc=126\n/var/tmp: exec rc=126\n/vol: exec rc=126\n/scratch: exec rc=126\n/home: cannot write there\n/root: cannot write there\n/etc: cannot write there\n/bb: exec rc=0' -- bi "$EXECS"
tc "without init they start" 0 \
  $'/tmp: exec rc=0\n/var/tmp: exec rc=0\n/vol: exec rc=0\n/scratch: exec rc=0\n/home: exec rc=0\n/root: exec rc=0\n/etc: exec rc=0\n/bb: exec rc=0' -- bc "$EXECS"
docker volume rm -f kcos-audit-claims-v0 >/dev/null 2>&1
BIOPT=("${PRIV[@]}")

claim S006 "R/I: nothing can be created, removed or written in program directories, whatever the file permissions"
WRITES='B=/bb/busybox; $B chmod 777 /bb /bb/probe /usr/local/bin /bin; echo "chmod=$?"
$B touch /usr/local/bin/new 2>/dev/null; echo "create=$?"
$B mkdir /usr/local/bin/d 2>/dev/null; echo "mkdir=$?"
$B ln -s /tmp /usr/local/bin/sl 2>/dev/null; echo "symlink=$?"
$B ln /etc/passwd /usr/local/bin/hl 2>/dev/null; echo "hardlink=$?"
$B mkfifo /usr/local/bin/ff 2>/dev/null; echo "mkfifo=$?"
$B rm -f /bin/ls 2>/dev/null; echo "remove=$?"
$B mkdir -p /tmp/e; $B rmdir /usr/local/bin 2>/dev/null; echo "rmdir=$?"
$B mv /bin/cat /bin/cat2 2>/dev/null; echo "rename=$?"
$B mv /bin/true /tmp/true 2>/dev/null; echo "move-out=$?"
$B mv /tmp/e /bb/e 2>/dev/null; echo "move-in=$?"
(echo x >> /bb/probe) 2>/dev/null; echo "append=$?"
$B truncate -s 0 /bb/probe 2>/dev/null; echo "truncate=$?"
$B dd if=/dev/zero of=/bb/probe bs=1 count=1 conv=notrunc 2>/dev/null; echo "overwrite=$?"
/bb/sc 45 s:/bb/probe 0; /bb/sc 276 -100 s:/bb/probe -100 s:/bb/probe2 0
$B sha256sum /bb/probe /bb/probe2 2>/dev/null | $B head -1 | $B cut -c1-64'
sum=$(R --entrypoint /bb/busybox "$A" sha256sum /bb/probe | cut -c1-64)
t "privileged root, after chmod 777 on the directories and the file" 0 \
  $'chmod=0\ncreate=1\nmkdir=1\nsymlink=1\nhardlink=1\nmkfifo=1\nremove=1\nrmdir=1\nrename=1\nmove-out=1\nmove-in=1\nappend=1\ntruncate=1\noverwrite=1\nerrno=13\nerrno=13\n'"$sum" -- bi "$WRITES"
tc "without init the same attempts change the image" 0 "chmod=0 create=0 mkdir=0 symlink=0 hardlink=0 mkfifo=0 remove=0 rmdir=1 rename=0 move-out=0 move-in=0 append=0 truncate=0 overwrite=0 ret=0 ret=0 changed" -- \
  bc "( $WRITES )"' | /bb/busybox sed "s/^'"$sum"'\$/same/; s/^[0-9a-f]\{64\}\$/changed/" | /bb/busybox tr "\n" " " | /bb/busybox sed "s/ \$//"'

claim S007 "R/I/L: memory files (memfd_create) cannot be created at all"
t "memfd_create and memfd_secret" 0 $'errno=1\nerrno=1' -- bi '/bb/sc 279 s:x 0; /bb/sc 447 0'
tc "without init memfd_create works" 0 "ret=3" -- bc '/bb/sc 279 s:x 0'

claim S008 "R/I/L: symbolic links are never followed when the rules are set up, so a link cannot turn a program directory into a writable one"
LINKS='B=/bb/busybox; $B ln -s usr/local /lnk-top; $B ln -s /bb /tmp/lnk-deep; $B mkdir -p /usr/share/x; $B chmod 777 /usr/share/x; $B ln -s /usr/share/x /data
exec $INIT /bb/busybox sh -c "{ B=/bb/busybox; \$B touch /lnk-top/bin/f; echo top-level-link=\$?; \$B touch /tmp/lnk-deep/f; echo link-in-tmp=\$?; \$B touch /data/f; echo data-link=\$?; \$B touch /usr/share/x/f; echo direct=\$?; } 2>/dev/null"'
t "links made before init starts (as a Dockerfile could): /lnk-top -> usr/local, /tmp/lnk-deep -> /bb, /data -> /usr/share/x" 0 \
  $'top-level-link=1\nlink-in-tmp=1\ndata-link=1\ndirect=1' -- R "${PRIV[@]}" -e INIT=/sbin/init --entrypoint /bb/busybox "$A" sh -c "$LINKS"
tc "with init left out the links lead to writable directories" 0 $'top-level-link=0\nlink-in-tmp=0\ndata-link=0\ndirect=0' -- \
  R "${PRIV[@]}" -e INIT= --entrypoint /bb/busybox "$A" sh -c "$LINKS"

claim S009 "R/I/L: of /dev a program can open null, zero, full, random, urandom, tty, console, the terminals in /dev/pts, and /dev/shm; nothing else, for reading or for writing; under --privileged that is every disk of the host"
SWEEP='B=/bb/busybox; n=0; for d in $($B find /dev \( -type b -o -type c \) ! -name "watchdog*" ! -name "*vsock*" | $B sort); do n=$((n+1)); (true < $d) 2>/dev/null && echo "read $d"; (true >> $d) 2>/dev/null && echo "write $d"; done; [ $n -gt 50 ] && echo "many device nodes tried"; [ $($B find /dev -type b | $B wc -l) -gt 0 ] && echo "block devices among them"; echo x > /dev/shm/f && echo "shm writable"'
t "privileged root opens every device node of /dev (watchdog and vsock nodes left out) for reading, then for appending" 0 \
  $'read /dev/full\nwrite /dev/full\nread /dev/null\nwrite /dev/null\nread /dev/pts/ptmx\nwrite /dev/pts/ptmx\nread /dev/random\nwrite /dev/random\nread /dev/urandom\nwrite /dev/urandom\nread /dev/zero\nwrite /dev/zero\nmany device nodes tried\nblock devices among them\nshm writable' -- bi "$SWEEP"
# No control over every node: block devices must not be opened without init. One harmless character device instead.
t "control device /dev/kmsg under init" 0 $'r=1\nw=1' -- bi '(true < /dev/kmsg) 2>/dev/null; echo "r=$?"; (true >> /dev/kmsg) 2>/dev/null; echo "w=$?"'
tc "/dev/kmsg without init" 0 $'r=0\nw=0' -- bc '(true < /dev/kmsg) 2>/dev/null; echo "r=$?"; (true >> /dev/kmsg) 2>/dev/null; echo "w=$?"'
v "with a terminal: /dev/tty, /dev/console and the terminal in /dev/pts open for reading and writing" "tty=0 console=0 pts=0 " \
  "$(python3 test/term.py -- docker run -it --rm "${P[@]}" "${PRIV[@]}" "$A" /bb/busybox sh -c '(true <> /dev/tty) && echo tty=0; (true <> /dev/console) && echo console=0; (true <> $(/bb/busybox tty)) && echo pts=0' | tr -d '\r' | grep -x -E '(tty|console|pts)=0' | tr '\n' ' ')"

claim S010 "R/I: a device passed with --device has to be named in KCOS_DEV; without the name the device is there but cannot be opened"
BIOPT=("${NOBODY[@]}" --device /dev/zero:/dev/kz)
OPENS='(true < /dev/kz) 2>/dev/null; echo "read=$?"; (true >> /dev/kz) 2>/dev/null; echo "write=$?"'
t "unnamed device (mode 0666), as nobody" 0 $'read=1\nwrite=1' -- bi "$OPENS"
tc "without init" 0 $'read=0\nwrite=0' -- bc "$OPENS"
BIOPT+=(-e KCOS_DEV=/dev/kz); t "named in KCOS_DEV" 0 $'read=0\nwrite=0' -- bi "$OPENS"
BIOPT=("${NOBODY[@]}" --device /dev/zero:/dev/kz --device /dev/zero:/dev/ky -e KCOS_DEV=/dev/kz)
t "two devices, one named: the other stays closed" 0 $'read=1\nwrite=1' -- bi "${OPENS//kz/ky}"
BIOPT=("${NOBODY[@]}" --device /dev/zero:/dev/net/tun --device /dev/zero:/dev/net/other -e KCOS_DEV=/dev/net/tun)
t "two devices in one subdirectory of /dev (the README's KCOS_DEV=/dev/net/tun), one named: the other stays closed" 0 $'read=1\nwrite=1' -- bi "${OPENS//kz/net/other}"
BIOPT=("${NOBODY[@]}" --device /dev/zero:/dev/net/tun --device /dev/zero:/dev/net/other)
t "  the same two with neither named: both closed" 0 $'read=1\nwrite=1\nread=1\nwrite=1' -- bi "${OPENS//kz/net/other}; ${OPENS//kz/net/tun}"
BIOPT=(--device /dev/fuse)
t "R (recipe): docker run --device /dev/fuse -e KCOS_DEV=/dev/fuse my-image: the device opens; without the name it does not" 0 $'named=0\nunnamed=1' -- \
  sh -c "timeout 120 docker run --rm --platform linux/arm64 --device /dev/fuse -e KCOS_DEV=/dev/fuse $IMG sh -c 'true >> /dev/fuse; echo named=\$?' 2>/dev/null; timeout 120 docker run --rm --platform linux/arm64 --device /dev/fuse $IMG sh -c 'true >> /dev/fuse; echo unnamed=\$?' 2>/dev/null"
BIOPT=("${PRIV[@]}")

claim S011 "R/I/L: under init, root cannot open the files of /proc and /sys for writing: not /proc/sys, not the sysrq trigger"
PROCSYS='B=/bb/busybox; $B find /proc/sys /proc/sysrq-trigger /proc/irq /proc/self/oom_score_adj /proc/self/comm /proc/self/coredump_filter /proc/self/attr /proc/1/oom_score_adj -type f -perm -200 2>/dev/null > /tmp/l; $B find /sys -maxdepth 5 -type f -perm -200 2>/dev/null >> /tmp/l; n=0; while read f; do n=$((n+1)); (true >> $f) 2>/dev/null && echo "opened $f"; done < /tmp/l; [ $n -gt 3000 ] && echo "more than 3000 files tried"; $B grep -c -x -E "/proc/sys/kernel/core_pattern|/proc/sysrq-trigger|/proc/self/oom_score_adj" /tmp/l'
t "privileged root opens for appending every file with the owner's write bit in /proc/sys, /proc/irq, /sys (5 levels) and a few of /proc/self" 0 $'more than 3000 files tried\n3' -- bi "$PROCSYS"
KFILES='for f in /proc/sys/kernel/core_pattern /proc/sysrq-trigger /proc/self/oom_score_adj /sys/kernel/mm/transparent_hugepage/enabled; do (true >> $f) 2>/dev/null; echo "$f $?"; done'
tc "without init root opens them (four files, opened for appending and closed)" 0 $'/proc/sys/kernel/core_pattern 0\n/proc/sysrq-trigger 0\n/proc/self/oom_score_adj 0\n/sys/kernel/mm/transparent_hugepage/enabled 0' -- bc "$KFILES"
claim S012 "R/I: as root a program cannot write to /proc or /sys at all, its own /proc/self/oom_score_adj included; as a non-root user ordinary file permissions apply"
BIOPT=(--user 0); t "root, not privileged" 0 $'/proc/sys/kernel/core_pattern 1\n/proc/sysrq-trigger 1\n/proc/self/oom_score_adj 1\n/sys/kernel/mm/transparent_hugepage/enabled 1' -- bi "$KFILES"
BIOPT=("${NOBODY[@]}"); t "nobody: its own file opens, root's do not" 0 $'/proc/sys/kernel/core_pattern 1\n/proc/sysrq-trigger 1\n/proc/self/oom_score_adj 0\n/sys/kernel/mm/transparent_hugepage/enabled 1' -- bi "$KFILES"
BIOPT=("${PRIV[@]}")

claim S013 "R/I: ptrace, reading or writing another process's memory, new namespaces, mounts, chroot, kernel modules, bpf, io_uring, perf, keyrings, clock and hostname changes, AF_VSOCK sockets and switching off address randomisation are refused"
# Arguments are chosen so that a call the kernel does accept changes nothing (bad pointers, nonexistent PIDs).
CALLS='for c in ptrace:117:1:999999 process_vm_readv:270:999999 process_vm_writev:271:999999 unshare:97:0 setns:268:-1:0 mount:40:0:0:0:0:0 umount2:39:0:0 pivot_root:41:0:0 chroot:51:0 init_module:105:0:0:0 finit_module:273:-1:0:0 delete_module:106:0:0 bpf:280:99:0:0 io_uring_setup:425:0:0 io_uring_enter:426:-1:0:0:0 io_uring_register:427:-1:0:0:0 perf_event_open:241:0:0:0:0:0 add_key:217:0:0:0:0:0 request_key:218:0:0:0:0 keyctl:219:99:0 clock_settime:112:0:0 settimeofday:170:0:0 adjtimex:171:0 clock_adjtime:266:0:0 sethostname:161:0:100000 setdomainname:162:0:100000 personality-no-aslr:92:0x40000; do n=${c%%:*}; r=${c#*:}; echo "$n $(/bb/sc $(echo $r | /bb/busybox tr : " "))"; done; echo "clone-newuser $(/bb/sc clone 0x10000000)"; echo "clone-newns $(/bb/sc clone 0x20000)"; echo "clone-newnet $(/bb/sc clone 0x40000000)"; echo "clone-newpid $(/bb/sc clone 0x20000000)"; echo "clone-newipc $(/bb/sc clone 0x08000000)"; echo "clone-newuts $(/bb/sc clone 0x04000000)"; echo "clone-newcgroup $(/bb/sc clone 0x02000000)"'
t "privileged root: each answers EPERM (errno 1)" 0 "34 calls, refused with errno 1: 34" -- bi "( $CALLS )"' | /bb/busybox awk "{n++} \$2==\"errno=1\"{r++} END{print n \" calls, refused with errno 1: \" r+0}"'
tc "without init none answers EPERM" 0 "34 calls, refused with errno 1: 0" -- bc "( $CALLS )"' | /bb/busybox awk "{n++} \$2==\"errno=1\"{r++} END{print n \" calls, refused with errno 1: \" r+0}"'
t "AF_VSOCK socket refused, other families not (no control: a hypervisor socket is not opened without init)" 0 $'vsock errno=1\ninet ret=3\nunix ret=3' -- \
  bi 'echo "vsock $(/bb/sc 198 40 1 0)"; echo "inet $(/bb/sc 198 2 1 0)"; echo "unix $(/bb/sc 198 1 1 0)"'
t "the whole refusal list of src/lock.rs, called with zero arguments" 0 "61 refused of 61" -- \
  bi 'r=0; n=0; for c in 279 447 117 270 271 272 438 440 448 97 268 39 40 41 51 428 429 430 431 432 433 442 264 265 104 294 105 106 273 280 241 282 425 426 427 217 218 219 18 42 58 60 443 89 116 142 161 162 112 170 171 266 224 225 262 460 235 237 238 239 450; do n=$((n+1)); [ "$(/bb/sc $c 0 0 0 0 0 0)" = errno=1 ] && r=$((r+1)); done; echo "$r refused of $n"'
t "plain fork and personality(0)/query still work" 0 $'fork ok\nret=0\nret=0' -- bi '[ "$(/bb/sc clone 0)" != errno=1 ] && echo "fork ok"; /bb/sc 92 0; /bb/sc 92 0xffffffff'
claim S014 "R/I: system calls newer than the filter knows are answered 'not implemented'"
t "numbers 467 to 600, 1000, 65535 and 2^32-1 answer ENOSYS (38)" 0 "137 of 137" -- \
  bi 'n=0; r=0; for c in $(/bb/busybox seq 467 600) 1000 65535 4294967295; do n=$((n+1)); [ "$(/bb/sc $c 0 0 0 0 0 0)" = errno=38 ] && r=$((r+1)); done; echo "$r of $n"'
tc "without init this kernel implements some of them (467 open_tree_attr answers something else)" 0 "467 implemented" -- bc '[ "$(/bb/sc 467 -1 0 0 0 0 0)" != errno=38 ] && echo "467 implemented"'
t "clone3 answers ENOSYS so that libc falls back to clone" 0 "errno=38" -- bi '/bb/sc 435 0 0'

claim S015 "R/I: image files are read-only and owned by root; the default user cannot modify the image"
t "files and directories in the image that nobody owns or may write (as listed without init)" 0 $'/tmp\n/var/tmp' -- \
  R --user 0 --entrypoint /bb/busybox "$A" sh -c '/bb/busybox find / -xdev "(" -perm -0002 -o -user 65534 -o -group 65534 ")" ! -type l | /bb/busybox sort'
t "entries of the image not owned by root (the audit image's /bb aside)" 0 "" -- \
  R --user 0 --entrypoint /bb/busybox "$A" sh -c '/bb/busybox find / -xdev ! -user 0 ! -path "/bb*" | /bb/busybox sort'
BIOPT=("${NOBODY[@]}")
t "nobody under init: writes to the image fail" 0 $'bin=1\netc=1\nusr=1\nroot=1\nrun=1\nhome=1\ntmp=0' -- \
  bi '(echo x >> /bin/kcontaineros) 2>/dev/null; echo "bin=$?"; (echo x >> /etc/passwd) 2>/dev/null; echo "etc=$?"; (echo x > /usr/local/bin/x) 2>/dev/null; echo "usr=$?"; (echo x > /root/x) 2>/dev/null; echo "root=$?"; (echo x > /run/x) 2>/dev/null; echo "run=$?"; (echo x > /home/x) 2>/dev/null; echo "home=$?"; (echo x > /tmp/x) 2>/dev/null; echo "tmp=$?"'

claim S016 "R/I: PID 1 is not dumpable: other processes cannot read its memory or environment"
PEEK='B=/bb/busybox; $B cat /proc/1/environ >/dev/null 2>&1; echo "environ=$?"; $B head -c1 /proc/1/mem >/dev/null 2>&1; echo "mem=$?"; $B cat /proc/1/maps >/dev/null 2>&1; echo "maps=$?"; $B ls /proc/1/fd >/dev/null 2>&1; echo "fd=$?"; $B readlink /proc/1/exe >/dev/null 2>&1; echo "exe=$?"; $B readlink /proc/1/cwd >/dev/null 2>&1; echo "cwd=$?"; (true >> /proc/1/mem) 2>/dev/null; echo "mem-write=$?"'
t "nobody (the same user as PID 1)" 0 $'environ=1\nmem=1\nmaps=1\nfd=1\nexe=1\ncwd=1\nmem-write=1' -- bi "$PEEK"
# Root owns the /proc/1 entries of a process that is not dumpable, so it can list the descriptor numbers; not asserted either way.
BIOPT=("${PRIV[@]}"); t "privileged root" 0 $'environ=1\nmem=1\nmaps=1\nexe=1\ncwd=1\nmem-write=1' -- bi "( $PEEK )"' | /bb/busybox grep -v "^fd="'
BIOPT=("${NOBODY[@]}"); tc "without init PID 1's environment and maps are readable by the same user" 0 $'environ=0\nmem=1\nmaps=0\nfd=0\nexe=0\ncwd=0\nmem-write=0' -- bc "$PEEK"
BIOPT=()
