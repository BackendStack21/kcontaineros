#!/bin/bash
# Init on a terminal, driven through test/term.py. Prints the sessions; the
# ones with a fixed outcome are compared.
cd "$(dirname "$0")"; . ./lib.sh
T="python3 ../../test/term.py"
D="timeout 100 docker run -it --rm $P --name kcos-audit-init-tty-$$ $IMG"
trap 'docker rm -f kcos-audit-init-tty-$$ >/dev/null 2>&1' EXIT
show() { echo "--- $1"; shift; "$@"; }

out=$($T '\x1a' -- $D /bb/busybox sleep 4)
ok "Ctrl-Z does not keep 'sleep 4' stopped" "^Z[exit 0]" "$out"
out=$($T '\x1a' '\x03' '\x1c' -- $D /bb/kh rec 3)
ok "Ctrl-Z, Ctrl-C and Ctrl-\\ reach a command that catches them" "ready
^Z20
^C2
^\\3
[exit 0]" "$out"
out=$($T -- $D $'\e[31mred\x07\n\x9b2J')
ok "a command name with escape sequences is made harmless in init's message on a terminal" "kcontaineros: ?[31mred?????2J: no such file or directory
[exit 127]" "$out"
long=$(printf 'n%.0s' $(seq 1 1200))
out=$($T -- $D /bb/$long)
ok "a message longer than init's 512-byte terminal buffer is printed whole" "kcontaineros: /bb/$long: file name too long
[exit 126]" "$out"
show "interactive shell: echo, Ctrl-C, exit 7" $T 'echo hi\n' '\x03' 'echo $?\n' 'exit 7\n' -- $D /bb/busybox sh
show "nested init in the foreground, then the outer shell again" \
    $T '/sbin/init -- /bb/busybox sh\n' 'echo inner $$\n' 'exit 3\n' 'echo outer $?\n' 'exit\n' -- $D /bb/busybox sh
show "nested init as a background job reading the terminal, then fg" \
    $T '/sbin/init -- /bb/busybox cat &\n' 'jobs\n' 'fg\n' 'hello\n' '\x04' 'echo back $?\n' 'exit\n' -- $D /bb/busybox sh
show "nested init as a background job writing with tostop set" \
    $T '/bb/busybox stty tostop\n' '/sbin/init -- /bb/busybox echo from-bg &\n' 'jobs\n' 'fg\n' 'echo back $?\n' 'exit\n' -- $D /bb/busybox sh
show "nested init in the foreground killed by Ctrl-C, terminal handed back" \
    $T '/sbin/init -- /bb/busybox sleep 30\n' '\x03' 'echo back $?\n' 'exit\n' -- $D /bb/busybox sh
show "nested init in the foreground, Ctrl-Z" \
    $T '/sbin/init -- /bb/busybox sleep 3\n' '\x1a' 'echo back $?\n' 'exit\n' -- $D /bb/busybox sh
summary
