#!/usr/bin/env bash
# Builds the iOS Swift compiler library in stages, within a time budget.
# env: BOOTSTRAP_ROOT (Swift release usr dir), BUDGET_SECONDS, JOBS
# Exit: 0 all stages done, 124 out of time (safe to continue later via cache), 1 a stage failed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=$ROOT/ci-out; mkdir -p "$OUT"
BUILD=$ROOT/.build-compiler
START=$(date +%s)
BUDGET=${BUDGET_SECONDS:-17700}
JOBS=${JOBS:-3}
S=$OUT/STATUS.md
: > "$S"
say() { printf '%s\n' "$*" | tee -a "$S"; }
left() { echo $(( BUDGET - ($(date +%s) - START) )); }

# Heartbeat: every 25 minutes publish a snapshot of the logs, so a long build can be watched.
heartbeat() {
  while true; do
    sleep 1500
    {
      echo "snapshot: $(date -u +%FT%TZ)  elapsed: $(( $(date +%s) - START ))s  disk: $(df -h / | tail -1 | awk '{print $4" free"}')"
      for f in "$OUT"/*.log; do
        [ -f "$f" ] && { echo "--- $(basename "$f") (last 25 lines)"; tail -25 "$f" | cut -c1-300; }
      done
    } > "$OUT/progress.txt" 2>&1
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      mkdir -p "$OUT/../ci-live" && cp "$S" "$OUT/progress.txt" "$OUT/../ci-live/" 2>/dev/null
      "$HERE/push-logs.sh" "$OUT/../ci-live" "${LOG_LABEL:-live}-live" >/dev/null 2>&1
    fi
  done
}
heartbeat &
HEARTBEAT_PID=$!
trap 'kill $HEARTBEAT_PID 2>/dev/null' EXIT

say "# Compiler build status"
say "started: $(date -u +%FT%TZ)  budget: ${BUDGET}s  jobs: $JOBS"
say "bootstrap: $BOOTSTRAP_ROOT"
"$BOOTSTRAP_ROOT/bin/swiftc" --version 2>&1 | head -3 | tee -a "$S"
say "xcode: $(xcodebuild -version 2>&1 | tr '\n' ' ')"
say "disk: $(df -h / | tail -1)"

say ""; say "## configure"
cmake -S "$ROOT/compiler" -B "$BUILD" -G Ninja \
  -DBUILD_TESTING=OFF -DTOOLCHAIN_ENABLE_COMPILER_BUILD=ON \
  -DTOOLCHAIN_BOOTSTRAP_ROOT="$BOOTSTRAP_ROOT" -DTOOLCHAIN_BUILD_JOBS="$JOBS" \
  -DTOOLCHAIN_CACHE_ROOT="$BUILD/native" > "$OUT/configure.log" 2>&1
rc=$?
tail -40 "$OUT/configure.log" > "$OUT/configure.tail"
if [ $rc -ne 0 ]; then say "configure FAILED (rc=$rc)"; exit 1; fi
say "configure ok"

for stage in toolchain-sources host-tools llvm-ios cmark-ios swift-ios; do
  r=$(left)
  if [ "$r" -lt 240 ]; then say "## $stage: not started, out of time"; exit 124; fi
  say ""; say "## $stage (time left ${r}s, disk: $(df -h / | tail -1 | awk '{print $4" free"}'))"
  t0=$(date +%s)
  python3 "$HERE/run-limited.py" "$r" cmake --build "$BUILD" --target "$stage" --parallel 1 > "$OUT/$stage.log" 2>&1
  rc=$?
  dt=$(( $(date +%s) - t0 ))
  tail -150 "$OUT/$stage.log" > "$OUT/$stage.tail"
  if [ $rc -eq 124 ]; then
    say "$stage: out of time after ${dt}s (will continue from the compiler cache)"
    exit 124
  elif [ $rc -ne 0 ]; then
    say "$stage: FAILED rc=$rc after ${dt}s"
    grep -n -B3 -A25 -E "FAILED:|fatal error:|CMake Error|error:" "$OUT/$stage.log" | head -400 > "$OUT/$stage.errors"
    exit 1
  fi
  say "$stage: ok in ${dt}s"
done

say ""; say "## collect"
mkdir -p "$ROOT/dist"
BRIDGE=$(find "$BUILD" -name 'libSwiftCompilerBridge.dylib' | head -1)
[ -n "$BRIDGE" ] || { say "bridge dylib not found"; exit 1; }
cp "$BRIDGE" "$ROOT/dist/"
# macro plugins: the in-process plugin server and the macro libraries (built for iPhone, loaded by the compiler)
mkdir -p "$ROOT/dist/plugins"
EXTRA=()
for n in SwiftInProcPluginServer ObservationMacros SwiftMacros; do
  f=$(find "$BUILD" -name "lib$n.dylib" | head -1)
  if [ -n "$f" ]; then cp "$f" "$ROOT/dist/plugins/"; EXTRA+=("$f"); say "plugin: $n"; else say "plugin missing: $n"; fi
done
# every dylib depends on companion dylibs (@rpath/...): copy the whole closure next to the bridge
python3 - "$BUILD" "$ROOT/dist" "$BRIDGE" "${EXTRA[@]}" <<'PY' 2>&1 | tee -a "$S"
import os, shutil, subprocess, sys
build, dist, bridge = sys.argv[1:4]
extra = sys.argv[4:]
index = {}
for r, _, fs in os.walk(build):
    for f in fs:
        if f.endswith('.dylib'):
            index.setdefault(f, os.path.join(r, f))
todo = [bridge] + extra
seen = {os.path.basename(bridge)} | {os.path.basename(e) for e in extra}
missing = []; absolute = []
while todo:
    p = todo.pop()
    out = subprocess.run(['otool', '-L', p], capture_output=True, text=True).stdout.splitlines()[1:]
    for line in out:
        name = line.strip().split(' ')[0]
        if name.startswith(('@rpath/', '@loader_path/', '@executable_path/')):
            base = os.path.basename(name)
            if base in seen: continue
            seen.add(base)
            if base in index:
                shutil.copy(index[base], dist); todo.append(index[base]); print('bundled', base)
            else:
                missing.append(base)
        elif not name.startswith(('/usr/lib/', '/System/')):
            absolute.append(name)
print('missing:', missing or 'none')
print('non-system absolute deps:', sorted(set(absolute)) or 'none')
PY
ls -lh "$ROOT/dist" "$ROOT/dist/plugins" | tee -a "$S"
say "ALL STAGES DONE"
exit 0
