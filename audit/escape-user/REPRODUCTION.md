# Independent reproduction of the escape-user findings

Images: `kcontaineros`, `kcontaineros:sealed`, `kcos-audit-escape-user-img`,
`kcos-audit-escape-user-third` (the auditor's, still present). Every container
was run with `--rm --name kcos-audit-vescape-user-*`; none is left.

## F1: reproduced, medium

README, Use section: "a trailing slash, `.` or `..` components and anything
reached through a symbolic link are ignored, with a warning. The top-level
directory of an ignored entry is not writable all the same."

```
$ for e in /tmp/ /tmp/. /tmp/../tmp //tmp /tmp /tmp/sub ''; do
    docker run --rm --platform linux/arm64 -u 65534:65534 -e "KCOS_EXEC=$e" \
      kcos-audit-escape-user-img /bin/sh -c 'echo x > /tmp/f; echo "write-to-/tmp=$?"'; done
== KCOS_EXEC=/tmp/        warning: ... /tmp/ is not a plain absolute path: ignored        write-to-/tmp=0
== KCOS_EXEC=/tmp/.       warning: ... /tmp/. is not a plain absolute path: ignored       write-to-/tmp=0
== KCOS_EXEC=/tmp/../tmp  warning: ... /tmp/../tmp is not a plain absolute path: ignored  write-to-/tmp=0
== KCOS_EXEC=//tmp        warning: ... //tmp is not a plain absolute path: ignored        write-to-/tmp=0
== KCOS_EXEC=/tmp         sh: /tmp/f: permission denied                                   write-to-/tmp=1
== KCOS_EXEC=/tmp/sub     warning: ... /tmp/sub is not a directory (...): ignored         write-to-/tmp=1
== KCOS_EXEC=             write-to-/tmp=0
```

Stock image, the operator typo:

```
$ docker run --rm --tmpfs /data:mode=1777 -e KCOS_EXEC=/data/bin/ kcontaineros sh -c 'echo x > /data/f; echo w=$?'
kcontaineros: warning: KCOS_EXEC: /data/bin/ is not a plain absolute path: ignored
w=0
$ docker run --rm --tmpfs /data:mode=1777 -e KCOS_EXEC=/data/bin kcontaineros sh -c 'echo x > /data/f; echo w=$?'
kcontaineros: warning: KCOS_EXEC: /data/bin is not a directory (symbolic links are not followed): ignored
sh: /data/f: permission denied
w=1
```

Control without init (`--entrypoint /bb/busybox`, `KCOS_EXEC=/tmp`): `w=0`, so
the refusal in the valid case is init's.

No execution follows from it:

```
$ docker run --rm -e KCOS_EXEC=/tmp/ kcontaineros sh -c 'cp /bin/kcontaineros /tmp/sh; echo cp=$?; chmod 755 /tmp/sh; /tmp/sh -c "echo ran"; echo exec=$?'
cp=0
sh: /tmp/sh: permission denied
exec=126
```

Cause as reported: `src/lock.rs` computes `holds_programs` from
`absolute_dirs(extra)`, which has already dropped these entries. The README
sentence is true only for entries refused later (not a directory, symlink).
The suite has no check for the top-level directory of a "not a plain absolute
path" entry. Run-or-write still holds; the false statement is the README's.

## F2: reproduced_but_documented, info

```
KCOS_EXEC=x\x1b[31mPWN\x07\x7f  kcontaineros true        (stderr a pipe)
  b'kcontaineros: warning: KCOS_EXEC: x\x1b[31mPWN\x07\x7f is not a plain absolute path: ignored\n'
E=\x1b[31mPWN\x07\x7f  kcontaineros sh -c 'nosuch"$E"'
  b'sh: nosuch\x1b[31mPWN\x07\x7f: not found\n'
E=...  kcontaineros sh -c 'cat "/nosuch$E"'
  b'cat: /nosuch\x1b[31mPWN\x07\x7f: no such file or directory\n'
kcontaineros:sealed, same KCOS_EXEC: same raw warning
with -t (test/term.py -- docker run -t ...):
  kcontaineros: warning: KCOS_EXEC: x?[31mPWN?? is not a plain absolute path: ignored
```

It happens, and it is what both documents say. README: "`ps` always, and `ls`
and `pwd` on a terminal, replace everything but printable ASCII in names with
`?`. So does every error message that goes to a terminal". AGENTS.md: "shown
through `Out::safe` or `eprint`, which replace everything but printable ASCII
when the output is a terminal". Without `-t` the descriptor is a pipe, and
byte-exact output on a pipe is what `ls` does everywhere. No ability is
gained: whoever sets the image's ENV or the arguments also chooses the command,
which can write any bytes to the same pipe (`echo -e '\033[31m'`). A sentence
in the README that without `-t` Docker relays the pipe to the caller's terminal
unfiltered would be a kindness, not a correction.

## F3: reproduced, info

```
$ docker run --rm --platform linux/arm64 kcos-audit-escape-user-third busybox sh -c '...'
uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)
65534 755 1795339185                 (stat -c "%u %a %Y" /app/bin/kp)
chmod=0                              (chmod 0500)
touch=0                              (touch -d "2001-01-01 00:00:00")
65534 500 978307200
sh: line 0: can't create /app/bin/kp: Permission denied
append=1                             (echo x >> /app/bin/kp)
suid=0  4755                         (chmod 4755; file is nobody's, no_new_privs set)
chmod: /bin/sh: Operation not permitted
chmod-rootowned=1
```

The README limit reads "Root can still change the permissions and timestamps of
files it owns, in program directories too. It cannot change what is in them."
The same holds for any owner, and only arises when the image builder chowns
program files to the run-time user (`COPY --chown=65534`); in the stock image
they are root's and nobody is refused. Contents stay immutable, a setuid bit
on a file owned by nobody gives nothing. A wording gap ("root" should be "the
owner"), not a false security claim.
