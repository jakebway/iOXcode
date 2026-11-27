import Foundation

/// Reads an .ipa the way a build inspector would: the app's Info.plist, the embedded provisioning profile,
/// the Mach-O load commands of every executable, and the bundle layout. Also rewrites the editable plist keys and re-zips.
final class IPAInspector {
    let work: URL
    private(set) var appDir: URL?
    var plist: [String: Any] = [:]
    private let log: (String) -> Void

    init(work: URL, log: @escaping (String) -> Void) { self.work = work; self.log = log }

    func open(_ ipa: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("Opening \(ipa.lastPathComponent) (\(size((try? fm.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? 0)))")
        try Zip.extract(ipa, to: work)
        let payload = work.appendingPathComponent("Payload")
        guard let app = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "IPA", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Payload/*.app inside this file"])
        }
        appDir = app
        plist = Self.readPlist(app.appendingPathComponent("Info.plist")) ?? [:]
        report(app)
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any]
    }

    private func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    private func report(_ app: URL) {
        let fm = FileManager.default
        log("\n== App ==")
        for (label, key) in [("Name", "CFBundleDisplayName"), ("Bundle name", "CFBundleName"), ("Bundle ID", "CFBundleIdentifier"), ("Version", "CFBundleShortVersionString"),
                             ("Build", "CFBundleVersion"), ("Executable", "CFBundleExecutable"), ("Min iOS", "MinimumOSVersion"), ("Package type", "CFBundlePackageType")] {
            if let v = plist[key] { log("\(label): \(v)") }
        }
        if let fam = plist["UIDeviceFamily"] as? [Int] { log("Devices: " + fam.map { $0 == 1 ? "iPhone" : $0 == 2 ? "iPad" : "\($0)" }.joined(separator: ", ")) }
        if let caps = plist["UIRequiredDeviceCapabilities"] { log("Required capabilities: \(caps)") }
        if let modes = plist["UIBackgroundModes"] as? [String] { log("Background modes: " + modes.joined(separator: ", ")) }
        if let urls = plist["CFBundleURLTypes"] as? [[String: Any]] {
            let schemes = urls.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
            if !schemes.isEmpty { log("URL schemes: " + schemes.joined(separator: ", ")) }
        }
        if let q = plist["LSApplicationQueriesSchemes"] as? [String] { log("Queries schemes: " + q.joined(separator: ", ")) }

        log("\n== Where it came from (build metadata) ==")
        var any = false
        for key in ["DTXcode", "DTXcodeBuild", "DTSDKName", "DTSDKBuild", "DTPlatformName", "DTPlatformVersion", "DTPlatformBuild", "DTCompiler", "BuildMachineOSBuild", "DTAppStoreToolsBuild"] {
            if let v = plist[key] { log("\(key): \(v)"); any = true }
        }
        if !any { log("none. No Xcode build keys in Info.plist (built by another tool or stripped).") }
        for extra in ["iTunesMetadata.plist", "../iTunesMetadata.plist", "../../iTunesMetadata.plist"] {
            if let m = Self.readPlist(app.appendingPathComponent(extra)) {
                log("iTunesMetadata: bought by \(m["appleId"] ?? "?"), item \(m["itemId"] ?? "?"), \(m["softwareVersionBundleId"] ?? "")")
                break
            }
        }

        log("\n== Permissions the app asks for ==")
        let usage = plist.keys.filter { $0.hasSuffix("UsageDescription") || $0.hasSuffix("UsageDescriptions") }.sorted()
        if usage.isEmpty { log("none declared") }
        for k in usage { log("\(k): \(plist[k] ?? "")") }

        log("\n== Signing ==")
        let prof = app.appendingPathComponent("embedded.mobileprovision")
        if let d = try? Data(contentsOf: prof), let p = Self.provisioning(d) {
            log("Profile: \(p["Name"] ?? "?")")
            log("Team: \(p["TeamName"] ?? "?") (\((p["TeamIdentifier"] as? [String])?.first ?? "?"))")
            if let ids = p["ProvisionedDevices"] as? [String] { log("Development/ad hoc profile, \(ids.count) device(s)") }
            else if (p["ProvisionsAllDevices"] as? Bool) == true { log("Enterprise profile (all devices)") }
            else { log("Distribution profile (App Store)") }
            if let exp = p["ExpirationDate"] as? Date { log("Expires: \(exp)") }
            if let ent = p["Entitlements"] as? [String: Any] {
                log("Entitlements in profile:")
                for k in ent.keys.sorted() { log("  \(k) = \(ent[k] ?? "")") }
            }
        } else { log("No embedded.mobileprovision (unsigned or already re-signed by a sideloader).") }
        if fm.fileExists(atPath: app.appendingPathComponent("_CodeSignature").path) { log("_CodeSignature present") } else { log("_CodeSignature missing (unsigned)") }

        log("\n== Contents ==")
        var frameworks: [String] = [], appex: [String] = [], dylibs: [String] = [], bundles: [String] = []
        var total = 0, fileCount = 0
        if let en = fm.enumerator(at: app, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let u as URL in en {
                let rel = String(u.path.dropFirst(app.path.count + 1))
                let ext = u.pathExtension.lowercased()
                if ext == "framework" && rel.components(separatedBy: "/").count == 2 { frameworks.append(u.lastPathComponent) }
                if ext == "appex" { appex.append(rel) }
                if ext == "dylib" { dylibs.append(rel) }
                if ext == "bundle" && !rel.contains(".framework/") { bundles.append(rel) }
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    fileCount += 1; total += v?.fileSize ?? 0
                }
            }
        }
        log("\(fileCount) files, \(size(total)) unpacked")
        log("Frameworks (\(frameworks.count)): " + (frameworks.isEmpty ? "none" : frameworks.sorted().joined(separator: ", ")))
        log("Extensions (\(appex.count)): " + (appex.isEmpty ? "none" : appex.sorted().joined(separator: ", ")))
        if !dylibs.isEmpty { log("Dylibs: " + dylibs.sorted().joined(separator: ", ")) }
        if !bundles.isEmpty { log("Resource bundles: " + bundles.sorted().joined(separator: ", ")) }
        for ext in appex.sorted() {
            if let p = Self.readPlist(app.appendingPathComponent(ext).appendingPathComponent("Info.plist")) {
                let point = (p["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] ?? "?"
                log("  \(ext): \(p["CFBundleIdentifier"] ?? "?"), \(point)")
            }
        }

        log("\n== Executable ==")
        if let exe = plist["CFBundleExecutable"] as? String { machoReport(app.appendingPathComponent(exe), name: exe) }
        for fw in frameworks.sorted() {
            let base = (fw as NSString).deletingPathExtension
            let u = app.appendingPathComponent("Frameworks/\(fw)/\(base)")
            if fm.fileExists(atPath: u.path) { machoReport(u, name: "\(fw)", brief: true) }
        }
    }

    // MARK: Mach-O

    private func machoReport(_ url: URL, name: String, brief: Bool = false) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 32 else { return }
        func u32(_ o: Int, _ be: Bool = false) -> UInt32 {
            let v = d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return be ? v.byteSwapped : v
        }
        var base = 0
        let magic = u32(0)
        var archs: [String] = []
        if magic == 0xBEBAFECA {      // fat, big endian
            let n = Int(u32(4, true))
            for i in 0..<n {
                let o = 8 + i * 20
                archs.append(cpu(Int(u32(o, true))))
                if Int(u32(o, true)) == 0x0100000C { base = Int(u32(o + 8, true)) }
            }
            if base == 0 { base = Int(u32(16, true)) }
        } else if magic == 0xFEEDFACF { archs = [cpu(Int(u32(4)))] }
        else { log("\(name): not a Mach-O file"); return }
        guard u32(base) == 0xFEEDFACF else { log("\(name): \(archs.joined(separator: "+")) (32-bit, skipped)"); return }
        let ncmds = Int(u32(base + 16))
        var o = base + 32
        var libs: [String] = [], rpaths: [String] = []
        var platform = "", minos = "", sdk = "", crypt = -1, uuid = "", sign = false
        for _ in 0..<ncmds {
            guard o + 8 <= d.count else { break }
            let cmd = u32(o), sz = Int(u32(o + 4))
            guard sz >= 8, o + sz <= d.count else { break }
            func str(_ off: Int) -> String {
                let s = d.subdata(in: (o + off)..<(o + sz)); return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
            }
            switch cmd {
            case 0xC, 0x8000_0018, 0x8000_001F, 0x1F: libs.append((cmd == 0x8000_0018 ? "(weak) " : "") + str(Int(u32(o + 8))))
            case 0x8000_001C: rpaths.append(str(Int(u32(o + 8))))
            case 0x32:
                let p = Int(u32(o + 8))
                platform = [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "Mac Catalyst", 7: "iOS Simulator", 11: "visionOS"][p] ?? "platform \(p)"
                minos = ver(u32(o + 12)); sdk = ver(u32(o + 16))
            case 0x2C: crypt = Int(u32(o + 16))
            case 0x1B: uuid = d.subdata(in: (o + 8)..<(o + 24)).map { String(format: "%02X", $0) }.joined()
            case 0x1D: sign = true
            default: break
            }
            o += sz
        }
        log("\(name): \(archs.joined(separator: "+"))\(platform.isEmpty ? "" : ", \(platform) min \(minos) sdk \(sdk)")\(crypt == 1 ? ", ENCRYPTED (App Store DRM)" : "")\(sign ? "" : ", no signature")")
        if brief { return }
        if !uuid.isEmpty { log("  UUID: \(uuid)") }
        let sys = libs.filter { $0.contains("/usr/lib/") || $0.contains("/System/") }
        let other = libs.filter { !($0.contains("/usr/lib/") || $0.contains("/System/")) }
        log("  Links \(libs.count) libraries (\(sys.count) system)")
        for l in other { log("    \(l)") }
        let fws = sys.compactMap { s -> String? in
            guard let r = s.range(of: "/Frameworks/"), let e = s.range(of: ".framework") else { return nil }
            return String(s[r.upperBound..<e.lowerBound])
        }
        if !fws.isEmpty { log("  System frameworks: " + fws.sorted().joined(separator: ", ")) }
        if !rpaths.isEmpty { log("  rpaths: " + rpaths.joined(separator: ", ")) }
        // the Swift runtime and the compiler leave strings behind that say what built the binary
        let hay = d.count > 80_000_000 ? d.prefix(80_000_000) : d[...]
        if let sw = findString(hay, prefix: "Swift version ") { log("  Compiler: \(sw)") }
        if libs.contains(where: { $0.contains("libswift") }) { log("  Written in Swift (links the Swift runtime)") }
        if libs.contains(where: { $0.contains("libc++") }) { log("  Uses C++") }
    }

    private func findString(_ d: Data, prefix: String) -> String? {
        guard let r = d.range(of: Data(prefix.utf8)) else { return nil }
        let tail = d[r.lowerBound...].prefix(120)
        return String(decoding: tail.prefix { $0 >= 32 && $0 < 127 }, as: UTF8.self)
    }

    private func cpu(_ t: Int) -> String { t == 0x0100000C ? "arm64" : t == 0x0200000C ? "arm64e" : t == 12 ? "armv7" : t == 0x01000007 ? "x86_64" : "cpu \(t)" }
    private func ver(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF)" + ((v & 0xFF) != 0 ? ".\(v & 0xFF)" : "") }

    /// The provisioning profile is a CMS blob around an XML plist.
    static func provisioning(_ d: Data) -> [String: Any]? {
        guard let s = d.range(of: Data("<?xml".utf8)), let e = d.range(of: Data("</plist>".utf8)) else { return nil }
        let xml = d.subdata(in: s.lowerBound..<e.upperBound)
        return (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any]
    }

    // MARK: Alter

    /// Applies the new values to Info.plist (and the extensions' bundle ids, which must stay prefixed by the app's) and zips.
    func repack(name: String?, bundleID: String?, version: String?, build: String?, minOS: String?, to out: URL) throws {
        guard let app = appDir else { return }
        let infoURL = app.appendingPathComponent("Info.plist")
        var p = plist
        let oldID = p["CFBundleIdentifier"] as? String ?? ""
        func set(_ k: String, _ v: String?) { if let v, !v.isEmpty, "\(p[k] ?? "")" != v { log("Set \(k): \(p[k] ?? "(none)") -> \(v)"); p[k] = v } }
        set("CFBundleDisplayName", name)
        if let name, !name.isEmpty { set("CFBundleName", name) }
        set("CFBundleIdentifier", bundleID)
        set("CFBundleShortVersionString", version)
        set("CFBundleVersion", build)
        set("MinimumOSVersion", minOS)
        try write(p, to: infoURL)
        plist = p
        if let new = bundleID, !new.isEmpty, !oldID.isEmpty, new != oldID, let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "appex" {
                let ip = u.appendingPathComponent("Info.plist")
                guard var ep = Self.readPlist(ip), let id = ep["CFBundleIdentifier"] as? String, id.hasPrefix(oldID) else { continue }
                ep["CFBundleIdentifier"] = new + id.dropFirst(oldID.count)
                try write(ep, to: ip)
                log("Set \(u.lastPathComponent) bundle id -> \(ep["CFBundleIdentifier"]!)")
            }
        }
        // the old signature no longer matches; a sideloader signs it again
        try? FileManager.default.removeItem(at: app.appendingPathComponent("_CodeSignature"))
        try Zip.create(from: work, to: out)
        log("Wrote \(out.lastPathComponent) (\(size((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0))). The signature was removed; sign it with FlareStore when you install it.")
    }

    private func write(_ p: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0).write(to: url)
    }
}
