import Foundation
import AssetKit
import ImageIO
import UniformTypeIdentifiers

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

        let fixed = normalizeAppleOptimizedPNGs(in: merged)
        if fixed > 0 { log.log("note: converted \(fixed) Xcode-optimized (CgBI) PNG image\(fixed == 1 ? "" : "s") to standard PNG") }

        // app icons are written separately (below), including sets nested inside folders, which AssetKit is strict about
        if let en = fm.enumerator(at: merged, includingPropertiesForKeys: nil) {
            var icons: [URL] = []
            for case let u as URL in en where u.pathExtension == "appiconset" || u.pathExtension == "launchimage" { icons.append(u) }
            for u in icons { try? fm.removeItem(at: u) }
        }

        let pdfs = rasterizePDFAssets(in: merged)
        if pdfs > 0 { log.log("note: rasterized \(pdfs) PDF image\(pdfs == 1 ? "" : "s") (3x) for the asset catalog") }

        func attempt() -> Box {
            let b = Box()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do { b.value = .success(try await XCAssetCompiler(deploymentTarget: minOS).compile(catalog: merged)) }
                catch { b.value = .failure(error) }
                sem.signal()
            }
            sem.wait()
            return b
        }
        var box = attempt()
        // an asset type AssetKit cannot read must not cost the whole catalog: leave that one asset out and carry on
        var dropped = 0
        while dropped < 40, case .failure(let e)? = box.value {
            let text = "\(e)"
            guard let r = text.range(of: "Unsupported asset type: ") else { break }
            let name = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let victim = removeAsset(named: name, in: merged) else { break }
            log.log("note: left out \(victim) (asset type not supported by the catalog compiler)")
            dropped += 1
            box = attempt()
        }
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

    /// Removes the asset (its .imageset/.colorset/... folder, else the file) that holds `fileName`. Returns what was removed.
    static func removeAsset(named fileName: String, in root: URL) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        let assetFolders: Set<String> = ["imageset", "colorset", "dataset", "symbolset", "spriteatlas", "textureset", "cubetextureset", "imagestack", "brandassets"]
        for case let u as URL in en where u.lastPathComponent == fileName {
            let parent = u.deletingLastPathComponent()
            let victim = assetFolders.contains(parent.pathExtension) ? parent : u
            let label = victim.lastPathComponent
            try? fm.removeItem(at: victim)
            return label
        }
        return nil
    }

    /// AssetKit reads bitmap images only. A vector PDF in an image set is drawn once at 3x and stored as a PNG instead.
    static func rasterizePDFAssets(in root: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var sets: [URL] = []
        for case let u as URL in en where u.pathExtension == "imageset" { sets.append(u) }
        var count = 0
        for set in sets {
            let json = set.appendingPathComponent("Contents.json")
            guard let data = try? Data(contentsOf: json),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var images = obj["images"] as? [[String: Any]] else { continue }
            guard let pdfName = images.compactMap({ $0["filename"] as? String }).first(where: { $0.lowercased().hasSuffix(".pdf") }) else { continue }
            let pdfURL = set.appendingPathComponent(pdfName)
            guard let doc = CGPDFDocument(pdfURL as CFURL), let page = doc.page(at: 1) else { continue }
            let box = page.getBoxRect(.cropBox)
            let scale: CGFloat = 3
            let w = max(1, Int((box.width * scale).rounded())), h = max(1, Int((box.height * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            guard let img = ctx.makeImage() else { continue }
            let pngName = (pdfName as NSString).deletingPathExtension + ".png"
            let pngURL = set.appendingPathComponent(pngName)
            guard let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            guard CGImageDestinationFinalize(dest) else { continue }
            try? fm.removeItem(at: pdfURL)
            images = [["idiom": "universal", "filename": pngName, "scale": "3x"]]
            obj["images"] = images
            obj.removeValue(forKey: "properties")
            if let out = try? JSONSerialization.data(withJSONObject: obj) { try? out.write(to: json) }
            count += 1
        }
        return count
    }

    /// Old Xcode versions "optimized" PNGs for iOS (a CgBI chunk, raw deflate, BGRA, premultiplied). iOS reads them,
    /// but asset compilers that follow the PNG standard cannot, so decode with ImageIO and write a standard PNG.
    static func normalizeAppleOptimizedPNGs(in root: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for case let u as URL in en where u.pathExtension.lowercased() == "png" {
            guard let h = try? FileHandle(forReadingFrom: u) else { continue }
            let head = (try? h.read(upToCount: 16)) ?? Data()
            try? h.close()
            guard head.count == 16, head[12] == 0x43, head[13] == 0x67, head[14] == 0x42, head[15] == 0x49 else { continue }   // "CgBI"
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let dest = CGImageDestinationCreateWithURL(u.appendingPathExtension("tmp") as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            let tmp = u.appendingPathExtension("tmp")
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest), (try? fm.removeItem(at: u)) != nil, (try? fm.moveItem(at: tmp, to: u)) != nil { count += 1 }
            else { try? fm.removeItem(at: tmp) }
        }
        return count
    }
}
