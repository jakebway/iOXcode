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
