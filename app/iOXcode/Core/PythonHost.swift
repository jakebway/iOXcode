import Foundation

/// The Python that ships inside iOXcode. Build scripts (Xcode Run Script phases, XcodeGen scripts,
/// GitHub workflow steps) run through it, together with ioxsh, a small built-in shell.
final class PythonHost {
    static let shared = PythonHost()
    private let gate = NSLock()
    private var started = false

    private var bundle: URL { Bundle.main.bundleURL }
    var frameworkBinary: URL { bundle.appendingPathComponent("Frameworks/Python.framework/Python") }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: frameworkBinary.path) }

    /// Starts Python once. Returns an error message, or nil when ready.
    func start() -> String? {
        if started { return nil }
        guard isAvailable else { return "This copy of iOXcode has no Python inside (build scripts can't run). Install the newest iOXcode IPA." }
        let home = bundle.appendingPathComponent("python")
        let lib = home.appendingPathComponent("lib")
        let ver = ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).first { $0.hasPrefix("python3.") } ?? "python3"
        let stdlib = lib.appendingPathComponent(ver)
        let paths = [stdlib.path, stdlib.appendingPathComponent("lib-dynload").path, bundle.appendingPathComponent("app_packages").path]
        setenv("PYTHONHOME", home.path, 1)
        setenv("PYTHONPATH", paths.joined(separator: ":"), 1)
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        let setup = "import sys, os\nsys.dont_write_bytecode = True\nimport ioxc_run\n"
        var buffer = [CChar](repeating: 0, count: 1024)
        let rc = ioxc_py_start(frameworkBinary.path, setup, &buffer, buffer.count)
        if rc != 0 { return "Python could not start: " + String(cString: buffer) }
        started = true
        return nil
    }

    enum Job {
        case shell(String)                 // a shell script (ioxsh)
        case script(String)                // a .py file
    }

    /// Runs a job in `cwd` with extra environment variables. Output is streamed to `log` as it arrives.
    func run(_ job: Job, args: [String] = [], cwd: URL, env: [String: String] = [:], log: LogSink? = nil) -> ToolResult {
        gate.lock()
        defer { gate.unlock() }
        if let e = start() { return ToolResult(exitCode: 1, message: e) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ioxc-py-\(UUID().uuidString).txt")
        var req: [String: Any] = ["out": out.path, "cwd": cwd.path, "env": env, "args": args]
        switch job {
        case .shell(let text): req["shell"] = text
        case .script(let path): req["script"] = path
        }
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { return ToolResult(exitCode: 1, message: "bad request") }
        let code = "ioxc_run.run('\(data.base64EncodedString())')"

        var finished = false
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = ioxc_py_exec(code)
            finished = true
            done.signal()
        }
        thread.stackSize = 64 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()

        // stream the output file while the job runs
        var shown = 0
        func pump() {
            guard let d = try? Data(contentsOf: out), d.count > shown else { return }
            let chunk = String(decoding: d[shown...], as: UTF8.self)
            if let nl = chunk.lastIndex(of: "\n") {
                let piece = String(chunk[...nl])
                shown += piece.utf8.count
                for line in piece.split(separator: "\n", omittingEmptySubsequences: false).dropLast() { log?.log(String(line)) }
            }
        }
        while done.wait(timeout: .now() + 0.3) == .timedOut { pump() }
        pump()
        _ = finished
        let bytes = (try? Data(contentsOf: out)) ?? Data()
        let all = String(decoding: bytes, as: UTF8.self)
        if bytes.count > shown { for line in String(decoding: bytes[shown...], as: UTF8.self).split(separator: "\n") { log?.log(String(line)) } }
        let status = Int32((try? String(contentsOf: URL(fileURLWithPath: out.path + ".code"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1") ?? 1
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.removeItem(atPath: out.path + ".code")
        return ToolResult(exitCode: status, message: all)
    }
}
