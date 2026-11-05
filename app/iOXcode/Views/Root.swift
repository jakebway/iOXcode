import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView(selection: $model.tab) {
            ProjectsView().tabItem { Label("Projects", systemImage: "folder") }.tag(0)
            ConsoleView().tabItem { Label("Console", systemImage: "terminal") }.tag(1)
            SetupView().tabItem { Label("Setup", systemImage: "gearshape") }.tag(2)
        }
        .sheet(isPresented: $model.shareIPA) {
            if let u = model.lastIPA { ShareSheet(items: [u]) }
        }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var askLink = false
    @State private var link = ""
    var body: some View {
        NavigationView {
            List {
                if model.importing { HStack { ProgressView(); Text(model.importMessage).padding(.leading, 8) } }
                if model.projects.isEmpty {
                    Text("No projects yet. Tap + and paste a GitHub link, or pick a .zip of your project. Or copy a project folder into Files > On My iPhone > iOXcode > iOXcode > Projects, then pull down to refresh.").foregroundColor(.secondary)
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
            .toolbar {
                Menu {
                    Button { askLink = true } label: { Label("From GitHub link", systemImage: "link") }
                    Button { FilePicker.present(types: [.zip], copy: true) { model.importProject($0) } } label: { Label("From a .zip file", systemImage: "doc.zipper") }
                } label: { Image(systemName: "plus") }
            }
            .alert("Import from GitHub", isPresented: $askLink) {
                TextField("github.com/owner/repo", text: $link).autocapitalization(.none).disableAutocorrection(true)
                Button("Import") { model.importGitHub(link); link = "" }
                Button("Cancel", role: .cancel) { link = "" }
            } message: { Text("Paste a public repository link.") }
            .onAppear { model.refresh() }
            .refreshable { model.refresh() }
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationView {
            ConsoleBody(console: model.console, building: model.building)
                .navigationTitle(model.building ? "Building…" : "Console")
                .toolbar {
                    if let u = model.lastIPA, !model.building {
                        Button { model.shareIPA = true } label: { Image(systemName: "square.and.arrow.up") }
                            .help(u.lastPathComponent)
                    }
                    Button { UIPasteboard.general.string = model.console.text } label: { Image(systemName: "doc.on.doc") }
                }
        }
    }
}

/// Watches the Console object itself, so new lines show up while a build is running.
struct ConsoleBody: View {
    @ObservedObject var console: Console
    let building: Bool
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(console.text.isEmpty ? (building ? "Starting…" : "Build output appears here.") : String(console.text.suffix(30_000)))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: console.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationView {
            Form {
                Section("Compiler") {
                    Text(model.compilerStatus)
                }
                Section("iPhone SDK pack") {
                    Text(model.importing ? model.importMessage : model.sdkStatus)
                    Button("Import SDK pack (.zip)") { FilePicker.present(types: [.zip], copy: true) { model.importSDK($0, scoped: false) } }.disabled(model.importing)
                }
            }
            .navigationTitle("Setup")
            .onAppear { model.refresh() }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
