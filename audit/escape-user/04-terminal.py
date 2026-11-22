#!/usr/bin/env python3
"""Goal: get an escape sequence onto the operator's terminal through a
message that init, the shell or a utility prints.

Every case runs `docker run -t` on a pseudo-terminal and looks at the raw
bytes that arrive: anything but printable ASCII, CR, LF and TAB counts as
"raw". The hostile bytes come in through the environment or the command
line, never through typed input (which the terminal would echo).
Run from anywhere: python3 audit/escape-user/04-terminal.py
"""
import os, pty, select, subprocess, sys, time

T = "kcos-audit-escape-user"
ESC = "\x1b[31mPWN\x07\x7f"          # CSI, BEL, DEL (docker itself replaces bytes that are not UTF-8)
BASE = ["timeout", "120", "docker", "run", "--rm", "--platform", "linux/arm64"]
held = findings = 0

def on_tty(cmd, typed=(), wait=25):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    out = bytearray()
    end = time.time() + wait
    todo = list(typed)
    next_type = time.time() + 3
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
        if todo and time.time() > next_type:
            os.write(fd, todo.pop(0).encode()); next_type = time.time() + 1
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    os.waitpid(pid, 0)
    return bytes(out)

def raw(b):
    return [c for c in b if not (0x20 <= c < 0x7f or c in (9, 10, 13))]

def verdict(name, data, expect_clean=True):
    global held, findings
    bad = raw(data)
    text = data.decode("latin1").replace("\r", "")
    shown = repr(text.strip()[-200:])
    if bad and expect_clean:
        findings += 1; print(f"  FINDING  {name}: raw bytes {sorted(set(bad))} reach the terminal: {shown}")
    elif bad:
        print(f"  NOTE     {name}: raw bytes reach the terminal (data output, not a message): {shown}")
    else:
        held += 1; print(f"  HELD     {name}: {shown}")

print("## init's own messages, on a terminal (docker run -t)")
verdict("command name", on_tty(BASE + ["-t", "kcontaineros", "cmd" + ESC]))
verdict("KCOS_EXEC entry that is not a plain path", on_tty(BASE + ["-t", "-e", "KCOS_EXEC=x" + ESC, "kcontaineros", "true"]))
verdict("KCOS_EXEC entry that is not a directory", on_tty(BASE + ["-t", "-e", "KCOS_EXEC=/no" + ESC, "kcontaineros", "true"]))
verdict("KCOS_EXEC entry in /dev", on_tty(BASE + ["-t", "-e", "KCOS_EXEC=/dev/" + ESC, "kcontaineros", "true"]))
verdict("KCOS_DEV entry", on_tty(BASE + ["-t", "-e", "KCOS_DEV=/dev/" + ESC + ":rel" + ESC, "kcontaineros", "true"]))
verdict("600-byte entry (crosses init's 512-byte buffer)", on_tty(BASE + ["-t", "-e", "KCOS_EXEC=" + ("A" * 505 + ESC) * 2, "kcontaineros", "true"]))

print("## init's own messages without -t: docker hands the container's stderr to the operator's terminal")
p = subprocess.run(BASE + ["-e", "KCOS_EXEC=x" + ESC, "kcontaineros", "true"], capture_output=True)
if raw(p.stderr):
    print(f"  NOTE     without -t init's warning carries the bytes of KCOS_EXEC unchanged: {p.stderr!r}")
data = on_tty(BASE + ["-e", "KCOS_EXEC=x" + ESC, "kcontaineros", "true"])
verdict("warning about KCOS_EXEC, docker run without -t, started from a terminal", data)

# Shell and utilities, under init, in the release image. E holds the bytes.
CASES = [
    ("command not found", 'nosuch"$E"'),
    ("path not found", '"/nosuch$E/x"'),
    ("cd", 'cd "/nosuch$E"'),
    ("redirection", 'true > "/nosuch$E/f"'),
    ("sh FILE", 'sh "/nosuch$E"'),
    ("cat", 'cat "/nosuch$E"'), ("ls", 'ls "/nosuch$E"'), ("rm", 'rm "/nosuch$E"'),
    ("cp", 'cp "/nosuch$E" "/tmp/x$E"'), ("mv", 'mv "/nosuch$E" /tmp/y'), ("ln", 'ln "/nosuch$E" /tmp/z'),
    ("mkdir", 'mkdir "/nosuch$E/a"'), ("touch", 'touch "/nosuch$E/a"'), ("chmod", 'chmod 644 "/nosuch$E"'),
    ("chmod mode", 'chmod "$E" /tmp'), ("chown", 'chown 1:1 "/nosuch$E"'), ("chown owner", 'chown "$E" /tmp'),
    ("kill pid", 'kill "$E"'), ("kill signal", 'kill -s "$E" 1'), ("sleep", 'sleep "$E"'),
    ("uname option", 'uname "-$E"'), ("env option", 'env "-$E"'), ("env command", 'env "$E"'), ("ls option", 'ls "-$E"'),
    ("rm option", 'rm "-$E"'), ("ps option", 'ps "-$E"'), ("pwd arg", 'pwd "$E"'),
    ("export", 'export "$E=1"'), ("wait", 'wait "$E"'), ("wait option", 'wait "-$E"'), ("umask", 'umask "$E"'),
    ("command option", 'command "-$E"'), ("unknown applet", 'kcontaineros "$E"'),
    ("set -x trace", 'set -x; : "$E"; set +x'),
    ("ls of a hostile name", 'mkdir "/tmp/d$E"; touch "/tmp/d$E/f$E"; ln -s "t$E" "/tmp/d$E/l"; ls /tmp; ls -l "/tmp/d$E"'),
    ("pwd in a hostile directory", 'cd "/tmp/d$E"; pwd; cd /'),
    ("ps with a hostile argument", 'sleep 2 "$E" 2>/dev/null & ps'),
    # builtins that print a name somebody else chose, as pwd and ls do
    ("cd - (prints the directory)", 'cd "/tmp/d$E"; cd /; cd -; cd /'),
    ("command -v (prints the path)", 'cp /bin/kcontaineros "/tmp/d$E/tool"; chmod 755 "/tmp/d$E/tool"; command -v "/tmp/d$E/tool" 2>&1; PATH="/tmp/d$E" command -v tool'),
]
DATA = [
    ("env (prints the environment)", 'env'),
    ("echo (prints its arguments)", 'echo "$E"'),
]
LAST = [("bad descriptor (ends the script)", ': 3>&"$E"'), ("shift (ends the script)", 'shift "$E"'), ("unset option (ends the script)", 'unset "-$E"'),
        ("exit (ends the script)", 'exit "$E"'), ("sh option", 'sh "-$E"'), ("set option", 'set "-$E"')]
script = "".join(f'/bin/echo "@""@{i}"; {c}\n' for i, (_, c) in enumerate(CASES + DATA))
out = on_tty(BASE + ["-t", "-e", "E=" + ESC, "kcontaineros", "sh", "-c", script], wait=40)
parts = out.split(b"@@")[1:]
print(f"## the shell and the utilities under init, on a terminal: {len(parts)} of {len(CASES + DATA)} cases ran")
for part in parts:
    num, _, body = part.partition(b"\n")
    i = int(num.strip())
    name = (CASES + DATA)[i][0]
    verdict(name, body, expect_clean=i < len(CASES))
for name, c in LAST:
    verdict(name, on_tty(BASE + ["-t", "-e", "E=" + ESC, "kcontaineros", "sh", "-c", c]))

print("## the interactive prompt in a hostile directory")
setup = 'mkdir "/tmp/d$E"; cd "/tmp/d$E"; exec sh'
out = on_tty(BASE + ["-it", "-e", "E=" + ESC, "kcontaineros", "sh", "-c", setup], typed=["true\n", "exit\n"], wait=12)
verdict("prompt", out)
print(f"\n== 04-terminal.py: {held} held, {findings} finding(s)")
