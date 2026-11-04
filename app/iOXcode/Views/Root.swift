import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            ProjectsView().tabItem { Label("Projects", systemImage: "folder") }
            ConsoleView().tabItem { Label("Console", systemImage: "terminal") }
            SetupView().tabItem { Label("Setup", systemImage: "gearshape") }
        }
    }
}

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = false
    var body: some View {
        NavigationView {
            List {
                if model.projects.isEmpty {
                    Text("No projects yet. Tap + and pick a folder or a .zip of your app.").foregroundColor(.secondary)
                }
                ForEach(model.projects) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.name).font(.headline)
                        Text(p.manifest.bundleId).font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("Build IPA") { model.build(p) }
                                .buttonStyle(.borderedProminent).disabled(model.building)
                            Button("Delete", role: .destructive) { model.delete(p) }.buttonStyle(.bordered)
                        }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("iOXcode")
            .toolbar { Button { picking = true } label: { Image(systemName: "plus") } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .zip]) { r in
                if case .success(let u) = r { model.importProject(u) }
            }
            .sheet(isPresented: $model.shareIPA) {
                if let u = model.lastIPA { ShareSheet(items: [u]) }
            }
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationView {
            ScrollView {
                Text(model.console.text.isEmpty ? "Build output appears here." : model.console.text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .textSelection(.enabled)
            }
            .navigationTitle(model.building ? "Building…" : "Console")
            .toolbar {
                if let u = model.lastIPA, !model.building {
                    Button { model.shareIPA = true } label: { Image(systemName: "square.and.arrow.up") }
                    .help(u.lastPathComponent)
                }
            }
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var pickingSDK = false
    @State private var repo = UserDefaults.standard.string(forKey: "sdk-repo") ?? "jakebway/ioxcode-sdk"
    @State private var token = Keychain.get("github-token") ?? ""
    var body: some View {
        NavigationView {
            Form {
                Section("Compiler") {
                    Text(model.compilerStatus)
                    Button("Load compiler") { model.loadCompiler() }
                    Text("Memory available: \(CompilerHost.shared.availableMemoryMB) MB").font(.caption).foregroundColor(.secondary)
                }
                Section("iPhone SDK pack") {
                    Text(model.sdkStatus)
                    TextField("Private repo (owner/name)", text: $repo).autocapitalization(.none).disableAutocorrection(true)
                    SecureField("GitHub token (read-only)", text: $token)
                    Button("Download SDK pack") { model.downloadSDK(repo: repo, token: token) }
                        .disabled(model.importing || token.isEmpty)
                    Button("Or import a .zip from Files") { pickingSDK = true }.disabled(model.importing)
                    if !model.importMessage.isEmpty { Text(model.importMessage).font(.caption) }
                }
                Section { Button("Refresh") { model.refresh() } }
            }
            .navigationTitle("Setup")
            .fileImporter(isPresented: $pickingSDK, allowedContentTypes: [.zip]) { r in
                if case .success(let u) = r { model.importSDK(u) }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
