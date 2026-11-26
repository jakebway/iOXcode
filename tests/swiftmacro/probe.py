"""Talks the compiler's plugin protocol to a wasm macro plugin run by node (WASI) and prints what comes back."""
import json, struct, subprocess, sys

wasm = sys.argv[1]
p = subprocess.Popen(["node", "--no-warnings", "/tmp/plugin-host.js", wasm], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
msg = json.dumps({"getCapability": {}}).encode()
p.stdin.write(struct.pack("<Q", len(msg)) + msg)
p.stdin.flush()
head = p.stdout.read(8)
print(wasm, "reply header:", head)
if len(head) == 8:
    n = struct.unpack("<Q", head)[0]
    print("reply:", p.stdout.read(n)[:400])
try:
    p.stdin.close()
except Exception:
    pass
try:
    p.wait(timeout=30)
except Exception as e:
    p.kill()
    print("timeout", e)
print("exit code:", p.returncode)
print("stderr:", p.stderr.read()[:2000].decode("utf-8", "replace"))
