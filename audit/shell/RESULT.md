# Track: shell

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Shell track (src/sh.rs, commit deffcb4), run against kcos-audit / kcontaineros on kernel 7.0.14-linuxkit.

NOTE ON DELIVERABLE 2: REPORT.md was NOT written. The Write tool refused it ("Subagents should return findings as text, not write report files"), and I did not route around that block. The full report content is this structured result; the harness and all raw outputs are in audit/shell/ and its work/ directory. Rerun with `sh audit/shell/run-all.sh` (about 25 minutes).

(a) Differential, kcos /bin/sh against busybox sh 1.38.0: 9000 generated scripts (seeds 21-23; 7200 documented-subset only, 900 with one README-unsupported construct inserted, 900 with one error-path line), each as a file, with -c and on stdin = 27000 runs per shell. Compared stdout, files left behind, exit status, stderr line count. Subset scripts: 20458 of 21600 runs identical; 22 refused up front (all correct refusals of generator artefacts); 3 stopped on stdin; 196 differ only in message count or error status number; 311 where kcos printed more errors; 270 with no extra message from kcos; 340 not comparable on stdin (a command reads the script). Unsupported constructs: 1800 of 1800 file and -c runs refused with status 2, empty stdout, no file created. Syntax error after part of a file/-c script ran: 0. Signal deaths: 0. All 724 "no extra message" runs (all kinds) were reduced automatically and sorted by cause (work/buckets.txt): 95 belong to findings SH-02/SH-06, the rest are error-path deviations (unset/export of invalid names, command -v, bad descriptor dups, cd - without OLDPWD, statuses) or harness artefacts. The "kcos louder" class (1023 runs) was only sampled by message, not reduced one by one. About 6600 further scripts (seeds 1-4) were used to tune the generator and are not counted.

(b) Crash/hang fuzz: 48000 inputs (seeds 11, 12: random bytes, shell punctuation, fragments, mutations of valid scripts; NUL, 8-bit, CRLF) = 139818 runs (48004 file, 48004 stdin, 43810 -c) with a 5 s limit, 512 MB, 128 processes, plus controls proving a hang shows as 137 and a SIGSEGV as 139. Shell crashes, panics (status 101) or unexplained hangs: 0. Ten flagged runs were all explained (input kills its own shell, a 2^31 s sleep, a file appended to itself hitting the harness file-size limit). Structured stress: 40 oversized cases x 2 modes = 80 runs (64 MB tokens, 1M arguments, 200000-deep ${A:-, 100000 redirections, 3000-stage pipelines against the process limit, 1M-digit numbers, 20 MB values): no signal death, no status 101, memory in line with the data. Two superlinear paths found (SH-03).

(c) Reading plus 80 hand-written probes run twice (without init, and under init as root) and 6 pseudo-terminal sessions: descriptor leaks, redirection restore, number parsing, environment, ENOEXEC fallback, interactive signals.

8 findings: 1 medium, 6 low, 1 info. No critical or high. Nothing found weakens the lockdown.

## What held

- Every construct the README lists as unsupported (if/for/while/case, functions, { }, !, $(..), backticks, here-documents, trap/eval/read/./return/local/readonly/alias/getopts/ulimit/type, set -u/-o, ${VAR:?} and the other operators, globs, ~, &>, $'..', quotes or $@ inside a default, IFS=) was refused with status 2, empty stdout and no file created in 1800 of 1800 file and -c runs, wherever in the script it stood
- No file or -c script printed a syntax error after it had started running (0 in 18000 differential runs; in 91814 fuzz file/-c runs only 4 runs, all a nested sh -c reporting its own error): nothing passed check() and then failed to parse
- No refusal depended on the value of a variable in anything generated or read: check() decides on the written text; set $X, >&$FD, shift $N, exit $X fail when the line runs, with a message
- Scripts restricted to the documented subset matched busybox sh in 20458 of 21600 runs (quoting, nested ${NAME:-default}, unset vs empty, positional parameters, "$@"/$*/$#/$?, field splitting, redirection order and fd numbers, pipelines, && || ; &, background lists, wait PID); every remaining difference was traced to a cause
- set -e matched busybox in 16 targeted cases (pipelines, && || lists in every position, background jobs, builtins, failing redirections, assignments, sh -e, set +e) and across the generated scripts
- No crash, panic, out-of-memory exit or unexplained hang in 139818 fuzz runs and 80 stress runs, including NUL bytes, 8-bit bytes, 64 MB tokens, 1M arguments, 200000-deep ${A:- nesting (refused at depth 33), 100000 redirections, 3000-stage pipelines with fork failing
- Number parsing never wrapped: exit, shift, umask, wait PID, descriptor numbers and ${N} with 20-digit to 1M-digit values were refused or treated as unset; wait rejects 0 and anything above 2^31-1; descriptors above 1023 are a syntax error
- Children inherit none of the shell's own descriptors: /proc/self/fd in a child showed only 0-2 (plus the listing's own) after pipelines of 2 and 3 commands and after `command PROGRAM >file` (the saved copies are close-on-exec); only descriptors opened with exec stay
- Redirections on builtins are undone, including ones that close 1 and 2 and ones naming descriptors 10-12; a failed redirection on a special builtin ends a script with status 1
- The ENOEXEC fallback starts the shell on exactly the file found, after `--` (a script named -c on PATH ran as a script, not as an option); a file with a NUL at the start is refused (126); under init none of the test scripts in /tmp could be executed directly (126), as the README says
- Interactive shell: Ctrl-C at the prompt and during a command (status 130), Ctrl-\ (131), Ctrl-Z ignored, wait interrupted by Ctrl-C (130), wait PID of a killed job (143), end of input, multi-line quotes and && continuation; syntax errors, set -u, shift x, export -p and a failed exec redirection return to the prompt
- The prompt, set -x traces and error messages replaced ESC with ? on a terminal
- A script on stdin stops at its first syntax error with status 2 after running the lines before it, as documented
- IFS, PWD and OLDPWD taken from the environment, names with a blank, leading digit or dash, a value containing =, and a 100 kB value behaved as in busybox

## Not tested

- REPORT.md was not written: the Write tool refused it with "Subagents should return findings as text, not write report files" and I did not work around the block. Its content is this structured result.
- Duplicate names and entries without '=' in the environment handed to the shell: the static helper (envx.c, env.sh) could not be built because `apk add gcc` in an alpine container failed with an I/O error, Docker's disk being full (0 bytes free on the overlay) with images I may not remove. From reading only: setenv replaces the first entry of a name and leaves a later duplicate for children, unset removes all, an entry without '=' is never matched and is passed on.
- The fuzzers and the differential run started the shell without init (--entrypoint); under init (Landlock on) only the 80 hand-written probes ran.
- The 'kcos printed more errors than busybox' class of the differential run (1023 runs) was sampled by first message for one seed, not reduced case by case.
- The in-process fallback when `sh` is neither on $PATH nor a file (exec_or_die calling main again), a container without /proc (the ENOEXEC path needs /proc/self/exe), kernels without Landlock, user namespaces, the coverage build.
- Signals sent to a non-interactive shell while it waits for a child, and Ctrl-C typed at the `> ` continuation prompt.
- The quadratic.sh timings were taken while another of my containers was running, so absolute times are approximate; the growth by about four for each doubling is what was measured.
- The sealed image has no shell and is outside this track.

## Findings

### SH-01 — A line continuation inside a token escapes the checks: keywords run as commands (the guarded body runs), other tokens change meaning silently

- Severity: auditor **medium**, reviewer **medium**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:1305-1327 (reserved-word and unsupported-builtin test on the raw text), 1509-1514 (parameter name scan), 1243-1247 (descriptor digits), 1348 (~ test on the previous raw byte)

POSIX removes backslash-newline before tokens are recognised. kcos skips it only between words and inside double quotes. A reserved word written with a backslash-newline inside it is not recognised by check(), is run as a command named if/then/fi (not found), and the lines between run unconditionally. This contradicts the README Security section ("rejects what it does not implement instead of running it as something else, and checks a whole script before running its first line") and AGENTS.md ("a syntax error found before the first command runs"). Related cases are silent (status 0, empty stderr): $A\<newline>B expands $A and appends B instead of expanding $AB; `2\<newline>>file` redirects stdout and passes 2 as an argument instead of redirecting stderr; `a=\<newline>~` assigns a literal ~ although a=~ is refused. Rated medium rather than high because it needs a backslash-newline in the middle of a word, which nobody writes on purpose; the documented claim is nevertheless false for these scripts.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'i\
f false
t\
hen
echo BODY RUNS
f\
i'
(the argument is seven lines: i\ / f false / t\ / hen / echo BODY RUNS / f\ / i)

docker run --rm --platform linux/arm64 kcontaineros sh -c 'A=1; AB=2; echo $A\
B; echo hi 2\
>/dev/null; echo end'

Also: sh audit/shell/probes.sh  (section 1)
```

Expected: First: a syntax error and status 2 with nothing run (or, as busybox sh does, a real if: no output, status 0). Second: busybox prints 2, hi, end.

Observed: First: "sh: if: not found", "sh: then: not found", "BODY RUNS", "sh: fi: not found", status 127. Second: prints "1B" and "end", status 0, nothing on stderr (hi is written to /dev/null with an extra argument 2).

Reviewer: README lines 194-196 and the feature table ("if ... Syntax error; nothing in the script runs") are false for these scripts. Not a lockdown bypass: the script author can run the body anyway. Medium as misleading documented claim plus silent meaning changes.

### SH-02 — $IFS, $LINENO, $OPTIND, $PS4 expand to nothing, and `set` / `export` without operands print nothing with status 0

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:1423-1451 (param), 950-971 (export), 1004-1022 (set)

Parameters every POSIX shell provides are simply unset, and the two listing forms of set and export are silent no-ops. A script that uses "$IFS" as a separator, $LINENO in a message, or set/export to dump its variables runs with different output and no error, against "correct or loud, never silently different". `export -p` is refused (status 2) but bare `export` is not. This was the cause of 91 silent differences in the differential run.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'echo "[a${IFS}b][$LINENO]"; X=5; set; export; echo "status $?"'
```

Expected: busybox sh: "[a <tab><newline>b][1]", then the variable listing from set and from export, then "status 0"; or a syntax error for what is not implemented.

Observed: [ab][] / status 0

Reviewer: README says only "IFS cannot be changed" and that set accepts -e, -x, -- ARGS; it does not say $IFS is empty or that bare set/export are silent no-ops. Silent difference against the project's correct-or-loud rule; functional only.

### SH-03 — Superlinear time on small input: a command left open across many lines on stdin, and many assignment prefixes on one command

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:258-277 (stdin loop re-runs check() on everything read so far for each further line unless inside a quote), src/sh.rs:1293 (overlay: cmd.assigns.clone() for every prefix)

On stdin, each additional line of an unfinished command (after a trailing backslash, |, && or ||) causes the whole accumulated input to be parsed again. 40000 continuation lines (160 kB) did not finish in 60 s; busybox sh takes under 0.01 s; the same file run as `sh FILE` takes under 0.01 s in kcos. Separately, N assignment prefixes on one command cost N squared copies in every mode. Whoever supplies the script can already run sleep, so this is a robustness defect rather than a way past anything.

Reproduction:

```
time ( { echo 'true &&'; yes '' | head -n 40000; echo 'echo done'; } | docker run --rm -i --platform linux/arm64 kcontaineros sh )
time ( { yes A=1 | head -n 20000 | tr '\n' ' '; echo 'echo done'; } | docker run --rm -i --platform linux/arm64 kcontaineros sh )
sh audit/shell/quadratic.sh   # the full table, with busybox on the same input
```

Expected: Time proportional to the input: busybox sh finishes each in well under a second (0.3 s including container start for the first).

Observed: First command: "done" after 10.0 s. Second: "done" after 15.7 s. quadratic.sh in kcos-audit, stdin: `: a \` lines 5000/10000/20000/40000 -> 1.17 / 4.45 / 16.91 s / killed at 60 s; `true |` + comment lines -> 0.41 / 1.66 / 6.80 / 29.09 s; `true &&` + empty lines -> 0.15 / 0.72 / 2.58 / 10.23 s. A=1 prefixes 5000/10000/20000/40000 as a file -> 0.67 / 2.83 / 11.64 / 47.70 s.

Reviewer: 4x input costs 12-14x time: quadratic, as claimed. Robustness only; whoever supplies the script can already consume CPU.

### SH-04 — In the interactive shell a failed `exec COMMAND` ends the session

- Severity: auditor **low**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: src/sh.rs:986-1003 (exec) -> exec_or_die, src/sh.rs:821-855

At the prompt every other error returns to the prompt (syntax error, set -u, shift x, export -p, exec with a failing redirection: statuses 2, 2, 2, 2, 1). exec of a command that cannot be started calls sys::exit(127). A typo after exec in `docker exec -it ... sh` closes the shell; when the shell is init's command, the container stops. busybox sh and POSIX keep an interactive shell alive here.

Reproduction:

```
python3 test/term.py 'exec /nosuch\n' 'echo b $?\n' -- docker run -it --rm --platform linux/arm64 kcos-audit
bash audit/shell/interactive.sh   # session 2
```

Expected: "sh: /nosuch: no such file or directory", a new prompt, then "b 127".

Observed: / # exec /nosuch / sh: /nosuch: no such file or directory / [exit 127]

Reviewer: The behaviour happens, but the finding's premise is wrong: the busybox sh in the audit image exits 127 in exactly the same way, and POSIX permits an interactive shell to exit on a failed exec (it only need not). README makes no claim about it. Usability wish at most.

### SH-05 — `cd -` and `command -v` write names to a terminal unfiltered

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:937 (cd -), src/sh.rs:1105 (command -v): write_all(1, ...)

AGENTS.md: "Nothing untrusted reaches a terminal raw. File names, arguments and process names are shown through Out::safe or eprint". Both builtins print a path with write_all. With a directory whose name contains ESC [31m, `cd -` sent the raw escape sequence to the terminal while the prompt, set -x and error messages in the same session masked it with ?. The README promises masking only for ps, ls, pwd and error messages, so this breaks the project's own rule rather than a published claim.

Reproduction:

```
bash audit/shell/interactive.sh   # session 4; equivalent to:
E=$(printf '\033'); python3 test/term.py '/bb/busybox mkdir "/tmp/$E[31mX"\n' 'cd "/tmp/$E[31mX"\n' 'cd /\n' 'cd -\n' 'command -v "/tmp/$E[31mX/../../bin/sh"\n' 'exit\n' -- docker run -it --rm --platform linux/arm64 -e "E=$E" kcos-audit | cat -v
```

Expected: /tmp/?[31mX from cd - and from command -v, as the prompt shows it.

Observed: / # cd - / /tmp/^[[31mX / /tmp/?[31mX # ... / / # command -v "/tmp/$E[31mX/../../bin/sh" / /tmp/^[[31mX/../../bin/sh / (^[ is the raw ESC byte made visible by cat -v)

Reviewer: README 191-193 promises masking only for ps, ls, pwd and error messages, so no published claim is false; it violates AGENTS.md's internal rule. cd - is the meaningful case (name created by another party echoed raw); for command -v the user typed the bytes himself.

### SH-06 — Syntax that POSIX shells reject is accepted, twice with another meaning

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:1196-1209 (an empty command before ; is accepted, ; and newline are the same separator), src/sh.rs:1268-1276 (redirection target: a word starting with # or digits before another operator)

`;;`, a leading `;` and `& ;` run as if the extra separator were a newline. `>#f` creates a file named #f (in sh the # starts a comment and the target is missing). `2> 4>&1` takes 4 as the file name for stderr (in sh 4>&1 is its own redirection and 2> has no target). None of this is in the documented subset, and the stated rule is that what is outside it is a syntax error.

Reproduction:

```
docker run --rm --platform linux/arm64 --entrypoint /bin/sh kcos-audit -c 'cd /tmp; echo a ;; echo b; echo x >#f; echo x 2> 4>&1; ls'
sh audit/shell/probes.sh   # section 3, with busybox side by side
```

Expected: A syntax error, status 2, nothing run (busybox sh: "syntax error: unexpected ";;"", "unexpected end of file", "unexpected redirection").

Observed: a / b / x / #f / 4 / (status 0: both echo commands ran, files named #f and 4 were created)

Reviewer: Not in the documented subset and not rejected; >#f and 2> 4>&1 run with a different meaning than in sh. Functional.

### SH-07 — `command exec REDIRECTION` does not keep the redirection; an assignment is kept when its redirection fails

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: src/sh.rs:860-902 (builtin_redirected saves and restores around `command`), src/sh.rs:699-705 (assignments applied before the redirections of an empty command are tried)

Both `command NAME ARGS` and `exec` with redirections are in the supported table. Combined, the redirection is undone as soon as `command` returns, silently: later output goes to the old stdout. Separately, `X=1 </nosuch` reports the failed redirection but X is set, where busybox leaves it unset.

Reproduction:

```
docker run --rm --platform linux/arm64 --entrypoint /bin/sh kcos-audit -c 'command exec >/tmp/o; echo visible; X=1 </nosuch; echo "[$X]"'
```

Expected: busybox sh: nothing on stdout ("visible" and "[]" go to /tmp/o), one error message for /nosuch.

Observed: visible / sh: /nosuch: no such file or directory / [1]

Reviewer: The `command exec` half is a clear silent deviation. The `X=1 </nosuch` half is weaker: POSIX leaves assignment/redirection order open for a command without a name.

### SH-08 — Error paths where the script goes on, or is silent, unlike busybox sh

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced, not a defect
- Where: src/sh.rs:958-969 (export), 981-983 (unset), 417-461 (apply_redirs), 821-825 (unsupported builtin reached through a variable); src/applets.rs:350-364 (echo options)

Not contradictions of a documented claim, recorded so they are known. `export 1a=3` and `export IFS=:` print an error, give status 1 and the script continues (after the second, values are still split on blanks only, so a script that relies on the new IFS carries on with the old splitting unless set -e is on). `unset 1bad`, `unset ''` and `unset -- -x` succeed silently (busybox: error, script ends). `true >&$UNSET` gives status 1 and continues (busybox ends the script). `X=eval; $X echo hi` prints "this builtin is not supported", status 2, and the script continues. `cd ''` fails (busybox: succeeds). `echo -neE 'a\tb'` leaves the escape alone because the last option wins (busybox interprets it). `exit 99999999999999999999` is an error with status 2.

Reproduction:

```
docker run --rm --platform linux/arm64 kcontaineros sh -c 'export IFS=:; echo "status $?, going on"; export 1a=3; echo "status $?, going on"; unset 1a; echo "unset status $?"'
sh audit/shell/probes.sh   # sections 4, 5 and 10
```

Expected: busybox sh ends the script at the first invalid name with status 2 (export IFS=: is valid there and changes the splitting).

Observed: sh: export: IFS=:: bad variable name / status 1, going on / sh: export: 1a=3: bad variable name / status 1, going on / unset status 0

Reviewer: Everything listed happens. All but unset of an invalid name are loud (message and non-zero status), and README only promises that an unknown option to export/unset/set/shift ends the script. Differences from busybox with no documented claim contradicted; agrees with the auditor's info rating. Verdicts and evidence written to audit/shell/REPRODUCTION.md; no kcos-audit-vshell-* containers remain.

