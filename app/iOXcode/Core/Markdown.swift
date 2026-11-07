import Foundation

private func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: p, options: o)
}

private extension String {
    /// Replaces every match; the closure gets the capture groups (index 0 is the whole match, "" for a group that did not take part).
    func replacing(_ r: NSRegularExpression, _ f: ([String]) -> String) -> String {
        let ns = self as NSString
        let matches = r.matches(in: self, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return self }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let rg = m.range(at: g)
                groups.append(rg.location == NSNotFound ? "" : ns.substring(with: rg))
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    func matches(_ r: NSRegularExpression) -> [String]? {
        let ns = self as NSString
        guard let m = r.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for g in 0..<m.numberOfRanges {
            let rg = m.range(at: g)
            groups.append(rg.location == NSNotFound ? "" : ns.substring(with: rg))
        }
        return groups
    }

    func has(_ r: NSRegularExpression) -> Bool { matches(r) != nil }
}

/// A small Markdown to HTML converter that follows GitHub Flavored Markdown closely enough for READMEs:
/// headings, emphasis, code, lists (nested, tasks), tables, quotes, images, links, raw HTML and badges.
final class Markdown {
    private let baseDir: URL
    private var defs: [String: String] = [:]
    private var stash: [String] = []

    private init(baseDir: URL) { self.baseDir = baseDir }

    /// A full HTML page. `baseDir` is the folder relative links and images are resolved against.
    static func page(_ source: String, baseDir: URL) -> String {
        let md = Markdown(baseDir: baseDir)
        let body = md.convert(source)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style></head>
        <body><article class="markdown-body">\(body)</article>
        <script>
        function send(){ try { window.webkit.messageHandlers.h.postMessage(document.body.scrollHeight); } catch(e) {} }
        window.addEventListener('load', send);
        if (window.ResizeObserver) { new ResizeObserver(send).observe(document.body); }
        </script></body></html>
        """
    }

    static func plainPage(_ text: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><style>\(css)</style></head><body><article class=\"markdown-body\"><pre>\(Markdown(baseDir: URL(fileURLWithPath: "/")).esc(text))</pre></article><script>function send(){try{window.webkit.messageHandlers.h.postMessage(document.body.scrollHeight);}catch(e){}} window.addEventListener('load',send);</script></body></html>"
    }

    // MARK: blocks

    private func convert(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\t", with: "    ")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines: [String] = []
        let defRx = rx("^ {0,3}\\[([^\\]]+)\\]:\\s*<?(\\S+?)>?(?:\\s+(?:\"[^\"]*\"|'[^']*'))?\\s*$")
        var inFence = false
        for l in text.components(separatedBy: "\n") {
            if l.hasPrefix("```") || l.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let g = l.matches(defRx) { defs[g[1].lowercased()] = g[2]; continue }
            lines.append(l)
        }
        return blocks(lines, tight: false)
    }

    private static let headingRx = rx("^ {0,3}(#{1,6})\\s+(.*?)(?:\\s+#+)?\\s*$")
    private static let fenceRx = rx("^ {0,3}(`{3,}|~{3,})\\s*([^`\\s]*).*$")
    private static let hrRx = rx("^ {0,3}([-*_])(?: *\\1){2,} *$")
    private static let quoteRx = rx("^ {0,3}>")
    private static let itemRx = rx("^( *)([-*+]|\\d{1,9}[.)])( +)(.*)$")
    private static let blockHTMLRx = rx("^ {0,3}<(?:/)?(?:div|p|table|thead|tbody|tfoot|tr|td|th|details|summary|center|h[1-6]|picture|source|hr|ul|ol|li|pre|blockquote|section|figure|figcaption|video|dl|dt|dd|nav|header|footer|main|aside|article)(?:[\\s/>]|$)", .caseInsensitive)
    private static let delimRx = rx("^ *\\|? *:?-+:? *(?:\\| *:?-+:? *)*\\|? *$")

    private func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

    private func startsBlock(_ l: String) -> Bool {
        l.has(Self.headingRx) || l.has(Self.fenceRx) || l.has(Self.hrRx) || l.has(Self.quoteRx) || l.has(Self.blockHTMLRx)
            || l.has(rx("^ {0,3}(?:[-*+]|1[.)]) +\\S"))
    }

    private func blocks(_ lines: [String], tight: Bool) -> String {
        var out = ""
        var i = 0
        let n = lines.count
        while i < n {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            // fenced code
            if let g = line.matches(Self.fenceRx) {
                let fence = g[1], lang = g[2]
                let ch = fence.first!
                var code: [String] = []
                i += 1
                while i < n {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(String(repeating: String(ch), count: fence.count)) && t.allSatisfy({ $0 == ch }) { i += 1; break }
                    code.append(lines[i]); i += 1
                }
                let cls = lang.isEmpty ? "" : " class=\"language-\(attr(lang))\""
                out += "<pre><code\(cls)>\(esc(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }
            // comment
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") {
                while i < n, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }
            // heading
            if let g = line.matches(Self.headingRx) {
                let level = g[1].count
                out += "<h\(level) id=\"\(slug(g[2]))\">\(Self.anchor(slug(g[2])))\(inline(g[2]))</h\(level)>\n"
                i += 1
                continue
            }
            // thematic break
            if line.has(Self.hrRx) { out += "<hr>\n"; i += 1; continue }
            // quote
            if line.has(Self.quoteRx) {
                var q: [String] = []
                while i < n, !isBlank(lines[i]) {
                    var l = lines[i]
                    if let r = l.range(of: ">") , l[l.startIndex..<r.lowerBound].allSatisfy({ $0 == " " }) {
                        l = String(l[r.upperBound...])
                        if l.hasPrefix(" ") { l.removeFirst() }
                    }
                    q.append(l); i += 1
                }
                out += "<blockquote>\(blocks(q, tight: false))</blockquote>\n"
                continue
            }
            // list
            if line.has(Self.itemRx), !line.has(Self.hrRx) {
                out += list(lines, &i)
                continue
            }
            // table
            if line.contains("|"), i + 1 < n, lines[i + 1].contains("-"), lines[i + 1].has(Self.delimRx) {
                out += table(lines, &i)
                continue
            }
            // raw HTML block
            if line.has(Self.blockHTMLRx) {
                var h: [String] = []
                while i < n, !isBlank(lines[i]) { h.append(lines[i]); i += 1 }
                out += rawHTML(h.joined(separator: "\n")) + "\n"
                continue
            }
            // paragraph (with setext headings)
            var para: [String] = [line]
            i += 1
            var heading = 0
            while i < n, !isBlank(lines[i]) {
                if lines[i].has(rx("^ {0,3}=+ *$")) { heading = 1; i += 1; break }
                if lines[i].has(rx("^ {0,3}-+ *$")) { heading = 2; i += 1; break }
                if startsBlock(lines[i]) { break }
                if lines[i].contains("|"), i + 1 < n, lines[i + 1].has(Self.delimRx), lines[i + 1].contains("-") { break }
                para.append(lines[i]); i += 1
            }
            let text = para.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if heading > 0 { out += "<h\(heading) id=\"\(slug(text))\">\(Self.anchor(slug(text)))\(inline(text))</h\(heading)>\n" }
            else if tight { out += inline(text) + "\n" }
            else { out += "<p>\(inline(text))</p>\n" }
        }
        return out
    }

    private func list(_ lines: [String], _ i: inout Int) -> String {
        let n = lines.count
        guard let first = lines[i].matches(Self.itemRx) else { return "" }
        let base = first[1].count
        let ordered = first[2].first!.isNumber
        let start = ordered ? (Int(first[2].dropLast()) ?? 1) : 1
        var items: [(html: String, loose: Bool)] = []
        var anyLoose = false

        while i < n {
            guard let g = lines[i].matches(Self.itemRx), g[1].count >= base, g[1].count < base + 2 || g[1].count == base,
                  g[2].first!.isNumber == ordered, !lines[i].has(Self.hrRx) else { break }
            let contentIndent = g[1].count + g[2].count + g[3].count
            var body: [String] = [g[4]]
            var loose = false
            i += 1
            while i < n {
                let l = lines[i]
                if isBlank(l) {
                    var j = i
                    while j < n, isBlank(lines[j]) { j += 1 }
                    if j < n, indentOf(lines[j]) >= max(base + 2, min(contentIndent, base + 4)), !(lines[j].matches(Self.itemRx).map { $0[1].count <= base } ?? false) {
                        for _ in i..<j { body.append("") }
                        loose = true
                        i = j
                        continue
                    }
                    break
                }
                let ind = indentOf(l)
                if ind >= base + 2 || (ind > base && l.matches(Self.itemRx) != nil) {
                    body.append(String(l.dropFirst(min(ind, contentIndent))))
                    i += 1
                    continue
                }
                if l.matches(Self.itemRx) != nil || startsBlock(l) { break }
                body.append(l.trimmingCharacters(in: .whitespaces))   // lazy continuation
                i += 1
            }
            var task = ""
            if let t = body[0].matches(rx("^\\[([ xX])\\]\\s+(.*)$")) {
                let done = t[1] != " "
                task = "<input type=\"checkbox\" disabled\(done ? " checked" : "")> "
                body[0] = t[2]
            }
            if loose { anyLoose = true }
            items.append((task + blocks(body, tight: !loose), loose))
            // skip blank lines between items; stop if the next line is not a sibling
            var j = i
            while j < n, isBlank(lines[j]) { j += 1 }
            if j > i, j < n, let nx = lines[j].matches(Self.itemRx), nx[1].count <= base + 1, nx[2].first!.isNumber == ordered {
                anyLoose = anyLoose || true
                i = j
            } else if j > i { break }
        }
        let tag = ordered ? "ol" : "ul"
        let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
        let hasTask = items.contains { $0.html.hasPrefix("<input type=\"checkbox\"") }
        var h = "<\(tag)\(startAttr)\(hasTask ? " class=\"contains-task-list\"" : "")>\n"
        for it in items {
            let cls = it.html.hasPrefix("<input type=\"checkbox\"") ? " class=\"task-list-item\"" : ""
            h += "<li\(cls)>\(it.html.trimmingCharacters(in: .newlines))</li>\n"
        }
        return h + "</\(tag)>\n"
    }

    private func indentOf(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    private func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var prev: Character = " "
        for ch in t {
            if ch == "|" && prev != "\\" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
            else { cur.append(ch) }
            prev = ch
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private func table(_ lines: [String], _ i: inout Int) -> String {
        let head = cells(lines[i])
        let aligns: [String] = cells(lines[i + 1]).map { c in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return l && r ? "center" : (r ? "right" : (l ? "left" : ""))
        }
        i += 2
        func style(_ k: Int) -> String { k < aligns.count && !aligns[k].isEmpty ? " style=\"text-align:\(aligns[k])\"" : "" }
        var h = "<div class=\"table-wrap\"><table><thead><tr>"
        for (k, c) in head.enumerated() { h += "<th\(style(k))>\(inline(c))</th>" }
        h += "</tr></thead><tbody>\n"
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            let row = cells(lines[i])
            h += "<tr>"
            for k in 0..<head.count { h += "<td\(style(k))>\(inline(k < row.count ? row[k] : ""))</td>" }
            h += "</tr>\n"
            i += 1
        }
        return h + "</tbody></table></div>\n"
    }

    // MARK: HTML safety

    private static let bannedTags = rx("^</?(script|iframe|style|object|embed|link|meta|form|base)\\b", .caseInsensitive)
    private static let eventAttr = rx("\\son\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", .caseInsensitive)
    private static let urlAttr = rx("\\b(src|href|poster)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", .caseInsensitive)

    /// Raw HTML from a README: scripts, frames and event handlers are dropped, relative URLs are pointed at the project folder.
    private func cleanTag(_ tag: String) -> String {
        if tag.has(Self.bannedTags) { return esc(tag) }
        var t = tag.replacing(Self.eventAttr) { _ in "" }
        t = t.replacing(Self.urlAttr) { g in
            let value = g[3].isEmpty ? g[4] : g[3]
            if value.lowercased().hasPrefix("javascript:") { return "" }
            return "\(g[1])=\"\(attr(resolve(value)))\""
        }
        return t
    }

    private func rawHTML(_ html: String) -> String {
        html.replacing(rx("</?[A-Za-z][A-Za-z0-9-]*(?:\\s+[^<>]*?)?/?>")) { cleanTag($0[0]) }
    }

    // MARK: inline

    private func hold(_ s: String) -> String {
        stash.append(s)
        return "\u{1}\(stash.count - 1)\u{2}"
    }

    func esc(_ s: String) -> String {
        s.replacing(rx("&(?!#?\\w+;)")) { _ in "&amp;" }
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private func slug(_ s: String) -> String {
        var t = s.replacing(rx("<[^>]*>")) { _ in "" }
        t = t.replacing(rx("[`*_~\\[\\]]")) { _ in "" }.lowercased()
        t = t.replacing(rx("[^\\p{L}\\p{N}\\s_-]")) { _ in "" }
        return t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    private func resolve(_ u: String) -> String {
        let t = u.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("//") || t.hasPrefix("data:") || t.hasPrefix("mailto:") { return t }
        if t.has(rx("^[A-Za-z][A-Za-z0-9+.-]*:")) { return t }
        var rel = t
        if rel.hasPrefix("/") { rel.removeFirst() }
        let encoded = rel.removingPercentEncoding == rel ? (rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "#?"))) ?? rel) : rel
        let base = baseDir.absoluteString.hasSuffix("/") ? baseDir : baseDir.appendingPathComponent("", isDirectory: true)
        return URL(string: encoded, relativeTo: base)?.absoluteString ?? t
    }

    private func inline(_ text: String) -> String {
        var s = text
        // code spans
        s = s.replacing(rx("(`+)(.+?)\\1", .dotMatchesLineSeparators)) { g in hold("<code>" + esc(g[2].trimmingCharacters(in: .whitespaces)) + "</code>") }
        // backslash escapes
        s = s.replacing(rx("\\\\([\\\\`*_{}\\[\\]()#+\\-.!|~<>])")) { g in hold(esc(g[1])) }
        // comments
        s = s.replacing(rx("<!--.*?-->", .dotMatchesLineSeparators)) { _ in "" }
        // <https://...>
        s = s.replacing(rx("<((?:https?://|mailto:)[^>\\s]+)>")) { g in hold("<a href=\"\(attr(g[1]))\">\(esc(g[1]))</a>") }
        // raw tags
        s = s.replacing(rx("</?[A-Za-z][A-Za-z0-9-]*(?:\\s+[^<>]*?)?/?>")) { g in hold(cleanTag(g[0])) }
        // images
        s = s.replacing(rx("!\\[([^\\]]*)\\]\\(\\s*<?([^)\\s>]+)>?(?:\\s+\"([^\"]*)\")?\\s*\\)")) { g in
            let title = g[3].isEmpty ? "" : " title=\"\(attr(g[3]))\""
            return hold("<img src=\"\(attr(resolve(g[2])))\" alt=\"\(attr(g[1]))\"\(title)>")
        }
        // reference images ![alt][ref]
        s = s.replacing(rx("!\\[([^\\]]*)\\]\\[([^\\]]*)\\]")) { g in
            let key = (g[2].isEmpty ? g[1] : g[2]).lowercased()
            guard let url = defs[key] else { return g[0] }
            return hold("<img src=\"\(attr(resolve(url)))\" alt=\"\(attr(g[1]))\">")
        }
        // links: only the tags are held, so the text still gets emphasis and escaping
        s = s.replacing(rx("\\[([^\\]]+)\\]\\(\\s*<?([^)\\s>]+)>?(?:\\s+\"([^\"]*)\")?\\s*\\)")) { g in
            let title = g[3].isEmpty ? "" : " title=\"\(attr(g[3]))\""
            return hold("<a href=\"\(attr(resolve(g[2])))\"\(title)>") + g[1] + hold("</a>")
        }
        // reference links [text][ref]
        s = s.replacing(rx("\\[([^\\]]+)\\]\\[([^\\]]*)\\]")) { g in
            let key = (g[2].isEmpty ? g[1] : g[2]).lowercased()
            guard let url = defs[key] else { return g[0] }
            return hold("<a href=\"\(attr(resolve(url)))\">") + g[1] + hold("</a>")
        }
        // bare URLs
        s = s.replacing(rx("(?<![\"'=>\\w\u{2}])(https?://[^\\s<>\"'\u{1}\u{2}]+[^\\s<>\"'.,;:!?)\u{1}\u{2}])")) { g in
            hold("<a href=\"\(attr(g[1]))\">") + g[1] + hold("</a>")
        }
        s = esc(s)
        // emphasis
        s = s.replacing(rx("\\*\\*\\*(?!\\s)(.+?)(?<!\\s)\\*\\*\\*")) { "<strong><em>\($0[1])</em></strong>" }
        s = s.replacing(rx("\\*\\*(?!\\s)(.+?)(?<!\\s)\\*\\*")) { "<strong>\($0[1])</strong>" }
        s = s.replacing(rx("(?<!\\w)__(?!\\s)(.+?)(?<!\\s)__(?!\\w)")) { "<strong>\($0[1])</strong>" }
        s = s.replacing(rx("\\*(?!\\s)(.+?)(?<!\\s)\\*")) { "<em>\($0[1])</em>" }
        s = s.replacing(rx("(?<!\\w)_(?!\\s)(.+?)(?<!\\s)_(?!\\w)")) { "<em>\($0[1])</em>" }
        s = s.replacing(rx("~~(?!\\s)(.+?)(?<!\\s)~~")) { "<del>\($0[1])</del>" }
        // hard breaks
        s = s.replacing(rx("(?: {2,}|\\\\)\n")) { _ in "<br>\n" }
        // put the held pieces back (they can contain each other)
        var guardCount = 0
        while s.contains("\u{1}"), guardCount < 8 {
            s = s.replacing(rx("\u{1}(\\d+)\u{2}")) { g in Int(g[1]).flatMap { $0 < stash.count ? stash[$0] : nil } ?? "" }
            guardCount += 1
        }
        return s
    }

    // MARK: style (modelled on GitHub's light and dark themes)

    /// The little chain-link GitHub puts beside every heading.
    static func anchor(_ slug: String) -> String {
        "<a class=\"anchor\" href=\"#\(slug)\" aria-label=\"Permalink\"><svg viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" fill=\"currentColor\"><path d=\"m7.775 3.275 1.25-1.25a3.5 3.5 0 1 1 4.95 4.95l-2.5 2.5a3.5 3.5 0 0 1-4.95 0 .751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018 1.998 1.998 0 0 0 2.83 0l2.5-2.5a2.002 2.002 0 0 0-2.83-2.83l-1.25 1.25a.751.751 0 0 1-1.042-.018.751.751 0 0 1-.018-1.042Zm-4.69 9.64a1.998 1.998 0 0 0 2.83 0l1.25-1.25a.751.751 0 0 1 1.042.018.751.751 0 0 1 .018 1.042l-1.25 1.25a3.5 3.5 0 1 1-4.95-4.95l2.5-2.5a3.5 3.5 0 0 1 4.95 0 .751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018 1.998 1.998 0 0 0-2.83 0l-2.5 2.5a1.998 1.998 0 0 0 0 2.83Z\"/></svg></a>"
    }

    static let css = """
    :root{color-scheme:light dark;--fg:#1f2328;--muted:#59636e;--bg:#ffffff;--border:#d1d9e0;--soft:#f6f8fa;--link:#0969da;--quote:#59636e;--codebg:rgba(129,139,152,.12)}
    @media (prefers-color-scheme:dark){:root{--fg:#f0f6fc;--muted:#9198a1;--bg:#0d1117;--border:#3d444d;--soft:#151b23;--link:#4493f8;--quote:#9198a1;--codebg:rgba(101,108,118,.2)}}
    html,body{margin:0;padding:0;background:transparent}
    .markdown-body{box-sizing:border-box;padding:4px 2px 12px 30px;color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;word-wrap:break-word;-webkit-text-size-adjust:100%}
    .markdown-body>*:first-child{margin-top:0!important}.markdown-body>*:last-child{margin-bottom:0!important}
    .markdown-body a{color:var(--link);text-decoration:none}.markdown-body a:hover{text-decoration:underline}
    .markdown-body h1,h2,h3,h4,h5,h6{margin-top:1.5rem;margin-bottom:1rem;font-weight:600;line-height:1.25}
    .markdown-body h1,h2,h3,h4,h5,h6{position:relative}
    .markdown-body .anchor{position:absolute;left:-28px;top:50%;transform:translateY(-50%);padding-right:4px;color:var(--fg);line-height:1}
    .markdown-body .anchor svg{display:block;vertical-align:middle}
    .markdown-body h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
    .markdown-body h2{font-size:1.5em;padding-bottom:.3em;border-bottom:1px solid var(--border)}
    .markdown-body h3{font-size:1.25em}.markdown-body h4{font-size:1em}.markdown-body h5{font-size:.875em}
    .markdown-body h6{font-size:.85em;color:var(--muted)}
    .markdown-body p,blockquote,ul,ol,dl,table,pre,details{margin-top:0;margin-bottom:1rem}
    .markdown-body hr{height:.25em;padding:0;margin:1.5rem 0;background:var(--border);border:0}
    .markdown-body blockquote{padding:0 1em;color:var(--quote);border-left:.25em solid var(--border)}
    .markdown-body ul,.markdown-body ol{padding-left:2em}
    .markdown-body li+li{margin-top:.25em}
    .markdown-body li>p{margin-top:1rem}
    .markdown-body .contains-task-list{list-style:none;padding-left:1.5em}
    .markdown-body .task-list-item input{margin:0 .4em .25em -1.4em;vertical-align:middle}
    .markdown-body img{max-width:100%;height:auto;box-sizing:content-box;background:transparent}
    .markdown-body code,.markdown-body tt{padding:.2em .4em;margin:0;font-size:85%;background:var(--codebg);border-radius:6px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    .markdown-body pre{padding:16px;overflow:auto;font-size:85%;line-height:1.45;background:var(--soft);border-radius:6px}
    .markdown-body pre code{padding:0;font-size:100%;background:transparent;white-space:pre;word-break:normal}
    .markdown-body .table-wrap{overflow-x:auto;margin-bottom:1rem}
    .markdown-body table{border-spacing:0;border-collapse:collapse;display:table;width:max-content;max-width:100%;margin-bottom:0}
    .markdown-body th,.markdown-body td{padding:6px 13px;border:1px solid var(--border)}
    .markdown-body th{font-weight:600}
    .markdown-body tr:nth-child(2n){background:var(--soft)}
    .markdown-body details summary{cursor:pointer}
    .markdown-body kbd{padding:3px 5px;font:11px ui-monospace,Menlo,monospace;background:var(--soft);border:1px solid var(--border);border-bottom-color:var(--border);border-radius:6px}
    .markdown-body [align=center]{text-align:center}.markdown-body [align=right]{text-align:right}
    """
}
