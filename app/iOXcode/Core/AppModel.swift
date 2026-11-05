import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var console = Console()
    @Published var building = false
    @Published var lastIPA: URL?
    @Published var shareIPA = false
    @Published var compilerStatus = "Not checked"
    @Published var sdkStatus = "Not installed"
    @Published var importing = false
    @Published var importMessage = ""
    @Published var notice: String?
    @Published var tab = 0

    init() {
        Paths.prepare()
        if Paths.compilerLibrary != nil { _ = CompilerHost.shared.load() }
        refresh()
    }

    static func isSDKPath(_ name: String) -> Bool {
        let first = name.split(separator: "/").first.map(String.init) ?? ""
        return first.hasPrefix("iPhoneOS") && first.hasSuffix(".sdk")
    }

    /// If an SDK pack ended up in the project list (added with the + button), move it to its proper place.
    private func migrateMisplacedSDK() {
        let fm = FileManager.default
        for p in Project.all() {
            let kids = (try? fm.contentsOfDirectory(atPath: p.url.path)) ?? []
            if kids.contains(where: { Self.isSDKPath($0) }) {
                try? fm.removeItem(at: Paths.sdkRoot)
                try? fm.moveItem(at: p.url, to: Paths.sdkRoot)
            }
        }
        Paths.ensure(Paths.sdkRoot)
    }

    func refresh() {
        migrateMisplacedSDK()
        projects = Project.all()
        if let l = SDKLayout.locate() { sdkStatus = "Ready (\(l.sdk.lastPathComponent))" }
        else { sdkStatus = SDKLayout.problem().map { "Not installed: \($0)" } ?? "Not installed" }
        if Paths.compilerLibrary == nil { compilerStatus = "Missing from this app" }
        else if CompilerHost.shared.isLoaded { compilerStatus = "Loaded (ABI \(CompilerHost.shared.abiVersion))" }
        else { compilerStatus = "Present" }
    }

    func loadCompiler() {
        if let e = CompilerHost.shared.load() { compilerStatus = e; console.line(e) }
        else { compilerStatus = "Loaded (ABI \(CompilerHost.shared.abiVersion))" }
    }

    func build(_ p: Project) {
        guard !building else { return }
        building = true
        tab = 1
        console.clear()
        let logURL = Paths.output.appendingPathComponent("last-build.log")
        try? FileManager.default.createDirectory(at: Paths.output, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logFile = try? FileHandle(forWritingTo: logURL)
        let sink = LogSink { [weak self] s in
            logFile?.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
            Task { @MainActor in self?.console.line(s) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ipa = try BuildPipeline(project: p, log: sink).run()
                DispatchQueue.main.async { self.lastIPA = ipa; self.shareIPA = true; self.building = false }
            } catch {
                sink.log("BUILD FAILED: \(error)")
                DispatchQueue.main.async { self.building = false }
            }
        }
    }

    /// Imports a project folder or a .zip chosen in Files.
    func importProject(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        // An SDK pack is not a project: store it quietly in the background.
        if !isDir.boolValue, Zip.names(url).contains(where: { Self.isSDKPath($0) }) {
            importSDK(url, scoped: true)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = url.deletingPathExtension().lastPathComponent
            let dest = Paths.projects.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: dest)
            if isDir.boolValue { try fm.copyItem(at: url, to: dest) }
            else {
                try Zip.extract(url, to: dest)
                // a zip with a single top folder: hoist it
                let kids = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
                if kids.count == 1, (try? kids[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let tmp = dest.appendingPathExtension("tmp")
                    try fm.moveItem(at: kids[0], to: tmp)
                    try fm.removeItem(at: dest)
                    try fm.moveItem(at: tmp, to: dest)
                }
            }
            // GitHub wraps artifacts in a zip: if the only thing inside is another zip, unpack that one instead
            if !isDir.boolValue {
                let inner = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? []
                if inner.count == 1, inner[0].pathExtension.lowercased() == "zip" {
                    let tmp = dest.appendingPathExtension("inner")
                    try? fm.removeItem(at: tmp)
                    try Zip.extract(inner[0], to: tmp)
                    try fm.removeItem(at: dest)
                    try fm.moveItem(at: tmp, to: dest)
                    let kids2 = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
                    if kids2.count == 1, (try? kids2[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let t2 = dest.appendingPathExtension("tmp")
                        try fm.moveItem(at: kids2[0], to: t2)
                        try fm.removeItem(at: dest)
                        try fm.moveItem(at: t2, to: dest)
                    }
                }
            }
            console.line("Imported project \(name)")
            notice = "Added \(name)"
        } catch { console.line("Import failed: \(error)"); notice = "Import failed: \(error)" }
        refresh()
    }

    func importSDK(_ url: URL, scoped useScope: Bool = true) {
        importing = true
        importMessage = "Unpacking…"
        let scoped = useScope && url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try? FileManager.default.removeItem(at: Paths.sdkRoot)
                Paths.ensure(Paths.sdkRoot)
                try Zip.extract(url, to: Paths.sdkRoot) { i, n in
                    if i % 500 == 0 { DispatchQueue.main.async { self.importMessage = "Unpacking \(i) of \(n)" } }
                }
                DispatchQueue.main.async { self.importMessage = "Done"; self.importing = false; self.refresh(); self.notice = "SDK pack stored" }
            } catch {
                DispatchQueue.main.async { self.importMessage = "Failed: \(error)"; self.importing = false }
            }
        }
    }

    func delete(_ p: Project) { try? FileManager.default.removeItem(at: p.url); refresh() }
}
