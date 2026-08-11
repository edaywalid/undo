#!/usr/bin/env python3
"""Drive an interactive shell through a pty, answering the terminal
queries reedline blocks on. Usage: drive.py <timeout> <cmd...> < commands"""
import os, pty, select, sys, time

timeout = float(sys.argv[1])
argv = sys.argv[2:]
cmds = [l.rstrip("\n") for l in sys.stdin.read().splitlines() if l.strip()]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

out = bytearray()
deadline = time.time() + timeout
idle_since = time.time()
sent = 0
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.15)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out += data
        idle_since = time.time()
        # reedline asks for the cursor position and waits for the reply;
        # a pipe never sends one, so the prompt loops and input is dropped
        if b"\x1b[6n" in data:
            os.write(fd, b"\x1b[1;1R")
    elif time.time() - idle_since > 0.6:
        if sent < len(cmds):
            os.write(fd, cmds[sent].encode() + b"\r")
            sent += 1
            idle_since = time.time()
        elif time.time() - idle_since > 2.0:
            break

os.close(fd)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.stdout.write(out.decode("utf-8", "replace"))
