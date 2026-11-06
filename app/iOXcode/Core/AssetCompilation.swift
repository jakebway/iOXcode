import Foundation
import AssetKit

/// Compiles .xcassets folders into a real Assets.car with AssetKit (a clean-room Swift actool, MIT), so
/// `Color("name")`, `Image("name")`, `UIImage(named:)` and app icons work the way Xcode builds them.
enum AssetCompilation {
    struct Output {
        var plistAdditions: [String: Any] = [:]
        var hasAppIcon = false
        var iconSource: URL?      // the main app icon image, written out by IconWriter at the sizes the home screen needs
    }

    /// The default (light) icon of an .appiconset: the entry with a file and no appearance variant, else the biggest PNG.
    static func mainIcon(in set: URL) -> URL? {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let images = obj["images"] as? [[String: Any]] {
            var best: (URL, Int)?
            for im in images {
                guard let fn = im["filename"] as? String, im["appearances"] == nil else { continue }
                let u = set.appendingPathComponent(fn)
                let size = Int(((im["size"] as? String) ?? "0x0").split(separator: "x").first.map(String.init) ?? "0") ?? 0
                if fm.fileExists(atPath: u.path), size >= (best?.1 ?? -1) { best = (u, size) }
            }
            if let b = best { return b.0 }
        }
        return ((try? fm.contentsOfDirectory(at: set, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private final class Box: @unchecked Sendable { var value: Result<CompileResult, Error>? }

    /// Merges the catalogs (Xcode does the same for several catalogs in one target), compiles them, and writes
    /// Assets.car (+ loose icon files) into `dir`. Returns nil when compilation failed (the reason is logged).
    static func compile(catalogs: [URL], minOS: String, into dir: URL, scratch: URL, label: String, log: LogSink) -> Output? {
        let fm = FileManager.default
        guard !catalogs.isEmpty else { return nil }
        var iconSource: URL?
        let merged = scratch.appendingPathComponent("\(label)-merged.xcassets", isDirectory: true)
        try? fm.removeItem(at: merged)
        do {
            try fm.createDirectory(at: merged, withIntermediateDirectories: true)
            var wroteContents = false
            for cat in catalogs {
                for case let u as URL in fm.enumerator(at: cat, includingPropertiesForKeys: nil) ?? NSEnumerator() where u.pathExtension == "appiconset" {
                    if iconSource == nil { iconSource = mainIcon(in: u) }
                }
                for item in (try? fm.contentsOfDirectory(at: cat, includingPropertiesForKeys: nil)) ?? [] {
                    if item.lastPathComponent == "Contents.json" {
                        if !wroteContents { try? fm.copyItem(at: item, to: merged.appendingPathComponent("Contents.json")); wroteContents = true }
                        continue
                    }
                    // app icons: AssetKit only handles the older per-size sets, so the icon is written separately
                    if item.pathExtension == "appiconset" { continue }
                    let dst = merged.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: dst.path) { continue }     // the first catalog wins on a name clash
                    try fm.copyItem(at: item, to: dst)
                }
            }
            if !wroteContents {
                try #"{"info":{"author":"xcode","version":1}}"#.write(to: merged.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
            }
        } catch {
            log.log("warning: could not stage asset catalogs: \(error.localizedDescription)")
            return nil
        }

        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await XCAssetCompiler(deploymentTarget: minOS).compile(catalog: merged)) }
            catch { box.value = .failure(error) }
            sem.signal()
        }
        sem.wait()
        switch box.value {
        case .success(let res)?:
            do {
                try res.carData.write(to: dir.appendingPathComponent("Assets.car"))
                var out = Output()
                out.iconSource = iconSource
                if let icon = res.appIconBundle {
                    for f in icon.looseFiles { try f.data.write(to: dir.appendingPathComponent(f.name)) }
                    for (k, v) in icon.infoPlistAdditions { out.plistAdditions[k] = v }
                    out.hasAppIcon = true
                }
                log.log("compiled asset catalog\(catalogs.count > 1 ? "s" : "") (\(label)): Assets.car \(res.carData.count / 1024) KB")
                return out
            } catch {
                log.log("warning: could not write Assets.car: \(error.localizedDescription)")
                return nil
            }
        case .failure(let e)?:
            log.log("warning: asset catalog (\(label)) did not compile: \(e)")
            return nil
        case nil:
            return nil
        }
    }
}
