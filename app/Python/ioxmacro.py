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


def _infer_literal_type(d):
    if d is None:
        return None
    d = d.strip()
    if d in ("true", "false"):
        return "Bool"
    if re.fullmatch(r"-?\d[\d_]*", d):
        return "Int"
    if re.fullmatch(r"-?\d[\d_]*\.\d+", d):
        return "Double"
    if re.fullmatch(r'"(?:\\.|[^"\\])*"', d):
        return "String"
    m = re.fullmatch(r"([A-Z]\w*(?:\.[A-Z]\w*)*)\s*\(.*\)", d, re.S)
    if m:
        return m.group(1)
    return None


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
            if not re.search(r"@Entry\b", attrs_clean) or pm.group(5) != "var":
                continue
            name = pm.group(6)
            a0, a1 = body_s + pm.start(2), body_s + pm.end(2)
            inferred = None
            if pm.group(7):
                type_start = body_s + pm.start(7)
                type_end = body_s + pm.end(7)
                type_text = src[type_start:type_end][1:].strip()
            else:
                type_start = type_end = body_s + pm.end(6)
                type_text = None
            tail = flat[pm.end():]
            m_end = re.search(r"[\n;]", tail)
            stmt = tail[:m_end.start()] if m_end else tail
            decl_end = body_s + pm.end() + len(stmt)
            eq = stmt.find("=")
            default = src[body_s + pm.end() + eq + 1:decl_end].strip() if eq >= 0 else None
            if type_text is None:
                type_text = _infer_literal_type(default)
                if type_text is None:
                    continue
                inferred = ": " + type_text
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
            edits.append((type_end, decl_end, (inferred or "") + accessors + key))
    if not edits:
        return None
    edits.sort(key=lambda e: (e[0], e[1]), reverse=True)
    out = src
    for a, b, r in edits:
        out = out[:a] + r + out[b:]
    return out


# ---------------------------------------------------------------- SwiftData @Query
_QUERY_HEAD = re.compile(r"\s*((?:(?:@\w+(?:\([^)]*\))?|private|fileprivate|internal|public|final|nonisolated)\s+)*)var\s+(\w+)\s*:\s*([^={\n;]+)")


def expand_query(src):
    if "@Query" not in src:
        return None
    clean = _blank_literals(src)
    edits = []
    for m in re.finditer(r"@Query\b", clean):
        i = m.end()
        n = len(clean)
        args = ""
        j = i
        while j < n and clean[j] in " \t":
            j += 1
        end_attr = i
        if j < n and clean[j] == "(":
            k = _find_close(clean, j)
            if k < 0:
                continue
            args = src[j + 1:k]
            end_attr = k + 1
        hm = _QUERY_HEAD.match(clean, end_attr)
        if not hm:
            continue
        name = hm.group(2)
        type_text = hm.group(3).strip()
        type_end = hm.start(3) + len(hm.group(3).rstrip())
        accessors = (" {\n    get { _%(n)s.wrappedValue }\n}\nprivate(set) var _%(n)s: SwiftData.Query<%(t)s.Element, %(t)s> = .init(%(a)s)" %
                     {"n": name, "t": type_text, "a": args.strip()})
        edits.append((type_end, type_end, accessors))
        edits.append((m.start(), end_attr, ""))
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


# ---------------------------------------------------------------- #Predicate / #Expression
# Clean-room translator: Swift closure expression -> Foundation.PredicateExpressions builder calls.
# Output shapes were captured from Apple's compiler (tools/macro-probe/Predicates.swift).

def _find_brace(clean, i):
    depth = 0
    for k in range(i, len(clean)):
        if clean[k] == "{":
            depth += 1
        elif clean[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return -1


class _Unsupported(Exception):
    pass


_P_TOK = re.compile(r'\s*(?:(?P<str>"(?:\\.|[^"\\])*")|(?P<num>\d[\d_]*(?:\.\d+)?)|(?P<id>\$\d+|[A-Za-z_]\w*)|(?P<op>\.\.\.|\.\.<|==|!=|<=|>=|&&|\|\||\?\?|\?\.|[-+*/%<>!?.:,(){}\[\]]))')
_P_CMP = {"==": "Equal", "!=": "NotEqual"}
_P_REL = {"<": "lessThan", "<=": "lessThanOrEqual", ">": "greaterThan", ">=": "greaterThanOrEqual"}
_B = "PredicateExpressions.build_"


def _p_tokens(text):
    toks, i, n = [], 0, len(text)
    while i < n:
        if text[i:].strip() == "":
            break
        m = _P_TOK.match(text, i)
        if not m:
            raise _Unsupported("token")
        k = m.lastgroup
        toks.append((k, m.group(k)))
        i = m.end()
    return toks


class _PredParser:
    LEVELS = [["||"], ["&&"], ["==", "!=", "<", "<=", ">", ">="], ["??"], ["...", "..<"], ["+", "-"], ["*", "/", "%"]]

    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self, off=0):
        j = self.i + off
        return self.t[j] if j < len(self.t) else (None, None)

    def eat(self, val=None):
        tok = self.peek()
        if tok[0] is None or (val is not None and tok[1] != val):
            raise _Unsupported("expected " + str(val))
        self.i += 1
        return tok

    def at(self, val):
        return self.peek()[1] == val and self.peek()[0] in ("op", "id")

    def done(self):
        return self.i >= len(self.t)

    def expr(self):
        c = self.binary(0)
        if self.at("?"):
            self.eat("?")
            a = self.expr()
            self.eat(":")
            b = self.expr()
            return "%sConditional(%s, %s, %s)" % (_B, c, a, b)
        return c

    def binary(self, lvl):
        if lvl >= len(self.LEVELS):
            return self.unary()
        ops = self.LEVELS[lvl]
        lhs = self.binary(lvl + 1)
        while self.peek()[0] == "op" and self.peek()[1] in ops:
            op = self.eat()[1]
            rhs = self.binary(lvl) if op == "??" else self.binary(lvl + 1)
            lhs = self.combine(op, lhs, rhs)
            if lvl == 2:
                break
        return lhs

    def combine(self, op, l, r):
        if op == "||":
            return "%sDisjunction(lhs: %s, rhs: %s)" % (_B, l, r)
        if op == "&&":
            return "%sConjunction(lhs: %s, rhs: %s)" % (_B, l, r)
        if op in _P_CMP:
            return "%s%s(lhs: %s, rhs: %s)" % (_B, _P_CMP[op], l, r)
        if op in _P_REL:
            return "%sComparison(lhs: %s, rhs: %s, op: .%s)" % (_B, l, r, _P_REL[op])
        if op == "??":
            return "%sNilCoalesce(lhs: %s, rhs: %s)" % (_B, l, r)
        if op == "...":
            return "%sClosedRange(lower: %s, upper: %s)" % (_B, l, r)
        if op == "..<":
            return "%sRange(lower: %s, upper: %s)" % (_B, l, r)
        if op in ("+", "-", "*"):
            return "%sArithmetic(lhs: %s, rhs: %s, op: .%s)" % (_B, l, r, {"+": "add", "-": "subtract", "*": "multiply"}[op])
        if op == "/":
            return "%sDivision(lhs: %s, rhs: %s)" % (_B, l, r)
        if op == "%":
            return "%sRemainder(lhs: %s, rhs: %s)" % (_B, l, r)
        raise _Unsupported(op)

    def unary(self):
        k, v = self.peek()
        if k == "op" and v == "!":
            self.eat()
            return "%sNegation(%s)" % (_B, self.unary())
        if k == "op" and v == "-" and self.peek(1)[0] == "num":
            self.eat()
            return "%sArg(-%s)" % (_B, self.eat()[1])
        return self.postfix()

    def primary(self):
        k, v = self.peek()
        if k in ("str", "num"):
            self.eat()
            return "%sArg(%s)" % (_B, v)
        if k == "id":
            self.eat()
            if v == "nil":
                return "%sNilLiteral()" % _B
            if self.at("("):
                raise _Unsupported("global function")
            return "%sArg(%s)" % (_B, v)
        if k == "op" and v == "(":
            self.eat()
            e = self.expr()
            self.eat(")")
            return e
        raise _Unsupported("primary " + str(v))

    def closure(self):
        """Current token is `{`. Returns (params_text, body)."""
        self.eat("{")
        j, names = self.i, []
        while j < len(self.t) and j - self.i < 8 and self.t[j][1] not in ("in", "}"):
            names.append(self.t[j][1])
            j += 1
        text = ""
        if j < len(self.t) and self.t[j][1] == "in":
            text = " ".join(names) + " in"
            self.i = j + 1
        if self.at("return"):
            self.eat()
        body = self.expr()
        self.eat("}")
        return text, body

    def postfix(self):
        e = self.primary()
        while True:
            k, v = self.peek()
            if k == "op" and v in (".", "?."):
                self.eat()
                nk, name = self.eat()
                if nk != "id":
                    raise _Unsupported("member")
                if v == "?.":
                    e = "%sflatMap(%s) { %s }" % (_B, e, self.chain_on_dollar(name))
                else:
                    e = self.member(e, name)
                continue
            if k == "op" and v == "!":
                raise _Unsupported("force unwrap")
            return e

    def chain_on_dollar(self, first):
        cur = "%sKeyPath(root: %sArg($0), keyPath: \\.%s)" % (_B, _B, first)
        while True:
            k, v = self.peek()
            if k == "op" and v == ".":
                self.eat()
                cur = "%sKeyPath(root: %s, keyPath: \\.%s)" % (_B, cur, self.eat()[1])
            elif k == "op" and v == "?.":
                self.eat()
                cur = "%sflatMap(%s) { %sKeyPath(root: %sArg($0), keyPath: \\.%s) }" % (_B, cur, _B, _B, self.eat()[1])
            else:
                return cur

    def args(self):
        out = []
        self.eat("(")
        while not self.at(")"):
            label = None
            if self.peek()[0] == "id" and self.peek(1)[1] == ":":
                label = self.eat()[1]
                self.eat(":")
            out.append((label, self.expr()))
            if self.at(","):
                self.eat()
        self.eat(")")
        return out

    def member(self, recv, name):
        k, v = self.peek()
        if k == "op" and v == "(":
            a = self.args()
            trailing = self.closure() if self.at("{") else None
            return self.method(recv, name, a, trailing)
        if k == "op" and v == "{":
            return self.method(recv, name, [], self.closure())
        return "%sKeyPath(root: %s, keyPath: \\.%s)" % (_B, recv, name)

    def method(self, recv, name, a, trailing):
        if trailing is not None and name in ("contains", "filter", "allSatisfy") and not a:
            return "%s%s(%s) { %s\n%s\n}" % (_B, name, recv, trailing[0], trailing[1])
        if name in ("contains", "localizedStandardContains") and len(a) == 1 and a[0][0] is None and trailing is None:
            return "%s%s(%s, %s)" % (_B, name, recv, a[0][1])
        if name == "starts" and len(a) == 1 and a[0][0] == "with" and trailing is None:
            return "%sstarts(%s, with: %s)" % (_B, recv, a[0][1])
        raise _Unsupported("method " + name)


def expand_predicate(src):
    if "#Predicate" not in src and "#Expression" not in src:
        return None
    clean = _blank_literals(src)
    out, pos, changed = [], 0, False
    for m in re.finditer(r'#(Predicate|Expression)\b', clean):
        if m.start() < pos:
            continue
        i, generic = m.end(), ""
        if i < len(clean) and clean[i] == "<":
            depth, j = 0, i
            while j < len(clean):
                depth += (clean[j] == "<") - (clean[j] == ">")
                if depth == 0:
                    break
                j += 1
            generic, i = src[i:j + 1], j + 1
        j = i
        while j < len(clean) and clean[j] in " \t\n":
            j += 1
        paren = j < len(clean) and clean[j] == "("
        if paren:
            j += 1
            while j < len(clean) and clean[j] in " \t\n":
                j += 1
        if j >= len(clean) or clean[j] != "{":
            continue
        close = _find_brace(clean, j)
        if close < 0:
            continue
        end = close + 1
        if paren:
            k = end
            while k < len(clean) and clean[k] in " \t\n":
                k += 1
            if k >= len(clean) or clean[k] != ")":
                continue
            end = k + 1
        try:
            p = _PredParser(_p_tokens(src[j:close + 1]))
            text, body = p.closure()
            if not p.done():
                raise _Unsupported("trailing")
        except _Unsupported:
            continue
        text = re.sub(r"\(\s*(\w+)\s*:\s*([^)]+?)\s*\)", r"(\1: PredicateExpressions.Variable<\2>)", text)
        out.append(src[pos:m.start()])
        out.append("Foundation.%s%s({ %s\n%s\n})" % (m.group(1), generic, text, body))
        pos, changed = end, True
    if not changed:
        return None
    out.append(src[pos:])
    return "".join(out)


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
    qry = expand_query(src)
    if qry is not None:
        src, changed = qry, True
    prd = expand_predicate(src)
    if prd is not None:
        src, changed = prd, True
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
