"""Emulated Swift macros.

iPhones cannot run macro plugins that are built on the device (unsigned code will not load), so packages that
define their own macros (a `.macro` target) would never compile. For well-known macros we expand the source
text ourselves, writing the same declarations the real macro produces.
Each emulator takes the macro call's arguments (source text) and returns Swift source.
"""
import os, re


def _find_close(src, i):
    """src[i] == '(' -> index of the matching ')', skipping strings and comments."""
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 1
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


_STR = r'"((?:\\.|[^"\\])*)"'


def atunion_builder(args):
    m = re.search(r'named\s*:\s*' + _STR, args)
    if not m:
        return None
    name = m.group(1)
    rest = args[m.end():]
    pairs = re.findall(_STR + r'\s*:\s*' + _STR, rest)
    if not pairs:
        return None
    out = ["public enum %s: Codable, Sendable {" % name]
    for k, v in pairs:
        out.append("    case %s(%s)" % (k, v))
    out.append("    public init(from decoder: Decoder) throws {")
    out.append("        let container = try decoder.singleValueContainer()")
    for idx, (k, v) in enumerate(pairs):
        out.append("        %sif let value = try? container.decode(%s.self) {" % ("" if idx == 0 else "} else ", v))
        out.append("            self = .%s(value)" % k)
    out.append("        } else {")
    out.append('            throw DecodingError.typeMismatch(%s.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown %s type"))' % (name, name))
    out.append("        }")
    out.append("    }")
    out.append("    public func encode(to encoder: Encoder) throws {")
    out.append("        var container = encoder.singleValueContainer()")
    out.append("        switch self {")
    for k, _ in pairs:
        out.append("        case .%s(let unionValue):" % k)
        out.append("            try container.encode(unionValue)")
    out.append("        }")
    out.append("    }")
    out.append("}")
    return "\n".join(out)


FREESTANDING = {"ATUnionBuilder": atunion_builder}


# ---------------------------------------------------------------- SwiftData @Model
# Written from what Apple's macro produces for the same input (observed with `swiftc -dump-macro-expansions`
# on a Mac; see .github/workflows/macro-probe.yml), not from its binary.

def _blank_literals(src):
    """Same text with comments and the inside of string literals replaced by spaces (newlines kept)."""
    out = list(src)
    i, n = 0, len(src)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif src[i] == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                j = n if j < 0 else j + 3
                blank(i + 3, max(i + 3, j - 3))
                i = j
            else:
                j = i + 1
                while j < n and src[j] != '"' and src[j] != "\n":
                    j += 2 if src[j] == "\\" else 1
                blank(i + 1, min(j, n))
                i = j + 1
        else:
            i += 1
    return "".join(out)


def _flat_mask(text):
    """Blank everything nested inside (), [], {} (delimiters stay); newlines inside become spaces."""
    out = list(text)
    depth = 0
    for k, c in enumerate(text):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            continue
        elif depth > 0:
            out[k] = " "
    return "".join(out)


_ACCESS = r"(?:public|open|internal|package|fileprivate|private)"
_MODEL_RE = re.compile(r"@Model\b\s*(?:\(\s*\))?")
_CLASS_RE = re.compile(r"((?:(?:" + _ACCESS + r"|final|@\w+(?:\(\s*\))?)\s+)*)class\s+(\w+)")
_PROP_RE = re.compile(
    r"(?m)^([ \t]*)((?:@\w+(?:\(\s*\))?[ \t\n]*)*)((?:(?:" + _ACCESS + r"(?:\(set\))?|final|weak|unowned|nonisolated|override|dynamic)[ \t]+)*)"
    r"(static[ \t]+|class[ \t]+|lazy[ \t]+)?(var|let)[ \t]+(\w+)[ \t]*(:[^=\n{;]*)?")


def _expand_model_class(src, clean, attr_start, attr_end):
    """Rewrites one `@Model class` found at src[attr_start:attr_end]. Returns (new_text_for_range, end_index) or None."""
    m = _CLASS_RE.match(clean, attr_end if clean[attr_end:attr_end + 1] else attr_end, ) if False else None
    rest = clean[attr_end:]
    m = re.match(r"\s*" + _CLASS_RE.pattern, rest)
    if not m:
        return None
    mods = m.group(1) or ""
    name = m.group(2)
    brace = clean.find("{", attr_end + m.end())
    if brace < 0:
        return None
    depth, k = 0, brace
    while k < len(clean):
        if clean[k] == "{":
            depth += 1
        elif clean[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    if depth != 0:
        return None
    close = k
    body_s, body_e = brace + 1, close
    flat = _flat_mask(clean[body_s:body_e])
    public = bool(re.search(r"\b(public|open)\b", mods))
    final = bool(re.search(r"\bfinal\b", mods))
    acc = "public " if public else ""
    props = []
    edits = []      # (start, end, replacement) in absolute coordinates
    for pm in _PROP_RE.finditer(flat):
        attrs_clean = pm.group(2) or ""
        if pm.group(5) == "let" or pm.group(4):
            if re.search(r"@Transient", attrs_clean) or True:
                # strip macro attributes only
                pass
        pname = pm.group(6)
        a0 = body_s + pm.start(2)
        a1 = body_s + pm.end(2)
        attr_text = src[a0:a1]
        has_transient = bool(re.search(r"@Transient\b", attrs_clean))
        # what follows the declaration head
        head_end = body_s + pm.end()
        # computed / observed property: next significant char is "{"
        tail = flat[pm.end():]
        stmt_end_rel = re.search(r"[\n;]", tail)
        stmt = tail[:stmt_end_rel.start()] if stmt_end_rel else tail
        init_rel = stmt.find("=")
        has_body = "{" in (stmt if init_rel < 0 else stmt[init_rel:]) or ("{" in stmt and init_rel < 0)
        def strip_macros():
            nonlocal_attr = re.sub(r"@(Transient|Attribute|Relationship|Unique|Index)\b(\s*\([^)]*\))?", "", attr_text) if False else None
        if pm.group(5) == "let" or pm.group(4) or has_transient or has_body:
            # not persisted: only drop @Transient / @Attribute / @Relationship text
            new_attr = _strip_model_attrs(attr_text)
            if new_attr != attr_text:
                edits.append((a0, a1, new_attr))
            continue
        type_text = (src[body_s + pm.start(7):body_s + pm.end(7)][1:].strip() if pm.group(7) else "")
        default = None
        stmt_abs_start = body_s + pm.end()
        if init_rel >= 0:
            default = src[stmt_abs_start + init_rel + 1:stmt_abs_start + len(stmt)].strip()
        decl_end = stmt_abs_start + len(stmt)
        metadata = "nil"
        am = re.search(r"@Attribute\b\s*(\(.*\))?", attr_text, re.S)
        rm = re.search(r"@Relationship\b\s*(\(.*\))?", attr_text, re.S)
        if am:
            metadata = "SwiftData.Schema.Attribute" + (am.group(1) or "()")
        elif rm:
            metadata = "SwiftData.Schema.Relationship" + (rm.group(1) or "()")
        optional = bool(re.search(r"(\?|!)\s*$", type_text)) or type_text.startswith("Optional<")
        props.append({"name": pname, "type": type_text, "default": default, "optional": optional, "meta": metadata,
                      "attrs": (a0, a1, _strip_model_attrs(attr_text)), "decl_end": decl_end})
    # build edits for persisted properties
    for p in props:
        a0, a1, new_attr = p["attrs"]
        edits.append((a0, a1, new_attr))
        n = p["name"]
        accessors = (
            " {\n"
            "    @storageRestrictions(accesses: _$backingData, initializes: _%(n)s)\n"
            "    init(initialValue) {\n"
            "        _$backingData.setValue(forKey: \\.%(n)s, to: initialValue)\n"
            "        _%(n)s = _SwiftDataNoType()\n"
            "    }\n"
            "    get {\n"
            "        _$observationRegistrar.access(self, keyPath: \\.%(n)s)\n"
            "        return self.getValue(forKey: \\.%(n)s)\n"
            "    }\n"
            "    set {\n"
            "        _$observationRegistrar.withMutation(of: self, keyPath: \\.%(n)s) {\n"
            "            self.setValue(forKey: \\.%(n)s, to: newValue)\n"
            "        }\n"
            "    }\n"
            "}" % {"n": n})
        storage = "\nprivate var _%s: _SwiftDataNoType%s%s" % (
            n, "?" if p["optional"] else "", " = _SwiftDataNoType()" if p["default"] is not None else "")
        edits.append((p["decl_end"], p["decl_end"], accessors + storage))
    req = "" if final else "required "
    members = (
        "\n    private var _$backingData: any SwiftData.BackingData<%(c)s> = %(c)s.createBackingData()\n"
        "    %(a)spublic_placeholder var persistentBackingData: any SwiftData.BackingData<%(c)s> {\n"
        "        get { return _$backingData }\n"
        "        set { _$backingData = newValue }\n"
        "    }\n"
        "    %(a)sstatic var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {\n"
        "        return [\n%(meta)s\n        ]\n"
        "    }\n"
        "    %(req)s%(a)sinit(backingData: any SwiftData.BackingData<%(c)s>) {\n%(inits)s"
        "        self.persistentBackingData = backingData\n"
        "    }\n"
        "    private let _$observationRegistrar = Observation.ObservationRegistrar()\n"
        "    internal nonisolated func access<_M>(keyPath: KeyPath<%(c)s, _M>) {\n"
        "        _$observationRegistrar.access(self, keyPath: keyPath)\n"
        "    }\n"
        "    internal nonisolated func withMutation<_M, _MR>(keyPath: KeyPath<%(c)s, _M>, _ mutation: () throws -> _MR) rethrows -> _MR {\n"
        "        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)\n"
        "    }\n"
        "    struct _SwiftDataNoType {}\n"
    ) % {
        "c": name, "a": acc, "req": req,
        "meta": ",\n".join('            SwiftData.Schema.PropertyMetadata(name: "%s", keypath: \\%s.%s, defaultValue: %s, metadata: %s)' % (
            p["name"], name, p["name"], p["default"] if p["default"] is not None else "nil", p["meta"]) for p in props),
        "inits": "".join("        _%s = _SwiftDataNoType()\n" % p["name"] for p in props),
    }
    members = members.replace("public_placeholder ", "")
    edits.append((brace + 1, brace + 1, members))
    # apply edits back to front over src[attr_start : close+1]
    edits.sort(key=lambda e: (e[0], e[1]), reverse=True)
    text = src
    for a, b, r in edits:
        text = text[:a] + r + text[b:]
    delta = len(text) - len(src)
    new_class = text[attr_end:close + 1 + delta]
    ext = (
        "\n\nextension %(c)s: SwiftData.PersistentModel {}\n"
        "extension %(c)s: Observation.Observable {}\n"
        "@available(*, unavailable, message: \"PersistentModels are not Sendable, consider utilizing a ModelActor or use %(c)s's persistentModelID instead\")\n"
        "extension %(c)s: Sendable {}\n"
    ) % {"c": name}
    return new_class + ext, close + 1


def _strip_model_attrs(attr_text):
    out = attr_text
    for nm in ("Transient", "Attribute", "Relationship"):
        out = re.sub(r"@" + nm + r"\b[ \t]*(\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?", "", out)
    return out


def expand_model(src):
    if "@Model" not in src:
        return None
    clean = _blank_literals(src)
    result, pos, changed = [], 0, False
    while True:
        m = _MODEL_RE.search(clean, pos)
        if not m:
            break
        got = _expand_model_class(src, clean, m.start(), m.end())
        if not got:
            result.append(src[pos:m.end()])
            pos = m.end()
            continue
        text, end = got
        result.append(src[pos:m.start()])
        result.append(text)
        pos = end
        changed = True
    result.append(src[pos:])
    return "".join(result) if changed else None


# ---------------------------------------------------------------- SwiftUI @Entry
_ENTRY_KEYS = {
    "EnvironmentValues": "SwiftUI.EnvironmentKey",
    "Transaction": "SwiftUI.TransactionKey",
    "ContainerValues": "SwiftUI.ContainerValueKey",
    "FocusedValues": "SwiftUI.FocusedValueKey",
}
_EXT_RE = re.compile(r"extension\s+(?:SwiftUI\.)?(EnvironmentValues|FocusedValues|Transaction|ContainerValues)\b[^{]*\{")


def expand_entry(src):
    if "@Entry" not in src:
        return None
    clean = _blank_literals(src)
    edits = []
    for em in _EXT_RE.finditer(clean):
        base = em.group(1)
        brace = em.end() - 1
        depth, k = 0, brace
        while k < len(clean):
            if clean[k] == "{":
                depth += 1
            elif clean[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        if depth != 0:
            continue
        body_s, body_e = brace + 1, k
        flat = _flat_mask(clean[body_s:body_e])
        for pm in _PROP_RE.finditer(flat):
            attrs_clean = pm.group(2) or ""
            if not re.search(r"@Entry\b", attrs_clean) or pm.group(5) != "var" or not pm.group(7):
                continue
            name = pm.group(6)
            a0, a1 = body_s + pm.start(2), body_s + pm.end(2)
            type_start = body_s + pm.start(7)
            type_end = body_s + pm.end(7)
            type_text = src[type_start:type_end][1:].strip()
            tail = flat[pm.end():]
            m_end = re.search(r"[\n;]", tail)
            stmt = tail[:m_end.start()] if m_end else tail
            decl_end = body_s + pm.end() + len(stmt)
            eq = stmt.find("=")
            default = src[body_s + pm.end() + eq + 1:decl_end].strip() if eq >= 0 else None
            optional = type_text.endswith("?") or type_text.endswith("!") or type_text.startswith("Optional<")
            if default is None and optional:
                default = "nil"
            if default is None:
                continue
            accessors = (" {\n    get { self[__Key_%(n)s.self] }\n    set { self[__Key_%(n)s.self] = newValue }\n}\n" % {"n": name})
            if base == "FocusedValues":
                value_t = type_text[:-1] if type_text.endswith("?") else type_text
                key = "private struct __Key_%s: SwiftUI.FocusedValueKey {\n    typealias Value = %s\n}" % (name, value_t)
            else:
                key = "private struct __Key_%s: %s {\n    static var defaultValue: %s { %s }\n}" % (name, _ENTRY_KEYS[base], type_text, default)
            # drop @Entry, drop "= default", add accessors and the key type
            edits.append((a0, a1, re.sub(r"@Entry\b[ \t]*(\(\s*\))?", "", src[a0:a1])))
            edits.append((type_end, decl_end, accessors + key))
    if not edits:
        return None
    edits.sort(key=lambda e: (e[0], e[1]), reverse=True)
    out = src
    for a, b, r in edits:
        out = out[:a] + r + out[b:]
    return out


def strip_previews(src):
    """Removes `#Preview ... { }` blocks (previews are Xcode-only and need Apple's preview macro plugin)."""
    if "#Preview" not in src:
        return None
    clean = _blank_literals(src)
    out, pos, changed = [], 0, False
    for m in re.finditer(r"(?<![A-Za-z0-9_])#Preview\b", clean):
        if m.start() < pos:
            continue
        i = m.end()
        n = len(clean)
        # optional (name, traits) arguments, then optional trailing closure(s)
        while i < n and clean[i] in " \t\r\n":
            i += 1
        if i < n and clean[i] == "(":
            j = _find_close(clean, i)
            if j < 0:
                continue
            i = j + 1
            while i < n and clean[i] in " \t\r\n":
                i += 1
        if i < n and clean[i] == "{":
            depth = 0
            while i < n:
                if clean[i] == "{":
                    depth += 1
                elif clean[i] == "}":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
            out.append(src[pos:m.start()])
            pos = i
            changed = True
    out.append(src[pos:])
    return "".join(out) if changed else None


def expand_source(src):
    """Returns the source with emulated macros expanded, or None when nothing changed."""
    changed = False
    sp = strip_previews(src)
    if sp is not None:
        src, changed = sp, True
    mdl = expand_model(src)
    if mdl is not None:
        src, changed = mdl, True
    ent = expand_entry(src)
    if ent is not None:
        src, changed = ent, True
    if "#" not in src:
        return src if changed else None
    for name, fn in FREESTANDING.items():
        pat = re.compile(r'(?<![A-Za-z0-9_])#' + name + r'\s*\(')
        pos = 0
        while True:
            m = pat.search(src, pos)
            if not m:
                break
            open_i = m.end() - 1
            close_i = _find_close(src, open_i)
            if close_i < 0:
                break
            body = fn(src[open_i + 1:close_i])
            if body is None:
                pos = close_i
                continue
            src = src[:m.start()] + body + src[close_i + 1:]
            pos = m.start() + len(body)
            changed = True
    return src if changed else None


def expand_files(files, out_dir):
    """Expand macros in the given files. Returns the new file list (changed files are copies under out_dir)."""
    result = []
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            result.append(path)
            continue
        new = expand_source(src)
        if new is None:
            result.append(path)
            continue
        dest = os.path.join(out_dir, "%08x_%s" % (abs(hash(path)) & 0xffffffff, os.path.basename(path)))
        os.makedirs(out_dir, exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(new)
        result.append(dest)
    return result


def run(request_path, result_path):
    """Entry point for the app: {"files": [...], "out": dir} -> {original path: path to compile}."""
    import json
    with open(request_path) as f:
        req = json.load(f)
    files = req["files"]
    new = expand_files(files, req["out"])
    with open(result_path, "w") as f:
        json.dump(dict(zip(files, new)), f)
