# Plan: building iOS apps on the iPhone itself

Test subject: [jakebway/tamaios](https://github.com/jakebway/tamaios).

Constraints from the owner: iPhone 16 Pro Max, iOS 27.3, **no JIT**, no Mac.
Everything below is ahead-of-time compilation plus normal signing.

## Idea

Only the Swift half of the app has to compile on the phone (about 9k lines, with `Bridge.h`).
The Rust emulator core (`ffi/` + `upstream/`) never compiles on the phone: CI keeps building
`libtamaios.a`, and the phone links it.

Pipeline on the phone:

1. `swift-frontend -c` (whole module, called in-process, not through the `swiftc` driver) -> `TamaiOS.o`
2. `ld64.lld` links `TamaiOS.o` + `libtamaios.a` against SDK stubs -> Mach-O executable
3. Write `Info.plist` (no variable substitution needed), copy firmware/assets, PNG icons
   (no `actool` on device, so either PNG icons in `CFBundleIcons` or a CI-built `Assets.car`)
4. Zip as `.ipa` and hand it to FlareStore (same as today). Later: on-device signing + install.

## Stages

| Stage | Goal | Needs JIT? |
|---|---|---|
| 0 | `.github/workflows/spike.yml`: measure compiler memory/time, SDK files read, lld link | no |
| 1 | CI publishes a trimmed SDK + toolchain pack (private release) | no |
| 2 | Compiler built as an iOS framework with `main()` exposed, run in-process on a big-stack thread | no |
| 3 | Minimal host app: pick folder, compile, show diagnostics, write IPA | no |
| 4 | Optional: on-device signing and install (zsign-style signer, `idevice` installation_proxy) | no |

## Known risks

- Swift frontend memory on SwiftUI code (unmeasured; stage 0 measures it). May need the
  increased-memory-limit entitlement, which the signing method has to be able to grant.
- The compiler version must match the SDK's `.swiftinterface` files (build the compiler from the
  Swift tag that matches the CI runner's Xcode).
- The SDK is Apple's; keep the packed copy private.
- Stock iOS has no `fork`/`exec`, so everything runs as function calls inside one process.
