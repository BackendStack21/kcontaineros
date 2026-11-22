#!/bin/sh
# Devices: the allowlist, access mode 3, ioctl, other names, KCOS_DEV, and the
# read-confinement switch. Run from the repo root after build.sh.
# Everything that touches a device not in the standard list runs UNDER INIT;
# the controls only use character devices that are harmless to open.
IMG=kcos-audit-landlock-img
L=/bb/lp
r()  { timeout 120 docker run --rm --platform linux/arm64 "$@"; }
sh_() { /bin/echo "$@"; }

echo "== D0. Landlock ABI of this kernel, as seen under init"
r $IMG /bb/busybox sh -c "uname -r; $L abi"

echo "== D1. --privileged, under init: every character device, opened with access mode 3 (O_NONBLOCK|O_NOCTTY), then closed"
echo "   (skipped: hvc*, vport*, vsock, vhost-vsock, sailor-uds, watchdog*, cpu_dma_latency; block devices are not swept)"
for u in 0:0 65534:65534; do
r --privileged -u $u $IMG /bb/busybox sh -c '
  ok=0; no=0; oklist=; nolist=
  for f in $(/bb/busybox find /dev -type c); do
    case $f in /dev/hvc*|/dev/vport*|/dev/vsock|/dev/vhost-vsock|/dev/sailor-uds|/dev/watchdog*|/dev/cpu_dma_latency) continue;; esac
    case $f in /dev/null|/dev/zero|/dev/full|/dev/random|/dev/urandom|/dev/tty|/dev/console|/dev/ptmx|/dev/pts/*) continue;; esac
    res=$('$L' sweep $f)
    if [ "$res" = ok ]; then ok=$((ok+1)); oklist="$oklist ${f#/dev/}"; else no=$((no+1)); nolist="$nolist ${f#/dev/}=$res"; fi
  done
  echo "uid $(/bb/busybox id -u): non-standard character devices opened: $ok, refused: $no"
  echo "  opened:$oklist"; echo "  refused:$nolist"'
done

echo "== D2. --privileged, under init: the same devices opened for reading and for writing (must be refused: this is the README's claim and it holds)"
r --privileged -u 0:0 $IMG /bb/busybox sh -c '
  for f in fuse net/tun rtc0 loop-control uinput mapper/control vhost-net kmsg mem ttyS0 tty0 hwrng; do
    echo "/dev/$f read=$('$L' open r /dev/$f) write=$('$L' open w /dev/$f) rdwr=$('$L' open rw /dev/$f) mode3=$('$L' sweep /dev/$f)"; done'

echo "== D3. --privileged, under init: ioctl on descriptors obtained with mode 3 (read-only queries)"
for u in 0:0 65534:65534; do
r --privileged -u $u $IMG /bb/busybox sh -c '
  echo "uid $(/bb/busybox id -u)"
  echo "  /dev/rtc0     RTC_RD_TIME      $('$L' ioctl 3 /dev/rtc0 80247009)"
  echo "  /dev/net/tun  TUNGETFEATURES   $('$L' ioctl 3 /dev/net/tun 800454cf)"
  echo "  /dev/uinput   UI_GET_VERSION   $('$L' ioctl 3 /dev/uinput 8004552d)"
  echo "  /dev/ttyS0    TCGETS           $('$L' ioctl 3 /dev/ttyS0 5401)"
  echo "  /dev/tty0     KDGETMODE        $('$L' ioctl 3 /dev/tty0 4b3b)"
  echo "  /dev/ram0     BLKGETSIZE64     $('$L' ioctl 3 /dev/ram0 80081272)   (block: a RAM disk)"
  echo "  /dev/vda      BLKGETSIZE64     $('$L' ioctl 3 /dev/vda 80081272)   (block: the disk of the Docker VM)"
  echo "  /dev/vda      open r / w / rw  $('$L' open r /dev/vda) $('$L' open w /dev/vda) $('$L' open rw /dev/vda)"'
done
echo "-- control for D3 without init (character devices only):"
r --privileged -u 0:0 --entrypoint /bb/busybox $IMG sh -c '
  echo "  /dev/rtc0     RTC_RD_TIME      $('$L' ioctl 3 /dev/rtc0 80247009)"
  echo "  /dev/net/tun  TUNGETFEATURES   $('$L' ioctl 3 /dev/net/tun 800454cf)"'

echo "== D4. not privileged: a device passed with --device and NOT named in KCOS_DEV"
for u in 0:0 65534:65534; do
r --device /dev/rtc0 --device /dev/fuse -u $u $IMG /bb/busybox sh -c '
  echo "uid $(/bb/busybox id -u): rtc0 read=$('$L' open r /dev/rtc0) write=$('$L' open w /dev/rtc0) mode3=$('$L' open 3 /dev/rtc0) RTC_RD_TIME-via-mode3=$('$L' ioctl 3 /dev/rtc0 80247009)"
  echo "         fuse read=$('$L' open r /dev/fuse) write=$('$L' open w /dev/fuse) rdwr=$('$L' open rw /dev/fuse) mode3=$('$L' open 3 /dev/fuse)"'
done
echo "-- the same, named: KCOS_DEV=/dev/rtc0:/dev/fuse"
r --device /dev/rtc0 --device /dev/fuse -e KCOS_DEV=/dev/rtc0:/dev/fuse -u 0:0 $IMG /bb/busybox sh -c '
  echo "rtc0 read=$('$L' open r /dev/rtc0) fuse rdwr=$('$L' open rw /dev/fuse)"'

echo "== D5. devices under other names (under init, root, not privileged)"
echo "-- D5a. O_PATH descriptor of an unnamed device, reopened through /proc/self/fd"
r --device /dev/rtc0 -u 0:0 $IMG /bb/busybox sh -c 'echo "reopen r=$('$L' reopen r /dev/rtc0) w=$('$L' reopen w /dev/rtc0) mode3=$('$L' reopen 3 /dev/rtc0)"'
echo "-- D5b. mknod of a new node for the same device (root has no CAP_MKNOD)"
r --device /dev/rtc0 -u 0:0 $IMG /bb/busybox sh -c 'echo "/tmp=$('$L' mknod c /tmp/n 1 3) /dev/shm=$('$L' mknod c /dev/shm/n 1 3) /dev=$('$L' mknod c /dev/n 1 3)"'
echo "-- D5c. /sys/dev/char/MAJ:MIN is a link into sysfs, not a device node"
r -u 0:0 $IMG /bb/busybox sh -c 'echo "/sys/dev/char/1:3 -> $('$L' stat /sys/dev/char/1:3); dev attribute open-append=$('$L' open a /sys/dev/char/1:3/dev)"'
echo "-- D5d. a device mapped to a path inside /dev that carries a standard name or lies in an allowed directory"
for dst in /dev/shm/a /dev/pts/a /dev/mqueue/a /dev/core /dev/fd /dev/sub/a; do
  printf '%s: ' "--device /dev/rtc0:$dst"
  r --device /dev/rtc0:$dst -u 0:0 $IMG /bb/busybox sh -c 'echo "stat=$('$L' stat '$dst') read=$('$L' open r '$dst') write=$('$L' open w '$dst') RTC_RD_TIME-rdonly=$('$L' ioctl r '$dst' 80247009)"' 2>&1 | /usr/bin/tail -1
done

echo "== D6. the read-confinement switch"
echo "-- D6a. baseline: one unnamed device => reads are confined; the device cannot be read"
r --device /dev/rtc0:/dev/x/a -u 0:0 $IMG /bb/busybox sh -c 'echo "read=$('$L' open r /dev/x/a) RTC_RD_TIME-rdonly=$('$L' ioctl r /dev/x/a 80247009)"'
echo "-- D6b. a second device in the same subdirectory is named: KCOS_DEV=/dev/x/b. /dev/x/a is still not named."
r --device /dev/rtc0:/dev/x/a --device /dev/fuse:/dev/x/b -e KCOS_DEV=/dev/x/b -u 0:0 $IMG /bb/busybox sh -c 'echo "a(unnamed): read=$('$L' open r /dev/x/a) write=$('$L' open w /dev/x/a) RTC_RD_TIME-rdonly=$('$L' ioctl r /dev/x/a 80247009);  b(named): rdwr=$('$L' open rw /dev/x/b)"'
r --device /dev/rtc0:/dev/x/a --device /dev/fuse:/dev/x/b -e KCOS_DEV=/dev/x/b -u 65534:65534 $IMG /bb/busybox sh -c 'echo "as nobody: a(unnamed): $('$L' stat /dev/x/a) read=$('$L' open r /dev/x/a)"'
echo "-- D6c. KCOS_DEV entries that init itself reports as ignored still switch read confinement off"
for v in /dev/rtc0/x /dev/rtc0/ /dev/rtc0/. ; do
  echo "KCOS_DEV=$v"
  r --device /dev/rtc0 -e KCOS_DEV=$v -u 0:0 $IMG /bb/busybox sh -c 'echo "   read=$('$L' open r /dev/rtc0) write=$('$L' open w /dev/rtc0) RTC_RD_TIME-rdonly=$('$L' ioctl r /dev/rtc0 80247009)"' 2>&1
done
echo "-- D6d. KCOS_DEV naming a directory grants everything in it"
r --device /dev/rtc0:/dev/x/a --device /dev/fuse:/dev/x/b -e KCOS_DEV=/dev/x -u 0:0 $IMG /bb/busybox sh -c 'echo "a: read=$('$L' open r /dev/x/a) write=$('$L' open w /dev/x/a)  b: rdwr=$('$L' open rw /dev/x/b)"' 2>&1
echo "-- D6e. odd KCOS_DEV values (symlink, outside /dev, .., empty, relative, repeated)"
for v in /dev/core /dev/stdin /dev/ptmx /tmp/x /dev/../tmp /dev/shm/../rtc0 ':' 'dev/rtc0' '/dev/rtc0:/dev/rtc0' '/dev//rtc0' '/dev' '/dev/'; do
  echo "KCOS_DEV=$v"
  r --device /dev/rtc0 -e "KCOS_DEV=$v" -u 0:0 $IMG /bb/busybox sh -c 'echo "   rtc0 read=$('$L' open r /dev/rtc0) write=$('$L' open w /dev/rtc0); /topfile read=$('$L' read /topfile); create /dev/kn=$('$L' open c /dev/kn)"' 2>&1
done
echo "-- D6f. what read confinement costs once it is on (--privileged): reads of ordinary places"
r --privileged -u 0:0 -v kcos-audit-landlock-dv:/vol --tmpfs /tfs $IMG /bb/busybox sh -c '
  '$L' copy /bb/lp /vol/f >/dev/null; '$L' copy /bb/lp /tfs/f >/dev/null; '$L' copy /bb/lp /dev/shm/f >/dev/null
  for f in /etc/passwd /topfile /topfifo /.dockerenv /vol/f /tfs/f /dev/shm/f /proc/self/status /sys/kernel/mm/transparent_hugepage/enabled /etc/hostname /dev/mqueue /dev/pts/ptmx /dev/core; do echo "   $f read-open=$('$L' open r $f)"; done'
timeout 60 docker volume rm -f kcos-audit-landlock-dv >/dev/null 2>&1

echo "== D7. POSIX message queues and the top-level FIFO (under init vs control, as nobody, not privileged)"
r $IMG /bb/busybox sh -c 'echo "init:    mq_open(O_CREAT)=$('$L' mq /q1) open rw /topfifo=$('$L' open rw /topfifo)"' 
r -u 65534:65534 --entrypoint /bb/busybox $IMG sh -c 'echo "control: mq_open(O_CREAT)=$('$L' mq /q1) open rw /topfifo=$('$L' open rw /topfifo)"'
r -u 65534:65534 --ipc none $IMG /bb/busybox sh -c 'echo "init, --ipc none: mq_open(O_CREAT)=$('$L' mq /q1)"'
