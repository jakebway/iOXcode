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
    @State private var choosing = false
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
            .toolbar { Button { choosing = true } label: { Image(systemName: "plus") } }
            .confirmationDialog("Add a project", isPresented: $choosing) {
                Button("Choose a folder") { FilePicker.present(types: [.folder], copy: false) { model.importProject($0) } }
                Button("Choose a .zip file") { FilePicker.present(types: [.zip], copy: true) { model.importProject($0) } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .sheet(isPresented: $model.shareIPA) {
            if let u = model.lastIPA { ShareSheet(items: [u]) }
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
