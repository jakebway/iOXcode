# Spike results #1 (Codemagic, Mac mini M2 VM, 12 GB RAM, Xcode 26.6 / Swift 6.3.3, iPhoneOS 26.5 SDK)

Subject: jakebway/tamaios @ main (24 Swift files). Raw output below.

```
# Toolchain
Xcode 26.6
Build version 17F113
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
machine: Apple M2 (Virtual) / 12 GB RAM
SDK: /Applications/Xcode-26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk (26.5)
-rwxr-xr-x  1 builder  staff   135M Jun 16 07:57 /Applications/Xcode-26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
-rwxr-xr-x  1 builder  staff   163M Jun 16 07:57 /Applications/Xcode-26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
clang resource headers:  25M
swift lib dir: 512M
full iPhoneOS SDK:   0B

# Rust core (prebuilt in the real pipeline; only needed here for the link test)
   Compiling serde_core v1.0.229
   Compiling zmij v1.0.23
   Compiling serde v1.0.229
   Compiling serde_json v1.0.154
   Compiling memchr v2.8.3
   Compiling adler2 v2.0.1
   Compiling itoa v1.0.18
   Compiling miniz_oxide v0.8.9
   Compiling syn v3.0.9
   Compiling serde_derive v1.0.229
   Compiling tg18-core v0.1.0 (/Users/builder/clone/tamaios/upstream/core)
   Compiling tamaios-ffi v0.1.0 (/Users/builder/clone/tamaios/ffi)
    Finished `release` profile [optimized] target(s) in 12.49s
total 43232
-rw-r--r--  1 builder  staff    21M Nov  4 18:33 libtamaios.a

# Compile only the Swift (what the phone would do). 'maximum resident set size' is bytes.
swift files: 24
== Onone-cold (cold module cache) exit=0 ==
       20.52 real        17.42 user         1.24 sys
           698368000  maximum resident set size
             9766528  peak memory footprint
== Onone-warm (warm module cache) exit=0 ==
       14.85 real        14.46 user         0.36 sys
           638861312  maximum resident set size
             9782976  peak memory footprint
== O-cold (cold module cache) exit=0 ==
       32.40 real        31.53 user         0.83 sys
          1120059392  maximum resident set size
             9782976  peak memory footprint
== O-warm (warm module cache) exit=0 ==
       27.75 real        27.39 user         0.33 sys
          1051000832  maximum resident set size
             9750144  peak memory footprint

# SDK folders the compile read
     0.5 MB  System/Library/Frameworks/AVFAudio.framework
     0.1 MB  System/Library/Frameworks/Accessibility.framework
     1.2 MB  System/Library/Frameworks/AudioToolbox.framework
     0.9 MB  System/Library/Frameworks/Combine.framework
     0.6 MB  System/Library/Frameworks/CoreData.framework
     0.7 MB  System/Library/Frameworks/CoreGraphics.framework
     0.8 MB  System/Library/Frameworks/CoreML.framework
     0.5 MB  System/Library/Frameworks/CoreText.framework
     0.1 MB  System/Library/Frameworks/CoreTransferable.framework
     0.3 MB  System/Library/Frameworks/CoreVideo.framework
     0.1 MB  System/Library/Frameworks/DataDetection.framework
     0.1 MB  System/Library/Frameworks/DeveloperToolsSupport.framework
     0.4 MB  System/Library/Frameworks/ExtensionFoundation.framework
     0.3 MB  System/Library/Frameworks/FileProvider.framework
    10.3 MB  System/Library/Frameworks/Foundation.framework
     0.2 MB  System/Library/Frameworks/LightweightCodeRequirements.framework
     3.4 MB  System/Library/Frameworks/Network.framework
     0.2 MB  System/Library/Frameworks/Photos.framework
     0.2 MB  System/Library/Frameworks/PhotosUI.framework
     7.5 MB  System/Library/Frameworks/SwiftUI.framework
     9.4 MB  System/Library/Frameworks/SwiftUICore.framework
     0.1 MB  System/Library/Frameworks/Symbols.framework
     5.8 MB  System/Library/Frameworks/UIKit.framework
     1.4 MB  System/Library/Frameworks/Vision.framework
     0.1 MB  System/Library/Frameworks/_PhotosUI_SwiftUI.framework
     0.2 MB  usr/lib/swift/AVFoundation.swiftmodule
     2.0 MB  usr/lib/swift/Accelerate.swiftmodule
     0.0 MB  usr/lib/swift/CoreAudio.swiftmodule
     0.0 MB  usr/lib/swift/CoreFoundation.swiftmodule
     0.0 MB  usr/lib/swift/CoreImage.swiftmodule
     0.0 MB  usr/lib/swift/CoreLocation.swiftmodule
     0.0 MB  usr/lib/swift/CoreMIDI.swiftmodule
     0.5 MB  usr/lib/swift/CoreMedia.swiftmodule
     0.0 MB  usr/lib/swift/Darwin.swiftmodule
     0.1 MB  usr/lib/swift/Dispatch.swiftmodule
     0.1 MB  usr/lib/swift/Distributed.swiftmodule
     0.1 MB  usr/lib/swift/Metal.swiftmodule
     0.0 MB  usr/lib/swift/OSLog.swiftmodule
     0.0 MB  usr/lib/swift/ObjectiveC.swiftmodule
     0.0 MB  usr/lib/swift/Observation.swiftmodule
     0.0 MB  usr/lib/swift/QuartzCore.swiftmodule
     0.6 MB  usr/lib/swift/Spatial.swiftmodule
     6.5 MB  usr/lib/swift/Swift.swiftmodule
     0.5 MB  usr/lib/swift/Synchronization.swiftmodule
     0.2 MB  usr/lib/swift/System.swiftmodule
     0.1 MB  usr/lib/swift/UniformTypeIdentifiers.swiftmodule
     0.1 MB  usr/lib/swift/XPC.swiftmodule
     0.0 MB  usr/lib/swift/_Builtin_float.swiftmodule
     0.7 MB  usr/lib/swift/_Concurrency.swiftmodule
     0.0 MB  usr/lib/swift/_DarwinFoundation1.swiftmodule
     0.0 MB  usr/lib/swift/_DarwinFoundation2.swiftmodule
     0.0 MB  usr/lib/swift/_DarwinFoundation3.swiftmodule
     0.1 MB  usr/lib/swift/_StringProcessing.swiftmodule
     0.3 MB  usr/lib/swift/os.swiftmodule
     0.4 MB  usr/lib/swift/simd.swiftmodule

paths in the trace that live in the SDK: 55
sum of the folders touched: 57.8 MB
(lower bound: C headers and .tbd stubs read by the clang importer may be missing from the trace)

# Link with lld (open-source Mach-O linker)
Removing: /Users/builder/Library/Logs/Homebrew/ca-certificates... (64B)
Pruned 1 symbolic links and 1 directories from /opt/homebrew
lrwxr-xr-x  1 builder  admin  3 Nov  2 10:45 /opt/homebrew/opt/lld/bin/ld64.lld -> lld
lld exit: 0
-rwxr-xr-x  1 builder  staff   6.0M Nov  4 18:36 out/TamaiOS.bin
out/TamaiOS.bin: Mach-O 64-bit executable arm64
```

Note: the 'full iPhoneOS SDK: 0B' line is a script bug (du on a symlink); ignore it.
