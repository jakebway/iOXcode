import Foundation

struct ToolResult {
    var exitCode: Int32
    var message: String
}

/// Wraps the C shim around libSwiftCompilerBridge.dylib. The compiler needs a very large stack, so every
/// call runs on its own thread. Only one call can run at a time.
final class CompilerHost {
    static let shared = CompilerHost()
    private let gate = NSLock()

    var isLoaded: Bool { ioxc_is_loaded() != 0 }

    func load() -> String? {
        if isLoaded { return nil }
        guard let url = Paths.compilerLibrary else {
            return "The compiler library (libSwiftCompilerBridge.dylib) is not inside this app. Build the app from the 'App' workflow after the 'Compiler' workflow has finished."
        }
        var buffer = [CChar](repeating: 0, count: 2048)
        let rc = ioxc_load(url.path, &buffer, buffer.count)
        if rc != 0 { return "Could not load the compiler: " + String(cString: buffer) }
        return nil
    }

    var abiVersion: UInt32 { ioxc_abi_version() }
    var availableMemoryMB: Int { Int(ioxc_available_memory() / 1_048_576) }

    func frontend(_ args: [String]) -> ToolResult { run(args, link: false) }
    /// `args` must start with the program name, for example "ld64.lld".
    func link(_ args: [String]) -> ToolResult { run(args, link: true) }

    private func run(_ args: [String], link: Bool) -> ToolResult {
        gate.lock()
        defer { gate.unlock() }
        var result = ToolResult(exitCode: 1, message: "did not run")
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = CompilerHost.invoke(args, link: link)
            done.signal()
        }
        thread.stackSize = 512 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
        done.wait()
        return result
    }

    private static func invoke(_ args: [String], link: Bool) -> ToolResult {
        // The compiler prints its detailed diagnostics to stderr: capture them in a file for the duration of the call.
        let path = NSTemporaryDirectory() + "ioxc-stderr.txt"
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 { dup2(fd, STDERR_FILENO); close(fd) }

        // Keep the C strings alive for the duration of the call.
        var pointers: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        let r: SwiftCompilerResult = pointers.withUnsafeMutableBufferPointer { buf in
            let base = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            return link ? ioxc_link(Int32(args.count), base) : ioxc_frontend(Int32(args.count), base)
        }
        pointers.forEach { free($0) }

        fflush(stderr)
        if saved >= 0 { dup2(saved, STDERR_FILENO); close(saved) }
        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        var text = ""
        if let m = r.message, r.messageLength > 0 {
            let data = Data(bytes: m, count: Int(r.messageLength))
            text = String(decoding: data, as: UTF8.self)
        }
        if let m = r.message { ioxc_release(m) }
        if !captured.isEmpty { text = text.isEmpty ? captured : text + "\n" + captured }
        return ToolResult(exitCode: r.exitCode, message: text)
    }
}
