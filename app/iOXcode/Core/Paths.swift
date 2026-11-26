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
    static var builds: URL { root.appendingPathComponent("Builds", isDirectory: true) }
    static var origins: URL { root.appendingPathComponent("Origins", isDirectory: true) }
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

    /// Where the Rust compiler iOXcode carries lives, for `cargo` and `rustc` in build scripts.
    static func rustEnvironment() -> [String: String] {
        var e: [String: String] = ["IOX_CACHES": caches.path]
        guard let fw = Bundle.main.privateFrameworksPath else { return e }
        let lib = (fw as NSString).appendingPathComponent("librustc_driver.dylib")
        guard FileManager.default.fileExists(atPath: lib) else { return e }
        let rust = (Bundle.main.bundlePath as NSString).appendingPathComponent("Rust")
        e["IOX_RUSTC_LIB"] = lib
        e["IOX_RUST_SYSROOT_ARCHIVE"] = (rust as NSString).appendingPathComponent("rustlib-aarch64-apple-ios.tar.gz")
        e["IOX_RUST_WASM_ARCHIVE"] = (rust as NSString).appendingPathComponent("rustlib-wasm32-wasip1.tar.gz")
        e["IOX_SWIFT_WASM_ARCHIVE"] = (rust as NSString).appendingPathComponent("swift-wasm-sdk-6.4.0.tar.gz")
        e["IOX_SWIFTSYNTAX_WASM_ARCHIVE"] = (rust as NSString).appendingPathComponent("swiftsyntax-wasm-604.0.0.tar.gz")
        e["IOX_RUST_PROC_MACROS"] = fw
        e["IOX_RUST_PROC_MACROS_INDEX"] = (rust as NSString).appendingPathComponent("macros")
        return e
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    static func prepare() {
        [root, sdkRoot, projects, work, output, builds, origins, caches].forEach(ensure)
    }
}
