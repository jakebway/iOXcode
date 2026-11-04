import Foundation
import Security

/// Stores one string (the GitHub token) in the Keychain.
enum Keychain {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum SDKDownloader {
    /// Downloads the newest release asset named sdk-pack.zip from a private GitHub repo and returns the local file.
    static func download(repo: String, token: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw BuildError.message(code == 404 ? "Repo or release not found (or the token cannot see it). Run the SDK workflow first."
                                                  : "GitHub said \(code). Check the token.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == "sdk-pack.zip" }),
              let id = asset["id"] as? Int else { throw BuildError.message("The release has no sdk-pack.zip.") }
        var dl = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(id)")!)
        dl.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        dl.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (tmp, r2) = try await URLSession.shared.download(for: dl)
        guard (r2 as? HTTPURLResponse)?.statusCode == 200 else { throw BuildError.message("Download failed.") }
        let dest = Paths.caches.appendingPathComponent("sdk-pack.zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
