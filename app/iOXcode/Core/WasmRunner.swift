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

extension WasmRunner {
    /// A 143-byte WASI program that prints "hello from wasm" (assembled by hand); proves the interpreter works.
    static let helloModule: [UInt8] = [0,97,115,109,1,0,0,0,1,12,2,96,4,127,127,127,127,1,127,96,0,0,2,35,1,22,119,97,115,105,95,115,110,97,112,115,104,111,116,95,112,114,101,118,105,101,119,49,8,102,100,95,119,114,105,116,101,0,0,3,2,1,1,5,3,1,0,1,7,19,2,6,109,101,109,111,114,121,2,0,6,95,115,116,97,114,116,0,1,10,16,1,14,0,65,1,65,0,65,1,65,228,0,16,0,26,11,11,35,2,0,65,0,11,8,8,0,0,0,16,0,0,0,0,65,8,11,16,104,101,108,108,111,32,102,114,111,109,32,119,97,115,109,10]

    /// Runs the hello program and reports in one line; shown in every build log.
    static func selfTest() -> String {
        let path = NSTemporaryDirectory() + "iox-hello.wasm"
        do { try Data(helloModule).write(to: URL(fileURLWithPath: path)) } catch { return "interpreter: could not write test module" }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0 else { return "interpreter: no pipes" }
        let code = run(path: path, args: ["hello.wasm"], environment: [:], preopens: [],
                       stdinFd: open("/dev/null", O_RDONLY), stdoutFd: out[1], stderrFd: err[1])
        close(out[1]); close(err[1])
        func drain(_ fd: Int32) -> String {
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(contentsOf: buf[0..<n]) }
            close(fd); return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let o = drain(out[0]), e = drain(err[0])
        return code == 0 && o == "hello from wasm" ? "WebAssembly interpreter ready (self-test passed)"
                                                  : "WebAssembly interpreter FAILED self-test (exit \(code)) \(o) \(e)"
    }
}
