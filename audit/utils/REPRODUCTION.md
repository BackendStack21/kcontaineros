# Independent reproduction of the "utils" findings

Reviewer run of 2026-11-22 against `kcontaineros` 0.2.0 and `kcos-audit`.
The auditor's helper image was gone; `audit/utils/helper/h.c` was compiled
unchanged (rust:1-alpine, `gcc -static -O1`) into a reviewer image
`kcos-audit-vutils-img` (`FROM kcos-audit`, `COPY h /bb/h`), built outside
the repo and removed afterwards. Every container ran with `--rm`.

| ID | Verdict | Severity |
|----|---------|----------|
| UTILS-1 | reproduced | high |
| UTILS-2 | reproduced | low |
| UTILS-3 | reproduced | low |
| UTILS-4 | reproduced | low |
| UTILS-5 | reproduced | low |
| UTILS-6 | reproduced | low |
| UTILS-7 | reproduced | info |
| UTILS-8 | reproduced | info |
| UTILS-9 | reproduced_not_a_defect | info |

## UTILS-1 rm -r DIR/ follows a swapped-in symlink: reproduced, high

    docker run --rm -i --platform linux/arm64 --tmpfs /work:size=32m --pids-limit 512 --memory 512m \
      kcos-audit-vutils-img /bb/busybox sh -s k VARIANT 300 < audit/utils/in/race-rm.sh

    first loss in round 30: 0 of 16 victim files left, rm exit 1
    RESULT impl=k variant=slash rounds=300 rounds-with-victim-files-deleted=25 rm-exit-0=127
    first loss in round 17: 0 of 16 victim files left, rm exit 1
    RESULT impl=k variant=relslash rounds=300 rounds-with-victim-files-deleted=29 rm-exit-0=117
    RESULT impl=k variant=plain rounds=300 rounds-with-victim-files-deleted=0 rm-exit-0=223
    RESULT impl=k variant=nested rounds=300 rounds-with-victim-files-deleted=0 rm-exit-0=264
    (busybox rm, slash: 38 of 300)

Without a race the operand is refused, so the loss needs the swap:

    $ cd /work; mkdir v; echo p > v/f; ln -s v l; /bin/rm -rf l/
    rm: l/: not a directory        rc=1, v/f still there

The victim directory is reachable only through the symlink, the flipper is
killed before the count, and the two variants without a trailing slash lose
nothing in 600 rounds, which fits the mechanism described (src/applets.rs
`Rm::at`: `unlinkat` then `openat(..O_NOFOLLOW)` on the operand as typed;
the kernel follows a final symlink when the path ends in a slash). The
README sentence "a symlink swapped in during the walk cannot send it
elsewhere" has no exception for this. Not a lockdown matter (plain file
semantics), so no init/no-init control applies. busybox has the same race
but makes no such claim.

## UTILS-2 mkdir -p chmods a directory outside the operand: reproduced, low

The loop from `audit/utils/in/safety.sh` (lines 126-137) alone, 1500 rounds:

    round 322: mode of the directory outside the operand changed from 500 to 777
    /bin/mkdir -p flip, 1500 rounds: rounds in which a directory outside the operand was chmod-ed: 15
    /bb/busybox mkdir -p flip, 1500 rounds: rounds in which a directory outside the operand was chmod-ed: 0

777 is what the code computes for a parent made under umask 0300
(0477 | 0300), applied through the link. Needs a umask without owner
write/search and an attacker who can write where the parent is created.
README says nothing about it.

## UTILS-3 uname ignores arguments after the first: reproduced, low

    $ docker run --rm kcontaineros uname -s -n            -> Linux                    rc=0
    $ docker run --rm kcontaineros uname -a --bogus -Z    -> Linux 1b743694e881 7.0.14-linuxkit ... aarch64   rc=0
    $ docker run --rm kcontaineros uname --bogus          -> uname: invalid option: --bogus   rc=1
    $ busybox uname -s -n                                 -> Linux 3ecb67b42719       rc=0

README: "`--` ends options; an unknown option is an error." False for
anything after uname's first argument.

## UTILS-4 chmod MODE -- / chown OWNER -- exit 0: reproduced, low

    chmod 644 --      -> (nothing) rc=0
    chown 0 --        -> (nothing) rc=0
    chmod -- 644 --   -> (nothing) rc=0
    chmod 644         -> chmod: usage: chmod OCTAL FILE...        rc=1
    chown 0           -> chown: usage: chown UID[:GID] FILE...    rc=1
    busybox chmod 644 -- -> usage text, rc=1

## UTILS-5 ls and symlinks: reproduced, low

    $ docker run --rm kcontaineros sh -c 'cd /tmp && ln -s /root/x l && ls -l l; echo "rc=$?"; ls -l'
    ls: l: permission denied
    rc=1
    lrwxrwxrwx 65534 65534 7 l -> /root/x
    (busybox ls -l l as uid 65534: lrwxrwxrwx 1 nobody nobody 7 ... l -> /root/x, rc=0)

    $ docker run --rm kcos-audit ls -l /proc/1/fd; echo rc=$?
    lrwx------ 0 0 64 0 -> 
    l-wx------ 0 0 64 1 -> 
    l-wx------ 0 0 64 2 -> 
    rc=0
    (busybox under init: "ls: /proc/1/fd/0: cannot read link: Permission denied" for each)
    control, --entrypoint /bb/busybox: /bin/ls -l /proc/1/fd shows "0 -> /dev/null", "1 -> pipe:[...]", rc=0

The readlink refusal itself is the documented "PID 1 is opaque"; the defect
is that ls shows an empty target and exits 0.

## UTILS-6 env prints values raw on a terminal: reproduced, low

    $ python3 test/term.py -- docker run -it --rm -e "A=$(printf '\033]0;owned\007\033[31mred')" kcontaineros env | od -c
    ... A   = 033   ]   0   ;   o   w   n   e   d  \a 033   [   3   1   m   r   e   d  \n ...
    contrast, a file of that name through ls on the same terminal:
    ?   ]   0   ;   o   w   n   e   d   ?   ?   [   3   1   m   r   e   d

The README names ps, ls, pwd and error messages only, so no README claim is
false; it also does not say env is an exception. The rule broken is the one
in AGENTS.md ("Nothing untrusted reaches a terminal raw"). The environment
is normally set by whoever starts the container, which keeps this low.

## UTILS-7 rm -r SIGSEGV on 4096 levels with a small stack: reproduced, info

    /bb/h mkdeep /work/d 4096 x; ulimit -s N; /bin/rm -r /work/d; echo rc=$?; /bb/h depth /work/d x
    N=8192: rc=0, 0 levels left
    N=1024: rc=0, 0 levels left
    N=512:  Segmentation fault, rc=139, 4096 levels left
    N=256:  Segmentation fault, rc=139, 4096 levels left
    (busybox rm -r, N=512: "Filename too long", rc=1, 4096 left)

Nothing is lost, only under a lowered stack limit. README mentions depth
and open files as limits, not the stack.

## UTILS-8 cat -n reads a file named -n: reproduced, info

    $ docker run --rm kcontaineros sh -c 'cd /tmp && echo secret > ./-n && cat -n /etc/os-release; echo "rc=$?"'
    secret
    NAME="kContainerOS"
    ...
    rc=0
    without such a file: output of the other operand, then "cat: -n: no such file or directory", rc=1
    sleep -x: "sleep: invalid time interval: -x", rc=1

Intended according to the comment on `operands()` in src/applets.rs; the
README's "an unknown option is an error" does not carve cat out. A
documentation mismatch more than a bug; sleep is loud either way.

## UTILS-9 cat a >> a fills the filesystem: reproduced, not a defect, info

    16 MB tmpfs: echo data > a; /bin/cat a >> a
    cat: write error: no space left on device     rc=1, a is 16777216 bytes
    busybox cat b >> b: the same message, rc=1, 16777216 bytes

Same as busybox, not required by POSIX, the failure is loud (exit 1), and
the README claims a self-copy check for cp only. A hardening idea.
