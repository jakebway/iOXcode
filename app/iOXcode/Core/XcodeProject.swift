import Foundation

/// Reads a real Xcode project (project.pbxproj) and turns its first app target into a Manifest.
enum XcodeProjectReader {
    struct Result {
        var manifest: Manifest
        var root: URL
        var warnings: [String]
    }

    static func findProject(in dir: URL) -> URL? {
        let fm = FileManager.default
        func scan(_ d: URL) -> URL? {
            let kids = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            return kids.first { $0.pathExtension == "xcodeproj" }
        }
        if let p = scan(dir) { return p }
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for k in kids {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: k.path, isDirectory: &isDir), isDir.boolValue, k.pathExtension != "xcodeproj" {
                if let p = scan(k) { return p }
            }
        }
        return nil
    }

    static func read(projectDir: URL) -> Result? {
        guard let proj = findProject(in: projectDir) else { return nil }
        let root = proj.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: proj.appendingPathComponent("project.pbxproj")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else { return nil }
        var warnings: [String] = []

        // parent map so that group paths can be resolved
        var parent: [String: String] = [:]
        for (id, o) in objects {
            let isa = o["isa"] as? String ?? ""
            if isa == "PBXGroup" || isa == "PBXVariantGroup" || isa == "XCVersionGroup" {
                for c in (o["children"] as? [String]) ?? [] { parent[c] = id }
            }
        }
        func resolve(_ id: String) -> String? {
            guard let o = objects[id] else { return nil }
            let path = o["path"] as? String
            let tree = o["sourceTree"] as? String ?? "<group>"
            switch tree {
            case "SOURCE_ROOT": return path ?? ""
            case "<group>":
                let base = parent[id].flatMap { resolve($0) } ?? ""
                guard let p = path else { return base }
                return base.isEmpty ? p : base + "/" + p
            default: return nil
            }
        }

        // pick the first application target
        let targets = objects.filter { ($0.value["isa"] as? String) == "PBXNativeTarget" }
        let appTargets = targets.filter { ($0.value["productType"] as? String) == "com.apple.product-type.application" }
        guard let target = (appTargets.sorted { ($0.value["name"] as? String ?? "") < ($1.value["name"] as? String ?? "") }.first) else { return nil }
        let targetName = target.value["name"] as? String ?? "App"
        if appTargets.count > 1 { warnings.append("This project has \(appTargets.count) app targets; building \(targetName).") }
        if targets.count > appTargets.count { warnings.append("Extensions, widgets and other targets are not built yet.") }

        // build settings: project level, then target level (Release)
        func settings(forList id: String?) -> [String: Any] {
            guard let id = id, let list = objects[id], let cfgs = list["buildConfigurations"] as? [String] else { return [:] }
            let all = cfgs.compactMap { objects[$0] }
            let pick = all.first { ($0["name"] as? String) == "Release" } ?? all.first
            return (pick?["buildSettings"] as? [String: Any]) ?? [:]
        }
        let projectObj = objects.first { ($0.value["isa"] as? String) == "PBXProject" }?.value
        var bs = settings(forList: projectObj?["buildConfigurationList"] as? String)
        for (k, v) in settings(forList: target.value["buildConfigurationList"] as? String) { bs[k] = v }

        func str(_ key: String) -> String? {
            if let s = bs[key] as? String { return s }
            if let a = bs[key] as? [String] { return a.joined(separator: " ") }
            return nil
        }
        let productName0 = (str("PRODUCT_NAME") ?? targetName)
        func expand(_ s: String) -> String {
            var out = s
            let vars: [String: String] = ["PRODUCT_NAME": productName0.replacingOccurrences(of: "$(TARGET_NAME)", with: targetName),
                                          "TARGET_NAME": targetName, "SRCROOT": ".", "PROJECT_DIR": ".",
                                          "inherited": "", "PRODUCT_NAME:rfc1034identifier": productName0.filter { $0.isLetter || $0.isNumber || $0 == "-" }]
            for (k, v) in vars {
                out = out.replacingOccurrences(of: "$(\(k))", with: v).replacingOccurrences(of: "${\(k)}", with: v)
            }
            return out
        }

        var m = Manifest()
        let cleanName = expand(productName0).filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        m.name = cleanName.isEmpty ? "App" : cleanName
        if let n = str("INFOPLIST_KEY_CFBundleDisplayName") { m.displayName = expand(n) }
        m.bundleId = expand(str("PRODUCT_BUNDLE_IDENTIFIER") ?? "com.example.\(m.name.lowercased())")
        if let v = str("MARKETING_VERSION") { m.version = expand(v) }
        if let v = str("CURRENT_PROJECT_VERSION") { m.build = expand(v) }
        if let v = str("IPHONEOS_DEPLOYMENT_TARGET") { m.minOS = expand(v) }
        if let v = str("SWIFT_VERSION") { m.swiftVersion = expand(v).replacingOccurrences(of: ".0", with: "") }
        if let h = str("SWIFT_OBJC_BRIDGING_HEADER") { m.bridgingHeader = expand(h).replacingOccurrences(of: "./", with: "") }
        switch str("SWIFT_OPTIMIZATION_LEVEL") ?? "" {
        case "-O", "-Ounchecked": m.optimization = "speed"
        case "-Osize": m.optimization = "size"
        default: m.optimization = "none"
        }
        if let f = str("INFOPLIST_FILE") { m.infoPlistFile = expand(f).replacingOccurrences(of: "./", with: "") }
        for (k, v) in bs where k.hasPrefix("INFOPLIST_KEY_") {
            let key = String(k.dropFirst("INFOPLIST_KEY_".count))
            if let s = v as? String, !s.isEmpty, s != "YES", s != "NO", !key.contains("Generation") { m.infoPlist[key] = expand(s) }
        }
        m.swiftFlags = (str("OTHER_SWIFT_FLAGS") ?? "").split(separator: " ").map(String.init).filter { !$0.hasPrefix("$") && !$0.isEmpty }
        m.linkerFlags = []
        // OTHER_LDFLAGS: -lname, -framework Name, everything else is passed through
        var extraLibs: [String] = [], extraFrameworks: [String] = []
        do {
            let raw: String = expand(str("OTHER_LDFLAGS") ?? "")
            let pieces: [String] = raw.split(separator: " ").map { String($0) }
            var toks: [String] = []
            for piece in pieces {
                if piece.isEmpty || piece == "$(inherited)" || piece == "-ObjC" { continue }
                toks.append(piece)
            }
            var i = 0
            while i < toks.count {
                let t = toks[i]
                if t == "-framework", i + 1 < toks.count { extraFrameworks.append(toks[i + 1]); i += 2; continue }
                if t.hasPrefix("-l") && t.count > 2 { extraLibs.append(String(t.dropFirst(2))) }
                else if !t.hasPrefix("$") { m.linkerFlags.append(t) }
                i += 1
            }
        }
        if (str("OTHER_LDFLAGS") ?? "").contains("-ObjC") { m.linkerFlags.append("-ObjC") }

        // build phases
        var swiftFiles: [String] = []
        var resources: [String] = []
        var frameworks: [String] = []
        var libs: [String] = []
        var libDirs: [String] = []
        var cSources: [String] = []
        var scripts: [BuildScript] = []
        var sawSources = false
        for phaseId in (target.value["buildPhases"] as? [String]) ?? [] {
            guard let phase = objects[phaseId], let isa = phase["isa"] as? String else { continue }
            if isa == "PBXSourcesBuildPhase" { sawSources = true }
            if isa == "PBXShellScriptBuildPhase", let text = phase["shellScript"] as? String {
                let name = (phase["name"] as? String) ?? "Run Script"
                let shell = (phase["shellPath"] as? String) ?? "/bin/sh"
                let body = shell.contains("python") ? "python3 - <<'IOXCODE_PY'\n\(text)\nIOXCODE_PY\n" : text
                scripts.append(BuildScript(name: name, script: body, afterCompile: sawSources))
                continue
            }
            for bf in (phase["files"] as? [String]) ?? [] {
                guard let buildFile = objects[bf] else { continue }
                if buildFile["productRef"] != nil { continue }
                guard let ref = buildFile["fileRef"] as? String, let fo = objects[ref] else { continue }
                let name = (fo["path"] as? String) ?? (fo["name"] as? String) ?? ""
                let ext = (name as NSString).pathExtension.lowercased()
                switch isa {
                case "PBXSourcesBuildPhase":
                    if ext == "swift", let p = resolve(ref) { swiftFiles.append(p) }
                    else if CCompiler.extensions.contains(ext), let p = resolve(ref) { cSources.append(p) }
                case "PBXResourcesBuildPhase":
                    if (fo["isa"] as? String) == "PBXVariantGroup" { continue }
                    if let p = resolve(ref) { resources.append(p) }
                case "PBXFrameworksBuildPhase":
                    let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
                    if ext == "framework" { frameworks.append(base) }
                    else if ext == "tbd" || ext == "dylib" { libs.append(base.hasPrefix("lib") ? String(base.dropFirst(3)) : base) }
                    else if ext == "a", let p = resolve(ref) {
                        libs.append(base.hasPrefix("lib") ? String(base.dropFirst(3)) : base)
                        libDirs.append((p as NSString).deletingLastPathComponent)
                    }
                default: break
                }
            }
        }
        // Folder-synced groups (Xcode 16+): every file in the folder belongs to the target, except listed exceptions.
        var syncedDirs: [String] = []
        var syncedExcludes: [String] = []
        for gid in (target.value["fileSystemSynchronizedGroups"] as? [String]) ?? [] {
            guard let g = objects[gid], let dir = resolve(gid) else { continue }
            syncedDirs.append(dir)
            for eid in (g["exceptions"] as? [String]) ?? [] {
                guard let ex = objects[eid], (ex["target"] as? String) == nil || (ex["target"] as? String) == target.key else { continue }
                for e in (ex["membershipExceptions"] as? [String]) ?? [] { syncedExcludes.append(dir + "/" + e) }
            }
        }
        if !syncedDirs.isEmpty {
            let fm = FileManager.default
            let ex = syncedExcludes.map { root.appendingPathComponent($0).standardizedFileURL.path }
            for d in syncedDirs {
                let base = root.appendingPathComponent(d)
                guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in en {
                    if u.lastPathComponent.hasPrefix(".") { en.skipDescendants(); continue }
                    let path = u.standardizedFileURL.path
                    if ex.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { en.skipDescendants(); continue }
                    let rel = String(path.dropFirst(root.standardizedFileURL.path.count + 1))
                    if u.pathExtension == "swift" { swiftFiles.append(rel) }
                    else if CCompiler.extensions.contains(u.pathExtension.lowercased()) { cSources.append(rel) }
                }
            }
            m.sources = syncedDirs
            m.excludes = syncedExcludes
            m.sourceResources = true
        }

        // Swift packages that live inside the project folder (referenced by path)
        var localDirs: [String: String] = [:]      // relative dir -> Package.swift text
        func addLocal(_ rel: String) {
            let pkg = root.appendingPathComponent(rel).appendingPathComponent("Package.swift")
            if let t = try? String(contentsOf: pkg, encoding: .utf8) { localDirs[rel] = t }
        }
        for (id, o) in objects {
            if (o["isa"] as? String) == "XCLocalSwiftPackageReference", let rel = o["relativePath"] as? String { addLocal(rel) }
            else if (o["isa"] as? String) == "PBXFileReference", (o["lastKnownFileType"] as? String) == "wrapper", let rel = resolve(id) { addLocal(rel) }
        }

        // Swift packages: XCRemoteSwiftPackageReference + the products this target links
        var wanted: [String: [String]] = [:]     // package reference id -> product names
        for pid in (target.value["packageProductDependencies"] as? [String]) ?? [] {
            guard let dep = objects[pid], let pname = dep["productName"] as? String else { continue }
            if let pref = dep["package"] as? String { wanted[pref, default: []].append(pname) }
            else if let rel = localDirs.first(where: { $0.value.contains("\"\(pname)\"") })?.key { wanted["local:" + rel, default: []].append(pname) }
        }
        var packages: [PackageRef] = []
        for (id, products) in wanted {
            if id.hasPrefix("local:") {
                let rel = String(id.dropFirst(6))
                let abs = root.appendingPathComponent(rel).standardizedFileURL.path
                packages.append(PackageRef(name: (rel as NSString).lastPathComponent, url: abs, kind: "local", value: "", products: products))
                continue
            }
            guard let o = objects[id] else { continue }
            if let rel = o["relativePath"] as? String {
                let abs = root.appendingPathComponent(rel).standardizedFileURL.path
                packages.append(PackageRef(name: (rel as NSString).lastPathComponent, url: abs, kind: "local", value: "", products: products))
            } else if let url = o["repositoryURL"] as? String {
                var kind = "branch", value = "HEAD"
                if let r = o["requirement"] as? [String: Any] {
                    switch r["kind"] as? String ?? "" {
                    case "upToNextMajorVersion": kind = "from"; value = r["minimumVersion"] as? String ?? ""
                    case "upToNextMinorVersion": kind = "minor"; value = r["minimumVersion"] as? String ?? ""
                    case "exactVersion": kind = "exact"; value = r["version"] as? String ?? ""
                    case "versionRange": kind = "from"; value = r["minimumVersion"] as? String ?? ""
                    case "branch": kind = "branch"; value = r["branch"] as? String ?? "HEAD"
                    case "revision": kind = "revision"; value = r["revision"] as? String ?? ""
                    default: break
                    }
                }
                packages.append(PackageRef(name: (url as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: ""), url: url, kind: kind, value: value, products: products))
            }
        }
        m.packages = packages
        m.swiftFiles = swiftFiles
        m.cFiles = cSources
        if let d = str("GCC_PREPROCESSOR_DEFINITIONS") { m.cDefines = d.split(separator: " ").map(String.init).filter { !$0.contains("$") && !$0.isEmpty } }
        if let a = str("CLANG_ENABLE_OBJC_ARC") { m.objcArc = a != "NO" }
        m.scripts = scripts
        m.resources = resources
        m.frameworks = frameworks + extraFrameworks
        m.libraries = libs + extraLibs
        // library search paths from build settings
        var dirs = libDirs
        if let ls = str("LIBRARY_SEARCH_PATHS") {
            for d in ls.split(separator: " ") { let e = expand(String(d)).replacingOccurrences(of: "\"", with: ""); if !e.hasPrefix("$") { dirs.append(e) } }
        }
        m.libraryDirs = Array(Set(dirs)).sorted()
        return Result(manifest: m, root: root, warnings: warnings)
    }
}
