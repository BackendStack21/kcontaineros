# Independent reproduction of the "shell" track findings

Images: `kcontaineros` (release), `kcos-audit` (release + busybox at /bb).
All commands were run in fresh `docker run --rm --platform linux/arm64`
containers, prefixed with `timeout 120`. Containers were named
`kcos-audit-vshell-*` and none are left. None of these findings is about the
lockdown, so the "control" is busybox sh on the same input
(`--entrypoint /bb/busybox kcos-audit sh -c ...`).

| id | verdict | severity |
|----|---------|----------|
| SH-01 | reproduced | medium |
| SH-02 | reproduced | low |
| SH-03 | reproduced | low |
| SH-04 | reproduced_not_a_defect | info |
| SH-05 | reproduced | low |
| SH-06 | reproduced | low |
| SH-07 | reproduced | low |
| SH-08 | reproduced_not_a_defect | info |

## SH-01 reproduced, medium

```
$ docker run --rm kcontaineros sh -c 'i\
f false
t\
hen
echo BODY RUNS
f\
i'
sh: if: not found
sh: then: not found
BODY RUNS
sh: fi: not found
status 127
```

Control, the same script without the continuations:
`sh: syntax error: if, for, while, case, { } and ! are not supported`, status 2,
nothing run.

```
$ docker run --rm kcontaineros sh -c 'A=1; AB=2; echo $A\
B; echo hi 2\
>/dev/null; echo end'
1B
end
status 0
```

busybox sh on the same input: `2`, `hi`, `end`, status 0.

```
$ docker run --rm kcontaineros sh -c 'a=\
~; echo "[$a]"'
[~]                      status 0
$ docker run --rm kcontaineros sh -c 'a=~; echo "[$a]"'
sh: syntax error: `~' expansion is not supported; use $HOME or quote it     status 2
```

README line 194-196 ("rejects what it does not implement instead of running it
as something else, and checks a whole script before running its first line")
and the feature table ("`if` ... Syntax error; nothing in the script runs") do
not hold for these scripts. Not a way past the lockdown: the shell is not a
security boundary and whoever writes the script can run the body anyway.

## SH-02 reproduced, low

```
$ docker run --rm kcontaineros sh -c 'echo "[a${IFS}b][$LINENO]"; X=5; set; export; echo "status $?"'
[ab][]
status 0
$ docker run --rm kcontaineros sh -c 'export -p; echo no'
sh: export: -p: options are not supported        status 2
```

busybox: `[a \t\nb][0]`, and `set` prints 17 lines. The README says "`IFS`
cannot be changed" and that `set` accepts `-e`, `-x` and `-- ARGS`; it does not
say that `$IFS` is empty or that bare `set`/`export` do nothing. Silent
difference, against the project's own "correct or loud" rule.

## SH-03 reproduced, low

```
{ echo 'true &&'; yes '' | head -n 40000; echo 'echo done'; } | docker run --rm -i kcontaineros sh
  -> done, real 8.77 s          (10000 lines: 0.71 s)
same input, --entrypoint /bb/busybox kcos-audit sh
  -> done, real 0.17 s
{ yes A=1 | head -n 20000 | tr '\n' ' '; echo 'echo done'; } | docker run --rm -i kcontaineros sh
  -> done, real 13.55 s         (5000 prefixes: 0.96 s)
same input, busybox
  -> done, real 0.18 s
```

4x the input costs about 12-14x the time: quadratic. Robustness only; the
script author can already burn CPU.

## SH-04 reproduced_not_a_defect, info

```
$ python3 test/term.py 'exec /nosuch\n' 'echo b $?\n' -- docker run -it --rm kcos-audit
/ # exec /nosuch
sh: /nosuch: no such file or directory
[exit 127]
```

The behaviour is as described, but the comparison in the finding is wrong.
The busybox in the audit image does exactly the same:

```
$ python3 test/term.py 'exec /nosuch\n' 'echo b $?\n' 'exit\n' -- docker run -it --rm --entrypoint /bb/busybox kcos-audit sh
/ # exec /nosuch
sh: exec: line 1: /nosuch: not found
[exit 127]
```

POSIX allows an interactive shell to exit here (it only says it need not).
The README makes no statement about it. A usability wish at most.

## SH-05 reproduced, low

```
/ # /bb/busybox mkdir "/tmp/$E[31mX"
/ # cd "/tmp/$E[31mX"
/tmp/?[31mX # cd /
/ # cd -
/tmp/^[[31mX                         <- raw ESC (cat -v)
/tmp/?[31mX # pwd
/tmp/?[31mX                          <- pwd masks it
/tmp/?[31mX # cd /
/ # command -v "/tmp/$E[31mX/../../bin/sh"
/tmp/^[[31mX/../../bin/sh            <- raw ESC
```

README (191-193) promises masking for `ps`, `ls`, `pwd` and error messages
only, so no published claim is false; AGENTS.md's "nothing untrusted reaches a
terminal raw" is broken. For `command -v` the user typed the name; `cd -` is
the real case (a directory name created by someone else, echoed back).

## SH-06 reproduced, low

```
$ docker run --rm --entrypoint /bin/sh kcos-audit -c 'cd /tmp; echo a ;; echo b; echo x >#f; echo x 2> 4>&1; ls'
a
b
x
#f
4
status 0
$ docker run --rm kcontaineros sh -c '; echo lead'       -> lead, status 0
$ docker run --rm kcontaineros sh -c 'true & ; echo amp'  -> amp, status 0
```

busybox, one construct at a time: `syntax error: unexpected ";;"`,
`unexpected newline` (for `>#f`), `unexpected redirection`, each status 2.
`>#f` and `2> 4>&1` run with a different meaning than in sh.

## SH-07 reproduced, low

```
$ docker run --rm --entrypoint /bin/sh kcos-audit -c 'command exec >/tmp/o; echo visible; X=1 </nosuch; echo "[$X]"'
visible
sh: /nosuch: no such file or directory
[1]
status 0
```

busybox: only the error on the terminal; /tmp/o holds `visible` and `[]`.
Control: plain `exec >/tmp/o; echo hidden` in kcos does redirect (file holds
`hidden`). The `X=1 </nosuch` half is a small deviation; POSIX leaves the
order of assignment and redirection open when there is no command name, so
only the `command exec` half is clearly wrong.

## SH-08 reproduced_not_a_defect, info

```
$ docker run --rm kcontaineros sh -c 'export IFS=:; echo "status $?, going on"; export 1a=3; echo "status $?, going on"; unset 1a; echo "unset status $?"'
sh: export: IFS=:: bad variable name
status 1, going on
sh: export: 1a=3: bad variable name
status 1, going on
unset status 0
$ docker run --rm kcontaineros sh -c 'IFS=:; echo no'
sh: syntax error: IFS is not supported: fields are split on whitespace     status 2
$ docker run --rm kcontaineros sh -c 'X=eval; $X echo hi; echo "st $?"; echo -neE "a\tb"; echo; cd ""; echo "cd $?"; unset -- -x; echo "u $?"; true >&$UNSET; echo "r $?"; exit 99999999999999999999'
sh: eval: this builtin is not supported
st 2
a\tb
sh: cd: : no such file or directory
cd 1
u 0
r 1          (preceded by "sh: ambiguous redirect: the target is empty")
sh: exit: 99999999999999999999: numeric argument required      status 2
```

busybox: `export 1a=3`, `unset 1bad`, `true >&$UNSET` each end the script
with status 2; `cd ""` gives 0; `echo -neE "a\tb"` prints a tab.

All of it happens. Every case except `unset` of an invalid name is loud
(message and non-zero status), and the README only promises that an unknown
*option* to export/unset/set/shift ends the script. `export IFS=:` is refused
with an error, consistent with "`IFS` cannot be changed", though not before
the first command as `IFS=:` is. Differences from busybox, no documented claim
contradicted; the auditor's "info" stands.
