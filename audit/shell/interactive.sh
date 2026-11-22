#!/bin/bash
# The interactive shell on a pseudo-terminal (test/term.py types the strings).
# Prints what the terminal received, control characters made visible by cat -v.
#   bash audit/shell/interactive.sh
IMG=${IMG:-kcos-audit}
T="python3 test/term.py"
R="timeout 100 docker run -it --rm --platform linux/arm64 --memory 256m --pids-limit 64"
ESC=$(printf '\033')
echo "--- 1 Ctrl-C at the prompt and during sleep, Ctrl-Z, Ctrl-\\, end of input"
$T 'echo one\n' '\x03' 'sleep 30\n' '\x03' 'echo st=$?\n' 'sleep 3\n' '\x1a' 'echo z=$?\n' 'sleep 30\n' '\x1c' 'echo q=$?\n' '\x04' -- $R --name kcos-audit-shell-i1-$$ $IMG | cat -v
echo "--- 2 a syntax error, an unsupported option, a failed exec and a misused builtin do not end the shell"
$T 'if true\n' 'echo still $?\n' 'set -u\n' 'echo a $?\n' 'exec /nosuch\n' 'echo b $?\n' 'exec >/nosuch/x\n' 'echo c $?\n' 'shift x\n' 'echo d $? $-\n' 'exit 7\n' -- $R --name kcos-audit-shell-i2-$$ $IMG | cat -v
echo "--- 3 strings and lists that span lines"
$T 'echo "a\n' 'b"\n' 'true &&\n' 'echo cont\n' 'echo a \\\n' 'b\n' 'exit\n' -- $R --name kcos-audit-shell-i3-$$ $IMG | cat -v
echo "--- 4 escape sequences in names: cd -, command -v, set -x, the prompt, an error message"
$T '/bb/busybox mkdir "/tmp/$E[31mX"\n' 'cd "/tmp/$E[31mX"\n' 'cd /\n' 'cd -\n' 'cd /\n' 'set -x\n' 'true "$E[32m"\n' 'set +x\n' 'command -v "/tmp/$E[31mX/../../bin/sh"\n' '"$E[33mnosuch"\n' 'exit\n' -- $R -e "E=$ESC" --name kcos-audit-shell-i4-$$ $IMG | cat -v
echo "--- 5 background job and wait interrupted by Ctrl-C"
$T 'sleep 20 &\n' 'wait\n' '\x03' 'echo w=$?\n' 'kill $!\n' 'wait $!\n' 'echo k=$?\n' 'exit\n' -- $R --name kcos-audit-shell-i5-$$ $IMG | cat -v
