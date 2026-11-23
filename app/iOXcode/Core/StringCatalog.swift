import Foundation

/// Xcode compiles a String Catalog (.xcstrings) into <language>.lproj/<Table>.strings (and .stringsdict for plurals).
/// Without this the catalog is just a file in the app and every translation, plural and variation is missing at runtime.
enum StringCatalog {
    static func quote(_ s: String) -> String {
        var o = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": o += "\\\\"
            case "\"": o += "\\\""
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            case "\r": o += "\\r"
            default: o.unicodeScalars.append(ch)
            }
        }
        return o
    }

    /// Writes the compiled tables into `app`. Returns how many languages it wrote, or nil when the file can't be read.
    @discardableResult
    static func compile(_ catalog: URL, into app: URL, log: LogSink?) -> Int? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: catalog),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { log?.log("warning: could not read \(catalog.lastPathComponent)"); return nil }
        let table = catalog.deletingPathExtension().lastPathComponent
        let source = root["sourceLanguage"] as? String ?? "en"
        var langs = Set<String>([source])
        for (_, v) in strings { if let l = (v as? [String: Any])?["localizations"] as? [String: Any] { langs.formUnion(l.keys) } }
        var written = 0
        for lang in langs.sorted() {
            var plain: [(String, String)] = []
            var plurals: [(String, [String: Any])] = []
            for (key, v) in strings.sorted(by: { $0.key < $1.key }) {
                let entry = v as? [String: Any] ?? [:]
                if entry["shouldTranslate"] as? Bool == false && lang != source { continue }
                let loc = (entry["localizations"] as? [String: Any])?[lang] as? [String: Any]
                if let unit = loc?["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                    // a translation that is still "new" or "needs_review" is shipped like Xcode ships it (state does not matter)
                    if let subs = loc?["substitutions"] as? [String: Any], !subs.isEmpty { plurals.append((key, ["value": value, "subs": subs])) }
                    else { plain.append((key, value)) }
                } else if let variations = loc?["variations"] as? [String: Any], let pl = variations["plural"] as? [String: Any] {
                    plurals.append((key, ["plural": pl]))
                } else if lang == source {
                    plain.append((key, key))                  // no stored text: the key is the source text
                }
            }
            if plain.isEmpty && plurals.isEmpty { continue }
            let dir = app.appendingPathComponent("\(lang).lproj", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !plain.isEmpty {
                let text = plain.map { "\"\(quote($0.0))\" = \"\(quote($0.1))\";" }.joined(separator: "\n") + "\n"
                try? text.write(to: dir.appendingPathComponent("\(table).strings"), atomically: true, encoding: .utf8)
            }
            if !plurals.isEmpty {
                var dict: [String: Any] = [:]
                for (key, p) in plurals {
                    var e: [String: Any] = [:]
                    func variants(_ forms: [String: Any]) -> [String: Any] {
                        var d: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"]
                        for (form, fv) in forms { if let s = (fv as? [String: Any])?["stringUnit"] as? [String: Any], let t = s["value"] as? String { d[form] = t } }
                        return d
                    }
                    if let forms = p["plural"] as? [String: Any] {
                        e["NSStringLocalizedFormatKey"] = "%#@value@"
                        e["value"] = variants(forms)
                    } else if let value = p["value"] as? String, let subs = p["subs"] as? [String: Any] {
                        e["NSStringLocalizedFormatKey"] = value
                        for (name, sv) in subs {
                            let s = sv as? [String: Any] ?? [:]
                            var d = variants(((s["variations"] as? [String: Any])?["plural"] as? [String: Any]) ?? [:])
                            if let spec = s["formatSpecifier"] as? String { d["NSStringFormatValueTypeKey"] = spec }
                            e[name] = d
                        }
                    }
                    dict[key] = e
                }
                if let d = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                    try? d.write(to: dir.appendingPathComponent("\(table).stringsdict"))
                }
            }
            written += 1
        }
        log?.log("compiled string catalog \(catalog.lastPathComponent): \(written) language(s)")
        return written
    }
}
