"""Sum the size of the SDK folders that a compile actually read (from swiftc's loaded-module trace).

usage: python3 sdk_needed.py <sdk path> <trace.json>
"""
import json
import os
import sys

sdk = os.path.realpath(sys.argv[1])
trace = sys.argv[2]
seen = set()


def walk(x):
    if isinstance(x, str):
        if x.startswith("/"):
            seen.add(x)
    elif isinstance(x, list):
        for y in x:
            walk(y)
    elif isinstance(x, dict):
        for y in x.values():
            walk(y)


try:
    for line in open(trace).read().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            walk(json.loads(line))
        except Exception:
            continue
except Exception as e:
    print("trace not readable:", e)


def size(path):
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    for r, _, fs in os.walk(path):
        for f in fs:
            try:
                total += os.path.getsize(os.path.join(r, f))
            except OSError:
                pass
    return total


roots = {}
for p in seen:
    rp = os.path.realpath(p)
    if not rp.startswith(sdk):
        continue
    rel = os.path.relpath(rp, sdk)
    parts = rel.split(os.sep)
    if rel.startswith("System/Library/Frameworks") and len(parts) >= 4:
        key = os.sep.join(parts[:4])
    elif rel.startswith("usr/lib/swift") and len(parts) >= 4:
        key = os.sep.join(parts[:4])
    else:
        key = os.sep.join(parts[:3])
    roots[key] = os.path.join(sdk, key)

total = 0
for k in sorted(roots):
    s = size(roots[k])
    total += s
    print(f"{s / 1e6:8.1f} MB  {k}")
print(f"\npaths in the trace that live in the SDK: {len(seen)}")
print(f"sum of the folders touched: {total / 1e6:.1f} MB")
print("(lower bound: C headers and .tbd stubs read by the clang importer may be missing from the trace)")
