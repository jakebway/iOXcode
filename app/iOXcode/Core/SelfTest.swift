import Foundation
import UIKit

/// The test report: builds a fixed set of projects and writes down what worked.
///   Tier 1: small sample projects shipped inside the app (one feature each).
///   Tier 2: real public GitHub repositories, imported by link exactly like a user would.
/// Run it after every new IPA; the report says what the build can and cannot do yet.
enum SelfTest {
    struct Case {
        var name: String
        var title: String
        var expect: [String]
        var gap: Bool
        var source: Source
        enum Source { case bundled(URL), github(String, String, String?) }
    }

    struct Outcome {
        var name: String
        var title: String
        var status: String        // PASS | FAIL | GAP (known missing feature) | SKIP
        var seconds: Int
        var detail: String
        var log: [String]
    }

    /// Real-world apps. Editable: owner, repo, optional branch.
    static let repos: [(String, String, String?)] = [
        ("nalexn", "clean-architecture-swiftui", nil),
        ("kishikawakatsumi", "KeychainAccess", nil),
        ("Dimillian", "IceCubesApp", nil),
    ]

    static func bundledCases() -> [Case] {
        guard let base = Bundle.main.url(forResource: "Samples", withExtension: nil),
              let kids = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return kids.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { dir in
            var title = dir.lastPathComponent, expect: [String] = [], gap = false
            if let d = try? Data(contentsOf: dir.appendingPathComponent("selftest.json")),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                title = (o["title"] as? String) ?? title
                expect = (o["expect"] as? [String]) ?? []
                gap = (o["gap"] as? Bool) ?? false
            }
            return Case(name: dir.lastPathComponent, title: title, expect: expect, gap: gap, source: .bundled(dir))
        }
    }

    static func githubCases() -> [Case] {
        repos.map { Case(name: "\($0.0)/\($0.1)", title: "Public repo imported by link: github.com/\($0.0)/\($0.1)",
                         expect: ["Info.plist"], gap: false, source: .github($0.0, $0.1, $0.2)) }
    }

    // MARK: running

    static func run(includeRepos: Bool, progress: @escaping (String) -> Void) -> (text: String, file: URL) {
        let started = Date()
        var cases = bundledCases()
        if includeRepos { cases += githubCases() }
        var outcomes: [Outcome] = []
        for (i, c) in cases.enumerated() {
            progress("Test \(i + 1)/\(cases.count): \(c.name)")
            outcomes.append(runOne(c))
        }
        let text = report(outcomes, total: Int(Date().timeIntervalSince(started)))
        try? FileManager.default.createDirectory(at: Paths.output, withIntermediateDirectories: true)
        let url = Paths.output.appendingPathComponent("test-report.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return (text, url)
    }

    static func runOne(_ c: Case) -> Outcome {
        let t0 = Date()
        var lines: [String] = []
        let lock = NSLock()
        let sink = LogSink { s in lock.lock(); lines.append(s); lock.unlock() }
        func done(_ status: String, _ detail: String) -> Outcome {
            lock.lock(); defer { lock.unlock() }
            return Outcome(name: c.name, title: c.title, status: status, seconds: Int(Date().timeIntervalSince(t0)), detail: detail, log: lines)
        }
        let fm = FileManager.default
        let root = Paths.projects.appendingPathComponent("_selftest", isDirectory: true)
        let dest = root.appendingPathComponent(c.name.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try? fm.removeItem(at: dest)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            switch c.source {
            case .bundled(let dir):
                try fm.copyItem(at: dir, to: dest)
                try? fm.removeItem(at: dest.appendingPathComponent("selftest.json"))
            case .github(let owner, let repo, let branch):
                let zip = try download(owner: owner, repo: repo, ref: branch)
                defer { try? fm.removeItem(at: zip) }
                try Zip.extract(zip, to: dest)
                let kids = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
                if kids.count == 1, (try? kids[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let tmp = dest.appendingPathExtension("tmp")
                    try fm.moveItem(at: kids[0], to: tmp)
                    try fm.removeItem(at: dest)
                    try fm.moveItem(at: tmp, to: dest)
                }
            }
        } catch {
            return done("FAIL", "could not set up the project: \(error.localizedDescription)")
        }
        let project = Project(url: dest)
        Generator.refresh(project, log: sink)
        for w in project.warnings { sink.log("note: \(w)") }
        do {
            let ipa = try BuildPipeline(project: project, log: sink).run()
            let names = Zip.names(ipa)
            let missing = c.expect.filter { want in !names.contains { $0.contains(want) } }
            if !missing.isEmpty { return done(c.gap ? "GAP" : "FAIL", "built, but the IPA is missing: \(missing.joined(separator: ", "))") }
            let size = ((try? fm.attributesOfItem(atPath: ipa.path)[.size] as? Int) ?? 0) / 1024
            let warns = lines.filter { $0.hasPrefix("warning:") || $0.hasPrefix("note:") }.count
            return done("PASS", "IPA \(size) KB, \(warns) warning(s)/note(s)")
        } catch {
            let msg = "\(error)"
            let firstError = lines.first { $0.contains("error:") }.map { String($0.split(separator: "/").last ?? "") } ?? ""
            return done(c.gap ? "GAP" : "FAIL", firstError.isEmpty ? msg : "\(msg) | \(firstError.prefix(200))")
        }
    }

    // MARK: GitHub download (blocking)

    static func download(owner: String, repo: String, ref: String?) throws -> URL {
        let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/zipball/\(ref ?? "HEAD")")!
        var req = URLRequest(url: api)
        req.setValue("iOXcode", forHTTPHeaderField: "User-Agent")
        var result: Result<URL, Error> = .failure(NSError(domain: "SelfTest", code: 1))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(err); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let tmp = tmp else { result = .failure(NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(code)"])); return }
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(repo)-\(UUID().uuidString).zip")
            do { try FileManager.default.moveItem(at: tmp, to: dst); result = .success(dst) } catch { result = .failure(error) }
        }.resume()
        sem.wait()
        return try result.get()
    }

    // MARK: report

    static func report(_ outcomes: [Outcome], total: Int) -> String {
        let device = UIDevice.current
        var s = "iOXcode test report\n"
        s += "date: \(ISO8601DateFormatter().string(from: Date()))\n"
        s += "device: \(device.model), iOS \(device.systemVersion), \(CompilerHost.shared.availableMemoryMB) MB free\n"
        s += "app: \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?") (\((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"))\n"
        s += "compiler: \(CompilerHost.shared.isLoaded ? "loaded, ABI \(CompilerHost.shared.abiVersion)" : "not loaded")\n"
        s += "sdk: \(SDKLayout.locate()?.sdk.lastPathComponent ?? "missing")\n"
        s += "python: \(PythonHost.shared.isAvailable ? "built in" : "missing")\n"
        let fw = Bundle.main.privateFrameworksURL
        let macros = ["SwiftInProcPluginServer", "ObservationMacros", "SwiftMacros"].filter { n in
            fw.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(n).framework/\(n)").path) } ?? false }
        s += "macro plugins: \(macros.isEmpty ? "none" : macros.joined(separator: ", "))\n\n"
        let pass = outcomes.filter { $0.status == "PASS" }.count
        let gap = outcomes.filter { $0.status == "GAP" }.count
        let fail = outcomes.filter { $0.status == "FAIL" }.count
        s += "RESULT: \(pass) passed, \(fail) failed, \(gap) known gaps, \(outcomes.count) total, \(total)s\n\n"
        for o in outcomes {
            s += "[\(o.status)] \(o.name) (\(o.seconds)s)\n    \(o.title)\n    \(o.detail)\n"
        }
        for o in outcomes where o.status == "FAIL" || o.status == "GAP" {
            s += "\n---- log: \(o.name) (last lines)\n"
            s += o.log.suffix(40).map { String($0.prefix(400)) }.joined(separator: "\n") + "\n"
        }
        return s
    }
}
