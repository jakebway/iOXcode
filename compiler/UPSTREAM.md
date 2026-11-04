# Where this comes from

The recipes in this folder are derived from
[mozharovsky/swift-toolchain-ios](https://github.com/mozharovsky/swift-toolchain-ios) (Apache-2.0),
which builds the Swift frontend, Clang and LLD as an iOS library behind a small C interface and
patches LLVM/Swift so they run inside an app (no subprocesses, no executable memory, no JIT).

What iOXcode changes:

- the compiler emits **arm64 iOS programs** (LLVM `AArch64` backend, Mach-O linker `lldMachO`)
  instead of WebAssembly
- the WebAssembly SDK, guest packaging and the LLVM stackify backport are dropped
- the bridge's `swift_compiler_link` runs the Mach-O LLD driver (`ld64.lld`)
- the producer's self-tests and artifact packaging are left out; CI and the host app replace them

The pinned upstream revisions are in `Toolchain.lock.json`. LLVM and Swift licenses are in `Licenses/`.
The upstream project's own NOTICE is kept as `NOTICE.upstream`.
