import Foundation

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
    }
    enum Keys: String, CodingKey {
        case name, displayName, bundleId, version, build, minOS, sources, bridgingHeader, optimization, swiftVersion
        case libraryDirs, libraries, frameworks, resources, icon, swiftFlags, linkerFlags, infoPlist, infoPlistFile, swiftFiles
    }

    static func load(from dir: URL) -> Manifest {
        let url = dir.appendingPathComponent("ioxcode.json")
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Manifest.self, from: d) { return m }
        if let r = XcodeProjectReader.read(projectDir: dir) { return r.manifest }
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
        return XcodeProjectReader.findProject(in: url)?.deletingLastPathComponent() ?? url
    }
    var warnings: [String] { XcodeProjectReader.read(projectDir: url)?.warnings ?? [] }
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
        for s in m.sources {
            let root = self.root.appendingPathComponent(s)
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in en where u.pathExtension == "swift" && !u.path.contains("/.build/") { out.append(u) }
            }
        }
        return Array(Set(out)).sorted { $0.path < $1.path }
    }
}
