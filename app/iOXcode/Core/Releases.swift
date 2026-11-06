import Foundation

struct GitHubOrigin: Codable, Hashable {
    var owner: String
    var repo: String

    /// Accepts "owner/repo" or any github.com link to the repo.
    static func parse(_ text: String) -> GitHubOrigin? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www.", "github.com/"] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        return GitHubOrigin(owner: parts[0], repo: repo)
    }
}

/// Remembers which GitHub repo a project came from (kept outside the project, so the repo's files stay untouched).
enum Origins {
    private static func file(_ name: String) -> URL { Paths.origins.appendingPathComponent(name + ".json") }
    static func save(_ o: GitHubOrigin, for name: String) {
        Paths.ensure(Paths.origins)
        if let d = try? JSONEncoder().encode(o) { try? d.write(to: file(name), options: .atomic) }
    }
    static func load(_ name: String) -> GitHubOrigin? {
        (try? Data(contentsOf: file(name))).flatMap { try? JSONDecoder().decode(GitHubOrigin.self, from: $0) }
    }
    static func remove(_ name: String) { try? FileManager.default.removeItem(at: file(name)) }
}

struct ReleaseAsset: Decodable, Identifiable, Hashable {
    let name: String
    let size: Int
    let url: URL
    var id: String { url.absoluteString }
    enum CodingKeys: String, CodingKey { case name, size, url = "browser_download_url" }
}

struct GitHubRelease: Decodable, Identifiable, Hashable {
    let tag: String
    let name: String?
    let prerelease: Bool
    let published: Date?
    let body: String?
    let assets: [ReleaseAsset]
    var id: String { tag }
    enum CodingKeys: String, CodingKey { case tag = "tag_name", name, prerelease, published = "published_at", body, assets }
}

/// Public releases of a GitHub repo (no sign-in or token needed).
enum Releases {
    static func fetch(_ o: GitHubOrigin) async throws -> [GitHubRelease] {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(o.owner)/\(o.repo)/releases?per_page=30")!)
        req.setValue("iOXcode", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: code == 403 ? "GitHub is rate limiting requests, try again in a while" : "GitHub answered \(code)"])
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([GitHubRelease].self, from: data)
    }

    static func download(_ a: ReleaseAsset) async throws -> URL {
        var req = URLRequest(url: a.url)
        req.setValue("iOXcode", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(code)"]) }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(a.name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        return dst
    }
}

extension GitHubOrigin {
    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static func api(_ path: String) async -> Data? {
        guard let url = URL(string: "https://api.github.com/" + path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("iOXcode", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Works out which GitHub repo a project folder came from, without asking: the git remote if there is one,
    /// then GitHub links in the README that point at a repo named like the project, then a GitHub search by name.
    static func infer(from project: URL) async -> GitHubOrigin? {
        let name = project.lastPathComponent
        let linkRx = try! NSRegularExpression(pattern: "github\\.com[:/]([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/([A-Za-z0-9._-]+)")

        func scan(_ text: String) -> [GitHubOrigin] {
            let ns = text as NSString
            return linkRx.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
                var repo = ns.substring(with: m.range(at: 2))
                while repo.hasSuffix(".") { repo.removeLast() }
                if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
                let owner = ns.substring(with: m.range(at: 1))
                return ["sponsors", "orgs", "topics", "apps", "marketplace", "features"].contains(owner.lowercased()) ? nil : GitHubOrigin(owner: owner, repo: repo)
            }
        }

        // 1. a git remote
        if let cfg = try? String(contentsOf: project.appendingPathComponent(".git/config"), encoding: .utf8), let o = scan(cfg).first { return o }

        // 2. links in the README whose repo name matches the project
        if let readme = ReadmeSection.find(in: project), let data = try? Data(contentsOf: readme),
           let text = String(data: data, encoding: .utf8) {
            var seen: [GitHubOrigin: Int] = [:]
            for o in scan(text) where squash(o.repo) == squash(name) { seen[o, default: 0] += 1 }
            for o in seen.sorted(by: { $0.value > $1.value }).map({ $0.key }) {
                if await api("repos/\(o.owner)/\(o.repo)") != nil { return o }
            }
        }

        // 3. search by name, most starred first
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let data = await api("search/repositories?q=\(q)+in:name&sort=stars&per_page=15"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let items = obj["items"] as? [[String: Any]] {
            for it in items {
                guard let n = it["name"] as? String, squash(n) == squash(name),
                      let owner = (it["owner"] as? [String: Any])?["login"] as? String else { continue }
                return GitHubOrigin(owner: owner, repo: n)
            }
        }
        return nil
    }
}
