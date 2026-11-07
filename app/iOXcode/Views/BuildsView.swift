import SwiftUI

/// Finished IPAs live here.
struct BuildsView: View {
    @EnvironmentObject var model: AppModel
    @State private var sharing: URL?

    var body: some View {
        NavigationView {
            List {
                if model.builds.isEmpty {
                    Text("Finished builds land here. Build a project and its IPA is kept in the app, ready to share or install.").foregroundColor(.secondary)
                }
                ForEach(model.builds) { r in
                    Button { sharing = BuildLibrary.url(for: r) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name).font(.headline).foregroundColor(.primary)
                            Text([r.bundleId, r.version].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
                            Text("\(r.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { model.deleteBuild(r) } }
                    .contextMenu {
                        Button { sharing = BuildLibrary.url(for: r) } label: { Label("Share / Install", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { model.deleteBuild(r) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Builds")
            .onAppear { model.builds = BuildLibrary.load() }
            .refreshable { model.builds = BuildLibrary.load() }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                if let u = sharing { ShareSheet(items: [u]) }
            }
        }
    }
}

/// A repo's GitHub releases, with their files.
struct ReleasesView: View {
    let origin: GitHubOrigin
    @EnvironmentObject var model: AppModel
    @State private var releases: [GitHubRelease]?
    @State private var error: String?
    @State private var busy: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundColor(.red) }
            else if releases == nil { HStack { ProgressView(); Text("Loading releases…").padding(.leading, 8) } }
            else if releases?.isEmpty == true { Text("\(origin.repo) has no releases.").foregroundColor(.secondary) }
            ForEach(releases ?? []) { rel in
                Section {
                    if rel.assets.isEmpty { Text((rel.name ?? rel.tag).localizedCaseInsensitiveContains("ios") ? "No files attached. iOS builds like this are usually distributed through TestFlight or the App Store; build it from source with iOXcode." : "No files attached.").font(.footnote).foregroundColor(.secondary) }
                    ForEach(rel.assets) { a in
                        Button {
                            busy = a.id
                            Task { await model.downloadAsset(a, release: rel, origin: origin); busy = nil }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(a.name).foregroundColor(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if busy == a.id { ProgressView() }
                                else { Image(systemName: a.name.lowercased().hasSuffix(".ipa") ? "tray.and.arrow.down" : "arrow.down.circle") }
                            }
                        }.disabled(busy != nil)
                    }
                } header: {
                    Text([rel.name?.isEmpty == false ? rel.name! : rel.tag, rel.prerelease ? "pre-release" : nil].compactMap { $0 }.joined(separator: " · "))
                } footer: {
                    if let d = rel.published { Text(d.formatted(date: .abbreviated, time: .omitted)) }
                }
            }
        }
        .navigationTitle("Releases")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { releases = try await Releases.fetch(origin); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

/// Opens a project's releases. The GitHub repo is remembered from the import, or worked out from the project itself.
struct ReleasesEntry: View {
    let projectName: String
    @State private var origin: GitHubOrigin?
    @State private var searching = true
    @State private var text = ""
    @State private var bad = false

    var body: some View {
        Group {
            if let origin { ReleasesView(origin: origin) }
            else if searching {
                VStack(spacing: 12) { ProgressView(); Text("Finding this project on GitHub…").foregroundColor(.secondary) }
            } else {
                Form {
                    Section {
                        TextField("github.com/owner/repo", text: $text).autocapitalization(.none).disableAutocorrection(true)
                        Button("Show releases") {
                            if let o = GitHubOrigin.parse(text) { Origins.save(o, for: projectName); origin = o }
                            else { bad = true }
                        }
                    } header: { Text("Which GitHub repo is this?") } footer: {
                        Text(bad ? "That doesn't look like owner/repo or a GitHub link." : "iOXcode couldn't tell where this project came from. It is remembered after this.")
                    }
                }
            }
        }
        .navigationTitle("Releases")
        .toolbar {
            if origin != nil {
                Menu {
                    Text("\(origin!.owner)/\(origin!.repo)")
                    Button { Origins.remove(projectName); origin = nil; searching = false; text = "" } label: { Label("Use a different repo", systemImage: "arrow.triangle.2.circlepath") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task {
            if let o = Origins.load(projectName) { origin = o; searching = false; return }
            let root = Paths.projects.appendingPathComponent(projectName, isDirectory: true)
            if let o = await GitHubOrigin.infer(from: root) { Origins.save(o, for: projectName); origin = o }
            searching = false
        }
    }
}
