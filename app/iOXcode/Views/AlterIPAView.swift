import SwiftUI
import UniformTypeIdentifiers

struct AlterIPAView: View {
    @EnvironmentObject var model: AppModel
    @State private var lines = ""
    @State private var inspector: IPAInspector?
    @State private var busy = false
    @State private var name = "", bundleID = "", version = "", build = "", minOS = ""
    @State private var loaded: String?
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        StackNavigation {
            VStack(spacing: 0) {
                if inspector != nil {
                    Form {
                        Section("Alter") {
                            TextField("Display name", text: $name)
                            TextField("Bundle ID", text: $bundleID).autocapitalization(.none).disableAutocorrection(true)
                            TextField("Version", text: $version)
                            TextField("Build", text: $build)
                            TextField("Minimum iOS", text: $minOS)
                            Button("Save altered IPA") { save() }.disabled(busy)
                        }
                    }.frame(maxHeight: 330)
                    Divider()
                }
                ScrollView {
                    Text(lines.isEmpty ? "Pick an .ipa to see what is inside it: bundle info, where it was built, permissions, signing, frameworks and what the executable links." : lines)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .foregroundColor(lines.isEmpty ? .secondary : .primary)
                }
            }
            .navigationTitle(loaded ?? "Alter IPA")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { pick() } label: { Label("Open IPA", systemImage: "square.and.arrow.down") }.disabled(busy)
                }
            }
            .sheet(isPresented: $showShare) { if let u = shareURL { ShareSheet(items: [u]) } }
        }
    }

    private func append(_ s: String) { DispatchQueue.main.async { lines += s + "\n" } }

    private func pick() {
        let t = UTType(filenameExtension: "ipa") ?? .zip
        FilePicker.present(types: [t, .zip, .data], copy: true) { url in open(url) }
    }

    private func open(_ url: URL) {
        busy = true; lines = ""; inspector = nil
        let work = Paths.work.appendingPathComponent("AlterIPA", isDirectory: true)
        let insp = IPAInspector(work: work, log: { append($0) })
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try insp.open(url)
                DispatchQueue.main.async {
                    inspector = insp; loaded = url.lastPathComponent; busy = false
                    name = (insp.plist["CFBundleDisplayName"] ?? insp.plist["CFBundleName"]) as? String ?? ""
                    bundleID = insp.plist["CFBundleIdentifier"] as? String ?? ""
                    version = insp.plist["CFBundleShortVersionString"] as? String ?? ""
                    build = insp.plist["CFBundleVersion"] as? String ?? ""
                    minOS = insp.plist["MinimumOSVersion"] as? String ?? ""
                }
            } catch {
                append("Could not read this file: \(error.localizedDescription)")
                DispatchQueue.main.async { busy = false }
            }
        }
    }

    private func save() {
        guard let insp = inspector else { return }
        busy = true
        let base = (loaded ?? "App.ipa") as NSString
        let out = Paths.output.appendingPathComponent(base.deletingPathExtension + "-altered.ipa")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: Paths.output, withIntermediateDirectories: true)
                try insp.repack(name: name, bundleID: bundleID, version: version, build: build, minOS: minOS, to: out)
                DispatchQueue.main.async { shareURL = out; showShare = true; busy = false }
            } catch {
                append("Save failed: \(error.localizedDescription)")
                DispatchQueue.main.async { busy = false }
            }
        }
    }
}
