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
    init(project: Project, log: LogSink) { self.project = project; self.log = log }

    /// Returns the finished .ipa.
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
        var fe: [String] = ["-c"] + files.map { $0.path }
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
                            "-platform_version", "ios", m.minOS, sdkVersion(layout.sdk),
                            "-syslibroot", layout.sdk.path,
                            "-L", layout.sdk.appendingPathComponent("usr/lib/swift").path,
                            "-L", layout.swiftResource.appendingPathComponent("iphoneos").path]
        for d in m.libraryDirs { ld += ["-L", project.root.appendingPathComponent(d).path] }
        for l in m.libraries { ld += ["-l" + l] }
        for f in m.frameworks { ld += ["-framework", f] }
        ld += ["-lSystem", "-lc++", "-lobjc",
               "-rpath", "/usr/lib/swift", "-rpath", "@executable_path/Frameworks",
               "-dead_strip", "-e", "_main", obj.path]
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
        let resourceURLs = m.resources.map { project.root.appendingPathComponent($0) } + project.sourceResourceFiles(for: m)
        for src in resourceURLs {
            let r = src.lastPathComponent
            let ext = src.pathExtension.lowercased()
            if ext == "xcassets" { iconFromCatalog = iconFromCatalog ?? Assets.extract(catalog: src, into: app, log: log); continue }
            if ["storyboard", "xib"].contains(ext) { log.log("note: \(src.lastPathComponent) is not compiled yet (no interface compiler on device)"); continue }
            let dst = app.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
            else { log.log("warning: resource not found: \(r)") }
        }
        var m2 = m
        if m2.icon == nil, let ic = iconFromCatalog { IconWriter.write(ic, into: app, log: log); m2.icon = "-" }
        try writeInfoPlist(m2, to: app.appendingPathComponent("Info.plist"), base: project.root)
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

    private func sdkVersion(_ sdk: URL) -> String {
        let name = sdk.deletingPathExtension().lastPathComponent // iPhoneOS26.2
        let v = name.replacingOccurrences(of: "iPhoneOS", with: "")
        return v.isEmpty ? "18.0" : v
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

    private func writeInfoPlist(_ m: Manifest, to url: URL, base: URL) throws {
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
