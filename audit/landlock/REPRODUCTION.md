# Independent reproduction, track "landlock"

Image: `kcos-audit-vlandlock-img`, built from `audit/landlock/helper/` (the
auditor's `kcos-audit-landlock-img` was gone) and removed afterwards.
Landlock ABI seen in the container: 8.

```sh
r() { timeout 120 docker run --rm --platform linux/arm64 "$@"; }
IMG=kcos-audit-vlandlock-img
```

## F1: reproduced, severity high

A device that is not in the allowlist opens under init with access mode 3
and answers ioctls.

Under init, `--device /dev/rtc0`, as nobody, no `KCOS_DEV`:

```
$ r --device /dev/rtc0 -u 65534:65534 $IMG /bb/busybox sh -c 'ls -l /dev/rtc0; for m in r w rw 3; do echo "open $m: $(/bb/lp open $m /dev/rtc0)"; done; echo "ioctl mode3 RTC_RD_TIME: $(/bb/lp ioctl 3 /dev/rtc0 80247009)"'
crw-rw-rw- 0 0 0 /dev/rtc0
open r: EACCES
open w: EACCES
open rw: EACCES
open 3: ok
ioctl mode3 RTC_RD_TIME: ioctl:ok ret=0 val=0x1b00000031
```

Control, same container without init (`--entrypoint /bb/busybox`):

```
open r: ok
open 3: ok
ioctl mode3: ioctl:ok ret=0 val=0x1b00000031
```

Under init, `--privileged`, as nobody:

```
/dev/net/tun r=EACCES w=EACCES rw=EACCES 3=ok
/dev/rtc0 r=EACCES w=EACCES rw=EACCES 3=ok
TUNGETFEATURES ioctl:ok ret=0 val=0x7173
```

Under init, `--privileged`, as root (CapPrm/CapEff/CapBnd all zero):

```
/dev/net/tun r=EACCES 3=ok
/dev/rtc0 r=EACCES 3=ok
RTC ioctl:ok ret=0 val=0x1b00000032
```

Cause: `src/lock.rs` handles `FS_EXECUTE | FS_REFER | read | write` only.
There is no `LANDLOCK_ACCESS_FS_IOCTL_DEV` (ABI 5), and an open with access
mode 3 asks Landlock for neither read nor write.

Documentation: README line 49 says "Only the standard devices can be
opened", and the Security table says "Nothing else, for reading or for
writing, whatever the device's permissions say". Neither mentions mode 3 or
ioctl, and `test/suite.sh` has no check for it. The claim is false as
written.

Bounds: the open still needs both r and w file permission on the node, and
the process holds no capabilities, so ioctls that check a capability fail.
Only harmless read-only ioctls on rtc and tun were issued. No block device
was opened.

## F2: reproduced, severity info

The mechanism is real, but it cannot be reached through `docker run`.

With a wrapper that lowers the limit and then execs init as PID 1:

```
$ r -u 0 --entrypoint /bb/busybox $IMG sh -c "cp /bb/lp /tmp/c; ulimit -n 3; exec /sbin/init -- /tmp/c abi"; echo rc=$?
kcontaineros: warning: Landlock is unavailable, so programs can be run from any path
8
rc=0
$ ... ulimit -n 64 ...
kcontaineros: /tmp/c: permission denied
rc=126
```

The same holds as uid 65534 and with only the soft limit lowered
(`ulimit -S -n 3`). A write into a program directory also goes through:

```
$ r -u 0 --entrypoint /bb/busybox $IMG sh -c "ulimit -n 3; exec /sbin/init -- /bb/lp mkdir /bb/newdir"
kcontaineros: warning: Landlock is unavailable, so programs can be run from any path
ok
$ ... ulimit -n 64 ...
EACCES
```

The seccomp filter stays on in both cases (`/bb/lp memfd` gives EPERM).

Only the limit of exactly 3 fails open (`landlock_create_ruleset` gets
EMFILE). At 4 and 5 the ruleset exists but no rule can be added, and init
fails closed:

```
kcontaineros: warning: KCOS_EXEC: /bb is not a directory (symbolic links are not followed): ignored
kcontaineros: /bb/busybox: permission denied     (rc=126)
```

Reachability: `docker run --ulimit nofile=N:N` with N = 3, 4, 5, 6, 7, 8,
10 and 16 never starts the container (runc: "too many open files" or
"procReady not received"), on the audit image, `kcontaineros` and
`kcontaineros:sealed`. The state needs a custom entrypoint that lowers the
limit before exec'ing init, which is a choice of the image author, not of
code running under the lockdown.

Documentation: the README documents the warning and the fail-open only for
"kernels without Landlock". The warning text "Landlock is unavailable" is
inaccurate here, and the result is loud but not fail-closed. This is a
message and documentation precision issue, not a hole an attacker inside
can open.
