import SwiftUI
import UniformTypeIdentifiers

/// One folder of a project: browse, create files and folders, rename, move, delete. Tapping a file opens the editor.
struct FileBrowserView: View {
    let folder: URL
    let projectRoot: URL
    let title: String

    @EnvironmentObject var model: AppModel
    @State private var items: [Item] = []
    @State private var query = ""
    @State private var askName: NameRequest?
    @State private var nameText = ""
    @State private var message: String?
    @State private var confirmDelete: Item?

    struct Item: Identifiable, Hashable {
        let url: URL
        let isDir: Bool
        let size: Int
        let modified: Date?
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    enum NameRequest: Identifiable {
        case newFile, newFolder, rename(Item)
        var id: String {
            switch self {
            case .newFile: return "file"
            case .newFolder: return "folder"
            case .rename(let i): return "rename-" + i.id
            }
        }
        var heading: String {
            switch self {
            case .newFile: return "New file"
            case .newFolder: return "New folder"
            case .rename: return "Rename"
            }
        }
    }

    var body: some View {
        List {
            if folder == projectRoot, let origin = Origins.load(projectRoot.lastPathComponent) {
                NavigationLink(destination: ReleasesView(origin: origin)) {
                    Label("Releases (\(origin.owner)/\(origin.repo))", systemImage: "shippingbox")
                }
            }
            if items.isEmpty {
                Text(query.isEmpty ? "This folder is empty." : "Nothing matches “\(query)”.").foregroundColor(.secondary)
            }
            ForEach(shown) { item in
                if item.isDir {
                    NavigationLink(destination: FileBrowserView(folder: item.url, projectRoot: projectRoot, title: item.name)) { row(item) }
                        .swipeActions(edge: .trailing) { actions(item) }
                        .contextMenu { menu(item) }
                } else {
                    NavigationLink(destination: FileViewer(url: item.url)) { row(item) }
                        .swipeActions(edge: .trailing) { actions(item) }
                        .contextMenu { menu(item) }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search files in \(title)")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { nameText = ""; askName = .newFile } label: { Label("New file", systemImage: "doc.badge.plus") }
                    Button { nameText = ""; askName = .newFolder } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button { FilePicker.present(types: [.item], copy: true) { addFile($0) } } label: { Label("Add a file from Files", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
            }
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
        .alert(askName?.heading ?? "", isPresented: Binding(get: { askName != nil }, set: { if !$0 { askName = nil } })) {
            TextField("name", text: $nameText).autocapitalization(.none).disableAutocorrection(true)
            Button("OK") { if let r = askName { apply(r) }; askName = nil }
            Button("Cancel", role: .cancel) { askName = nil }
        }
        .alert("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let i = confirmDelete { delete(i) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text(confirmDelete?.isDir == true ? "The folder and everything in it will be removed." : "This can't be undone.") }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) {} }
    }

    // MARK: rows

    private var shown: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return items }
        // searching looks through the whole folder tree, not only this level
        return Self.search(in: folder, matching: q)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(item)).foregroundColor(item.isDir ? .accentColor : .secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body).lineLimit(1)
                if !query.isEmpty {
                    Text(relative(item.url)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                } else if !item.isDir {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func actions(_ item: Item) -> some View {
        Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
        Button { nameText = item.name; askName = .rename(item) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
    }

    @ViewBuilder private func menu(_ item: Item) -> some View {
        Button { nameText = item.name; askName = .rename(item) } label: { Label("Rename", systemImage: "pencil") }
        Button { duplicate(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { confirmDelete = item } label: { Label("Delete", systemImage: "trash") }
    }

    private func relative(_ url: URL) -> String {
        let base = folder.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : url.lastPathComponent
    }

    private func icon(_ item: Item) -> String {
        if item.isDir { return item.name.hasSuffix(".xcodeproj") || item.name.hasSuffix(".xcassets") ? "shippingbox" : "folder.fill" }
        switch item.url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "png", "jpg", "jpeg", "gif", "heic", "pdf": return "photo"
        case "json", "yml", "yaml", "plist", "xml", "toml": return "curlybraces"
        case "py", "sh", "rb", "js": return "terminal"
        case "md", "txt": return "doc.text"
        case "zip", "a", "dylib", "bin": return "archivebox"
        default: return "doc"
        }
    }

    // MARK: file operations

    private func reload() { items = Self.list(folder) }

    static func list(_ dir: URL) -> [Item] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return kids.filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".ioxcode" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Item(url: u, isDir: v?.isDirectory ?? false, size: v?.fileSize ?? 0, modified: v?.contentModificationDate)
        }.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func search(in dir: URL, matching q: String) -> [Item] {
        var out: [Item] = []
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return [] }
        for case let u as URL in en {
            if u.lastPathComponent.hasPrefix(".") { en.skipDescendants(); continue }
            if u.lastPathComponent.lowercased().contains(q) {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                out.append(Item(url: u, isDir: v?.isDirectory ?? false, size: v?.fileSize ?? 0, modified: v?.contentModificationDate))
                if out.count >= 300 { break }
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func apply(_ request: NameRequest) {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(":") else { message = "Enter a name."; return }
        let fm = FileManager.default
        do {
            switch request {
            case .newFile:
                let target = folder.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { message = "\(name) already exists."; return }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: target)
            case .newFolder:
                let target = folder.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { message = "\(name) already exists."; return }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .rename(let item):
                let target = folder.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { message = "\(name) already exists."; return }
                try fm.moveItem(at: item.url, to: target)
            }
        } catch { message = error.localizedDescription }
        reload()
    }

    private func delete(_ item: Item) {
        do { try FileManager.default.removeItem(at: item.url) } catch { message = error.localizedDescription }
        reload()
    }

    private func duplicate(_ item: Item) {
        let fm = FileManager.default
        let ext = item.url.pathExtension
        let base = item.url.deletingPathExtension().lastPathComponent
        var n = 2
        var target: URL
        repeat {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: target.path)
        do { try fm.copyItem(at: item.url, to: target) } catch { message = error.localizedDescription }
        reload()
    }

    private func addFile(_ source: URL) {
        let target = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        } catch { message = error.localizedDescription }
        reload()
    }
}

/// Opens text files in the editor, shows images, and says so plainly for everything else.
struct FileViewer: View {
    let url: URL
    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path), ["png", "jpg", "jpeg", "gif", "heic"].contains(url.pathExtension.lowercased()) {
                ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().padding() }
                    .navigationTitle(url.lastPathComponent)
            } else if FileViewer.isText(url) {
                CodeEditorScreen(url: url)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc").font(.largeTitle).foregroundColor(.secondary)
                    Text(url.lastPathComponent).font(.headline)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    Text("Binary file, \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)). It can't be shown as text.")
                        .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                }.navigationTitle(url.lastPathComponent)
            }
        }
    }

    static func isText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let data = h.readData(ofLength: 4096)
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        return String(data: data, encoding: .utf8) != nil || String(data: data, encoding: .isoLatin1) != nil
    }
}
