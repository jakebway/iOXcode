import Foundation
import WasmKit
import WasmKitWASI

/// Runs WebAssembly (WASI preview 1) programs inside the app. iOS can't load code that was compiled on the
/// device, so everything that has to run at build time (Swift macros, Rust build scripts and proc macros,
/// SwiftPM plugins, code generators) is compiled to wasm32-wasip1 instead and interpreted here.
/// Python reaches it through a C function pointer (see `WasmRunner.pointerForPython`).
enum WasmRunner {
    /// Runs one module as a WASI command. Returns its exit code, or -1 if it could not be run
    /// (the reason is written to `stderrFd`).
    static func run(path: String, args: [String], environment: [String: String],
                    preopens: [(guest: String, host: String)],
                    stdinFd: Int32, stdoutFd: Int32, stderrFd: Int32) -> Int32 {
        func complain(_ text: String) {
            let data = Array((text + "\n").utf8)
            _ = data.withUnsafeBytes { write(stderrFd, $0.baseAddress, $0.count) }
        }
        do {
            let module = try parseWasm(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)))
            let wasi = try WASIBridgeToHost(
                args: args,
                environment: environment,
                preopens: preopens.map { WASIBridgeToHost.Preopen(guestPath: $0.guest, hostPath: $0.host) },
                stdin: stdinFd, stdout: stdoutFd, stderr: stderrFd)
            let engine = Engine()
            let store = Store(engine: engine)
            return try wasi.runAndClose { wasi in
                var imports = Imports()
                wasi.link(to: &imports, store: store)
                let instance = try module.instantiate(store: store, imports: imports)
                return Int32(truncatingIfNeeded: try wasi.start(instance))
            }
        } catch {
            complain("wasm: \(error)")
            return -1
        }
    }

    /// `int ioxwasm_run(const char *wasm, int argc, char **argv, int envc, char **envp,
    ///                  int dirc, char **dirs, int in_fd, int out_fd, int err_fd)`
    /// `dirs` entries are "guest::host". The call blocks until the program exits.
    typealias Entry = @convention(c) (UnsafePointer<CChar>, Int32, UnsafePointer<UnsafePointer<CChar>?>,
                                      Int32, UnsafePointer<UnsafePointer<CChar>?>,
                                      Int32, UnsafePointer<UnsafePointer<CChar>?>,
                                      Int32, Int32, Int32) -> Int32

    static let entry: Entry = { wasm, argc, argv, envc, envp, dirc, dirs, inFd, outFd, errFd in
        func strings(_ p: UnsafePointer<UnsafePointer<CChar>?>, _ n: Int32) -> [String] {
            (0..<Int(n)).compactMap { p[$0].map { String(cString: $0) } }
        }
        var env: [String: String] = [:]
        for e in strings(envp, envc) {
            if let eq = e.firstIndex(of: "=") { env[String(e[..<eq])] = String(e[e.index(after: eq)...]) }
        }
        let preopens: [(guest: String, host: String)] = strings(dirs, dirc).map {
            let parts = $0.components(separatedBy: "::")
            return parts.count == 2 ? (parts[0], parts[1]) : ($0, $0)
        }
        let path = String(cString: wasm)
        let arguments = strings(argv, argc)
        var result: Int32 = -1
        let done = DispatchSemaphore(value: 0)
        // The interpreter recurses deeply for large guests, so it gets a big stack of its own.
        let thread = Thread {
            result = run(path: path, args: arguments, environment: env, preopens: preopens,
                         stdinFd: inFd, stdoutFd: outFd, stderrFd: errFd)
            done.signal()
        }
        thread.stackSize = 512 * 1024 * 1024
        thread.start()
        done.wait()
        return result
    }

    /// The address Python calls through ctypes (set as IOX_WASM_ENTRY before Python starts).
    static var pointerForPython: String {
        String(UInt(bitPattern: unsafeBitCast(entry, to: UnsafeRawPointer.self)))
    }
}

/// The in-process linker (lld) for Python: Rust and C build steps that need a WebAssembly link call it
/// (IOX_LINK_ENTRY). `argv[0]` picks the flavor: "wasm-ld" or "ld64.lld".
enum NativeLinker {
    typealias Entry = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>, UnsafeMutablePointer<CChar>, Int32) -> Int32

    static let entry: Entry = { argc, argv, buffer, capacity in
        let result = ioxc_link(argc, argv)
        var text = ""
        if let m = result.message, result.messageLength > 0 {
            text = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(m).assumingMemoryBound(to: UInt8.self),
                                                        count: result.messageLength), as: UTF8.self)
        }
        ioxc_release(result.message)
        let bytes = Array(text.utf8.prefix(max(0, Int(capacity) - 1)))
        for (i, b) in bytes.enumerated() { buffer[i] = CChar(bitPattern: b) }
        buffer[bytes.count] = 0
        return result.exitCode
    }

    static var pointerForPython: String {
        String(UInt(bitPattern: unsafeBitCast(entry, to: UnsafeRawPointer.self)))
    }
}
