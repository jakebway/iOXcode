import Foundation

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var root: URL { documents.appendingPathComponent("iOXcode", isDirectory: true) }
    static var sdkRoot: URL { root.appendingPathComponent("SDK", isDirectory: true) }
    static var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    static var work: URL { root.appendingPathComponent("Work", isDirectory: true) }
    static var output: URL { root.appendingPathComponent("Output", isDirectory: true) }
    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iOXcode", isDirectory: true)
    }

    /// The compiler library is shipped inside the app so that it is signed together with it.
    static var compilerLibrary: URL? {
        let names = ["libSwiftCompilerBridge.dylib"]
        var dirs: [String] = []
        if let p = Bundle.main.privateFrameworksPath { dirs.append(p) }
        dirs.append(Bundle.main.bundlePath)
        for d in dirs {
            for n in names {
                let u = URL(fileURLWithPath: d).appendingPathComponent(n)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    static func prepare() {
        [root, sdkRoot, projects, work, output, caches].forEach(ensure)
    }
}
