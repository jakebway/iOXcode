"""Run a command in its own process group with a time limit; exit 124 on timeout (like timeout(1)).

usage: run-limited.py <seconds> <command> [args...]
Kills the whole group (cmake, ninja, compilers) so nothing keeps running after the limit.
"""
import os
import signal
import subprocess
import sys

limit = int(sys.argv[1])
cmd = sys.argv[2:]
proc = subprocess.Popen(cmd, start_new_session=True)
try:
    sys.exit(proc.wait(timeout=max(limit, 1)))
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=90)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
    sys.exit(124)
