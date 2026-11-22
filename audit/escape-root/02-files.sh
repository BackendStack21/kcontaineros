#!/bin/bash
# Run-or-write, the program directories, /proc, /sys and /dev as root under
# init in a privileged container, each with its control without init.
# Run from the repo root after build.sh.
. "$(dirname "$0")/lib.sh"

section "starting a program brought along: under init"
init /aud/esc exec /aud/esc /tmp /dev/shm /var/tmp /etc /run
section "starting a program brought along: control"
ctl /aud/esc exec /aud/esc /tmp /dev/shm
section "program loader and script interpreter in a writable directory: under init"
init $BB sh -c "$BB cp /aud/esc /tmp/kcos-ld; $BB cp /aud/esc /tmp/kcos-interp; $BB chmod 755 /tmp/kcos-ld /tmp/kcos-interp; /aud/interp-in-tmp hello; echo \"PT_INTERP=/tmp/kcos-ld: exit \$?\"; /aud/shebang-in-tmp hello; echo \"#!/tmp/kcos-interp: exit \$?\""
section "program loader and script interpreter in a writable directory: control"
ctl $BB sh -c "$BB cp /aud/esc /tmp/kcos-ld; $BB cp /aud/esc /tmp/kcos-interp; $BB chmod 755 /tmp/kcos-ld /tmp/kcos-interp; /aud/interp-in-tmp hello; echo \"PT_INTERP=/tmp/kcos-ld: exit \$?\"; /aud/shebang-in-tmp hello; echo \"#!/tmp/kcos-interp: exit \$?\""

for pair in "/aud /aud/interp-in-tmp" "/bin /bin/kcontaineros" "/usr/bin /usr/bin/env" "/bb /bb/busybox"; do
    section "changing a program directory ($pair): under init"
    init /aud/esc writes $pair
done
section "changing a program directory (/aud): control"
ctl /aud/esc writes /aud /aud/shebang-in-tmp

section "every regular file of /proc and /sys opened for append: under init (nothing is written)"
init /aud/esc scanw /proc | tail -5
init /aud/esc scanw /sys | tail -5
section "a sample of the same files: control (opened for append and closed, nothing is written)"
SAMPLE="/proc/sys/kernel/hostname /proc/sys/kernel/core_pattern /proc/sys/vm/drop_caches /proc/sysrq-trigger /proc/self/oom_score_adj /proc/self/mem /proc/self/attr/current /proc/self/uid_map /proc/1/mem /sys/kernel/uevent_helper /sys/fs/cgroup/cgroup.procs /sys/fs/cgroup/cgroup.subtree_control /sys/power/state /sys/kernel/mm/ksm/run /sys/module/printk/parameters/time"
init /aud/esc wr $SAMPLE
echo "-- control"
ctl /aud/esc wr $SAMPLE

section "every node under /dev opened for read and for append: under init"
init /aud/esc scandev
section "/dev: control (listing only; no host device is opened without init)"
ctl $BB sh -c "$BB find /dev ! -type d ! -type l | $BB wc -l; $BB ls -l /dev/mem /dev/kmsg /dev/vda /dev/vsock /dev/fuse /dev/tty /dev/null 2>&1"
echo "-- control: /dev/kmsg and /dev/fuse (character devices, harmless to open) opened read-only"
ctl /aud/esc rd /dev/kmsg /dev/fuse /dev/null
echo "-- the same two under init"
init /aud/esc rd /dev/kmsg /dev/fuse /dev/null

section "core dump into a program directory (core_pattern is a relative file name on this host)"
init $BB cat /proc/sys/kernel/core_pattern
init /aud/esc core /aud
init /aud/esc core /tmp
echo "-- control"
ctl /aud/esc core /aud

section "kernel files only root may read (opened read-only, not read): under init, then control"
RO="/proc/kcore /proc/kmsg /proc/kallsyms /proc/slabinfo /proc/vmallocinfo /proc/kpagecount /proc/kpageflags /proc/keys /proc/timer_list /proc/sched_debug /proc/iomem /proc/1/environ /sys/kernel/notes /sys/firmware/devicetree/base/chosen/bootargs /sys/kernel/debug/sleep_time /sys/kernel/tracing/trace /sys/kernel/security/lsm /sys/fs/bpf /proc/config.gz /proc/self/pagemap /proc/sys/kernel/random/boot_id"
init /aud/esc rd $RO
echo "-- control"
ctl /aud/esc rd $RO
