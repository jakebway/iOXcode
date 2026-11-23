# iOXcode work order: everything that stands between iOXcode and Xcode

Goal: building on the phone gives the same result Xcode / a GitHub macOS runner gives, for any repo.
Tags: [EMULATE] we know the behavior and write it. [REVERSE] closed format; a Mac runner is the oracle. [WORKAROUND] the real tool cannot exist on iPhone.
Status: done / building (pushed, not yet verified on device) / todo.

## A. Proof and measurement (do first, everything else is checked by it)
1. Fidelity harness: a Mac-runner job builds a repo with real xcodebuild and with iOXcode's own pipeline (iOXcode runs in the iOS Simulator, binaries retagged for it), then diffs the .app trees: Info.plist, Mach-O load commands, Assets.car, nibs, strings, embedded frameworks. [EMULATE/REVERSE] todo (#29)
2. Test ladder run through the harness: OldOS, NetNewsWire, kiwix-apple, wikipedia-ios, TamaiOS, SwiftUI-Kit, sample-food-truck, MovieSwiftUI, sample-backyard-birds. todo
3. `xcodebuild -showBuildSettings` as the oracle for the build-setting engine (B1). todo

## B. Build system
1. Build-setting engine: the real Xcode rules ($(VAR:modifier), $(inherited), xcconfig chains, per-configuration and conditional values, project/target/xcconfig/environment precedence). Replaces the ad-hoc expansion. [EMULATE] todo
2. Configurations and schemes: Debug/Release choice, .xcscheme (build/test/archive actions, pre/post actions, environment, arguments), test plans. [EMULATE] todo
3. Workspaces: .xcworkspace with several projects, cross-project target dependencies. [EMULATE] todo
4. .swiftpm app packages (AppleProductTypes iOSApplication), Package.swift-only apps, code-appended Package.swift settings (upcoming features, defines). [EMULATE] todo
5. Incremental builds: per-file compile cache, cached package modules keyed by hash, batch mode, parallel frontends, memory splitting for big projects. [EMULATE] todo
6. Run Script phases with input/output files and dependency analysis; Copy Files phases; Embed Frameworks as real dynamic frameworks (Bundle(for:) fidelity); Embed Foundation Extensions. [EMULATE] partly done (extensions, static frameworks)
7. Archive / export: .xcarchive, exportOptions.plist, IPA variants, App Store Connect upload through its REST API. [REVERSE] todo
8. Mixed Swift/Objective-C frameworks: umbrella headers, module maps, framework-style imports (<Framework/Header.h>). [EMULATE] todo
9. C++ interop (-cxx-interoperability-mode), prefix headers/PCH, .s assembly, Objective-C++ modules. [EMULATE] verify (#24)
10. Package build-tool plugins and command plugins; SwiftPM resource rules (.process / .copy / .embedInCode). [WORKAROUND via D] todo

## C. Resource and asset compilers (Xcode's "tools")
1. Asset catalogs: generated asset symbols (Image(.foo), Color(.bar)), appearance/contrast/P3 variants, data sets, sticker packs, Icon Composer .icon bundles (iOS 26). [EMULATE/REVERSE] partly done
2. Interface Builder: ibc ported (storyboards, xibs). Remaining: diff against ibtool on the whole corpus, storyboard references, segues, size-class variants, IBDesignable, image/color references. [REVERSE] building (#21)
3. Localization: .xcstrings compiled (building); .strings/.stringsdict encoding, InfoPlist.strings, export/import XLIFF. [EMULATE] partly done
4. Core ML: compile done (building); generated model classes. [EMULATE] todo
5. App Intents: Metadata.appintents (extract.actionsdata) from compiler const-values; .intentdefinition generated classes. [REVERSE] todo (#22)
6. Metal: ship .metal sources and make makeDefaultLibrary() compile from source at run time. [WORKAROUND] todo
7. SceneKit scntool, RealityKit/.rcproject/.usdz, Core Data mapping models, .xcprivacy aggregation, DocC. [REVERSE] todo
8. Info.plist: full parity of generated keys and their values with Xcode for every INFOPLIST_KEY_*, DT* build keys. [EMULATE] mostly done
9. Widgets, extensions, watchOS apps, App Clips, Messages/sticker extensions: extensions done (building); watch app/App Clip todo (#22). [EMULATE]

## D. Running code at build time (the wall: nothing compiled on the phone can be loaded)
1. WebAssembly host: embed an interpreter (WasmKit, pure Swift, no JIT; wasm3 as the fast fallback) with WASI. Compile host-side code to wasm32-wasip1 and interpret it. [WORKAROUND] spike running (wasm-spike.yml)
2. Wasm backends in our compilers: the iPhone Swift compiler is built with the AArch64 backend only (needs WebAssembly + lld wasm); rustc needs wasm32-wasip1 std + a wasm linker. [EMULATE] todo
3. Swift macros: third-party macros built to wasm and hosted through the compiler's plugin protocol (Wacro shows the approach); keep prebuilt first-party macros. [WORKAROUND] todo
4. Rust: build scripts and proc macros as wasm (replaces the fixed prebuilt set); linking bin/cdylib; code-appended features. [WORKAROUND] in progress (#26); today 38 prebuilt macros
5. Build tools run by repos (SwiftGen, Sourcery, SwiftLint, protoc, jq, ripgrep ...): prebuilt in CI as wasm or ported to Python. [WORKAROUND] todo
6. Scripting languages some repos use: Ruby (mruby), Node (JavaScriptCore subset), shell (done). [WORKAROUND] todo
7. More shell tools Mac runners have (plutil/PlistBuddy/awk/cut ... done; zsh, perl subset, sqlite3, openssl, lipo, install_name_tool, otool, nm, vtool, strings, file, xattr). [EMULATE] partly done

## E. Dependencies and project formats
1. CocoaPods: resolve through the CDN's JSON podspecs, download sources, build as modules, generate Pods-*.xcconfig and resource scripts. [EMULATE] todo
2. Carthage: prebuilt xcframeworks; xcframework slice selection and linking; binary targets. [EMULATE] todo
3. Tuist and other generators (Project.swift), XcodeGen include/templates/schemes, Bazel-free only. [EMULATE] partly done
4. Git submodules and LFS (zip downloads today): real fetch of submodule repos at the pinned commits, LFS pointers resolved. [EMULATE] todo
5. Private repositories and tokens; GitHub Enterprise URLs. todo

## F. GitHub-in-the-app
1. Workflow runner: multi-job (needs:), matrix expansion, reusable workflows, local composite actions, common marketplace actions emulated (setup-*, cache, upload/download-artifact, gh-release). [EMULATE] partly done
2. Remote repo browse, diff, commit, push, search, branches, PRs, releases (#25). todo
3. Releases per repo with README card (done); publishing releases from the app. partly done
4. Automatic re-fetch of imported repos (done).

## G. Platform limits and device work
1. Background builds that survive leaving the app; thermal and memory handling (jetsam); build cancel/resume. todo
2. Signing handoff: entitlements, app groups/keychain rewriting for sideload, FlareStore install flow. [WORKAROUND] todo
3. Foldable (iPhone Duo) layout polish (#27). todo
4. SDK pack: one-button import, newer SDK packs, link-free pack builder in the private SDK repo. partly done

## H. Languages
1. Swift (done), Objective-C/C/C++ (done, verify C++ heavy repos), Rust (in progress), assembly, Swift C++ interop, Swift embedded-mode flags. todo/in progress
2. Testing: XCTest / Swift Testing build (and run in-process where the framework allows). [WORKAROUND] todo
