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

    static func load(from dir: URL) -> Manifest {
        let url = dir.appendingPathComponent("ioxcode.json")
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Manifest.self, from: d) { return m }
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

    static func all() -> [Project] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil)) ?? []
        return items.filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map(Project.init)
    }

    func swiftFiles(for m: Manifest) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for s in m.sources {
            let root = url.appendingPathComponent(s)
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in en where u.pathExtension == "swift" && !u.path.contains("/.build/") { out.append(u) }
            }
        }
        return Array(Set(out)).sorted { $0.path < $1.path }
    }
}
