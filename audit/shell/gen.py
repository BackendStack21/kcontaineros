#!/usr/bin/env python3
"""Generator of shell scripts for the differential test (kcos /bin/sh against
busybox sh).  Deterministic for a given seed.

Scripts come in two kinds:
  pure    only constructs the README lists as supported
  unsup   a pure script with one construct the README lists as NOT supported
          (kcos must refuse it: exit 2, nothing run)

External commands are always called by an absolute busybox path, so that
both shells run the same program and only the shell's own work is compared.
`echo`, `true` and `false` are the exception: they are part of the claim.
"""
import random
import re

BB = "/bb/busybox"
P = BB + " printf '<%s>\\n'"          # shows its arguments, one per line

# name -> single-quoted shell source of the value
VARS = {
    "A": "'abc'",
    "S": "'a b'",
    "T": "' lead trail '",
    "M": "'x\ty\nz  w'",
    "Q": "'q\"r'\\''s\\t'",
    "E": "''",
    "D": "'$A ${S}'",
    "H": "'#h'",
    "N": "'-n'",
    "B": "'a;b&c|d>e<f'",
    "Z": "'0'",
    "F": "'f1'",
    "X3": "'3'",
    "IN": "'in1'",
}
UNSET = ["U", "U2"]
ALLV = list(VARS) + UNSET

UNSUPPORTED = [
    "if true; then echo x; fi", "for i in 1 2; do echo $i; done",
    "while false; do :; done", "until true; do :; done",
    "case x in x) echo y;; esac", "f() { echo x; }", "{ echo a; }",
    "! true", "echo $(echo a)", "echo `echo a`", "cat <<EOF\nx\nEOF",
    "trap : INT", "eval echo x", "read x", ". /dev/null", "return",
    "local x", "readonly x=1", "alias a=b", "getopts a x", "ulimit -n",
    "type echo", "set -u", "set -o pipefail", "set -eu", "echo ${A:?}",
    "echo ${A:=x}", "echo ${A:+x}", "echo ${#A}", "echo ${A%x}",
    "echo ${A#x}", "echo ${A-x}", "echo ${A+x}", "echo ${A=x}",
    "echo ${A?x}", "echo ${A%%x}", "echo ${A##x}", "echo *", "echo ?",
    "echo [a]", "echo a*", "echo ~", "echo ~/x", "echo a &>f9", "echo $'a'",
    "(echo a)", "echo $((1+1))", "[[ a ]]", "function f { echo; }",
    "break", "continue", "echo a |& cat", "echo <(echo)", "x=(a b)",
    "echo ${A/x/y}", "echo ${A:1:2}", "echo ${!A}", "source /dev/null",
    "select x in a; do :; done", "X=~", "X=a:~", "export X=~",
    "echo a ) b", "echo a ( b", "hash -r", "times", "jobs", "fg", "bg",
    "unalias a", "echo \"$(echo a)\"", "echo \"`echo a`\"",
    "echo ${U:-\"a\"}", "echo ${U:-'a'}", "echo ${U:-\\a}", "echo ${U:-$@}",
    "echo ${U:-*}", "IFS=:", "IFS=: true", "cat <<-EOF\nx\nEOF",
    "cat <<<x", "echo a 1025>f9",
]
# Outside the subset too, but only found when the line runs (an error
# message and a non-zero status are expected, not a refusal up front).
RUNTIME_UNSUPPORTED = [
    "[ a = a ]", "test a = a", "umask -S", "umask u=rwx", "export -p",
    "unset -f x", "wait -n", "command -V echo", "command -p echo x",
    "exec -a x true", "printf x", "let x=1", "set -a", "shopt -s x",
    "declare x", "typeset x", "echo a >& f9", "exec 3<>f9", "echo a >|f9",
    "export IFS=:", "pwd -L", "X+=a",
    # error paths where the two shells are known to disagree on whether the
    # script goes on (kcos: status 1 and on; busybox: the script ends)
    "export 1a=3", "export a-b=1", "export =x", "export ''", "export a.b",
    "export -n V", "unset 1bad", "unset a-b", "unset ''", "unset -- -x",
    "unset -v", "true >&$U", "true >&$A",
    "cd ''", "command exec >f9", "command -v nosuchcmd", "command -v /tmp", "command", "true >&\"$E\"", "cd -",
]


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.bg = 0
        self.tags = set()

    # ---- words ---------------------------------------------------------
    def pick(self, *xs):
        return self.r.choice(xs)

    def lit(self):
        return self.pick("a", "b", "foo", "x1", "-n", "-e", "--", "=", "a=b",
                         "%s", ".", "/", "..", "0", "1", "-", "+", "@", "%",
                         ",", ":", "{", "}", "{a,b}", "^", "!x", "a#b", "a~b",
                         "_", "A", "if", "do", "-ne", "-x", "a,b", "1a", "a.b")

    def var(self):
        return self.pick(*ALLV)

    def default(self, depth=0):
        out = ""
        for _ in range(self.r.randint(0, 3)):
            k = self.r.randint(0, 9)
            if k <= 2:
                out += self.pick("d", "d e", " ", "  x ", "-", "=", ":", "#", "/", "{", "a.b", "%", "~x"[1:], "\n", "\t")
            elif k <= 4:
                out += "$" + self.pick(self.var(), "1", "2", "3", "9", "#", "?", "*", "0")
            elif k <= 6:
                out += "${" + self.pick(self.var(), "1", "3", "#", "*") + "}"
            elif k == 7 and depth < 3:
                out += "${" + self.var() + ":-" + self.default(depth + 1) + "}"
            else:
                out += self.pick("x", "y z")
        return out

    def expansion(self):
        k = self.r.randint(0, 11)
        self.tags.add("exp")
        if k <= 2:
            return "$" + self.var()
        if k <= 4:
            return "${" + self.var() + "}"
        if k <= 6:
            self.tags.add("default")
            return "${" + self.pick(self.var(), "1", "3", "9", "@", "*", "#", "?") + ":-" + self.default() + "}"
        if k == 7:
            return self.pick("$1", "$2", "$3", "$4", "$9", "${2}", "${10}", "$10", "${3}")
        if k == 8:
            self.tags.add("at")
            return self.pick("$@", "$*", "${@}", "${*}")
        if k == 9:
            return self.pick("$#", "$?", "${#}", "${?}", "$0")
        if k == 10:
            return self.pick("$=", "$%", "$,")   # $- differs by design: busybox adds s or c
        return "$" + self.var()

    def sq(self):
        return "'" + self.pick("", "a b", "$A", '"', "\\", "#", "*", "~", " ", "a\nb", ";", "|&", "${U:-x}", "\\n", "a  b", "`x`", "$(x)", "\t", "-n", "=") + "'"

    def dq(self):
        out = ""
        for _ in range(self.r.randint(0, 4)):
            k = self.r.randint(0, 9)
            if k <= 2:
                out += self.pick("a", " ", "a b", "'", "#", "*", "?", "[", "~", ";", "&", "|", "<", ">", "(", ")", "  ", "\n", "\t", "{", "}", "=", "!")
            elif k == 3:
                out += self.pick('\\"', "\\$", "\\\\", "\\`", "\\a", "\\n", "\\'", "\\ ", "\\\n", "\\}", "\\{")
            elif k == 4:
                out += self.pick("$ ", "$=", "$%", "$.", "$/")
            else:
                out += self.expansion()
        self.tags.add("dq")
        return '"' + out + '"'

    def bs(self):
        return "\\" + self.pick(" ", "$", '"', "'", "\\", "#", ";", "&", "|", ">", "<", "*", "?", "[", "~", "a", "n", "(", ")", "{", "=", "\n", "`", "\t", "-")

    def word(self):
        n = self.pick(1, 1, 1, 2, 2, 3)
        out = ""
        for _ in range(n):
            k = self.r.randint(0, 11)
            if k <= 2:
                out += self.lit()
            elif k <= 4:
                out += self.dq()
            elif k == 5:
                out += self.sq()
            elif k == 6:
                self.tags.add("bs")
                out += self.bs()
            elif k == 7:
                out += self.pick('""', "''", '""""', "''\"\"")
            else:
                out += self.expansion()
        if out.startswith("~") or out.startswith("#"):
            out = "x" + out
        return out

    def words(self, lo=0, hi=4):
        return " ".join(self.word() for _ in range(self.r.randint(lo, hi)))

    def fname(self):
        return self.pick("f1", "f2", "f3", "$F", '"$F"', "'f 4'", '"f 4"', "f\\ 4", "${U:-f5}", "/dev/null", "$U", '"$E"', "nodir/f", "${F}x", ".")

    def redir(self):
        self.tags.add("redir")
        k = self.r.randint(0, 13)
        sp = self.pick("", "", " ")
        if k <= 2:
            return ">" + sp + self.fname()
        if k <= 4:
            return ">>" + sp + self.fname()
        if k == 5:
            return "<" + sp + self.pick("in1", "in1", "/dev/null", "$IN", "nofile", '"$E"', "$U")
        if k == 6:
            return "2>" + sp + self.fname()
        if k == 7:
            return self.pick("2>&1", ">&2", "1>&2", "2>&2", "1>&1")
        if k == 8:
            return self.pick("3>", "4>>", "9>", "0<", "1>", "2>>", "10>") + sp + self.pick("f1", "f2", "f3")
        if k == 9:
            return self.pick(">&3", "3>&1", "3>&2", "2>&3", "<&3", "4>&3", ">&9", "0<&4", ">&$X3", '>&"$X3"', "3>&$Z")
        if k == 10:
            return self.pick("3>&-", ">&-", "2>&-", "<&-", "0<&-", "1>&-", "9>&-", "3<&-")
        if k == 11:
            return self.pick("2>/dev/null", ">/dev/null", "</dev/null", "2>>f3", "2>f3")
        if k == 12:
            return self.pick("2>&1 >f2", ">f2 2>&1", ">f1 >f2", "3>f1 >&3", "3>f1 >&3 3>&-", "2>f3 >&2", ">&2 2>f3", "3>&1 >f2 2>&3")
        return ">" + sp + self.word()

    # ---- commands ------------------------------------------------------
    def status_cmd(self):
        return self.pick("true", "false", "true", "false", BB + " sh -c 'exit 3'", BB + " sh -c 'exit 0'", BB + " sh -c 'echo o; echo e >&2; exit 5'", "nosuchcmd", "/nosuch/cmd", "/dev/null", "/")

    def reader(self):
        return self.pick(BB + " cat", BB + " tr a-z A-Z", BB + " wc -c", BB + " sh -c 'cat; exit 4'", BB + " cat -", BB + " rev", BB + " sh -c 'read x; echo $x; exit 6'")

    def assignment(self):
        self.tags.add("assign")
        return self.pick("A", "S", "E", "U", "V", "W", "F", "N", "PATH0", "_x", "a1") + "=" + (self.word() if self.r.random() < 0.9 else "")

    def builtin(self):
        self.tags.add("builtin")
        k = self.r.randint(0, 21)
        if k <= 1:
            return "cd " + self.pick("/tmp", "/", "/nosuch", "..", ".", "", "$U", "$S", "/bb", "-P /", "-L /tmp", "-- /", "/ /tmp", "$A", "//", "/tmp/")
        if k <= 3:
            return "export " + self.pick("V=" + self.word(), "V", "V=$S W=" + self.word(), "A", "V=", "-- V=1", "V=$S", 'V="$S"', "V=$T$T", "V=${U:-a b}", "$D", "V=a b", "_y=1", "W=$@", 'W="$@"', "W=$*", "V==", "V=a=b", "A=$A$A", "A B=2 C", "V W")
        if k == 4:
            return "unset " + self.pick("A", "S", "U", "A S", "V", "-v A", "-- A", "E", "PATH0", "F Z")
        if k <= 6:
            return "set " + self.pick("-- " + self.words(0, 3), "--", "-e", "+e", "-- a 'b c' ''", self.words(1, 3), "-", "- a b", "-e -- x y", "-- -e", "+e a", '-- "$@" z', "-- $S", '-- "$S"', "-- $@", '-- "$*"', "-ee", "-e +e", "--  ", "-- --", "-- -", "+")
        if k == 7:
            return "shift" + self.pick("", "", " 1", " 2", " 0", " 9", " $Z", " $U", " $X3", " 4", " 5")
        if k == 8:
            return "exit" + self.pick("", " 0", " 1", " 3", " 255", " 256", " 257", " $?", " $Z", " $U", " 7 8", " 1000")
        if k == 9:
            return "exec " + self.pick(self.redir(), "3>f1", "3>&-", ">f2", "2>f3", "2>&1", ">>f1", "<in1", BB + " true", P + " x", BB + " sh -c 'exit 9'", "-- " + P + " y", "nosuchcmd", "", ">nodir/x", "3<nofile")
        if k == 10:
            return "wait" + self.pick("", "", " $!", " $! $!", " 1", " 99999")
        if k == 11:
            return "umask" + self.pick("", " 022", " 077", " 0", " 0777", " 27", " 007", " 0022")
        if k == 12:
            return "command " + self.pick("-v echo", "-v cd", "-v /bin/sh", "-v sh", P + " " + self.word(), "cd /tmp", "true", "false", "-v exit", "-- " + P + " q", "export V=5", "exit 4", "shift", "set -- c d", "nosuchcmd", "unset A")
        if k == 13:
            return ": " + self.words(0, 3)
        if k == 14:
            return self.pick("true", "false") + " " + self.words(0, 2)
        if k == 15:
            return "echo " + self.pick("-n", "-e", "-E", "-ne", "--", "-", "", "-n -e", "-nx", "-n --", "-en", "-neE") + " " + self.words(0, 3)
        if k == 16:
            return "echo " + self.pick("'a\\tb'", "'a\\nb'", "'a\\\\b'", "-e 'a\\tb'", "-e 'a\\nb\\c' x", "-e 'a\\0101'", "-e '\\x41'", "'\\c' x", "-e", "-n", "-e 'a\\' b", "-e 'a\\qb'", "-E 'a\\tb'", "-e '\\e[0m'", "-e '\\0'", "-e 'x\\rb'")
        if k == 17:
            return self.assignment() + " " + self.pick("cd /tmp", "export W", "set -- q", ":", "shift 0", "command true", "umask", "wait", "exec", "unset V", "export V")
        if k in (18, 19):
            return ": " + self.words(1, 2)
        if k == 20:
            return "cd " + self.pick("/tmp", "/bb") + self.pick(" && ", "; ") + self.pick(P + ' "$PWD" "$OLDPWD"', BB + " pwd", "cd -", "cd - >f1", "cd .. && " + BB + " pwd")
        return "umask " + self.pick("77", "022", "0") + self.pick("; ", " && ") + self.pick("umask", BB + " touch f1 && " + BB + " stat -c %a f1", ">f1; " + BB + " stat -c %a f1", BB + " mkdir d1; " + BB + " stat -c %a d1")

    def simple(self, in_pipe=False, first=True):
        k = self.r.randint(0, 19)
        pre = ""
        if self.r.random() < 0.12:
            pre = self.assignment() + " "
            if self.r.random() < 0.3:
                pre += self.assignment() + " "
        if in_pipe and not first and k <= 9:
            c = self.reader()
        elif k <= 5:
            c = P + " " + self.words(0, 4)
        elif k <= 7:
            c = "echo " + self.words(0, 3)
        elif k <= 9:
            c = self.status_cmd()
        elif k <= 11:
            pre = ""
            c = self.assignment()
            if self.r.random() < 0.3:
                c += " " + self.assignment()
            if self.r.random() < 0.3:
                c += " " + P + " " + self.pick('"$V"', '"$A"', "$S", '"$W$U"')
            elif self.r.random() < 0.3:
                c += " " + BB + " printenv " + self.pick("A", "V", "S", "W", "E", "U")
        elif k <= 16:
            c = self.builtin()
        elif k == 17:
            c = BB + " printenv " + self.pick("A", "V", "S", "W", "E", "U", "PWD", "OLDPWD", "_x", "PATH0", "F")
        elif k == 18:
            c = BB + " sh -c " + self.pick("'echo \"$0|$1|$#\"'", "'echo \"$V|$W|$A\"'", "'cat'", "'echo out; echo err >&2'", "'echo to3 >&3'", "'echo $#'") + " " + self.words(0, 3)
        else:
            c = self.pick(BB + " cat in1", BB + " cat <in1", BB + " cat <$IN", BB + " cat <&3", BB + " pwd", BB + " cat in1 -")
        c = pre + c
        nred = self.pick(0, 0, 0, 0, 1, 1, 2, 3)
        for _ in range(nred):
            if self.r.random() < 0.15:
                c = self.redir() + " " + c
            else:
                c = c + " " + self.redir()
        return c

    def pipeline(self):
        n = self.pick(1, 1, 1, 1, 2, 2, 3, 4)
        if n > 1:
            self.tags.add("pipe")
        sep = self.pick(" | ", "|", " |\n", " | \\\n", " |  # c\n ")
        if sep != " | " and n > 1:
            self.tags.add("oddsep")
        cmds = [self.simple(n > 1, i == 0) for i in range(n)]
        # The commands of a pipeline run at the same time: give each its own
        # files, or the result depends on which of them opens a file first.
        for i in range(1, n):
            c = re.sub(r"\bf([1-5])\b", r"f\1p%d" % i, cmds[i])
            c = re.sub(r"f(\\?) 4", r"f\1 4p%d" % i, c)
            c = re.sub(r"\$\{?F\}?", "fFp%d" % i, c)
            cmds[i] = c
        return sep.join(cmds)

    def andor(self):
        n = self.pick(1, 1, 1, 2, 2, 3, 4)
        out = self.pipeline()
        for _ in range(n - 1):
            self.tags.add("andor")
            out += self.pick(" && ", " || ", " && ", " || ", "&&", "||", " &&\n", " ||\n  ", " && \\\n") + self.pipeline()
        return out

    def line(self):
        k = self.r.randint(0, 19)
        if k == 0:
            return self.pick("# a comment", "", "  ", "   # indented comment ; echo no", ": # c", "\t")
        if k == 1:
            self.tags.add("bg")
            self.bg += 1
            n = self.bg
            form = self.r.randint(0, 5)
            a = "%s x%d >bg%d" % (P, n, n)
            if form == 0:
                return a + " &"
            if form == 1:
                return "%s && %s &" % (self.status_cmd() + " 2>/dev/null", a)
            if form == 2:
                return "%s || %s &\nwait $!\n%s $?" % (self.status_cmd() + " 2>/dev/null", a, P)
            if form == 3:
                return "%s sh -c 'cat; echo in; exit 7' >bg%d &\nwait $!; %s $?" % (BB, n, P)
            if form == 4:
                return "%s sh -c 'exit 3' & %s sh -c 'exit 4' &\nwait $!\n%s $?\nwait; %s $?" % (BB, BB, P, P)
            return "%s | %s cat >bg%d &\nwait\n%s $? \"${!:-none}\" >/dev/null" % (a.split(" >")[0], BB, n, P)
        if k == 2:
            self.tags.add("sete")
            return self.pick("set -e", "set -e", "set +e", "set -e; " + self.andor(), "set -e\n" + self.andor() + "\nset +e")
        if k == 3:
            return self.andor() + self.pick("; ", " ; ", ";") + self.andor()
        if k == 4:
            self.tags.add("cont")
            w = [self.word() for _ in range(3)]
            return self.pick(P + " " + w[0] + " \\\n" + w[1] + " \\\n  " + w[2],
                             P + " a\\\nb " + w[0],
                             P + " \"a\\\nb\" 'c\\\nd'",
                             "ec\\\nho " + w[0],
                             P + " " + w[0] + " # c \\\n" + P + " next",
                             P + " $\\\nA \"$\\\nS\"",
                             P + " " + w[0] + " >\\\nf1",
                             P + " " + w[0] + " \\\n>f1 \\\n&& \\\n" + P + " ok")
        if k == 5:
            return self.andor() + " # " + self.pick("comment", "c; echo no", "c 'x", 'c "y', "c \\")
        return self.andor()

    # ---- scripts -------------------------------------------------------
    def script(self, kind="pure"):
        self.bg = 0
        self.tags = set()
        n = self.r.randint(1, 6)
        lines = [self.line() for _ in range(n)]
        if kind == "unsup":
            lines.insert(self.r.randint(0, len(lines)), self.r.choice(UNSUPPORTED))
        elif kind == "runtime":
            lines.insert(self.r.randint(0, len(lines)), self.r.choice(RUNTIME_UNSUPPORTED))
        if self.r.random() < 0.25:
            self.tags.add("sete")
            lines.insert(0, "set -e")
        body = "\n".join(lines)
        if self.bg:
            body += "\nwait"
        used = [v for v in VARS if re.search(r"\b" + v + r"\b", body)]
        pre = "".join("%s=%s\n" % (v, VARS[v]) for v in used)
        # kcos exports every variable (documented); make busybox do the same
        pre += "export A S T M Q E D H N B Z F X3 IN U U2 V W _x _y PATH0 a1\n"
        pre += BB + " printf 'l1\\nl2 x\\n' >in1\n"
        # something that shows whether anything ran at all
        src = pre + P + " start\n" + body + "\n"
        if self.r.random() < 0.05:
            src = src.rstrip("\n")
        return src, sorted(self.tags)


def generate(seed, count):
    """[(kind, source, tags)]"""
    g = Gen(seed)
    out = []
    for i in range(count):
        kind = "pure"
        if i % 10 == 8:
            kind = "unsup"
        elif i % 10 == 9:
            kind = "runtime"
        src, tags = g.script(kind)
        out.append((kind, src, tags))
    return out


if __name__ == "__main__":
    import sys
    for kind, src, tags in generate(int(sys.argv[1]) if len(sys.argv) > 1 else 1, 5):
        print("----", kind, tags)
        print(src)
