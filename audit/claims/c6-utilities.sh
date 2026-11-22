# The utilities: the options the README names, and "how the tools behave where it matters".
echo "== utilities"
BIOPT=()
# ub 'script'   busybox sh as root without init, in /tmp; the tools under test are called as /bin/NAME
ub() { R "${UOPT[@]+"${UOPT[@]}"}" -w /tmp --entrypoint /bb/busybox "$A" sh -c "{ $1
} 2>&1"; }
UOPT=()

claim T001 "R: utilities: common flags such as ls -la, rm -rf, mkdir -p, ln -s, chown UID:GID, env -i -u NAME NAME=value command, echo -ne, kill -s TERM, sleep 1.5, sleep 2m, sleep infinity"
t "ls -la shows hidden files, long format" 0 $'-rw-r--r-- 0 0 .h\n-rw-r--r-- 0 0 v' -- ub 'mkdir d; cd d; : > .h; : > v; /bin/ls -la | /bb/busybox awk "{print \$1, \$2, \$3, \$NF}"'
t "rm -rf, mkdir -p, ln -s" 0 $'c\nlrwxrwxrwx 0 0 1 l -> a\ngone' -- ub '/bin/mkdir -p a/b/c a; /bin/ls a/b; /bin/ln -s a l; /bin/ls -l | /bb/busybox grep " l "; /bin/rm -rf a l nonexistent; [ -e a ] || echo gone'
t "chown UID:GID" 0 "-rw-r--r-- 12 34 0 f" -- ub ': > f; /bin/chown 12:34 f; /bin/ls -l f'
t "env -i -u NAME NAME=value command" 0 $'B=2\nC=3' -- ub 'A=1 B=2 /bin/env -i B=2 A=1 C=3 /bin/env -u A /bin/env'
t "echo -ne" 0 "a	b|" -- ub '/bin/echo -ne "a\tb"; echo "|"'
t "kill -s TERM" 0 "rc=143" -- ub '/bb/busybox sleep 50 & /bin/kill -s TERM $!; wait $!; echo "rc=$?"'
t "sleep 1.5, sleep 2m (cut short), sleep infinity (cut short)" 0 $'1.5 s: yes\n2m: still asleep after 1 s\ninfinity: still asleep after 1 s' -- \
  ub 'exec 2>/dev/null; up() { /bb/busybox awk "{print int(\$1 * 100)}" /proc/uptime; }; s=$(up); /bin/sleep 1.5; e=$(up); [ $((e - s)) -ge 150 ] && [ $((e - s)) -lt 250 ] && echo "1.5 s: yes"; /bb/busybox timeout 1 /bin/sleep 2m 2>/dev/null; [ $? -eq 143 ] && echo "2m: still asleep after 1 s"; /bb/busybox timeout 1 /bin/sleep infinity 2>/dev/null; [ $? -eq 143 ] && echo "infinity: still asleep after 1 s"'
claim T009 "AGENTS (correct or loud, never silently different): ls -a lists . and .. as POSIX has it"
t "ls -a in a directory with one hidden and one visible file" 0 $'.\n..\n.h\nv' -- ub '/bb/busybox mkdir d; cd d; : > .h; : > v; /bin/ls -a'
claim T002 "R/I: -- ends options; an unknown option is an error"
t "an option none of them has (-Z): status of each utility, and nothing created" 0 \
  "cat=1 chmod=1 chown=1 cp=1 env=1 kill=1 ln=1 ls=1 mkdir=1 mv=1 ps=1 pwd=1 rm=1 sleep=1 touch=1 uname=1 files:" -- \
  ub 'for a in cat chmod chown cp env kill ln ls mkdir mv ps pwd rm sleep touch uname; do /bin/$a -Z x y >/dev/null 2>&1 </dev/null; /bb/busybox printf "%s=%s " $a $?; done; echo "files:$(/bb/busybox ls -A | /bb/busybox tr "\n" " ")"'
t "the options the README says are not there: cp -r, chmod u+x, rm -i, ls -R, mkdir -m, ln -f, touch -t, mv -n, kill -l, uname -o" 0 \
  "cp=1 chmod=1 rm=1 ls=1 mkdir=1 ln=1 touch=1 mv=1 kill=1 uname=1 " -- \
  ub ': > f; /bin/mkdir d; /bin/cp -r d e 2>/dev/null; /bb/busybox printf "cp=%s " $?; /bin/chmod u+x f 2>/dev/null; /bb/busybox printf "chmod=%s " $?; /bin/rm -i f 2>/dev/null </dev/null; /bb/busybox printf "rm=%s " $?; /bin/ls -R >/dev/null 2>&1; /bb/busybox printf "ls=%s " $?; /bin/mkdir -m 700 x 2>/dev/null; /bb/busybox printf "mkdir=%s " $?; /bin/ln -f f g 2>/dev/null; /bb/busybox printf "ln=%s " $?; /bin/touch -t 200001010000 f 2>/dev/null; /bb/busybox printf "touch=%s " $?; /bin/mv -n f h 2>/dev/null; /bb/busybox printf "mv=%s " $?; /bin/kill -l >/dev/null 2>&1; /bb/busybox printf "kill=%s " $?; /bin/uname -o >/dev/null 2>&1; /bb/busybox printf "uname=%s " $?; echo'
t "-- ends options: files named like options" 0 $'-l\n-r\ncontent\ngone' -- ub '/bin/mkdir d; cd d; /bin/touch -- -l -r; /bin/ls -- -l -r; echo content > ./-n; /bin/cat -- -n; /bin/rm -- -l -r -n; [ -z "$(/bb/busybox ls -A)" ] && echo gone'
t "grep, sed, tar, wget and the rest are not in the image" 0 "grep sed tar wget awk find head tail sort wc test [ printf id which date " -- \
  ub 'for c in grep sed tar wget awk find head tail sort wc test [ printf id which date; do [ -e /bin/$c ] || [ -e /usr/bin/$c ] || [ -e /sbin/$c ] || /bb/busybox printf "%s " "$c"; done; echo'
claim T003 "R: mv does not cross filesystems"
t "mv from /tmp to /dev/shm" 0 $'mv: f: cross-device link\nrc=1\nf' -- ub ': > f; /bin/mv f /dev/shm/f; echo "rc=$?"; /bb/busybox ls'
claim T004 "R/I: rm -r does not follow symlinks; it refuses /, . and ..; trees deeper than 4096 levels or than the limit on open files allows are refused; what it cannot remove it reports once, and it still empties a directory it is not allowed to delete"
t "symlinks to a directory, at the top and inside the tree, are removed as links" 0 "precious" -- ub '/bin/mkdir -p keep tree/sub; : > keep/precious; /bin/ln -s ../keep tree/l1; /bin/ln -s /tmp/keep tree/sub/l2; /bin/ln -s keep top; /bin/rm -r tree top; /bb/busybox ls keep; [ -e tree ] && echo "tree left"; [ -e top ] && echo "top left"; true'
t "rm -rf / . .. and paths that end in them" 1 $'rm: refusing to remove /\nrm: refusing to remove .\nrm: refusing to remove ..\nrm: refusing to remove ./\nrm: refusing to remove d/..\nrm: refusing to remove //\nstill there' -- \
  ub '/bin/mkdir d; /bin/rm -rf / . .. ./ d/.. //; rc=$?; [ -d /tmp/d ] && [ -e /bin/kcontaineros ] && echo "still there"; exit $rc'
# Built with the shell under test: busybox's cd gives up when the path gets too long.
t "a tree 4200 levels deep: refused with a message, not a crash; one of 4000 is removed" 0 $'rm: directory tree too deep\nrc=1\nrc=0 gone' -- \
  ub 'mk() { { echo "mkdir /tmp/$1"; echo "cd /tmp/$1"; i=0; while [ $i -lt $2 ]; do echo "mkdir d"; echo "cd d"; i=$((i+1)); done; } | /bin/sh; }; mk deep 4200; /bin/rm -r /tmp/deep 2>&1 | /bb/busybox sed "s/^rm: .*: directory tree too deep/rm: directory tree too deep/" | /bb/busybox head -3; /bin/rm -r /tmp/deep 2>/dev/null; echo "rc=$?"; mk ok 4000; /bin/rm -r /tmp/ok; echo "rc=$? $([ -e /tmp/ok ] || echo gone)"'
t "with 20 descriptors allowed, a tree 40 levels deep: refused with a message, not a crash" 0 "refused rc=1" -- \
  ub '/bb/busybox mkdir -p $(/bb/busybox printf "d/%.0s" $(/bb/busybox seq 1 40)); ulimit -n 20; out=$(/bin/rm -r d 2>&1); rc=$?; case "$out" in "rm: "*) echo "refused rc=$rc";; *) echo "rc=$rc out=$out";; esac'
UOPT=("${NOBODY[@]}" --tmpfs /tmp:mode=1777)
t "as nobody: a file in a directory without write permission is reported once, the rest is emptied" 0 $'rm: tree/locked/f: permission denied\nrc=1\nlocked' -- \
  ub '/bin/mkdir -p tree/open tree/locked; : > tree/open/a; : > tree/open/b; : > tree/locked/f; /bin/chmod 555 tree/locked; /bin/rm -r tree; echo "rc=$?"; /bb/busybox ls tree'
UOPT=()
claim T005 "R/I: kill accepts only real process IDs: 0, -1 and numbers that would wrap around a 32-bit PID are rejected"
t "kill 0, -- -1, 4294967295, 4294967297, 2147483648, -5, 1x; the shell that ran them is still alive" 0 \
  $'kill: invalid pid: 0\nkill: invalid pid: -1\nkill: invalid pid: 4294967295\nkill: invalid pid: 4294967297\nkill: invalid pid: 2147483648\nkill: invalid pid: -5\nkill: invalid pid: 1x\nalive' -- \
  ub '/bin/kill 0; /bin/kill -- -1; /bin/kill -9 4294967295; /bin/kill -0 4294967297; /bin/kill 2147483648; /bin/kill -- -5; /bin/kill 1x; echo alive'
claim T006 "R/I: cp never copies setuid, setgid or sticky bits, and refuses to copy a file onto itself"
t "cp of a 7755 file; onto itself, a hard link, a symlink to itself" 0 \
  $'-rwsr-sr-t\n-rwxr-xr-x\ncp: src: source and destination are the same file\ncp: src: source and destination are the same file\ncp: src: source and destination are the same file\ndata' -- \
  ub 'echo data > src; /bb/busybox chmod 7755 src; /bin/cp src copy; /bin/ls -l src copy | /bb/busybox cut -d" " -f1; /bb/busybox ln src hard; /bb/busybox ln -s src soft; /bin/cp src src; /bin/cp src hard; /bin/cp src soft; /bb/busybox cat src'
claim T007 "R/I: ps always, and ls and pwd on a terminal, replace everything but printable ASCII in names with ?"
t "ps, piped: a command line with ESC and a UTF-8 byte pair" 0 "/bb/busybox sh -c /bb/busybox sleep 31; : x?[31my??z" -- \
  ub '/bb/busybox sh -c "/bb/busybox sleep 31; :" "$(/bb/busybox printf "x\033[31my\303\251z")" & /bb/busybox sleep 0.3; /bin/ps | /bb/busybox sed -n "s/^ *[0-9]* S \(.*y??z\)\$/\1/p"; /bb/busybox pkill sleep; true'
t "ls and pwd, piped: bytes pass unchanged" 0 "1b5b33316d 1b5b33316d" -- \
  ub 'n=$(/bb/busybox printf "\033[31m"); /bb/busybox mkdir "$n"; cd "$n"; echo "$(cd ..; /bin/ls | /bb/busybox head -1 | /bb/busybox od -An -tx1 | /bb/busybox tr -d " \n" | /bb/busybox cut -c1-10) $(/bin/pwd | /bb/busybox od -An -tx1 | /bb/busybox tr -d " \n" | /bb/busybox cut -c11-20)"'
got=$(python3 test/term.py -- docker run -t --rm "${P[@]}" -w /tmp --entrypoint /bb/busybox "$A" sh -c 'n=$(/bb/busybox printf "a\033[31mb\303\251"); /bb/busybox mkdir "$n"; : > "$n/$n"; cd "$n"; /bin/ls; /bin/ls -l; /bin/pwd; /bin/cat "nope$n"; /bin/sh -c "exec \"\$0\"" "nope$n"; /sbin/init "nope$n"; :' | tr -d '\r' | sed '$d')
v "on a terminal: ls, ls -l, pwd, an error from a utility, from the shell and from init" \
  $'a?[31mb??\n-rw-r--r-- 0 0 0 a?[31mb??\n/tmp/a?[31mb??\ncat: nopea?[31mb??: no such file or directory\nsh: nopea?[31mb??: not found\nkcontaineros: nopea?[31mb??: no such file or directory' "$got"
claim T008 "R/I: a utility whose output cannot be written (full disk, closed descriptor) exits with status 1"
t "output to /dev/full" 0 "cat=1 echo=1 env=1 ls=1 ls-l=1 ps=1 pwd=1 uname=1 uname-a=1 list=1 version=1 help=1 " -- \
  ub 'r() { n=$1; shift; "$@" > /dev/full 2>/dev/null; /bb/busybox printf "%s=%s " $n $?; }; r cat /bin/cat /etc/passwd; r echo /bin/echo hi; r env /bin/env; r ls /bin/ls /; r ls-l /bin/ls -l /; r ps /bin/ps; r pwd /bin/pwd; r uname /bin/uname; r uname-a /bin/uname -a; r list /bin/kcontaineros --list; r version /bin/kcontaineros --version; r help /bin/kcontaineros --help; echo'
t "output to a closed descriptor" 0 "cat=1 echo=1 env=1 ls=1 ls-l=1 ps=1 pwd=1 uname=1 uname-a=1 list=1 version=1 help=1 " -- \
  ub 'r() { n=$1; shift; "$@" >&- 2>/dev/null; /bb/busybox printf "%s=%s " $n $? >&2; }; r cat /bin/cat /etc/passwd; r echo /bin/echo hi; r env /bin/env; r ls /bin/ls /; r ls-l /bin/ls -l /; r ps /bin/ps; r pwd /bin/pwd; r uname /bin/uname; r uname-a /bin/uname -a; r list /bin/kcontaineros --list; r version /bin/kcontaineros --version; r help /bin/kcontaineros --help; echo'
t "the shell's own echo, to /dev/full and to a closed descriptor, inside a script" 0 $'rc=1\nrc=1' -- R "$IMG" sh -c 'echo hi > /dev/full; echo "rc=$?"; echo hi >&-; echo "rc=$?"'
tc "the same commands with somewhere to write succeed" 0 "cat=0 echo=0 env=0 ls=0 ps=0 pwd=0 uname=0 list=0 " -- \
  ub 'r() { n=$1; shift; "$@" > /dev/null 2>&1; /bb/busybox printf "%s=%s " $n $?; }; r cat /bin/cat /etc/passwd; r echo /bin/echo hi; r env /bin/env; r ls /bin/ls /; r ps /bin/ps; r pwd /bin/pwd; r uname /bin/uname; r list /bin/kcontaineros --list; echo'
