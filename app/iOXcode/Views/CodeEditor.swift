import SwiftUI
import UIKit

/// The text of one file, saved automatically a moment after you stop typing.
final class EditorDocument: ObservableObject {
    let url: URL
    @Published var text: String = ""
    @Published var saved = true
    @Published var loadError: String?
    private var pending: DispatchWorkItem?
    private(set) var encoding: String.Encoding = .utf8

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url) {
            if let s = String(data: d, encoding: .utf8) { text = s }
            else if let s = String(data: d, encoding: .isoLatin1) { text = s; encoding = .isoLatin1 }
            else { loadError = "This file isn't text." }
        }
    }

    func changed() {
        saved = false
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func save() {
        pending?.cancel()
        do { try text.write(to: url, atomically: true, encoding: encoding); saved = true } catch { loadError = "Could not save: \(error.localizedDescription)" }
    }
}

struct CodeEditorScreen: View {
    let url: URL
    @StateObject private var doc: EditorDocument
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @State private var undo: (() -> Void)?
    @State private var redo: (() -> Void)?
    @State private var jump = false
    @State private var lineText = ""
    @State private var requestedLine: Int?
    @State private var finding = false
    @State private var findText = ""
    @State private var findToken = 0

    init(url: URL) {
        self.url = url
        _doc = StateObject(wrappedValue: EditorDocument(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let e = doc.loadError { Text(e).font(.footnote).foregroundColor(.red).padding(8) }
            if finding {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Find in this file", text: $findText, onCommit: { findToken += 1 })
                        .autocapitalization(.none).disableAutocorrection(true)
                    Button("Next") { findToken += 1 }.disabled(findText.isEmpty)
                    Button { finding = false; findText = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundColor(.secondary)
                }.padding(8).background(Color(.secondarySystemBackground))
            }
            CodeTextView(doc: doc, fileExtension: url.pathExtension.lowercased(), fontSize: fontSize, line: $requestedLine,
                         find: findText, findToken: findToken, register: { u, r in undo = u; redo = r })
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !doc.saved { Text("Saving…").font(.caption).foregroundColor(.secondary) }
                Menu {
                    Button { undo?() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    Button { redo?() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    Button { finding.toggle() } label: { Label("Find", systemImage: "magnifyingglass") }
                    Button { lineText = ""; jump = true } label: { Label("Go to line", systemImage: "arrow.down.to.line") }
                    Button { fontSize = min(fontSize + 1, 28) } label: { Label("Bigger text", systemImage: "textformat.size.larger") }
                    Button { fontSize = max(fontSize - 1, 9) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                    Button { doc.save() } label: { Label("Save now", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Go to line", isPresented: $jump) {
            TextField("line number", text: $lineText).keyboardType(.numberPad)
            Button("Go") { requestedLine = Int(lineText) }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear { doc.save() }
    }
}

/// UITextView with a symbol bar above the keyboard, Tab = 4 spaces, and colouring for common languages.
struct CodeTextView: UIViewRepresentable {
    @ObservedObject var doc: EditorDocument
    let fileExtension: String
    let fontSize: Double
    @Binding var line: Int?
    let find: String
    let findToken: Int
    let register: (@escaping () -> Void, @escaping () -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.backgroundColor = .systemBackground
        tv.inputAccessoryView = context.coordinator.makeBar(for: tv)
        context.coordinator.textView = tv
        tv.text = doc.text
        context.coordinator.highlight(tv)
        DispatchQueue.main.async {
            self.register({ tv.undoManager?.undo() }, { tv.undoManager?.redo() })
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.fontSize != fontSize { c.fontSize = fontSize; c.highlight(tv) }
        if let l = line {
            DispatchQueue.main.async { self.line = nil }
            c.scroll(tv, toLine: l)
        }
        if findToken != c.lastFindToken {
            c.lastFindToken = findToken
            c.findNext(tv, find)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        weak var textView: UITextView?
        var fontSize: Double
        var lastFindToken = 0
        private var highlightWork: DispatchWorkItem?

        init(_ p: CodeTextView) { parent = p; fontSize = p.fontSize }

        func textViewDidChange(_ tv: UITextView) {
            parent.doc.text = tv.text
            parent.doc.changed()
            highlightWork?.cancel()
            let w = DispatchWorkItem { [weak self, weak tv] in if let tv = tv { self?.highlight(tv) } }
            highlightWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }

        // MARK: symbol bar

        func makeBar(for tv: UITextView) -> UIView {
            let bar = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.backgroundColor = .secondarySystemBackground
            bar.showsHorizontalScrollIndicator = false
            let keys = ["⇥", "{", "}", "(", ")", "[", "]", "<", ">", "\"", "'", ";", ":", "=", ".", ",", "/", "\\", "$", "#", "_", "-", "+", "*", "!", "?", "&", "|"]
            var x: CGFloat = 6
            for k in keys {
                let b = UIButton(type: .system)
                b.setTitle(k, for: .normal)
                b.titleLabel?.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
                b.frame = CGRect(x: x, y: 5, width: 38, height: 34)
                b.backgroundColor = .systemBackground
                b.layer.cornerRadius = 6
                b.addAction(UIAction { [weak tv] _ in
                    guard let tv = tv else { return }
                    let s = k == "⇥" ? "    " : k
                    tv.insertText(s)
                }, for: .touchUpInside)
                bar.addSubview(b)
                x += 42
            }
            let done = UIButton(type: .system)
            done.setTitle("Done", for: .normal)
            done.frame = CGRect(x: x + 6, y: 5, width: 60, height: 34)
            done.addAction(UIAction { [weak tv] _ in tv?.resignFirstResponder() }, for: .touchUpInside)
            bar.addSubview(done)
            bar.contentSize = CGSize(width: x + 76, height: 44)
            bar.autoresizingMask = .flexibleWidth
            return bar
        }

        // MARK: navigation

        func scroll(_ tv: UITextView, toLine n: Int) {
            let ns = tv.text as NSString
            var idx = 0, current = 1
            while current < n, idx < ns.length {
                let r = ns.lineRange(for: NSRange(location: idx, length: 0))
                idx = NSMaxRange(r)
                current += 1
            }
            let range = NSRange(location: min(idx, ns.length), length: 0)
            tv.selectedRange = range
            tv.scrollRangeToVisible(range)
            tv.becomeFirstResponder()
        }

        func findNext(_ tv: UITextView, _ query: String) {
            guard !query.isEmpty else { return }
            let ns = tv.text as NSString
            let start = min(NSMaxRange(tv.selectedRange), ns.length)
            var r = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { r = ns.range(of: query, options: .caseInsensitive) }
            if r.location != NSNotFound {
                tv.selectedRange = r
                tv.scrollRangeToVisible(r)
            }
        }

        // MARK: colours

        func highlight(_ tv: UITextView) {
            let text = tv.text ?? ""
            let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
            let saved = tv.selectedRange
            let attr = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
            if text.utf16.count < 250_000 {
                for rule in Syntax.rules(for: parent.fileExtension) {
                    rule.regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: attr.length)) { m, _, _ in
                        guard let m = m else { return }
                        attr.addAttribute(.foregroundColor, value: rule.color, range: rule.group > 0 && m.numberOfRanges > rule.group ? m.range(at: rule.group) : m.range)
                    }
                }
            }
            let offset = tv.contentOffset
            tv.attributedText = attr
            tv.selectedRange = saved
            tv.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
            tv.setContentOffset(offset, animated: false)
        }
    }
}

enum Syntax {
    struct Rule { let regex: NSRegularExpression; let color: UIColor; let group: Int }

    private static var cache: [String: [Rule]] = [:]

    static func rules(for ext: String) -> [Rule] {
        if let r = cache[ext] { return r }
        let r = build(ext)
        cache[ext] = r
        return r
    }

    private static func rx(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: p, options: opts)
    }

    private static func words(_ w: [String]) -> String { "\\b(" + w.joined(separator: "|") + ")\\b" }

    private static func build(_ ext: String) -> [Rule] {
        let keyword = UIColor.systemPink, type = UIColor.systemTeal, string = UIColor.systemRed,
            comment = UIColor.systemGreen, number = UIColor.systemPurple, attr = UIColor.systemOrange
        var rules: [(String, UIColor, Int, NSRegularExpression.Options)] = []
        switch ext {
        case "swift":
            let kw = ["import", "func", "var", "let", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "init", "deinit", "self", "Self", "super",
                      "switch", "case", "default", "for", "in", "while", "repeat", "break", "continue", "throw", "throws", "rethrows", "try", "catch", "do", "defer", "where", "as", "is",
                      "nil", "true", "false", "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating", "lazy", "weak", "unowned", "async", "await",
                      "some", "any", "typealias", "associatedtype", "inout", "operator", "subscript", "actor", "nonisolated", "indirect", "get", "set", "willSet", "didSet"]
            rules = [("\\b[A-Z][A-Za-z0-9_]*\\b", type, 0, []), (words(kw), keyword, 0, []), ("\\b\\d+(\\.\\d+)?\\b", number, 0, []),
                     ("@[A-Za-z_]+|#[A-Za-z]+", attr, 0, []), ("\"(\\\\.|[^\"\\\\\\n])*\"", string, 0, []),
                     ("//[^\\n]*", comment, 0, []), ("/\\*[\\s\\S]*?\\*/", comment, 0, [])]
        case "py":
            let kw = ["def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "return", "yield", "with", "try", "except", "finally", "raise", "pass", "break", "continue",
                      "lambda", "None", "True", "False", "and", "or", "not", "in", "is", "global", "nonlocal", "assert", "del", "async", "await"]
            rules = [(words(kw), keyword, 0, []), ("\\b\\d+(\\.\\d+)?\\b", number, 0, []), ("@[A-Za-z_.]+", attr, 0, []),
                     ("\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''", string, 0, []), ("\"(\\\\.|[^\"\\\\\\n])*\"|'(\\\\.|[^'\\\\\\n])*'", string, 0, []), ("#[^\\n]*", comment, 0, [])]
        case "c", "h", "m", "mm", "cpp", "cc", "hpp", "rs", "js", "ts", "java", "kt", "go":
            let kw = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "struct", "enum", "union", "typedef", "static", "const", "extern", "void", "int",
                      "char", "long", "short", "unsigned", "signed", "float", "double", "sizeof", "class", "public", "private", "protected", "namespace", "using", "template", "new", "delete",
                      "fn", "let", "mut", "pub", "impl", "trait", "use", "mod", "match", "loop", "self", "Self", "function", "var", "import", "export", "from", "true", "false", "nil", "null", "NULL",
                      "@interface", "@implementation", "@end", "@property", "@class", "@protocol", "@selector", "BOOL", "YES", "NO", "id"]
            rules = [(words(kw), keyword, 0, []), ("\\b\\d+(\\.\\d+)?[fFuUlL]*\\b|\\b0x[0-9A-Fa-f]+\\b", number, 0, []), ("^\\s*#\\s*\\w+", attr, 0, [.anchorsMatchLines]),
                     ("\"(\\\\.|[^\"\\\\\\n])*\"", string, 0, []), ("//[^\\n]*", comment, 0, []), ("/\\*[\\s\\S]*?\\*/", comment, 0, [])]
        case "json":
            rules = [("\"(\\\\.|[^\"\\\\\\n])*\"\\s*:", keyword, 0, []), ("\"(\\\\.|[^\"\\\\\\n])*\"", string, 0, []), ("\\b-?\\d+(\\.\\d+)?\\b", number, 0, []), ("\\b(true|false|null)\\b", attr, 0, [])]
        case "yml", "yaml":
            rules = [("^\\s*-?\\s*([A-Za-z0-9_.\\-\\$\\(\\)]+):", keyword, 1, [.anchorsMatchLines]), ("\"(\\\\.|[^\"\\\\\\n])*\"|'[^'\\n]*'", string, 0, []),
                     ("\\b(true|false|null|YES|NO)\\b", attr, 0, []), ("#[^\\n]*", comment, 0, [])]
        case "sh", "bash", "zsh":
            let kw = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "exit", "export", "local", "set", "echo", "cd", "source"]
            rules = [(words(kw), keyword, 0, []), ("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", attr, 0, []), ("\"(\\\\.|[^\"\\\\\\n])*\"|'[^'\\n]*'", string, 0, []), ("(^|\\s)#[^\\n]*", comment, 0, [])]
        case "plist", "xml", "html", "storyboard", "xib", "entitlements":
            rules = [("</?[A-Za-z][^>]*>", keyword, 0, []), ("\"[^\"]*\"", string, 0, []), ("<!--[\\s\\S]*?-->", comment, 0, [])]
        case "md":
            rules = [("^#{1,6} [^\\n]*", keyword, 0, [.anchorsMatchLines]), ("`[^`\\n]+`", string, 0, []), ("\\*\\*[^*\\n]+\\*\\*", attr, 0, [])]
        default:
            return []
        }
        return rules.compactMap { p, c, g, o in rx(p, o).map { Rule(regex: $0, color: c, group: g) } }
    }
}
