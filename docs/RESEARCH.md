# Research notes (what exists, what others found)

## Swift macros on device
- Swift (since 6.0) runs *library plugins* through an in-process plugin server:
  `libSwiftInProcPluginServer.dylib` + `-in-process-plugin-server-path` (swiftlang/swift#73725). The compiler keeps its
  own copy of swift-syntax; plugins use a separate copy, so both sets of dylibs have to be bundled.
- Our compiler build already restricts plugin loading to frameworks inside the app
  (`swift_toolchain_copy_bundled_plugin_path`). So macros ship as `Frameworks/<Name>.framework/<Name>`.
- OSS macro libraries: `ObservationMacros` (@Observable), `SwiftMacros` (@TaskLocal, @OptionSet, #externalMacro users).
- Not available: `PreviewsMacros` (#Preview) and SwiftData's macros ship only inside Xcode. #Preview blocks are
  stripped before compiling. SwiftData (@Model) cannot work until someone re-implements those macros.

## Rust on device
- rustc refuses to produce dylibs for *-ios targets, but flipping `dynamic_linking` in the target spec is enough
  (internals.rust-lang.org "Embedding rustc on iOS"). rustc_driver can then be built as an iOS dylib.
- cargo spawns rustc/build scripts as processes: needs an in-process "mini cargo" (ioxcargo) calling rustc_driver.
- build.rs programs can't run (they are compiled host programs). Common ones (cc, cmake-less) need special cases.
- Alternative for pure `staticlib` crates: rustc -> LLVM IR/bitcode -> our in-process LLVM/clang/lld.

## Others on iPhone
- Bitrig / Swifty Compiler: interpreters (Swift parsed and mapped to compiled framework calls); no native codegen.
- Our approach is the first we know of that runs the real Swift frontend, clang and lld in-process.
