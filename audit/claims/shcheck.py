#!/usr/bin/env python3
"""Shell claims: (1) every supported feature of the README's table, run in the
image's sh and in busybox sh, must give the same stdout and exit status;
(2) every construct the README lists as not supported must be a syntax error
(exit 2, message "sh: syntax error: ...") with nothing of the script run.

Prints lines in the format of lib.sh and appends to out/results.tsv.
Usage: shcheck.py RESULTS_TSV
"""
import subprocess, sys

IMG = "kcos-audit-claims-img"
res = open(sys.argv[1], "a")
ntests = ndiff = nclaims = 0
cur = ""

def run(shell, script, args=(), stdin=b""):
    cmd = ["timeout", "60", "docker", "run", "--rm", "-i", "--platform", "linux/arm64", "-w", "/tmp", "-e", "PATH=/bin",
           "--entrypoint", shell, IMG] + (["sh"] if shell.endswith("busybox") else []) + ["-c", script, "arg0"] + list(args)
    p = subprocess.run(cmd, input=stdin, capture_output=True)
    return p.stdout.decode("latin1"), p.stderr.decode("latin1"), p.returncode

def claim(cid, text):
    global cur, nclaims
    cur = cid; nclaims += 1
    print("\n[%s] %s" % (cid, text)); res.write("%s\tCLAIM\t%s\n" % (cid, text))

def verdict(name, want, got):
    global ntests, ndiff
    ntests += 1
    if want == got:
        print("  ok    " + name); res.write("%s\tok\t%s\n" % (cur, name))
    else:
        ndiff += 1
        print("  DIFF  " + name)
        for l in want.split("\n"): print("        claimed  | " + l)
        for l in got.split("\n"): print("        observed | " + l)
        res.write("%s\tDIFF\t%s\n" % (cur, name))

def same(name, script, args=(), stdin=b""):
    """A supported feature: stdout and status as busybox sh gives them."""
    bo, be, brc = run("/bb/busybox", script, args, stdin)
    ko, ke, krc = run("/bin/sh", script, args, stdin)
    verdict(name + "   [" + script.replace("\n", "\\n")[:70] + "]", "%s[rc %d]" % (bo, brc), "%s[rc %d]" % (ko, krc))

def refused(name, construct):
    """Not supported: a syntax error before the first command runs."""
    ko, ke, krc = run("/bin/sh", "echo RAN\n" + construct)
    got = "ran=%s rc=%d syntax-error=%s" % ("yes" if "RAN" in ko else "no", krc, "yes" if ke.startswith("sh: syntax error: ") else "no")
    if got != "ran=no rc=2 syntax-error=yes":
        got += "\nstdout: " + ko.strip().replace("\n", "\\n") + "\nstderr: " + ke.strip().replace("\n", "\\n")
    verdict(name + "   [" + construct.replace("\n", "\\n")[:60] + "]", "ran=no rc=2 syntax-error=yes", got)

def exact(name, script, want_out, want_rc, args=(), stdin=b"", err_has=None):
    ko, ke, krc = run("/bin/sh", script, args, stdin)
    got = "%s[rc %d]" % (ko, krc)
    want = "%s[rc %d]" % (want_out, want_rc)
    if err_has is not None:
        want += " stderr has: " + err_has
        got += " stderr has: " + (err_has if err_has in ke else "NOT (" + ke.strip() + ")")
    verdict(name + "   [" + script.replace("\n", "\\n")[:70] + "]", want, got)

print("== shell")
claim("H001", "R: Shell: quoting, $VAR, ${VAR:-default}, $?, $$, $!, $#, $-, \"$@\", $*, $1..$9")
same("single and double quotes, backslash", r'''echo 'a  b' "c  d" e\ f "x\"y" 'it'"'"'s' "\$HOME" \\''')
same("$VAR and ${VAR}", 'A=1; B=two; echo $A ${B} "$A$B" ${A}x')
same("${VAR:-default}: unset, empty, set", 'U=; S=set; echo "${NOPE:-d1}" "${U:-d2}" "${S:-d3}"')
same("$? after true, false, a missing command", 'true; echo $?; false; echo $?; /nonexistent 2>/dev/null; echo $?; sh -c "exit 42"; echo $?')
same("$$ is a number and stable", 'A=$$; B=$$; sh -c "exit 0"; echo "${A:-none}" | cat > /dev/null; env | cat > /dev/null; echo same', )
exact("$$ is the shell's PID", 'echo $$', "1\n", 0)
same("$! and wait", 'sh -c "exit 7" & P=$!; wait $P; echo "status $?"')
same("$# and shift", 'echo $#; shift; echo $# $1; shift 2; echo $#', ("a", "b", "c", "d"))
same('"$@" keeps arguments whole, $* and unquoted $@ split', 'sh -c \'echo $#\' x "$@"; sh -c \'echo $#\' x $@; sh -c \'echo $#\' x $*; sh -c \'echo $#\' x "$*"; echo "$*"', ("a b", "c", ""))
same("$1..$9 and $0", 'echo "$0|$1|$2|$3|$4|$5|$6|$7|$8|$9"', tuple("123456789"))
same("$10 is $1 followed by 0", 'echo $10', ("x", "2", "3", "4", "5", "6", "7", "8", "9", "ten"))
exact("$- shows e after set -e", 'set -e; echo $-', "e\n", 0)
claim("H002", "R: every variable is exported")
exact("an assignment is seen by a child without export", 'X=seen; sh -c \'echo "$X"\'', "seen\n", 0)
claim("H003", "R: a default may contain further $ expansions but no quotes and no $@")
same("nested defaults and expansions in a default", 'H=/h; echo "${X:-$H/data}" "${A:-${B:-c}}" ${Z:-a b} "${Q:-$H$H}"')
refused("quotes in a default", 'echo "${X:-"a b"}"')
refused("$@ in a default", 'echo "${U:-$@}"')
claim("H004", "R: unquoted expansions are split on whitespace and never globbed; IFS cannot be changed")
exact("split on blanks, tabs and newlines; a * from a variable stays a *", 'X="a  b\t*\nc"; sh -c \'echo $#\' x $X; cd /; Y="*"; echo $Y', "4\n*\n", 0)
refused("IFS=:", 'IFS=:; echo x')
refused("IFS= read", 'IFS= read -r line')
claim("H005", "R: pipes, &&, ||, ;, &, <, >, >>, N>&M, N>&-; also on builtins")
same("pipeline of three, status of the last", 'echo a | cat | cat; false | true; echo $?; true | false; echo $?')
same("&& and || chains, left to right", 'true && echo a; false && echo b; false || echo c; true || echo d; false && echo e || echo f; true || echo g && echo h')
same("; and newlines", 'echo a; echo b\necho c')
same("> >> <", 'echo one > f; echo two >> f; cat < f; cat f f > g; cat g')
same("2>&1 and 1>&2, order of redirections", 'sh -c "echo out; echo err >&2" > o 2>&1; cat o; sh -c "echo out; echo err >&2" 2>&1 > o2 | cat; cat o2')
same("N>&- closes", 'echo gone >&- 2>/dev/null; echo "rc=$?"; echo kept 2>&-')
same("3> and >&3", 'exec 3> f3; echo via3 >&3; exec 3>&-; cat f3')
same("redirections on builtins do not stick", 'cd / > /tmp/o; echo visible; export A=1 > /tmp/o; echo also')
same("redirection before the command and in the middle", '> f1 echo a; echo b > f2 c; cat f1 f2')
same("a && b & runs the whole list in the background", 'sleep 0.2 && echo late & echo early; wait')
exact("a background command reads from /dev/null", 'cat & wait; echo "rc=$?"', "rc=0\n", 0, stdin=b"SHOULD-NOT-BE-READ\n")
claim("H006", "R: builtins cd exit export unset exec set shift wait umask command :")
same("cd, cd -, PWD and OLDPWD", 'cd /etc; cd /tmp; echo "$PWD $OLDPWD"; cd - > /dev/null; echo "$PWD"; cd /var/run; cd -P .; echo "$PWD"')
exact("cd sets PWD to the physical directory, as cd -P does (/var/run is a link to /run)", 'cd /var/run; echo "$PWD"; cd -L /var/run; echo "$PWD"', "/run\n/run\n", 0)
same("exit N, exit with the last status", 'sh -c "exit 3"; echo $?; sh -c "false; exit"; echo $?; exit 9; echo not-reached')
same("export and unset", 'export A=1 B=2; C=3; export C; unset A; env | cat > e; sh -c \'echo "[$A][$B][$C]"\'; unset B C; echo "[$B][$C]"')
same("exec replaces the shell; exec with only redirections keeps it", 'exec > o; echo into-file; exec >&2; cat o >&2; exec echo replaced; echo not-reached')
same("set -- and shift", 'set -- x "y z" w; echo $# "$2"; shift; echo "$1"; set --; echo $#')
same("set -e stops at a failing command, not in && || lists", 'set -e; false || echo guarded; false && echo no; echo before; false; echo after')
same("set -x traces to stderr", 'set -x; echo traced 2>/dev/null')
same("wait PID returns that command's status; wait alone returns 0", 'sh -c "exit 5" & A=$!; sh -c "exit 6" & B=$!; wait $B; echo $?; wait $A; echo $?; wait; echo $?')
same("umask", 'umask 027; umask; echo x > f; ls -l f | cat > /dev/null; umask 0; umask')
same("command -v and command NAME", 'command -v cd; command -v cat; command -v nope || echo not-found; command echo hi')
same(": does nothing, successfully", ': ignored args; echo $?; : > made; cat made; echo "rc=$?"')
same("-- ends a builtin's options", 'cd -- /tmp; export -- A=1; unset -- A; set -- -x; echo "$1"; exec -- echo done')
exact("an unknown option ends the script for export, unset, set, shift", 'export -z A=1; echo wrong', "", 2, err_has="export")
exact("  unset", 'unset -z A; echo wrong', "", 2, err_has="unset")
exact("  set (found before the script starts)", 'echo start; set -z; echo wrong', "", 2, err_has="set")
exact("  shift", 'shift -z; echo wrong', "", 2, err_has="shift")
exact("  the others fail and the script goes on: cd, wait, umask, command", 'cd -z; echo "cd=$?"; wait -z; echo "wait=$?"; umask -z; echo "umask=$?"; command -z; echo "command=$?"', "cd=1\nwait=2\numask=2\ncommand=2\n", 0)
claim("H007", "R: script files, sh -c, sh -ec, commands on stdin; #!/bin/sh scripts and executable text files without #! run; quoted strings, pipelines and && lists may span lines")
same("a script file with arguments; a #! script; a text file without #!", 'echo \'echo "file $1"\' > s; sh s one; echo "#!/bin/sh" > t; echo \'echo "shebang $1"\' >> t; chmod 755 t s; ./t two; ./s three')
same("sh -ec", 'sh -ec "echo a; false; echo b"; echo $?')
same("commands on stdin", 'sh', stdin=b"echo one\nX=2\necho $X\nexit 4\n")
same("a quoted string, a pipeline and an && list across lines", 'echo "first\nsecond"\necho piped |\ncat\ntrue &&\necho listed\necho back\\\nslash')
exact("a script on stdin stops at its first syntax error, having run what came before", 'sh', "before\n", 2, stdin=b"echo before\nif true; then\necho BODY\nfi\necho after\n", err_has="sh: syntax error: ")
same("comments", 'echo a # comment\n# whole line\necho b#not-a-comment')

claim("H008", "R: if / for / while / case, functions, { }, !, $(...), backticks, here-documents: syntax error, nothing in the script runs")
for name, c in [("if", 'if true; then echo x; fi'), ("for", 'for i in 1 2; do echo $i; done'), ("while", 'while false; do :; done'),
                ("until", 'until true; do :; done'), ("case", 'case x in x) echo y;; esac'), ("function f()", 'f() { echo x; }'),
                ("function keyword", 'function f { echo x; }'), ("{ } group", '{ echo a; echo b; }'), ("! negation", '! false'),
                ("subshell ( )", '(echo sub)'), ("$( )", 'echo $(echo x)'), ("$( ) in quotes", 'echo "$(echo x)"'), ("backticks", 'echo `echo x`'),
                ("arithmetic $(( ))", 'echo $((1 + 2))'), ("here-document", 'cat <<EOF\nx\nEOF'), ("here-document <<-", 'cat <<-EOF\nx\nEOF'),
                ("here-string", 'cat <<< x'), ("keyword after &&", 'true && if true; then echo x; fi'), ("keyword after a pipe", 'echo x | while read l; do echo $l; done'),
                ("keyword after ;", 'true; for i in 1; do echo; done'), ("keyword after an assignment", 'A=1 if true; then echo x; fi'),
                ("select", 'select x in a b; do echo $x; done'), ("[[ ]]", '[[ -n x ]] && echo y'), ("(( ))", '((1 + 1))'),
                ("then / do / done / fi / esac / else / elif alone", 'done')]:
    refused(name, c)
claim("H009", "R: trap, eval, read, ., return, local, readonly, alias, getopts, ulimit, type, set -u, set -o: syntax error, nothing in the script runs")
for name, c in [("trap", 'trap "echo bye" EXIT'), ("eval", 'eval echo x'), ("read", 'read x'), (".", '. /etc/os-release'), ("source", 'source /etc/os-release'),
                ("return", 'return 0'), ("local", 'local x=1'), ("readonly", 'readonly X=1'), ("alias", 'alias ll="ls -l"'), ("unalias", 'unalias ll'), ("getopts", 'getopts ab: o'),
                ("ulimit", 'ulimit -n 100'), ("type", 'type ls'), ("set -u", 'set -u'), ("set -o", 'set -o pipefail'), ("set -eu", 'set -eu'),
                ("break", 'break'), ("continue", 'continue'), ("times", 'times'),
                ("hash", 'hash -r'), ("jobs", 'jobs'), ("fg", 'fg'), ("bg", 'bg'), ("trap - INT", 'trap - INT')]:
    refused(name, c)
claim("H010", "R: ${VAR:?}, ${VAR:=x}, ${VAR:+x}, ${#VAR}, ${VAR%x}, ${VAR#x} and the other ${...} operators: syntax error, nothing in the script runs")
for c in ['${V:?}', '${V:?msg}', '${V:=x}', '${V:+x}', '${#V}', '${V%x}', '${V%%x}', '${V#x}', '${V##x}', '${V-x}', '${V=x}', '${V?x}', '${V+x}', '${V:1}', '${V:1:2}',
          '${V/a/b}', '${V//a/b}', '${V^^}', '${V,,}', '${!V}', '${V@Q}', '${}', '${:-x}', '${V[0]}']:
    refused("echo " + c, 'echo "%s"' % c)
claim("H011", "R: globbing (*, ?, [) and ~: syntax error when unquoted; quote them to pass them literally")
for c in ['ls *', 'ls /etc/pass??', 'ls /etc/[a-z]*', 'echo a*b', 'cd ~', 'cd ~/x', 'echo ~root', 'A=~/x', 'export P=/a:~/b', 'rm -f /tmp/*.log', 'echo [', 'echo ]x[', '[ -f /etc/passwd ] && echo y']:
    refused(c, c)
exact("quoted, they are literal", 'echo "*" \'?\' "[a]" "~" \\* \\? \\[ \\~ a~b', "* ? [a] ~ * ? [ ~ a~b\n", 0)
claim("H012", "R: &>file and $'...': syntax error")
for c in ['echo a &> /tmp/f', "echo $'a\\tb'", 'echo a |& cat', 'echo a >| /tmp/f', 'cat <> /tmp/f', 'cat < <(echo x)', 'echo x > >(cat)']:
    refused(c, c)
claim("H013", "R: [ and test: there is no such command; (FAQ) a script with [ stops with a syntax error before its first command runs; (page) there is no test command either")
refused("[", '[ -n x ] && echo yes')
exact("test is not found when the script reaches it; the lines before it have run", 'echo before; test -n x; echo "rc=$?"', "before\nrc=127\n", 0, err_has="test: not found")
claim("H015", "observed, not claimed by the documents: constructs outside the README's lists")
same("${1:-x}, ${10}, ${#}, ${@}, ${*}, ${?} behave as in POSIX", 'echo "${1:-x}" "${10}" "${#}" "${?}"; sh -c \'echo $#\' x "${@}"; echo "${*}"', tuple("123456789") + ("ten",))
same("set +e, set +x, set ARGS, set - ARGS behave as in POSIX (the README names only -e, -x and --)", 'set -e; set +e; false; echo still; set a b; echo "$# $1"; set - c; echo "$# $1"')
exact("set with no arguments prints nothing (POSIX: the variables)", 'A=1; set; echo "rc=$?"', "rc=0\n", 0)
exact("printf, time and coproc are not found when reached; the script has run up to there and goes on", 'echo before; printf x; echo "rc=$?"; time true; echo "rc=$?"', "before\nrc=127\nrc=127\n", 0, err_has="printf: not found")
exact(">&WORD with a word that is no descriptor fails when reached (bash: a redirection of both streams)", 'echo before; echo a >& /tmp/f; echo "rc=$?"', "before\nrc=1\n", 0, err_has="bad file descriptor")
exact("cd -z is taken for a directory named -z", 'cd -z; echo "rc=$?"', "rc=1\n", 0, err_has="sh: cd: -z: no such file or directory")
claim("H014", "AGENTS/R: whether a script is valid must not depend on the value of a variable; what a variable holds is never parsed as syntax")
exact("operators, keywords and globs coming out of a variable are plain words", 'A="if"; B="|"; C="*"; D=";"; E=\'$(id)\'; F="&&"; cd /; echo $A $B $C $D $E $F', "if | * ; $(id) &&\n", 0)
exact("a keyword from a variable in command position is looked up as a command, not run as syntax", 'K=if; $K true 2>/dev/null; echo "rc=$?"', "rc=127\n", 0)

res.write("__COUNTS__\t%d\t%d\t%d\n" % (nclaims, ntests, ndiff))
print("\nshell: claims %d  experiments %d  did not hold %d" % (nclaims, ntests, ndiff))
