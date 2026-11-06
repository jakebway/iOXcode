import Foundation

/// Compiles C, Objective-C, Objective-C++ and C++ sources with clang running inside the app.
struct CCompiler {
    static let extensions: Set<String> = ["c", "m", "mm", "cpp", "cc", "cxx"]

    let log: LogSink
    let sdk: URL
    let clangResource: URL?        // the directory that holds include/ with clang's own headers
    let target: String             // arm64-apple-ios16.0
    let moduleCache: URL

    struct Options {
        var includeDirs: [String] = []
        var systemIncludeDirs: [String] = []
        var frameworkDirs: [String] = []
        var defines: [String] = []
        var extraFlags: [String] = []
        var arc = false
        var optimize = false
        var modules = true
        var prefixHeader: String?
    }

    /// Every directory below `roots` that holds a header, so `#include "x.h"` and `#include <x.h>` find it the way
    /// Xcode's recursive header search does for a project.
    static func headerDirectories(under roots: [URL], limit: Int = 400) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        var seen = Set<String>()
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let u as URL in en {
                let name = u.lastPathComponent
                if name.hasPrefix(".") || name == "build" || name == "Pods" || name == "DerivedData" { en.skipDescendants(); continue }
                if ["h", "hpp", "hh"].contains(u.pathExtension.lowercased()) {
                    let d = u.deletingLastPathComponent().standardizedFileURL.path
                    if seen.insert(d).inserted { out.append(d) }
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    /// Compiles each file to an object in `dir`. Throws on the first failure.
    func compile(_ files: [URL], into dir: URL, options o: Options, label: String) throws -> [URL] {
        guard !files.isEmpty else { return [] }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var objects: [URL] = []
        log.log("-- compiling \(files.count) C/Objective-C file\(files.count == 1 ? "" : "s") (\(label))")
        for (i, file) in files.enumerated() {
            let ext = file.pathExtension.lowercased()
            let out = dir.appendingPathComponent(String(format: "%03d_", i) + file.deletingPathExtension().lastPathComponent + ".o")
            var a: [String] = ["clang", "-c", file.path, "-o", out.path,
                               "-target", target, "-isysroot", sdk.path, "-fblocks", "-fno-common", "-w", "-fexceptions",
                               "-fvisibility=default", "-ffunction-sections", "-fdata-sections"]
            if let c = clangResource { a += ["-resource-dir", c.path] }
            switch ext {
            case "c": a += ["-std=gnu11"]
            case "m": a += ["-std=gnu11", "-fobjc-exceptions"]
            case "mm": a += ["-std=gnu++17", "-fobjc-exceptions"]
            default: a += ["-std=gnu++17"]
            }
            if ext == "m" || ext == "mm" { a += [o.arc ? "-fobjc-arc" : "-fno-objc-arc"] }
            if o.modules {
                a += ["-fmodules", "-fimplicit-module-maps", "-fmodules-cache-path=\(moduleCache.path)", "-fno-modules-validate-system-headers"]
            }
            a += o.optimize ? ["-O2"] : ["-O0"]
            a += ["-DNDEBUG=1"]
            for d in o.defines { a += ["-D", d] }
            // headers beside the source come first, as with a quoted include
            a += ["-I", file.deletingLastPathComponent().path]
            for d in o.includeDirs { a += ["-I", d] }
            for d in o.systemIncludeDirs { a += ["-isystem", d] }
            for d in o.frameworkDirs { a += ["-F", d] }
            if let p = o.prefixHeader { a += ["-include", p] }
            a += o.extraFlags
            let r = CompilerHost.shared.clang(a)
            if !r.message.isEmpty { log.log(r.message) }
            guard r.exitCode == 0 else { throw BuildError.message("clang failed on \(file.lastPathComponent) (exit \(r.exitCode))") }
            objects.append(out)
        }
        return objects
    }
}
