# Runs INSIDE a container (busybox ash, fed on stdin by matrix.sh).
# Prints one line per attempt: target <TAB> operation <TAB> result.
# MODE=init|control is passed in the environment. Under "control" there is no
# init and (as root) real capabilities, so the rules of the audit apply:
# kernel files and devices are only opened and closed, block devices and
# hypervisor devices are not touched at all.
L=/bb/lp
o() { t=$1; op=$2; shift 2; printf '%s\t%s\t%s\n' "$t" "$op" "$($L "$@" 2>&1)"; }
n=0

# Scratch sources in /tmp for "link into" / "rename into".
src() { n=$((n+1)); S=/tmp/ks$n; $L copy /bb/lp $S >/dev/null 2>&1; $L chmod 777 $S >/dev/null 2>&1; }

dirops() { # a directory holding kv (0777 copy of the probe) and kd (1777 dir)
    D=$1
    o $D exec        exec $D/kv
    o $D execveat-fd fexec r $D/kv
    o $D exec-procfd procfdexec $D/kv
    o $D mmap-exec   mmapx $D/kv
    o $D list        open d $D
    o $D read        read $D/kv
    o $D open-write  open w $D/kv
    o $D open-append open a $D/kv
    o $D create      open c $D/kn
    o $D mkdir       mkdir $D/knd
    o $D mknod-fifo  mknod p $D/kfifo
    o $D mknod-chr   mknod c $D/kchr 1 3
    o $D bind-socket bind $D/ksock
    o $D symlink     symlink /tmp $D/ksym
    o $D link-within link $D/kv $D/klink
    n=$((n+1)); o $D link-out link $D/kv /tmp/klo$n
    src; o $D link-in   link $S $D/klin
    src; o $D rename-in rename $S $D/krin
    n=$((n+1)); o $D rename-file-out rename $D/kv /tmp/kro$n
    [ -e /tmp/kro$n ] && $L rename /tmp/kro$n $D/kv >/dev/null 2>&1
    n=$((n+1)); o $D rename-dir-out rename $D/kd /tmp/kdo$n
    [ -e /tmp/kdo$n ] && $L rename /tmp/kdo$n $D/kd >/dev/null 2>&1
    src; o $D exchange exch $S $D/kv
    [ -e $D/kv ] || true
    o $D chmod       chmod 777 $D/kv
    o $D chown       chown 65534 65534 $D/kv
    o $D utimes      utime $D/kv
    o $D setxattr    setxattr $D/kv
    o $D ftruncate   ftrunc $D/kv
    o $D truncate    trunc $D/kv
    o $D unlink      unlink $D/kv
    o $D rmdir       rmdir $D/kd
}

prep() { # make kv and kd in a directory that is filled at run time
    printf '%s\tprep-copy\t%s\n' "$1" "$($L copy /bb/lp $1/kv 2>&1)"
    $L chmod 777 $1/kv >/dev/null 2>&1; $L mkdir $1/kd >/dev/null 2>&1
}

# --- top-level directories of the image, and directories below them
for d in /bb /bin /sbin /usr /usr/bin /usr/local/bin /etc /home /root /run /var /var/tmp /tmp /app /app/bin /app/data /w /opt /srv; do dirops $d; done

# --- mounts: named volumes (prepared by matrix.sh), tmpfs, nested ones
for d in /vol /usr/nested /app/nested /w/nested; do dirops $d; done
for d in /tfs /tfsnoexec /dev/shm; do prep $d; dirops $d; done

# --- a directory created after init started
o /tmp/knew mkdir-after-init mkdir /tmp/knew; prep /tmp/knew; dirops /tmp/knew

# --- the root directory itself
o / list open d /
o / create open c /kn
o / mkdir mkdir /knd
o / symlink symlink /tmp /ksym
o / mknod-fifo mknod p /kfifo
src; o / rename-in rename $S /krin
src; o / link-in link $S /klin
o / rename-toplevel-dir rename /srv /srv2
[ -e /srv2 ] && $L rename /srv2 /srv >/dev/null 2>&1
o / rmdir-toplevel-dir rmdir /emptytop
o / exchange-toplevel exch /opt /srv
[ -e /opt/kv ] || $L exch /opt /srv >/dev/null 2>&1

# --- single files at the top level: image file, fifo, Docker's file, a file mount, a symlink
for f in /topfile /topmnt /.dockerenv; do
    o $f read read $f
    o $f open-write open w $f
    o $f open-append open a $f
    o $f exec exec $f
    o $f chmod chmod 666 $f
    n=$((n+1)); o $f link-out link $f /tmp/ktl$n
    n=$((n+1)); o $f rename-out rename $f /tmp/ktr$n
    o $f truncate trunc $f
    o $f unlink unlink $f
done
o /topfifo open-rw open rw /topfifo
o /topfifo unlink unlink /topfifo
o /lnk list-through open d /lnk/bin
o /lnk exec-through exec /lnk/bin/lp
o /lnk create-through open c /lnk/data/kn2
o /lnk unlink unlink /lnk

# --- /dev: the directory, then each node
o /dev list open d /dev
o /dev create open c /dev/kn
o /dev mkdir mkdir /dev/knd
o /dev mknod-chr mknod c /dev/kchr 1 3
o /dev mknod-fifo mknod p /dev/kfifo
o /dev symlink symlink /dev/null /dev/ksym
o /dev rename-node rename /dev/full /dev/full2
[ -e /dev/full2 ] && $L rename /dev/full2 /dev/full >/dev/null 2>&1
o /dev chmod-null chmod 666 /dev/null
# Character devices that are harmless to open and close. hvc*, vport*, vsock,
# vhost-vsock (hypervisor) and block devices are deliberately not here.
for f in null zero full random urandom tty console ptmx pts/ptmx stdin stdout stderr fd/1 core \
         fuse kmsg net/tun rtc0 loop-control mapper/control uinput vhost-net; do
    f=/dev/$f
    [ -e $f ] || [ -L $f ] || { printf '%s\tpresent\tno\n' $f; continue; }
    o $f open-read open r $f
    o $f open-write open w $f
    o $f open-rdwr open rw $f
    o $f open-mode3 open 3 $f
    o $f ioctl-TCGETS-rdonly ioctl r $f 5401
    o $f ioctl-TCGETS-mode3 ioctl 3 $f 5401
done
o /dev/pts list open d /dev/pts
o /dev/pts create open c /dev/pts/kn
o /dev/pts mkdir mkdir /dev/pts/knd
o /dev/mqueue list open d /dev/mqueue
o /dev/mqueue create open c /dev/mqueue/kn
o /dev/mqueue mq_open-create mq /kq
o /dev/mqueue mkdir mkdir /dev/mqueue/knd

# --- /proc and /sys: read, and open for appending (never a write)
o /proc read read /proc/self/status
o /proc list open d /proc/self/fd
for f in /proc/self/oom_score_adj /proc/self/attr/current /proc/self/comm /proc/sys/kernel/hostname /proc/sys/kernel/core_pattern /proc/sysrq-trigger; do
    o $f read read $f
    o $f open-append open a $f
done
o /proc/self/mem open-rdwr open rw /proc/self/mem
o /proc/1/mem open-rdwr open rw /proc/1/mem
o /proc/1/environ read read /proc/1/environ
o /proc/1/root list-tmp open d /proc/1/root/tmp
o /proc/1/root exec-tmp-copy exec /proc/1/root/tmp/ks1
o /proc/1/root exec-bb exec /proc/1/root/bb/lp
o /proc/self/root exec-tmp-copy exec /proc/self/root/tmp/ks1
o /proc/self/cwd exec-bb exec /proc/self/cwd/bb/lp
o /proc/self/exe exec exec /proc/self/exe
for f in /sys/fs/cgroup/cgroup.procs /sys/kernel/uevent_helper /sys/kernel/mm/transparent_hugepage/enabled /sys/class/net/lo/mtu; do
    o $f read read $f
    o $f open-append open a $f
done
o /sys list open d /sys/kernel

# --- programs without a path, and interpreters
o memfd memfd_create memfd
o /tmp tmpfile-exec tmpfileexec /tmp /bb/lp
o /dev/shm tmpfile-exec tmpfileexec /dev/shm /bb/lp
o /tfs tmpfile-exec tmpfileexec /tfs /bb/lp
o /w/script exec-script-in-writable-dir exec /w/script
o /w/viabb exec-script-with-program-dir-interpreter exec /w/viabb
o /app/bin/viaw exec-script-whose-interpreter-is-in-writable-dir exec /app/bin/viaw
o /w/hardlp exec-hardlink-of-program exec /w/hardlp
o /w/hardlp open-write-hardlink-of-program open w /w/hardlp
o /w/applink exec-through-symlink-to-program-dir exec /w/applink/lp
o /app/wlink exec-through-symlink-from-program-dir exec /app/wlink/lp
