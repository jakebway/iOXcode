import SwiftUI
import WebKit

/// The README of a folder, drawn the way GitHub shows it under the file list.
struct ReadmeSection: View {
    let folder: URL
    @State private var file: URL?
    @State private var name = ""
    @State private var page: URL?
    @State private var height: CGFloat = 80

    static func find(in folder: URL) -> URL? {
        let kids = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let order = ["readme.md", "readme.markdown", "readme.mdown", "readme", "readme.txt"]
        for want in order {
            if let k = kids.first(where: { $0.lastPathComponent.lowercased() == want }) { return k }
        }
        return nil
    }

    var body: some View {
        Group {
            if let page {
                Section {
                    ReadmeWebView(page: page, readAccess: Paths.root, height: $height)
                        .frame(height: max(height, 40))
                } header: {
                    Label(name, systemImage: "book")
                }
            }
        }
        .task(id: folder) { await load() }
    }

    private func load() async {
        guard let f = Self.find(in: folder) else { page = nil; return }
        name = f.lastPathComponent
        let folderCopy = folder
        let url: URL? = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let data = try? Data(contentsOf: f), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
            let ext = f.pathExtension.lowercased()
            let html = (ext == "md" || ext == "markdown" || ext == "mdown")
                ? Markdown.page(text, baseDir: URL(fileURLWithPath: folderCopy.path, isDirectory: true))
                : Markdown.plainPage(text)
            let dir = Paths.root.appendingPathComponent("ReadmeCache", isDirectory: true)
            Paths.ensure(dir)
            let out = dir.appendingPathComponent("readme-\(abs(folderCopy.path.hashValue)).html")
            try? html.write(to: out, atomically: true, encoding: .utf8)
            return out
        }.value
        page = url
    }
}

struct ReadmeWebView: UIViewRepresentable {
    let page: URL
    let readAccess: URL
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "h")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.navigationDelegate = context.coordinator
        context.coordinator.loaded = page
        w.loadFileURL(page, allowingReadAccessTo: readAccess)
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != page {
            context.coordinator.loaded = page
            w.loadFileURL(page, allowingReadAccessTo: readAccess)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReadmeWebView
        var loaded: URL?
        init(_ p: ReadmeWebView) { parent = p }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            let v: CGFloat
            if let d = message.body as? Double { v = CGFloat(d) }
            else if let i = message.body as? Int { v = CGFloat(i) }
            else { return }
            DispatchQueue.main.async { if abs(self.parent.height - v) > 1 { self.parent.height = v } }
        }

        func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { decisionHandler(.allow); return }
            if url.isFileURL {
                // links to a heading inside the README scroll; links to other files are left alone
                decisionHandler(url.fragment != nil && url.path == loaded?.path ? .allow : .cancel)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }
    }
}
