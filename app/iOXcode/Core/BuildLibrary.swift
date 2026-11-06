import Foundation

/// A finished IPA kept inside the app (Documents/iOXcode/Builds), so builds survive between launches.
struct BuildRecord: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleId: String
    var version: String
    var date: Date
    var size: Int
    var file: String
}

enum BuildLibrary {
    private static var index: URL { Paths.builds.appendingPathComponent("index.json") }

    static func url(for r: BuildRecord) -> URL { Paths.builds.appendingPathComponent(r.file) }

    static func load() -> [BuildRecord] {
        guard let data = try? Data(contentsOf: index) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let all = (try? dec.decode([BuildRecord].self, from: data)) ?? []
        return all.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }.sorted { $0.date > $1.date }
    }

    private static func save(_ records: [BuildRecord]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        Paths.ensure(Paths.builds)
        if let d = try? enc.encode(records) { try? d.write(to: index, options: .atomic) }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func store(_ src: URL, name: String, bundleId: String, version: String, fileName: String?, move: Bool) -> BuildRecord? {
        let fm = FileManager.default
        Paths.ensure(Paths.builds)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let file = fileName.map { "\(stamp())-\($0)" } ?? "\(safe)-\(stamp()).ipa"
        let dst = Paths.builds.appendingPathComponent(file)
        do {
            try? fm.removeItem(at: dst)
            if move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
        } catch { return nil }
        let size = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        let rec = BuildRecord(id: UUID().uuidString, name: name, bundleId: bundleId, version: version, date: Date(), size: size, file: file)
        var all = load(); all.append(rec); save(all)
        return rec
    }

    @discardableResult
    static func add(ipa: URL, manifest: Manifest, projectName: String) -> BuildRecord? {
        store(ipa, name: projectName, bundleId: manifest.bundleId, version: "\(manifest.version) (\(manifest.build))", fileName: nil, move: false)
    }

    @discardableResult
    static func addDownloaded(_ ipa: URL, name: String, version: String, fileName: String) -> BuildRecord? {
        store(ipa, name: name, bundleId: "", version: version, fileName: fileName, move: true)
    }

    static func remove(_ r: BuildRecord) {
        try? FileManager.default.removeItem(at: url(for: r))
        save(load().filter { $0.id != r.id })
    }
}
