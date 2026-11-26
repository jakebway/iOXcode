import Foundation

/// GitHub starts every run from a clean checkout; on the phone the project folder lives between builds.
/// Whatever a build's scripts created (a cloned dependency, generated sources, a zip) is therefore removed again at
/// the start of the next build, so scripts that refuse to run on an existing checkout (`git clone`, "refusing to
/// modify an existing checkout") behave exactly as they do on a runner. Only paths that did not exist before the
/// previous build's scripts ran are ever removed, never anything that was in the project before.
struct FreshWorkspace {
    let root: URL
    let stateFile: URL
    private var before: Set<String> = []

    init(root: URL, name: String) {
        self.root = root.standardizedFileURL
        self.stateFile = Paths.work.appendingPathComponent("fresh-\(name).json")
    }

    private static let skipped: Set<String> = [".git"]

    private func listing() -> Set<String> {
        var out: Set<String> = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return out }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let u as URL in e {
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count))
            if FreshWorkspace.skipped.contains(rel.components(separatedBy: "/")[0]) {
                e.skipDescendants()
                continue
            }
            out.insert(rel)
            let v = try? u.resourceValues(forKeys: [.isSymbolicLinkKey])
            if v?.isSymbolicLink == true { e.skipDescendants() }
        }
        return out
    }

    /// Removes what the previous build created, then remembers what exists now.
    mutating func begin(log: LogSink) {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: stateFile), let paths = try? JSONDecoder().decode([String].self, from: data) {
            var removed = 0
            for rel in paths where !rel.isEmpty && !rel.hasPrefix("/") && !rel.contains("..") {
                let u = root.appendingPathComponent(rel)
                if fm.fileExists(atPath: u.path) || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil {
                    try? fm.removeItem(at: u)
                    removed += 1
                }
            }
            if removed > 0 { log.log("fresh checkout: removed \(removed) item(s) the previous build created (a runner starts clean)") }
        }
        try? fm.removeItem(at: stateFile)
        before = listing()
    }

    /// Records the top-level paths created since `begin`.
    func end() {
        let after = listing()
        let created = after.subtracting(before)
        // keep only the outermost new paths: "upstream", not every file inside it
        let outermost = created.filter { rel in
            var parts = rel.components(separatedBy: "/")
            parts.removeLast()
            var prefix = ""
            for part in parts {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                if created.contains(prefix) { return false }
            }
            return true
        }.sorted()
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(outermost) { try? data.write(to: stateFile) }
    }
}
