import Foundation
import CryptoKit

/// Keeps an imported GitHub project in step with its repo: before a build (and when the repo is opened) iOXcode
/// asks GitHub for the newest commit and, if there is one, brings the files up to date. Files you edited in iOXcode
/// are never overwritten.
enum GitHubSync {
    struct Base: Codable {
        var sha: String
        var files: [String: String]   // path -> content hash at the last sync
    }

    private static func baseFile(_ name: String) -> URL { Paths.origins.appendingPathComponent(name + ".base.json") }
    static func loadBase(_ name: String) -> Base? {
        (try? Data(contentsOf: baseFile(name))).flatMap { try? JSONDecoder().decode(Base.self, from: $0) }
    }
    private static func saveBase(_ b: Base, _ name: String) {
        Paths.ensure(Paths.origins)
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: baseFile(name), options: .atomic) }
    }
    static func forget(_ name: String) { try? FileManager.default.removeItem(at: baseFile(name)) }

    private static func hash(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// path -> hash for every file of a project folder (iOXcode's own `.ioxcode` folder and `.git` are not part of the repo).
    static func snapshot(_ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return out }
        let prefix = dir.standardizedFileURL.path + "/"
        for case let u as URL in en {
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(prefix) else { continue }
            let rel = String(p.dropFirst(prefix.count))
            if rel == ".ioxcode" || rel.hasPrefix(".ioxcode/") || rel == ".git" || rel.hasPrefix(".git/") {
                if rel == ".ioxcode" || rel == ".git" { en.skipDescendants() }
                continue
            }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let h = hash(u) { out[rel] = h }
        }
        return out
    }

    private static func request(_ path: String, accept: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(path)")!)
        req.setValue("iOXcode", forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        req.timeoutInterval = 15
        return req
    }

    /// Full SHA of the newest commit of the repo's branch, or nil when GitHub can't be reached.
    static func latestSHA(_ o: GitHubOrigin) async -> String? {
        let ref = o.branch ?? "HEAD"
        guard let (data, resp) = try? await URLSession.shared.data(for: request("\(o.owner)/\(o.repo)/commits/\(ref)", accept: "application/vnd.github.sha")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 40 else { return nil }
        return s
    }

    /// Records the state of a freshly imported project so later syncs know what you changed.
    static func recordImport(name: String, folder: URL, origin: GitHubOrigin) async {
        guard let sha = await latestSHA(origin) else { return }
        saveBase(Base(sha: sha, files: snapshot(folder)), name)
    }

    enum Result { case unchanged, updated(String), unreachable }

    /// Brings `project` up to the newest commit. Returns what happened; `log` receives one line per notable thing.
    static func sync(_ project: Project, origin: GitHubOrigin, log: @escaping (String) -> Void) async -> Result {
        guard let sha = await latestSHA(origin) else { return .unreachable }
        let name = project.url.lastPathComponent
        let base = loadBase(name)
        if base?.sha == sha { return .unchanged }
        let fm = FileManager.default
        do {
            log("Updating \(name) from GitHub (\(String(sha.prefix(7))))…")
            var req = request("\(origin.owner)/\(origin.repo)/zipball/\(sha)")
            req.timeoutInterval = 120
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "GitHub", code: (resp as? HTTPURLResponse)?.statusCode ?? 0) }
            let work = fm.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: work); try? fm.removeItem(at: tmp) }
            let zip = work.appendingPathExtension("zip")
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: tmp, to: zip)
            defer { try? fm.removeItem(at: zip) }
            try Zip.extract(zip, to: work)
            var root = work
            let kids = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            if kids.count == 1, (try? kids[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { root = kids[0] }
            let fresh = snapshot(root)
            var kept: [String] = [], changed = 0, added = 0, removed = 0
            for (rel, h) in fresh {
                let dst = project.url.appendingPathComponent(rel)
                let localHash = hash(dst)
                if localHash == h { continue }
                if let b = base?.files[rel], let lh = localHash, lh != b {
                    if h != b { kept.append(rel) }   // edited on both sides: yours stays
                    continue
                }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: root.appendingPathComponent(rel), to: dst)
                if localHash == nil { added += 1 } else { changed += 1 }
            }
            if let b = base {
                for (rel, bh) in b.files where fresh[rel] == nil {
                    let dst = project.url.appendingPathComponent(rel)
                    if hash(dst) == bh { try? fm.removeItem(at: dst); removed += 1 }
                }
            }
            var newBase = Base(sha: sha, files: fresh)
            for rel in kept { newBase.files[rel] = base?.files[rel] ?? fresh[rel] }   // keep treating them as edited
            saveBase(newBase, name)
            for rel in kept.prefix(10) { log("kept your edit of \(rel) (it also changed on GitHub)") }
            let summary = "\(changed) changed, \(added) new, \(removed) removed"
            log("Up to date with GitHub: \(summary)")
            return .updated(summary)
        } catch {
            log("Could not update from GitHub: \(error.localizedDescription)")
            return .unreachable
        }
    }
}
