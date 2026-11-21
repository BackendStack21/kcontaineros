#!/usr/bin/env python3
"""Run a command on a pseudo-terminal, type the given strings into it, and
print everything it wrote followed by "[exit N]".

    term.py 'echo hi\n' '\x03' -- docker run -it --rm kcontaineros

Each string is typed after the previous one has had time to take effect.
Escapes such as \\n, \\x03 (Ctrl-C) and \\x1a (Ctrl-Z) are understood.
"""
import os
import pty
import select
import sys
import time

STARTUP = 2.0   # seconds to let the command start
STEP = 0.5      # seconds between inputs
LIMIT = 15.0    # seconds to wait for it to exit afterwards


def main():
    argv = sys.argv[1:]
    split = argv.index("--")
    inputs, command = argv[:split], argv[split + 1:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)

    output = bytearray()

    def pump(seconds):
        """Collect output for a while; False once the command has gone."""
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if not ready:
                continue
            try:
                data = os.read(fd, 4096)
            except OSError:
                return False
            if not data:
                return False
            output.extend(data)
        return True

    alive = pump(STARTUP)
    for text in inputs:
        if not alive:
            break
        os.write(fd, text.encode().decode("unicode_escape").encode("latin1"))
        alive = pump(STEP)
    deadline = time.time() + LIMIT
    while alive and time.time() < deadline:
        alive = pump(0.2)
    if alive:
        os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)
    sys.stdout.buffer.write(bytes(output).replace(b"\r\n", b"\n"))
    sys.stdout.flush()
    print("[exit %s]" % ("timeout" if alive else os.waitstatus_to_exitcode(status)))


if __name__ == "__main__":
    main()
