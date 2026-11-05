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
    var scripts: [BuildScript] = []            // run by ioxsh before/after compiling
    var excludes: [String] = []                // folders/files under `sources` that are not compiled
    var sourceResources = false                // non-code files inside `sources` are copied too (XcodeGen does that)

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
        scripts = get(.scripts, []); excludes = get(.excludes, []); sourceResources = get(.sourceResources, false)
    }
    enum Keys: String, CodingKey {
        case name, displayName, bundleId, version, build, minOS, sources, bridgingHeader, optimization, swiftVersion
        case libraryDirs, libraries, frameworks, resources, icon, swiftFlags, linkerFlags, infoPlist, infoPlistFile, swiftFiles, scripts, excludes, sourceResources
    }

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
                    if wholeExt.contains(ext) { en.skipDescendants(); if !["framework", "xcframework", "docc", "metal"].contains(ext) { out.append(u) } }
                    continue
                }
                if skipExt.contains(ext) || p == plist || name == "Info.plist" || name == "LICENSE" { continue }
                out.append(u)
            }
        }
        return out
    }
}
