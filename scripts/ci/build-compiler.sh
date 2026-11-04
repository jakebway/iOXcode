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
find "$BUILD" -name 'libSwiftCompilerBridge.dylib' -print -exec cp {} "$ROOT/dist/" \; | tee -a "$S"
ls -lh "$ROOT/dist" | tee -a "$S"
say "ALL STAGES DONE"
exit 0
