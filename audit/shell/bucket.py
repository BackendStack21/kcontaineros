#!/usr/bin/env python3
"""Sort the reduced differences (reduce.py) into the causes already looked at.

    python3 audit/shell/bucket.py SEED...

Reads work/reduced-SEED-MODE.json for the three modes and prints how many
original scripts fall under each cause, and in full every reduced script
that matches none: those are the ones to read.
"""
import collections, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
KNOWN = [
    (r"cd -", "`cd -` with OLDPWD unset: kcos fails loudly, busybox prints the current directory"),
    (r"command -v", "`command -v`: echo/true/false are programs in kcos (prints /bin/echo), status 1 not 127 when not found, several names"),
    (r"^\s*(\S+=\S* )*(export|set)( --)?\s*(\d*>.*|\|.*|&&.*|\|\|.*)?$", "`export`/`set` without operands print nothing (finding)"),
    (r"\bunset\b", "`unset` of an invalid name: no error in kcos (busybox ends the script)"),
    (r"\bexport\b", "`export` of an invalid name or with an option: kcos status 1 or 2, busybox ends the script or accepts"),
    (r"\bcd\b", "`cd`: status 1 against 2 on failure, `cd ''`, PWD physical (documented)"),
    (r"echo -[neE]+|echo '?\\", "echo option clusters and escapes (the applet)"),
    (r"(?<!busybox )\bprintf\b|\bpwd\b|\bumask\b|\blet\b|\btest\b|\[ ", "a builtin kcos does not have, or has with fewer options"),
    (r"&\s*$", "a background job still writing when the script ended (race in the harness)"),
    (r"[<>]&", "duplicating a descriptor that is not open or not a number: kcos status 1 and on, busybox ends the script"),
    (r"\bshift\b", "`shift` too far: kcos says so, busybox is silent"),
    (r"\bexec\b", "`exec` with a failing redirection or command: status 1 against 2"),
    (r"\bcommand\b|\bwait\b", "`command`/`wait` forms kcos refuses loudly"),
    (r"^\s*\S+=.*[<>]", "assignment with a failing redirection: kcos assigns, busybox does not"),
    (r"printenv\s*(\S+=|\||&|$)", "reducer left a bare printenv (environment order)"),
    (r"> ?\d*>|< ?\d*<|>> ?\d*>", "a redirection operator right after another: kcos takes the digits as the file name"),
    (r"\|\s*(set|export)\s*$", "`export`/`set` without operands print nothing (finding)"),
    (r"^\s*;", "an empty command before `;`: kcos accepts it, busybox reports a syntax error"),
    (r"\bstat f1", "reducer left a bare stat (inode numbers)"),
    (r">\$\{IN\}", "a pipeline that truncates the file it reads (race)"),
]
# stdin mode only: after reduction a command reads the shell's own stdin
STDIN_READER = (r"^\s*(\S+=\S* )*(/bb/busybox )?(cat|rev|wc|tr|sh -c '(cat|read))", "stdin mode: a command reads the rest of the script (busybox reads ahead, kcos does not)")


def main():
    counts = collections.Counter()
    rest = []
    for seed in sys.argv[1:]:
        for mode in ("file", "c", "stdin"):
            p = os.path.join(HERE, "work", "reduced-%s-%s.json" % (seed, mode))
            if not os.path.exists(p):
                continue
            for g in json.load(open(p)):
                for rx, name in KNOWN + ([STDIN_READER] if mode == "stdin" else []):
                    if re.search(rx, g["src"], re.M):
                        counts[name] += len(g["ids"])
                        break
                else:
                    rest.append((seed, mode, g))
    for name, n in counts.most_common():
        print("%5d  %s" % (n, name))
    print("%5d  not matched:" % sum(len(g["ids"]) for _, _, g in rest))
    for seed, mode, g in rest:
        print("=== seed %s %s scripts %s" % (seed, mode, g["ids"]))
        print(g["src"])


if __name__ == "__main__":
    main()
