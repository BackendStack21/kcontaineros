#!/bin/bash
# Follow-ups on what the first three scripts turned up. Run from the repo
# root after build.sh.
. "$(dirname "$0")/lib.sh"
asuser() { timeout 120 docker run --rm $PLAT $PRIV --user 1000:1000 "$IMG" "$@" 2>&1; }

section "host kernel files readable only by root: content under init as root"
READS='for f in /proc/slabinfo /proc/vmallocinfo /proc/timer_list /proc/kallsyms /proc/iomem /proc/keys /proc/kpagecount /proc/kpageflags /proc/self/pagemap /proc/config.gz /sys/firmware/devicetree/base/chosen/bootargs; do printf "%s (%s): " $f "$(/bb/busybox stat -c "%a %U" $f)"; /bb/busybox head -c 4096 $f 2>&1 | /bb/busybox tr -c "[:print:]\n" "." | /bb/busybox sed -n "3p" | /bb/busybox cut -c1-90; echo; done; /bb/busybox wc -l /proc/slabinfo /proc/vmallocinfo /proc/timer_list 2>&1; /bb/busybox grep -c -v "^0000000000000000" /proc/kallsyms; /bb/busybox od -An -tx8 -N16 /proc/kpagecount; /bb/busybox od -An -tx8 -N16 /proc/kpageflags; /bb/busybox od -An -tx8 -N8 -j 32768 /proc/self/pagemap'
init $BB sh -c "$READS"
section "the same as uid 1000 under init (what an ordinary user gets)"
asuser $BB sh -c "$READS"
section "the same in a container that is not privileged, as root, without init (Docker's own masking)"
timeout 120 docker run --rm $PLAT --entrypoint $BB "$IMG" sh -c "$READS" 2>&1

section "PID 1: what can be read of it under init"
init $BB sh -c "$BB cat /proc/1/stack; $BB cat /proc/1/syscall; $BB cat /proc/1/io | $BB head -2; $BB cat /proc/1/stat; $BB ls -l /proc/1/fd; $BB cat /proc/1/personality; $BB cat /proc/1/wchan; echo; $BB cat /proc/1/environ | $BB wc -c"

section "kernel files reached under another name: under init (append-open, nothing written)"
init /aud/esc wr /proc/self/root/proc/sys/kernel/hostname /proc/thread-self/root/sys/fs/cgroup/cgroup.procs /proc/self/cwd/proc/sysrq-trigger /dev/fd/../../sys/kernel/hostname /proc/self/task/1/../../../sys/vm/drop_caches
section "creating a cgroup (mkdir in /sys/fs/cgroup): under init only, removed at once if it ever succeeds"
init $BB sh -c "$BB mkdir /sys/fs/cgroup/kcos-audit-x && { echo CREATED; $BB rmdir /sys/fs/cgroup/kcos-audit-x; }; echo exit \$?"

section "extended attributes on the image's own program, after root gives itself write permission"
init $BB sh -c "/aud/esc writes /bin /bin/kcontaineros | $BB grep xattr; $BB chmod u+w /bin/kcontaineros && $BB ls -l /bin/kcontaineros; /aud/esc writes /bin /bin/kcontaineros | $BB grep -E 'xattr|O_WRONLY'; $BB setfattr -n user.kcos -v planted /bin/kcontaineros; echo setfattr exit \$?; $BB getfattr -n user.kcos /bin/kcontaineros 2>&1; $BB chmod 555 /bin/kcontaineros"
section "image files outside the program directories, as root under init"
init $BB sh -c "echo x >> /etc/passwd; echo \"append to /etc/passwd (mode 444, directory 555): \$?\"; $BB chmod 644 /etc/passwd; echo x >> /etc/passwd; echo \"after chmod 644: \$?\"; $BB tail -1 /etc/passwd; $BB chmod 755 /etc; $BB touch /etc/kcos-new; echo \"create /etc/kcos-new after chmod 755 /etc: \$?\"; echo > /.dockerenv; echo \"write /.dockerenv: \$?\""

section "POSIX message queues under init"
echo "-- privileged root:";            init /aud/esc ipc | grep mq_open
echo "-- default options, root:";      timeout 120 docker run --rm $PLAT "$IMG" /aud/esc ipc 2>&1 | grep mq_open
echo "-- default options, uid 65534:"; timeout 120 docker run --rm $PLAT --user 65534:65534 "$IMG" /aud/esc ipc 2>&1 | grep mq_open
echo "-- control, default options, uid 65534:"; timeout 120 docker run --rm $PLAT --user 65534:65534 --entrypoint /aud/esc "$IMG" ipc 2>&1 | grep mq_open

section "with a terminal (-t): which devices open, under init"
timeout 120 docker run --rm -t $PLAT $PRIV "$IMG" $BB sh -c "/aud/esc scandev | $BB grep -vE 'null|zero|full|random'; $BB ls -l /dev/console /dev/pts/" 2>&1 | tr -d '\r'
