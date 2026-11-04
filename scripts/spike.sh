#!/usr/bin/env bash
# Measures what an on-device Swift compile of TamaiOS would need.
# Runs on any macOS machine with Xcode (Codemagic, GitHub Actions, a Mac).
# Never fails the build: the numbers are the product. Results: tamaios/out/SUMMARY.md
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REF=${TAMAIOS_REF:-main}

[ -d tamaios ] || git clone --depth 1 --branch "$REF" https://github.com/jakebway/tamaios tamaios
cd tamaios
mkdir -p out
S=out/SUMMARY.md
: > "$S"
say() { printf '%s\n' "$*" | tee -a "$S"; }

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SDKV=$(xcrun --sdk iphoneos --show-sdk-version)
FE=$(xcrun -f swift-frontend)
TC=$(dirname "$(dirname "$FE")")

say "# Toolchain"
{
  xcodebuild -version
  swift --version 2>&1
  echo "machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null) / $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"
  echo "SDK: $SDK ($SDKV)"
  ls -lh "$FE" "$(xcrun -f clang)"
  echo "clang resource headers: $(du -sh "$TC/lib/clang" | cut -f1)"
  echo "swift lib dir: $(du -sh "$TC/lib/swift" | cut -f1)"
  echo "full iPhoneOS SDK: $(du -sh "$SDK" | cut -f1)"
} 2>&1 | tee -a "$S"

say ""
say "# Rust core (prebuilt in the real pipeline; only needed here for the link test)"
(
  set -e
  if ! command -v cargo >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    . "$HOME/.cargo/env"
  fi
  [ -d upstream ] || git clone https://github.com/oreo-fox/tg18-emu upstream
  git -C upstream checkout 41204c92e98a8882d5c90a9876d8990f3b63e285
  git -C upstream apply ../patches/radio.patch 2>/dev/null || git -C upstream apply ../patches/radio.patch --check -R
  git -C upstream apply ../patches/ir_partner.patch 2>/dev/null || git -C upstream apply ../patches/ir_partner.patch --check -R
  rustup target add aarch64-apple-ios
  (cd ffi && IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build --release --target aarch64-apple-ios)
  mkdir -p ios/lib
  cp ffi/target/aarch64-apple-ios/release/libtamaios.a ios/lib/
  ls -lh ios/lib/
) 2>&1 | tail -15 | tee -a "$S"

say ""
say "# Compile only the Swift (what the phone would do). 'maximum resident set size' is bytes."
SRC=$(find ios/TamaiOS -name '*.swift' | sort)
say "swift files: $(echo "$SRC" | wc -l | tr -d ' ')"
run() { # name, optimisation flag, cold|warm
  local name=$1 flags=$2 fresh=$3
  [ "$fresh" = "cold" ] && rm -rf out/mc
  /usr/bin/time -l swiftc -wmo $flags -parse-as-library -swift-version 5 \
    -target arm64-apple-ios16.0 -sdk "$SDK" \
    -import-objc-header ios/TamaiOS/Bridge.h -module-name TamaiOS \
    -module-cache-path out/mc -emit-object -o "out/$name.o" \
    -emit-loaded-module-trace-path "out/$name.trace.json" \
    $SRC > "out/$name.log" 2> "out/$name.time"
  local rc=$?
  {
    echo "== $name ($fresh module cache) exit=$rc =="
    grep -E "real|maximum resident set size|peak memory footprint" "out/$name.time"
    tail -3 "out/$name.log"
  } | tee -a "$S"
}
run Onone-cold "-Onone" cold
run Onone-warm "-Onone" warm
run O-cold "-O" cold
run O-warm "-O" warm

say ""
say "# SDK folders the compile read"
python3 "$HERE/sdk_needed.py" "$SDK" out/O-cold.trace.json 2>&1 | tee -a "$S"

say ""
say "# Link with lld (open-source Mach-O linker)"
(
  brew install lld 2>&1 | tail -2
  LLD=$(brew --prefix lld)/bin/ld64.lld
  ls -l "$LLD"
  "$LLD" -arch arm64 -platform_version ios 16.0 "$SDKV" -syslibroot "$SDK" \
    -L "$SDK/usr/lib/swift" -L "$TC/lib/swift/iphoneos" -L "$TC/lib/swift-5.0/iphoneos" \
    -L ios/lib -ltamaios -lSystem -lc++ -rpath /usr/lib/swift -rpath @executable_path/Frameworks \
    -dead_strip -e _main out/O-cold.o -o out/TamaiOS.bin 2>&1 | tail -30
  echo "lld exit: ${PIPESTATUS[0]}"
  ls -lh out/TamaiOS.bin 2>&1
  file out/TamaiOS.bin 2>&1
) 2>&1 | tee -a "$S"

echo
echo "================ SUMMARY (copy this) ================"
cat "$S"
exit 0
