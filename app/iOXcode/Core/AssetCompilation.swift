import Foundation
import AssetKit

/// Compiles .xcassets folders into a real Assets.car with AssetKit (a clean-room Swift actool, MIT), so
/// `Color("name")`, `Image("name")`, `UIImage(named:)` and app icons work the way Xcode builds them.
enum AssetCompilation {
    struct Output {
        var plistAdditions: [String: Any] = [:]
        var hasAppIcon = false
    }

    private final class Box: @unchecked Sendable { var value: Result<CompileResult, Error>? }

    /// Merges the catalogs (Xcode does the same for several catalogs in one target), compiles them, and writes
    /// Assets.car (+ loose icon files) into `dir`. Returns nil when compilation failed (the reason is logged).
    static func compile(catalogs: [URL], minOS: String, into dir: URL, scratch: URL, label: String, log: LogSink) -> Output? {
        let fm = FileManager.default
        guard !catalogs.isEmpty else { return nil }
        let merged = scratch.appendingPathComponent("\(label)-merged.xcassets", isDirectory: true)
        try? fm.removeItem(at: merged)
        do {
            try fm.createDirectory(at: merged, withIntermediateDirectories: true)
            var wroteContents = false
            for cat in catalogs {
                for item in (try? fm.contentsOfDirectory(at: cat, includingPropertiesForKeys: nil)) ?? [] {
                    if item.lastPathComponent == "Contents.json" {
                        if !wroteContents { try? fm.copyItem(at: item, to: merged.appendingPathComponent("Contents.json")); wroteContents = true }
                        continue
                    }
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
