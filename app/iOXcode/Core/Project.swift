import Foundation

/// A build script: an Xcode "Run Script" phase, an XcodeGen script or a workflow step.
struct BuildScript: Codable, Hashable {
    var name: String
    var script: String
    var afterCompile: Bool = false
    var dir: String?            // folder to run in, relative to the imported folder (default: the project folder)

    init(name: String, script: String, afterCompile: Bool = false, dir: String? = nil) {
        self.name = name; self.script = script; self.afterCompile = afterCompile; self.dir = dir
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "script"
        script = (try? c.decode(String.self, forKey: .script)) ?? ""
        afterCompile = (try? c.decode(Bool.self, forKey: .afterCompile)) ?? false
        dir = try? c.decode(String.self, forKey: .dir)
    }
}

/// A Swift package dependency of the app.
struct PackageRef: Codable, Hashable {
    var name: String
    var url: String
    var kind: String = "branch"       // from | minor | exact | branch | revision
    var value: String = "HEAD"
    var products: [String] = []

    init(name: String, url: String, kind: String = "branch", value: String = "HEAD", products: [String] = []) {
        self.name = name; self.url = url; self.kind = kind; self.value = value; self.products = products
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? (url.split(separator: "/").last.map(String.init) ?? "")
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "branch"
        value = (try? c.decode(String.self, forKey: .value)) ?? "HEAD"
        products = (try? c.decode([String].self, forKey: .products)) ?? []
    }
}

/// What ioxgen (inside the app's Python) made from project.yml and the GitHub workflows.
struct Generated: Decodable {
    var manifest: Manifest?
    var root: String?
    var scripts: [BuildScript]?
    var notes: [String]?

    static func load(_ dir: URL) -> Generated? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(".ioxcode/generated.json")) else { return nil }
        return try? JSONDecoder().decode(Generated.self, from: d)
    }
}

/// ioxcode.json in a project folder. Every field has a default, so a plain folder of .swift files builds.
struct Manifest: Codable {
    var name: String = "App"
    var displayName: String?
    var bundleId: String = "com.example.app"
    var version: String = "1.0"
    var build: String = "1"
    var minOS: String = "16.0"
    var sources: [String] = ["."]
    var bridgingHeader: String?
    var optimization: String = "none"          // "none" | "speed" | "size"
    var swiftVersion: String = "5"
    var libraryDirs: [String] = []             // searched for .a files, relative to the project
    var libraries: [String] = []               // -l names, e.g. "tamaios"
    var frameworks: [String] = []              // extra -framework names
    var resources: [String] = []               // files/folders copied into the .app
    var icon: String?                          // a 1024px PNG
    var swiftFlags: [String] = []
    var linkerFlags: [String] = []
    var infoPlist: [String: String] = [:]      // extra string keys
    var infoPlistFile: String?                 // an Info.plist from an Xcode project
    var swiftFiles: [String]?                  // explicit file list (from an Xcode project)
    var cFiles: [String]?                      // explicit C/ObjC/C++ file list (from an Xcode project)
    var cDefines: [String] = []
    var cFlags: [String] = []
    var headerDirs: [String] = []
    var objcArc = true
    var scripts: [BuildScript] = []            // run by ioxsh before/after compiling
    var packages: [PackageRef] = []            // Swift package dependencies
    var excludes: [String] = []                // folders/files under `sources` that are not compiled
    var deviceFamily: [Int]?                   // TARGETED_DEVICE_FAMILY: 1 = iPhone, 2 = iPad (Xcode default: both)
    var sourceResources = false                // non-code files inside `sources` are copied too (XcodeGen does that)
    var productType: String?                   // "app-extension" for an extension target; nil for the app
    var extensions: [Manifest] = []            // app extensions (widgets, share, intents) embedded in the app
    var localTargets: [Manifest] = []          // framework / static-library targets of this project that this target uses, dependencies first

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ k: Keys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        name = get(.name, "App"); displayName = get(.displayName, nil as String?)
        bundleId = get(.bundleId, "com.example.app"); version = get(.version, "1.0"); build = get(.build, "1")
        minOS = get(.minOS, "16.0"); sources = get(.sources, ["."]); bridgingHeader = get(.bridgingHeader, nil as String?)
        optimization = get(.optimization, "none"); swiftVersion = get(.swiftVersion, "5")
        libraryDirs = get(.libraryDirs, []); libraries = get(.libraries, []); frameworks = get(.frameworks, [])
        resources = get(.resources, []); icon = get(.icon, nil as String?)
        swiftFlags = get(.swiftFlags, []); linkerFlags = get(.linkerFlags, []); infoPlist = get(.infoPlist, [:])
        infoPlistFile = get(.infoPlistFile, nil as String?); swiftFiles = get(.swiftFiles, nil as [String]?)
        cFiles = get(.cFiles, nil as [String]?); cDefines = get(.cDefines, []); cFlags = get(.cFlags, []); headerDirs = get(.headerDirs, []); objcArc = get(.objcArc, true)
        scripts = get(.scripts, []); packages = get(.packages, []); excludes = get(.excludes, []); sourceResources = get(.sourceResources, false); deviceFamily = get(.deviceFamily, nil as [Int]?)
        productType = get(.productType, nil as String?); extensions = get(.extensions, []); localTargets = get(.localTargets, [])
    }
    enum Keys: String, CodingKey {
        case name, displayName, bundleId, version, build, minOS, sources, bridgingHeader, optimization, swiftVersion
        case libraryDirs, libraries, frameworks, resources, icon, swiftFlags, linkerFlags, infoPlist, infoPlistFile, swiftFiles, cFiles, cDefines, cFlags, headerDirs, objcArc, scripts, excludes, sourceResources, packages, deviceFamily, productType, extensions, localTargets
    }

    /// The Swift packages of this target and of the local targets it uses, one entry per package with all products.
    var allPackages: [PackageRef] {
        var out: [PackageRef] = []
        for p in packages + localTargets.flatMap({ $0.packages }) {
            if let i = out.firstIndex(where: { $0.url == p.url && $0.kind == p.kind && $0.value == p.value }) {
                for pr in p.products where !out[i].products.contains(pr) { out[i].products.append(pr) }
            } else { out.append(p) }
        }
        return out
    }
    /// Names that are modules of this project (framework and static-library targets), so they are not linked as system frameworks.
    var localModuleNames: Set<String> { Set(localTargets.map { $0.name }) }

    static func load(from dir: URL) -> Manifest {
        var m = loadBase(from: dir)
        if let g = Generated.load(dir), let extra = g.scripts, !extra.isEmpty { m.scripts = extra + m.scripts }
        return m
    }
    private static func loadBase(from dir: URL) -> Manifest {
        let url = dir.appendingPathComponent("ioxcode.json")
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Manifest.self, from: d) { return m }
        if let r = XcodeProjectReader.read(projectDir: dir) { return r.manifest }
        if let g = Generated.load(dir), let gm = g.manifest { return gm }
        var m = Manifest()
        m.name = dir.lastPathComponent.filter { $0.isLetter || $0.isNumber }
        if m.name.isEmpty { m.name = "App" }
        m.bundleId = "com.example." + m.name.lowercased()
        return m
    }
    func save(to dir: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: dir.appendingPathComponent("ioxcode.json")) }
    }
}

struct Project: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
    var manifest: Manifest { Manifest.load(from: url) }
    /// The folder that relative paths in the manifest refer to (the folder holding the .xcodeproj, if any).
    var root: URL {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("ioxcode.json").path) { return url }
        if let p = XcodeProjectReader.findProject(in: url) { return p.deletingLastPathComponent() }
        if let g = Generated.load(url), g.manifest != nil, let r = g.root { return url.appendingPathComponent(r).standardizedFileURL }
        return url
    }
    var warnings: [String] {
        if let w = XcodeProjectReader.read(projectDir: url)?.warnings { return w }
        return Generated.load(url)?.notes ?? []
    }
    var isXcodeProject: Bool { XcodeProjectReader.findProject(in: url) != nil }

    /// Whether this repo is meant to produce an iPhone app. iOXcode only offers "Build IPA" for those: a documentation
    /// repo, a Python tool, a Swift package that is only a library or a macOS-only app has nothing to build.
    /// Decided the way Xcode and the CI would: an explicit ioxcode.json, an Xcode project or XcodeGen spec with an iOS
    /// application target, a workflow that builds one, a Swift package that declares an iOS application product, or -
    /// for a bare folder of Swift files - a SwiftUI/UIKit app entry point.
    var buildsIPA: Bool {
        let fm = FileManager.default
        let stamp = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
        let generatedStamp = ((try? fm.attributesOfItem(atPath: url.appendingPathComponent(".ioxcode/generated.json").path))?[.modificationDate] as? Date) ?? .distantPast
        let key = url.path + "|\(stamp.timeIntervalSince1970)|\(generatedStamp.timeIntervalSince1970)"
        if let hit = Project.kindCache[key] { return hit }
        let result = computeBuildsIPA()
        Project.kindCache[key] = result
        return result
    }
    private static var kindCache: [String: Bool] = [:]

    private func computeBuildsIPA() -> Bool {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(name).path) }
        if exists("ioxcode.json") { return true }
        if XcodeProjectReader.read(projectDir: url) != nil { return true }          // an iOS application target
        if let g = Generated.load(url), g.manifest != nil { return true }           // project.yml / workflow with an iOS app
        let top = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if exists("Package.swift") {
            let text = (try? String(contentsOf: url.appendingPathComponent("Package.swift"), encoding: .utf8)) ?? ""
            return text.contains(".iOSApplication(") || text.contains("iOSApplication(")
        }
        // another kind of project definition that did not describe an iOS app (a macOS-only Xcode project, a library spec)
        if top.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) || exists("project.yml") || exists("project.yaml") {
            return false
        }
        // a bare folder of Swift files: is there an app entry point?
        var scanned = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                let name = u.lastPathComponent
                if name == "Pods" || name == "Carthage" || name == "node_modules" || name == "build" { en.skipDescendants(); continue }
                guard u.pathExtension == "swift" || u.pathExtension == "m" else { continue }
                scanned += 1
                if scanned > 400 { break }
                if let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512 * 1024 { continue }
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                if text.contains("@UIApplicationMain") || text.contains("UIApplicationMain(") || text.contains("UIApplicationDelegate") { return true }
                if text.contains("@main"), text.range(of: #":\s*App\b"#, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    static func all() -> [Project] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil)) ?? []
        return items.filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map(Project.init)
    }

    func swiftFiles(for m: Manifest) -> [URL] {
        if let list = m.swiftFiles {
            return list.map { root.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        var out: [URL] = []
        let fm = FileManager.default
        let excluded = m.excludes.map { self.root.appendingPathComponent($0).standardizedFileURL.path }
        for s in m.sources {
            let root = self.root.appendingPathComponent(s)
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in en {
                    let p = u.standardizedFileURL.path
                    if excluded.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { en.skipDescendants(); continue }
                    if u.lastPathComponent.hasPrefix(".") { en.skipDescendants(); continue }
                    if u.pathExtension == "swift" && !u.path.contains("/.build/") { out.append(u) }
                }
            }
        }
        return Array(Set(out)).sorted { $0.path < $1.path }
    }

    func cFiles(for m: Manifest) -> [URL] {
        let fm = FileManager.default
        if let list = m.cFiles {
            return list.map { root.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        }
        guard m.swiftFiles == nil else { return [] }
        var out: [URL] = []
        let excluded = m.excludes.map { self.root.appendingPathComponent($0).standardizedFileURL.path }
        for s in m.sources {
            guard let en = fm.enumerator(at: root.appendingPathComponent(s), includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en {
                let p = u.standardizedFileURL.path
                if excluded.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { en.skipDescendants(); continue }
                if u.lastPathComponent.hasPrefix(".") || u.lastPathComponent == "Pods" { en.skipDescendants(); continue }
                if CCompiler.extensions.contains(u.pathExtension.lowercased()) && !p.contains("/.build/") { out.append(u) }
            }
        }
        return Array(Set(out)).sorted { $0.path < $1.path }
    }

    /// Non-code files inside the source folders, copied into the app the way XcodeGen/Xcode would.
    /// Folders that are bundles of their own (asset catalogs, .bundle, .lproj, ...) are returned whole.
    func sourceResourceFiles(for m: Manifest) -> [URL] {
        guard m.sourceResources else { return [] }
        let fm = FileManager.default
        let skipExt: Set<String> = ["swift", "h", "hpp", "m", "mm", "c", "cc", "cpp", "cxx", "s", "modulemap", "pch",
                                    "entitlements", "xcconfig", "md", "yml", "yaml", "a", "dylib", "tbd", "o", "xcodeproj", "xcworkspace", "playground"]
        let wholeExt: Set<String> = ["xcassets", "bundle", "lproj", "storyboard", "xib", "xcdatamodeld", "scnassets", "rcproject", "metal", "framework", "xcframework", "docc"]
        let excluded = m.excludes.map { root.appendingPathComponent($0).standardizedFileURL.path }
        let plist = m.infoPlistFile.map { root.appendingPathComponent($0).standardizedFileURL.path }
        var out: [URL] = []
        for s in m.sources {
            guard let en = fm.enumerator(at: root.appendingPathComponent(s), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let u as URL in en {
                let p = u.standardizedFileURL.path
                let name = u.lastPathComponent
                if name.hasPrefix(".") || excluded.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { en.skipDescendants(); continue }
                let ext = u.pathExtension.lowercased()
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir {
                    if wholeExt.contains(ext) { en.skipDescendants(); if !["framework", "xcframework", "docc", "metal", "xcdatamodeld"].contains(ext) { out.append(u) } }
                    continue
                }
                if skipExt.contains(ext) || p == plist || name == "Info.plist" || name == "LICENSE" { continue }
                out.append(u)
            }
        }
        return out
    }
}
