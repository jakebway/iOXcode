import Foundation
import UIKit

struct SDKLayout {
    let sdk: URL            // iPhoneOS.sdk
    let swiftResource: URL  // usr/lib/swift  (shims, iphoneos stdlib modules)
    let clangResource: URL? // usr/lib/clang/<version>

    static func locate() -> SDKLayout? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Paths.sdkRoot, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return nil }
        var sdk: URL?
        var swift: URL?
        var clang: URL?
        for case let u as URL in en {
            let p = u.path
            if sdk == nil, u.lastPathComponent.hasSuffix(".sdk"), u.lastPathComponent.hasPrefix("iPhoneOS") { sdk = u; en.skipDescendants(); continue }
            if swift == nil, p.hasSuffix("usr/lib/swift"), fm.fileExists(atPath: p + "/iphoneos") { swift = u; en.skipDescendants(); continue }
            if clang == nil, p.hasSuffix("usr/lib/clang") {
                let vs = (try? fm.contentsOfDirectory(atPath: p)) ?? []
                if let v = vs.sorted().last { clang = u.appendingPathComponent(v) }
                en.skipDescendants()
            }
        }
        guard let s = sdk, let sw = swift else { return nil }
        return SDKLayout(sdk: s, swiftResource: sw, clangResource: clang)
    }

    /// Says what is missing, for the Setup screen.
    static func problem() -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Paths.sdkRoot, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return "No SDK pack imported yet" }
        var hasSDK = false, hasSwift = false
        for case let u as URL in en {
            if u.lastPathComponent.hasPrefix("iPhoneOS"), u.lastPathComponent.hasSuffix(".sdk") { hasSDK = true; en.skipDescendants(); continue }
            if u.path.hasSuffix("usr/lib/swift"), fm.fileExists(atPath: u.path + "/iphoneos") { hasSwift = true }
        }
        if !hasSDK { return "The zip has no iPhoneOS.sdk folder" }
        if !hasSwift { return "The zip has no usr/lib/swift/iphoneos folder" }
        return nil
    }
}

enum BuildError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let s) = self { return s }; return "error" }
}

final class BuildPipeline {
    let project: Project
    let log: LogSink
    /// Resource bundles that Swift package targets expect next to the executable (Bundle.module): name -> files/folders.
    var packageResourceBundles: [(name: String, sources: [URL])] = []
    /// `-Xcc` arguments that let Swift import the C modules of the packages.
    var packageCArgs: [String] = []
    var packageCCompiler: CCompiler?
    init(project: Project, log: LogSink) { self.project = project; self.log = log }

    /// Returns the finished .ipa.
    static let runtimeShim = """
    import Foundation

    @_cdecl("__isPlatformVersionAtLeast")
    public func iox_isPlatformVersionAtLeast(_ platform: UInt32, _ major: UInt32, _ minor: UInt32, _ sub: UInt32) -> Int32 {
        // platform 2 is iOS; any other platform is not what this device runs, so answer "yes"
        guard platform == 2 else { return 1 }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let cur = (v.majorVersion, v.minorVersion, v.patchVersion)
        let want = (Int(major), Int(minor), Int(sub))
        if cur.0 != want.0 { return cur.0 > want.0 ? 1 : 0 }
        if cur.1 != want.1 { return cur.1 > want.1 ? 1 : 0 }
        return cur.2 >= want.2 ? 1 : 0
    }

    @_cdecl("__isOSVersionAtLeast")
    public func iox_isOSVersionAtLeast(_ major: Int32, _ minor: Int32, _ sub: Int32) -> Int32 {
        return iox_isPlatformVersionAtLeast(2, UInt32(max(major, 0)), UInt32(max(minor, 0)), UInt32(max(sub, 0)))
    }
    """

    func run() throws -> URL {
        let fm = FileManager.default
        Generator.refresh(project, log: log)
        let m = project.manifest
        let t0 = Date()
        log.log("== Building \(m.name) (\(m.bundleId))")
        log.log("memory available: \(CompilerHost.shared.availableMemoryMB) MB")

        if let err = CompilerHost.shared.load() { throw BuildError.message(err) }
        guard let layout = SDKLayout.locate() else {
            throw BuildError.message("No iPhone SDK found. Open Setup and import the SDK pack first.")
        }
        let work = Paths.work.appendingPathComponent(m.name, isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let app = work.appendingPathComponent("Payload/\(m.name).app", isDirectory: true)
        try runScripts(m.scripts.filter { !$0.afterCompile }, m: m, app: app, work: work, layout: layout)

        let files = project.swiftFiles(for: m)
        guard !files.isEmpty else {
            if let listed = m.swiftFiles, !listed.isEmpty {
                throw BuildError.message("The project file lists \(listed.count) Swift files (for example \(listed[0])) but they are not in what you imported. Import the whole folder: the source files and the .xcodeproj together.")
            }
            let kids = ((try? fm.contentsOfDirectory(atPath: project.url.path)) ?? []).sorted()
            let shown = kids.prefix(12).joined(separator: ", ")
            throw BuildError.message("No .swift files and no .xcodeproj found. The imported folder contains: \(kids.isEmpty ? "nothing" : shown). Import the folder that holds your Swift files or the .xcodeproj.")
        }
        log.log("\(files.count) Swift files, SDK \(layout.sdk.lastPathComponent)")
        for w in project.warnings { log.log("note: \(w)") }

        let moduleCache = Paths.caches.appendingPathComponent("ModuleCache", isDirectory: true)
        // Compiled modules remember the timestamps of the SDK files they were built from. When the SDK pack was
        // replaced, start from an empty cache.
        let stampFile = Paths.caches.appendingPathComponent("ModuleCache.sdkstamp")
        let probe = layout.sdk.appendingPathComponent("usr/include/AvailabilityInternal.h")
        let mtime = ((try? fm.attributesOfItem(atPath: probe.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(layout.sdk.path) \(Int(mtime))"
        if (try? String(contentsOf: stampFile, encoding: .utf8)) != stamp {
            try? fm.removeItem(at: moduleCache)
            try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: moduleCache, withIntermediateDirectories: true)

        // 1. compile all Swift to one object (whole module)
        let obj = work.appendingPathComponent("\(m.name).o")
        let target = "arm64-apple-ios\(m.minOS)"
        // A resource directory made of the pack's Swift files plus clang headers that match THIS compiler (clang 21).
        let resourceDir = work.appendingPathComponent("resource-dir", isDirectory: true)
        try fm.createDirectory(at: resourceDir, withIntermediateDirectories: true)
        for entry in (try? fm.contentsOfDirectory(atPath: layout.swiftResource.path)) ?? [] where entry != "clang" {
            try? fm.createSymbolicLink(atPath: resourceDir.appendingPathComponent(entry).path,
                                       withDestinationPath: layout.swiftResource.appendingPathComponent(entry).path)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("ClangResource")
        let clangDir: URL? = fm.fileExists(atPath: bundled.appendingPathComponent("include/arm_neon.h").path) ? bundled : layout.clangResource
        if let c = clangDir {
            try? fm.createSymbolicLink(atPath: resourceDir.appendingPathComponent("clang").path, withDestinationPath: c.path)
            log.log("clang headers: \(c == bundled ? "built-in (matching)" : "from the SDK pack (may not match)")")
        }
        // Swift packages: compile each module (dependencies first) into .o + .swiftmodule
        var packageObjects: [URL] = []
        let moduleDir = work.appendingPathComponent("modules", isDirectory: true)
        let commonArgs: [String] = ["-target", target, "-sdk", layout.sdk.path,
               "-parse-as-library",
               "-resource-dir", resourceDir.path,
               "-module-cache-path", moduleCache.path,
               "-enable-objc-interop", "-no-color-diagnostics",
               "-Xllvm", "-aarch64-use-tbi", "-empty-abi-descriptor", "-disable-clang-spi",
               "-no-auto-bridging-header-chaining", "-enable-cross-import-overlays",
               "-target-sdk-version", sdkVersion(layout.sdk), "-target-sdk-name", "iphoneos" + sdkVersion(layout.sdk)]
        if !m.packages.isEmpty {
            packageCCompiler = CCompiler(log: log, sdk: layout.sdk, clangResource: clangDir, target: target, moduleCache: moduleCache)
            try fm.createDirectory(at: moduleDir, withIntermediateDirectories: true)
            packageObjects = try buildPackages(m, work: work, moduleDir: moduleDir, common: commonArgs)
        }
        // C / Objective-C / C++ of the app itself, compiled by the in-process clang
        var cObjects: [URL] = []
        var headerArgs: [String] = []
        let cFiles = project.cFiles(for: m)
        let ccompiler = CCompiler(log: log, sdk: layout.sdk, clangResource: clangDir, target: target, moduleCache: moduleCache)
        var copts = CCompiler.Options()
        if !cFiles.isEmpty || m.bridgingHeader != nil {
            var dirs = CCompiler.headerDirectories(under: [project.root])
            dirs += m.headerDirs.map { project.root.appendingPathComponent($0).path }
            dirs.append(project.root.path)
            copts.includeDirs = dirs
            copts.defines = m.cDefines
            copts.arc = m.objcArc
            copts.optimize = m.optimization != "none"
            copts.extraFlags = m.cFlags
            if m.bridgingHeader != nil { for d in dirs { headerArgs += ["-Xcc", "-I", "-Xcc", d] } }
        }
        if !cFiles.isEmpty {
            cObjects = try ccompiler.compile(cFiles, into: work.appendingPathComponent("c", isDirectory: true), options: copts, label: m.name)
        }
        let strippedSources = PreviewStripper.prepare(files, root: project.root, work: work, log: log)
        var sourcesForCompile = MacroEmulation.prepare(strippedSources, work: work, log: log)
        // Apple's linker line adds libclang_rt, which provides the runtime check behind `#available`. We have no
        // libclang_rt on the device, so the app carries its own copy of that one function.
        let shim = work.appendingPathComponent("iox_runtime_shim.swift")
        try Self.runtimeShim.write(to: shim, atomically: true, encoding: .utf8)
        sourcesForCompile.append(shim)
        var fe: [String] = ["-c"] + sourcesForCompile.map { $0.path }
        fe += ["-target", target, "-sdk", layout.sdk.path,
               "-module-name", m.name, "-parse-as-library", "-swift-version", m.swiftVersion,
               "-resource-dir", resourceDir.path,
               "-module-cache-path", moduleCache.path,
               "-enable-objc-interop", "-no-color-diagnostics",
               "-Xllvm", "-aarch64-use-tbi", "-empty-abi-descriptor", "-disable-clang-spi",
               "-no-auto-bridging-header-chaining", "-enable-cross-import-overlays",
               "-target-sdk-version", sdkVersion(layout.sdk), "-target-sdk-name", "iphoneos" + sdkVersion(layout.sdk),
               "-o", obj.path]
        switch m.optimization {
        case "speed": fe += ["-O"]
        case "size": fe += ["-Osize"]
        default: fe += ["-Onone"]
        }
        fe += MacroPlugins.arguments(log: log)
        if !packageObjects.isEmpty { fe += ["-I", moduleDir.path] }
        fe += headerArgs + packageCArgs
        if let h = m.bridgingHeader { fe += ["-import-objc-header", project.root.appendingPathComponent(h).path] }
        fe += m.swiftFlags
        log.log("-- compiling Swift")
        let r1 = CompilerHost.shared.frontend(fe)
        if !r1.message.isEmpty { log.log(r1.message) }
        guard r1.exitCode == 0 else { throw BuildError.message("Swift compile failed (exit \(r1.exitCode))") }
        log.log("compiled in \(Int(Date().timeIntervalSince(t0)))s")

        // 2. link
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let exe = app.appendingPathComponent(m.name)
        var ld: [String] = ["ld64.lld", "-arch", "arm64",
                            "-platform_version", "ios", m.minOS, Self.linkedSDK(sdkVersion(layout.sdk)),
                            "-syslibroot", layout.sdk.path,
                            "-L", layout.sdk.appendingPathComponent("usr/lib/swift").path,
                            "-L", layout.swiftResource.appendingPathComponent("iphoneos").path]
        for d in m.libraryDirs { ld += ["-L", project.root.appendingPathComponent(d).path] }
        for l in m.libraries { ld += ["-l" + l] }
        for f in m.frameworks { ld += ["-framework", f] }
        ld += ["-lSystem", "-lc++", "-lobjc",
               "-rpath", "/usr/lib/swift", "-rpath", "@executable_path/Frameworks",
               "-dead_strip", "-e", "_main", obj.path] + packageObjects.map { $0.path } + cObjects.map { $0.path }
        // Apple's own link line also adds the back-deployment pack
        let compat = layout.swiftResource.appendingPathComponent("iphoneos/libswiftCompatibilityPacks.a")
        if fm.fileExists(atPath: compat.path) { ld.append(compat.path) }
        ld += ["-o", exe.path]
        ld += m.linkerFlags
        log.log("-- linking")
        let r2 = CompilerHost.shared.link(ld)
        if !r2.message.isEmpty { log.log(r2.message) }
        guard r2.exitCode == 0 else { throw BuildError.message("Link failed (exit \(r2.exitCode))") }
        chmod(exe.path, 0o755)

        // 3. bundle
        log.log("-- packaging")
        var iconFromCatalog: URL?
        var appCatalogs: [URL] = []
        var catalogPlist: [String: Any] = [:]
        let resourceURLs = m.resources.map { project.root.appendingPathComponent($0) } + project.sourceResourceFiles(for: m)
        for src in resourceURLs {
            let r = src.lastPathComponent
            let ext = src.pathExtension.lowercased()
            if ext == "xcassets" { appCatalogs.append(src); continue }
            if ["storyboard", "xib"].contains(ext) { log.log("note: \(src.lastPathComponent) is not compiled yet (no interface compiler on device)"); continue }
            let dst = app.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
            else { log.log("warning: resource not found: \(r)") }
        }
        if !appCatalogs.isEmpty {
            if let out = AssetCompilation.compile(catalogs: appCatalogs, minOS: m.minOS, into: app, scratch: work, label: "app", log: log) {
                catalogPlist = out.plistAdditions
                iconFromCatalog = out.hasAppIcon ? nil : out.iconSource
            } else {
                log.log("note: falling back to plain image files for the app's asset catalogs")
                for c in appCatalogs { iconFromCatalog = iconFromCatalog ?? Assets.extract(catalog: c, into: app, log: log) }
            }
        }
        for rb in packageResourceBundles {
            var bundleCatalogs: [URL] = []
            let dir = app.appendingPathComponent(rb.name, isDirectory: true)
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleName": rb.name, "CFBundleIdentifier": "\(m.bundleId).\(rb.name.replacingOccurrences(of: ".bundle", with: ""))",
                                       "CFBundlePackageType": "BNDL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
            (info as NSDictionary).write(to: dir.appendingPathComponent("Info.plist"), atomically: true)
            for src in rb.sources {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
                let items: [URL] = isDir.boolValue && src.pathExtension.lowercased() != "xcassets"
                    ? ((try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []) : [src]
                for item in items {
                    if item.pathExtension.lowercased() == "xcassets" { bundleCatalogs.append(item); continue }
                    if item.lastPathComponent.hasPrefix(".") { continue }
                    let dst = dir.appendingPathComponent(item.lastPathComponent)
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: item, to: dst)
                }
            }
            if !bundleCatalogs.isEmpty {
                let label = rb.name.replacingOccurrences(of: ".bundle", with: "")
                if AssetCompilation.compile(catalogs: bundleCatalogs, minOS: m.minOS, into: dir, scratch: work, label: label, log: log) == nil {
                    log.log("note: \(rb.name): colors and images from its asset catalog will be missing at runtime")
                }
            }
        }
        var m2 = m
        if m2.icon == nil, let ic = iconFromCatalog { IconWriter.write(ic, into: app, log: log); m2.icon = "-" }
        try writeInfoPlist(m2, to: app.appendingPathComponent("Info.plist"), base: project.root, extra: catalogPlist)
        if let icon = m.icon, icon != "-" {
            let src = project.root.appendingPathComponent(icon)
            if fm.fileExists(atPath: src.path) { IconWriter.write(src, into: app, log: log) }
        }
        try runScripts(m.scripts.filter { $0.afterCompile }, m: m, app: app, work: work, layout: layout)
        try fm.createDirectory(at: Paths.output, withIntermediateDirectories: true)
        let ipa = Paths.output.appendingPathComponent("\(m.name).ipa")
        try Zip.create(from: work.appendingPathComponent("Payload").deletingLastPathComponent().appendingPathComponent("Payload"), to: ipa, prefix: "Payload")
        let attrs = try? fm.attributesOfItem(atPath: ipa.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        log.log("== Done in \(Int(Date().timeIntervalSince(t0)))s: \(ipa.lastPathComponent) (\(size / 1024) KB)")
        return ipa
    }

    /// iOS 27 gives apps linked against an older SDK a compatibility layout (iPhone Duo shows a blank strip at the
    /// right edge). The pack's SDK is 26.x, so the binary is stamped as linked against 27.1, which turns on the
    /// native layout for the folding screen. The APIs the app can call are still those of the pack's SDK.
    static func linkedSDK(_ real: String) -> String {
        let r = real.split(separator: ".").compactMap { Int($0) }
        return (r.first ?? 0) >= 27 ? real : "27.1"
    }

    private func sdkVersion(_ sdk: URL) -> String {
        let name = sdk.deletingPathExtension().lastPathComponent // iPhoneOS26.2
        let v = name.replacingOccurrences(of: "iPhoneOS", with: "")
        return v.isEmpty ? "18.0" : v
    }

    /// Resolves the project's Swift packages (ioxspm, in the app's Python) and compiles their modules.
    func buildPackages(_ m: Manifest, work: URL, moduleDir: URL, common: [String]) throws -> [URL] {
        let fm = FileManager.default
        log.log("-- resolving Swift packages")
        let req: [String: Any] = [
            "work": work.path, "root": project.root.path, "cache": Paths.caches.appendingPathComponent("Packages").path,
            "packages": m.packages.map { ["url": $0.url, "req": ["kind": $0.kind, "value": $0.value]] },
            "products": m.packages.flatMap { p in (p.products.isEmpty ? [p.name] : p.products).map { ["name": $0, "package": p.name] } },
        ]
        let reqURL = work.appendingPathComponent("packages-request.json")
        try JSONSerialization.data(withJSONObject: req).write(to: reqURL)
        let r = PythonHost.shared.run(.shell("python3 -c 'import ioxspm; ioxspm.resolve(\"\(reqURL.path)\")'"), cwd: work, log: nil)
        guard r.exitCode == 0, let data = try? Data(contentsOf: work.appendingPathComponent("packages.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuildError.message("Could not resolve the Swift packages: \(r.message.suffix(600))")
        }
        for n in (obj["notes"] as? [String]) ?? [] { log.log("  \(n)") }
        var objects: [URL] = []
        var cModuleIncludes: [String: [String]] = [:]
        var cModuleDeps: [String: [String]] = [:]
        let modules = (obj["modules"] as? [[String: Any]]) ?? []
        for mod in modules {
            guard let rawName = mod["name"] as? String else { continue }
            // SwiftPM turns "Camera-SwiftUI" into the module name "Camera_SwiftUI"
            let name = String(rawName.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            if let bundle = mod["resourceBundle"] as? String {
                packageResourceBundles.append((bundle, ((mod["resources"] as? [String]) ?? []).map { URL(fileURLWithPath: $0) }))
            }
            let files = ((mod["files"] as? [String]) ?? [])
            let cfiles = (mod["cfiles"] as? [String]) ?? []
            if !cfiles.isEmpty, let cc = packageCCompiler {
                let inc = (mod["includeDir"] as? String) ?? ""
                var o = CCompiler.Options()
                let declared = (mod["headerSearch"] as? [String]) ?? []
                o.includeDirs = [inc] + declared
                if declared.isEmpty {
                    o.includeDirs += CCompiler.headerDirectories(under: [URL(fileURLWithPath: (mod["dir"] as? String) ?? "")], limit: 200)
                }
                // public headers of the C modules this one depends on, directly or through other modules
                var seen = Set<String>(), queue = ((mod["deps"] as? [String]) ?? [])
                while let d = queue.popLast() {
                    if !seen.insert(d).inserted { continue }
                    o.includeDirs += cModuleIncludes[d] ?? []
                    queue += cModuleDeps[d] ?? []
                }
                o.defines = (mod["cdefines"] as? [String]) ?? []
                o.optimize = true
                if let c = mod["cStd"] as? String { o.cStd = c }
                if let c = mod["cxxStd"] as? String { o.cxxStd = c }
                o.arc = true   // SwiftPM compiles Objective-C with ARC unless the target says otherwise
                o.extraFlags = ((mod["cflags"] as? [String]) ?? []).filter { !$0.hasPrefix("-W") }
                cModuleIncludes[rawName] = [inc]
                cModuleDeps[rawName] = (mod["deps"] as? [String]) ?? []
                objects += try cc.compile(cfiles.map { URL(fileURLWithPath: $0) }, into: work.appendingPathComponent("pkgc-\(name)", isDirectory: true), options: o, label: name)
                // a module map over the public headers so Swift can `import name`
                var mapDir = URL(fileURLWithPath: inc)
                let existing = mapDir.appendingPathComponent("module.modulemap")
                if !fm.fileExists(atPath: existing.path) {
                    mapDir = work.appendingPathComponent("modmaps/\(name)", isDirectory: true)
                    try fm.createDirectory(at: mapDir, withIntermediateDirectories: true)
                    try "module \(name) {\n  umbrella \"\(inc)\"\n  export *\n  module * { export * }\n}\n".write(to: mapDir.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)
                }
                packageCArgs += ["-Xcc", "-fmodule-map-file=" + mapDir.appendingPathComponent("module.modulemap").path, "-Xcc", "-I", "-Xcc", inc]
            } else if !cfiles.isEmpty {
                log.log("warning: \(name) has \(cfiles.count) C/Objective-C files, which are not compiled yet")
            }
            if files.isEmpty { continue }
            log.log("-- module \(name) (\(files.count) files)")
            let o = work.appendingPathComponent("pkg-\(name).o")
            var fe = ["-c"] + files + common + ["-module-name", name, "-package-name", (mod["package"] as? String) ?? name, "-swift-version", "5",
                      "-emit-module", "-emit-module-path", moduleDir.appendingPathComponent("\(name).swiftmodule").path,
                      "-I", moduleDir.path, "-o", o.path, "-O"]
            for d in (mod["defines"] as? [String]) ?? [] { fe += ["-D", d] }
            fe += MacroPlugins.arguments(log: LogSink { _ in })
            fe += packageCArgs
            let res = CompilerHost.shared.frontend(fe)
            if !res.message.isEmpty { log.log(res.message) }
            guard res.exitCode == 0 else { throw BuildError.message("Swift package module \(name) failed to compile (exit \(res.exitCode))") }
            objects.append(o)
        }
        _ = fm
        return objects
    }

    /// Runs build scripts with the variables Xcode gives a Run Script phase.
    func runScripts(_ scripts: [BuildScript], m: Manifest, app: URL, work: URL, layout: SDKLayout) throws {
        guard !scripts.isEmpty else { return }
        let root = project.root
        let products = app.deletingLastPathComponent()
        let derived = work.appendingPathComponent("DerivedSources", isDirectory: true)
        try? FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let env: [String: String] = [
            "SRCROOT": root.path, "PROJECT_DIR": root.path, "SOURCE_ROOT": root.path,
            "PROJECT_NAME": m.name, "TARGET_NAME": m.name, "PRODUCT_NAME": m.name, "EXECUTABLE_NAME": m.name,
            "PRODUCT_BUNDLE_IDENTIFIER": m.bundleId, "MARKETING_VERSION": m.version, "CURRENT_PROJECT_VERSION": m.build,
            "CONFIGURATION": "Release", "ACTION": "build", "PLATFORM_NAME": "iphoneos", "SDK_NAME": "iphoneos",
            "EFFECTIVE_PLATFORM_NAME": "-iphoneos", "SDKROOT": layout.sdk.path, "ARCHS": "arm64", "CURRENT_ARCH": "arm64",
            "NATIVE_ARCH": "arm64", "IPHONEOS_DEPLOYMENT_TARGET": m.minOS,
            "BUILT_PRODUCTS_DIR": products.path, "TARGET_BUILD_DIR": products.path, "CONFIGURATION_BUILD_DIR": products.path,
            "CODESIGNING_FOLDER_PATH": app.path, "WRAPPER_NAME": "\(m.name).app", "FULL_PRODUCT_NAME": "\(m.name).app",
            "CONTENTS_FOLDER_PATH": "\(m.name).app", "UNLOCALIZED_RESOURCES_FOLDER_PATH": "\(m.name).app",
            "EXECUTABLE_PATH": "\(m.name).app/\(m.name)", "INFOPLIST_PATH": "\(m.name).app/Info.plist",
            "DERIVED_FILE_DIR": derived.path, "DERIVED_SOURCES_DIR": derived.path, "TEMP_DIR": work.path,
            "OBJECT_FILE_DIR": work.path, "SCRIPT_INPUT_FILE_COUNT": "0", "SCRIPT_OUTPUT_FILE_COUNT": "0",
            "IOXCODE": "1",
        ]
        for s in scripts {
            log.log("-- script: \(s.name)")
            var e = env
            let cwd = s.dir.map { project.url.appendingPathComponent($0).standardizedFileURL } ?? root
            e["GITHUB_WORKSPACE"] = project.url.path
            e["RUNNER_TEMP"] = work.appendingPathComponent("runner").path
            let r = PythonHost.shared.run(.shell(s.script), cwd: cwd, env: e, log: log)
            if r.exitCode != 0 {
                if r.message.isEmpty || r.message.hasPrefix("This copy of iOXcode") || r.message.hasPrefix("Python could not start") { log.log(r.message) }
                log.log("warning: script '\(s.name)' ended with code \(r.exitCode); continuing")
            }
        }
    }

    private func writeInfoPlist(_ m: Manifest, to url: URL, base: URL, extra: [String: Any] = [:]) throws {
        var d: [String: Any] = [
            "CFBundleExecutable": m.name,
            "CFBundleIdentifier": m.bundleId,
            "CFBundleName": m.displayName ?? m.name,
            "CFBundleDisplayName": m.displayName ?? m.name,
            "CFBundleShortVersionString": m.version,
            "CFBundleVersion": m.build,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "MinimumOSVersion": m.minOS,
            "DTPlatformName": "iphoneos", "DTPlatformVersion": "27.1", "DTSDKName": "iphoneos27.1",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [1, 2],
            "LSRequiresIPhoneOS": true,
            "UILaunchScreen": [String: Any](),
            "UIRequiredDeviceCapabilities": ["arm64"],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        ]
        if let f = m.infoPlistFile,
           let data = try? Data(contentsOf: base.appendingPathComponent(f)),
           let extra = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            for (k, v) in extra {
                if let sv = v as? String, sv.contains("$(") { continue }   // build variables: keep our own values
                d[k] = v
            }
        }
        if m.icon != nil {
            d["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"]]]
        }
        for (k, v) in extra { d[k] = v }
        for (k, v) in m.infoPlist { d[k] = v }
        let data = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
        try data.write(to: url)
    }
}

/// No asset compiler exists on the phone, so images are copied out of the catalog as plain files
/// (UIImage(named:) and Image("name") find them), and the biggest app icon is used for the home screen.
enum Assets {
    static func extract(catalog: URL, into app: URL, log: LogSink) -> URL? {
        let fm = FileManager.default
        var icon: URL?
        var iconSize = 0
        guard let en = fm.enumerator(at: catalog, includingPropertiesForKeys: nil) else { return nil }
        var colorSets = 0
        for case let u as URL in en {
            let ext = u.pathExtension
            if ext == "appiconset" {
                for f in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where f.pathExtension.lowercased() == "png" {
                    let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > iconSize { iconSize = size; icon = f }
                }
            } else if ext == "imageset" {
                let name = u.deletingPathExtension().lastPathComponent
                let files = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                // use scale suffixes the loader understands when the catalog has several sizes
                if let json = try? Data(contentsOf: u.appendingPathComponent("Contents.json")),
                   let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                   let images = obj["images"] as? [[String: Any]] {
                    for im in images {
                        guard let fn = im["filename"] as? String else { continue }
                        let scale = (im["scale"] as? String) ?? "1x"
                        let suffix = scale == "1x" ? "" : "@" + scale
                        let e = (fn as NSString).pathExtension
                        let dst = app.appendingPathComponent(name + suffix + "." + e)
                        try? fm.removeItem(at: dst)
                        try? fm.copyItem(at: u.appendingPathComponent(fn), to: dst)
                    }
                } else if let f = files.first {
                    try? fm.copyItem(at: f, to: app.appendingPathComponent(name + "." + f.pathExtension))
                }
            } else if ext == "colorset" { colorSets += 1 }
        }
        if colorSets > 0 { log.log("note: \(colorSets) named colors in \(catalog.lastPathComponent) are not available (Color(\"name\") needs a compiled catalog)") }
        return icon
    }
}

/// The home screen only accepts loose icons at their exact pixel sizes, so the big source image is
/// scaled to each size (flattened onto black, since icons can't be transparent).
enum IconWriter {
    static func write(_ source: URL, into app: URL, log: LogSink) {
        guard let img = UIImage(contentsOfFile: source.path) else { log.log("warning: could not read app icon"); return }
        let sizes: [(String, CGFloat)] = [("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180), ("AppIcon76x76@2x", 152), ("AppIcon76x76@2x~ipad", 152)]
        for (name, px) in sizes {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1; fmt.opaque = true
            let out = UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: fmt).image { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
                img.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
            }
            if let d = out.pngData() { try? d.write(to: app.appendingPathComponent(name + ".png")) }
        }
    }
}

/// Re-reads project.yml and the GitHub workflows of a project with ioxgen (in the app's Python).
enum Generator {
    static func needed(_ project: Project) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: project.url.appendingPathComponent(".github/workflows").path) { return true }
        let kids = (try? fm.contentsOfDirectory(atPath: project.url.path)) ?? []
        if kids.contains("project.yml") { return true }
        return kids.contains { fm.fileExists(atPath: project.url.appendingPathComponent($0).appendingPathComponent("project.yml").path) }
    }

    static func refresh(_ project: Project, log: LogSink?) {
        guard needed(project), PythonHost.shared.isAvailable else { return }
        let r = PythonHost.shared.run(.shell("python3 -c 'import ioxgen; ioxgen.generate(\".\")'"), cwd: project.url, log: nil)
        if r.exitCode != 0 { log?.log("note: could not read project.yml / workflows: \(r.message.suffix(400))") }
    }
}

/// Swift macros (@Observable, @TaskLocal, @OptionSet ...) are expanded by plugin libraries that ship inside
/// the app as frameworks and are loaded in-process through the plugin server.
enum MacroPlugins {
    static func arguments(log: LogSink) -> [String] {
        guard let fw = Bundle.main.privateFrameworksURL else { return [] }
        let fm = FileManager.default
        func binary(_ name: String) -> String? {
            let p = fw.appendingPathComponent("\(name).framework/\(name)").path
            return fm.fileExists(atPath: p) ? p : nil
        }
        guard let server = binary("SwiftInProcPluginServer") else {
            log.log("note: Swift macros are not available in this build of the app (no plugin server inside)")
            return []
        }
        var args = ["-in-process-plugin-server-path", server]
        var names: [String] = []
        for module in ["ObservationMacros", "SwiftMacros"] {
            if let b = binary(module) { args += ["-load-resolved-plugin", "\(b)##\(module)"]; names.append(module) }
        }
        if !names.isEmpty { log.log("macros: \(names.joined(separator: ", "))") }
        return args
    }
}

/// `#Preview { ... }` only feeds Xcode's canvas, and its macro ships with Xcode, not with the SDK:
/// those blocks are removed from a copy of each file before compiling.
/// Expands the macros iOXcode emulates (SwiftData @Model, SwiftUI @Entry, ...) in the app's own sources.
enum MacroEmulation {
    static func prepare(_ files: [URL], work: URL, log: LogSink) -> [URL] {
        let wanted = files.filter {
            guard let t = try? String(contentsOf: $0, encoding: .utf8) else { return false }
            return t.contains("@Model") || t.contains("@Entry") || t.contains("#ATUnionBuilder") || t.contains("@Query") || t.contains("#Predicate") || t.contains("#Expression")
        }
        if wanted.isEmpty { return files }
        let outDir = work.appendingPathComponent("expanded-app", isDirectory: true)
        let req: [String: Any] = ["files": wanted.map { $0.path }, "out": outDir.path]
        let reqURL = work.appendingPathComponent("macro-request.json")
        let resURL = work.appendingPathComponent("macro-result.json")
        guard (try? JSONSerialization.data(withJSONObject: req).write(to: reqURL)) != nil else { return files }
        let r = PythonHost.shared.run(.shell("python3 -c 'import ioxmacro; ioxmacro.run(\"\(reqURL.path)\", \"\(resURL.path)\")'"), cwd: work, log: nil)
        guard r.exitCode == 0, let d = try? Data(contentsOf: resURL),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
            log.log("note: macro emulation did not run: \(r.message.suffix(300))")
            return files
        }
        var changed = 0
        let out = files.map { f -> URL in
            if let n = obj[f.path], n != f.path { changed += 1; return URL(fileURLWithPath: n) }
            return f
        }
        if changed > 0 { log.log("expanded emulated macros in \(changed) file(s)") }
        return out
    }
}

enum PreviewStripper {
    static func prepare(_ files: [URL], root: URL, work: URL, log: LogSink) -> [URL] {
        let fm = FileManager.default
        let dir = work.appendingPathComponent("sources", isDirectory: true)
        var out: [URL] = []
        var changed = 0
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8), text.contains("#Preview") else { out.append(f); continue }
            let stripped = strip(text)
            if stripped == text { out.append(f); continue }
            var rel = f.standardizedFileURL.path
            let base = root.standardizedFileURL.path + "/"
            if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) } else { rel = f.lastPathComponent }
            let dst = dir.appendingPathComponent(rel)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try stripped.write(to: dst, atomically: true, encoding: .utf8); out.append(dst); changed += 1 }
            catch { out.append(f) }
        }
        if changed > 0 { log.log("removed #Preview blocks from \(changed) file(s)") }
        return out
    }

    static func strip(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var i = 0
        let n = chars.count
        let key = Array("#Preview")
        func matches(_ at: Int) -> Bool {
            guard at + key.count <= n else { return false }
            for k in 0..<key.count where chars[at + k] != key[k] { return false }
            return true
        }
        // returns the index just after the balanced group starting at `start` (which holds the opener)
        func skipBalanced(_ start: Int) -> Int {
            let open = chars[start]
            let close: Character = open == "{" ? "}" : open == "(" ? ")" : "]"
            var depth = 0
            var j = start
            while j < n {
                let c = chars[j]
                if c == "\"" {
                    // string literal (single-line or """ multi-line)
                    if j + 2 < n, chars[j + 1] == "\"", chars[j + 2] == "\"" {
                        j += 3
                        while j + 2 < n, !(chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\"") { j += chars[j] == "\\" ? 2 : 1 }
                        j += 3; continue
                    }
                    j += 1
                    while j < n, chars[j] != "\"", chars[j] != "\n" { j += chars[j] == "\\" ? 2 : 1 }
                    j += 1; continue
                }
                if c == "/", j + 1 < n, chars[j + 1] == "/" { while j < n, chars[j] != "\n" { j += 1 }; continue }
                if c == "/", j + 1 < n, chars[j + 1] == "*" {
                    j += 2
                    while j + 1 < n, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                    j += 2; continue
                }
                if c == open { depth += 1 }
                else if c == close { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return n
        }
        func skipSpaces(_ at: Int) -> Int { var j = at; while j < n, chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" || chars[j] == "\r" { j += 1 }; return j }
        while i < n {
            if matches(i), i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_") {
                var j = i + key.count
                var k = skipSpaces(j)
                if k < n, chars[k] == "(" { j = skipBalanced(k); k = skipSpaces(j) }
                if k < n, chars[k] == "{" { j = skipBalanced(k) } else { j = max(j, i + key.count) }
                result += "// #Preview removed by iOXcode\n"
                i = j
                continue
            }
            result.append(chars[i]); i += 1
        }
        return result
    }
}
