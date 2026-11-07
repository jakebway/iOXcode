import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Group {
            if sizeClass == .regular {
                // Unfolded / iPad: the repo browser on the left, the live console on the right, side by side.
                HStack(spacing: 0) {
                    tabs(console: false).frame(minWidth: 380, idealWidth: 520, maxWidth: 560)
                    Divider()
                    ConsolePanel()
                }
            } else {
                tabs(console: true)
            }
        }
        .sheet(isPresented: $model.shareIPA) {
            if let u = model.lastIPA { ShareSheet(items: [u]) }
        }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func tabs(console: Bool) -> some View {
        TabView(selection: $model.tab) {
            ProjectsView().tabItem { Label("Projects", systemImage: "folder") }.tag(0)
            if console { ConsoleView().tabItem { Label("Console", systemImage: "terminal") }.tag(1) }
            BuildsView().tabItem { Label("Builds", systemImage: "shippingbox") }.tag(3)
            SetupView().tabItem { Label("Setup", systemImage: "gearshape") }.tag(2)
        }
        .navigationViewStyle(.stack)
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
                        NavigationLink(destination: RepoHomeView(project: p)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.headline)
                                Text(p.manifest.bundleId).font(.caption).foregroundColor(.secondary)
                            }
                        }
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
/// Lines are tinted like a terminal: errors red, warnings yellow, section markers bold, success green.
struct ConsoleBody: View {
    @ObservedObject var console: Console
    let building: Bool
    var dark = false
    private static func tint(_ l: Substring) -> Color? {
        if l.contains("error:") || l.hasPrefix("error") || l.contains("FAILED") { return Color(red: 1, green: 0.38, blue: 0.36) }
        if l.contains("warning:") || l.hasPrefix("warning") { return Color(red: 0.95, green: 0.78, blue: 0.3) }
        if l.hasPrefix("== Done") || l.hasPrefix("verified") { return Color(red: 0.35, green: 0.85, blue: 0.5) }
        if l.hasPrefix("--") || l.hasPrefix("==") { return Color(red: 0.45, green: 0.7, blue: 1) }
        if l.hasPrefix("note:") { return Color(red: 0.6, green: 0.75, blue: 0.9) }
        return nil
    }
    var body: some View {
        let lines = console.text.suffix(30_000).split(separator: "\n", omittingEmptySubsequences: false)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if console.text.isEmpty {
                        Text(building ? "Starting…" : "Build output appears here.").foregroundColor(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            Text(String(l).isEmpty ? " " : String(l))
                                .foregroundColor(Self.tint(l) ?? (dark ? Color(white: 0.85) : .primary))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: dark ? 12 : 11, design: .monospaced))
                .padding(dark ? 14 : 16)
                .textSelection(.enabled)
            }
            .onChange(of: console.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// The console as a permanent pane for wide screens: a terminal-style window with a status bar.
struct ConsolePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(model.building ? Color.yellow : Color.green).frame(width: 9, height: 9)
                Text(model.building ? "Building…" : "Console").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let u = model.lastIPA, !model.building {
                    Button { model.shareIPA = true } label: { Label(u.lastPathComponent, systemImage: "square.and.arrow.up").font(.system(size: 13)) }
                        .buttonStyle(.bordered)
                }
                Button { UIPasteboard.general.string = model.console.text } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(white: 0.11))
            .foregroundColor(.white)
            Divider()
            ConsoleBody(console: model.console, building: model.building, dark: true)
                .background(Color(red: 0.05, green: 0.067, blue: 0.09))
        }
        .environment(\.colorScheme, .dark)
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
