#!/bin/sh
# Focused confirmation of the two findings, each with its control. Repo root, after build.sh.
IMG=kcos-audit-landlock-img
L=/bb/lp
r() { timeout 120 docker run --rm --platform linux/arm64 "$@"; }

echo "=== F1: a non-standard device opened under init with access mode 3, then ioctl ==="
echo "Landlock ABI seen by init:"; r $IMG /bb/busybox sh -c "$L abi"
echo
echo "[F1a] --privileged, as nobody, UNDER INIT. open modes r/w/rw must fail (README), mode 3 + ioctl:"
r --privileged -u 65534:65534 $IMG /bb/busybox sh -c '
  echo "  /dev/net/tun   r=$('$L' open r /dev/net/tun) w=$('$L' open w /dev/net/tun) mode3=$('$L' open 3 /dev/net/tun) TUNGETFEATURES=$('$L' ioctl 3 /dev/net/tun 800454cf)"
  echo "  /dev/rtc0      r=$('$L' open r /dev/rtc0) mode3=$('$L' open 3 /dev/rtc0) RTC_RD_TIME=$('$L' ioctl 3 /dev/rtc0 80247009)"
  echo "  /dev/uinput    r=$('$L' open r /dev/uinput) mode3=$('$L' open 3 /dev/uinput) UI_GET_VERSION=$('$L' ioctl 3 /dev/uinput 8004552d)"'
echo "[F1b] not privileged, device passed with --device, NOT in KCOS_DEV, as nobody, UNDER INIT:"
r --device /dev/rtc0 -u 65534:65534 $IMG /bb/busybox sh -c '
  echo "  /dev/rtc0  r=$('$L' open r /dev/rtc0) mode3=$('$L' open 3 /dev/rtc0) RTC_RD_TIME=$('$L' ioctl 3 /dev/rtc0 80247009)"'
echo "[F1 control] without init (char devices only) the device opens every way, as expected:"
r --device /dev/rtc0 -u 65534:65534 --entrypoint /bb/busybox $IMG sh -c '
  echo "  /dev/rtc0  r=$('$L' open r /dev/rtc0) mode3=$('$L' open 3 /dev/rtc0) RTC_RD_TIME=$('$L' ioctl 3 /dev/rtc0 80247009)"'
echo
echo "=== F2: Landlock confinement fails open (warning only) when it cannot build the ruleset ==="
echo "init's own message and whether the run-or-write rule still holds, at a few RLIMIT_NOFILE values:"
for lim in 3 6 64; do
  printf '  ulimit -n %s -> ' $lim
  r --entrypoint /bb/busybox -e KCOS_EXEC=/bb $IMG sh -c "ulimit -n $lim 2>/dev/null; exec /sbin/init -- /bb/busybox sh -c '
    w=\$('$L' exec /tmp/c 2>/dev/null; '$L' copy /bb/lp /tmp/c >/dev/null 2>&1; '$L' chmod 755 /tmp/c >/dev/null 2>&1; '$L' exec /tmp/c)
    echo \"exec of a /tmp copy = \$w\"'" 2>&1 | /usr/bin/tr '\n' '|'
  echo
done
