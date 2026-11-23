import Foundation

/// Xcode's Swift build settings that change how the compiler runs, turned into compiler flags the way Xcode does:
/// SWIFT_ACTIVE_COMPILATION_CONDITIONS, SWIFT_STRICT_CONCURRENCY, SWIFT_UPCOMING_FEATURE_*, SWIFT_DEFAULT_ACTOR_ISOLATION,
/// SWIFT_APPROACHABLE_CONCURRENCY and SWIFT_STRICT_MEMORY_SAFETY.
enum SwiftSettings {
    /// Names whose build setting spelling does not turn into the flag by simply capitalizing each word.
    static let featureNames: [String: String] = [
        "BARE_SLASH_REGEX_LITERALS": "BareSlashRegexLiterals", "IMPORT_OBJC_FORWARD_DECLS": "ImportObjcForwardDeclarations",
        "DISABLE_OUTWARD_ACTOR_ISOLATION": "DisableOutwardActorInference", "DISABLE_OUTWARD_ACTOR_INFERENCE": "DisableOutwardActorInference",
        "INFER_SENDABLE_FROM_CAPTURES": "InferSendableFromCaptures", "NONFROZEN_ENUM_EXHAUSTIVITY": "NonfrozenEnumExhaustivity",
        "GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "GlobalActorIsolatedTypesUsability", "STRICT_CONCURRENCY": "StrictConcurrency",
    ]
    static let approachable = ["NonisolatedNonsendingByDefault", "InferIsolatedConformances", "DisableOutwardActorInference",
                               "GlobalActorIsolatedTypesUsability", "InferSendableFromCaptures"]

    static func isOn(_ v: String?) -> Bool { v == "YES" || v == "true" || v == "TRUE" }

    static func flags(_ settings: [String: String]) -> [String] {
        var out: [String] = []
        for c in (settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let t = String(c)
            if t.contains("$") || t.isEmpty { continue }          // $(inherited) and other variables
            out += ["-D", t]
        }
        if let s = settings["SWIFT_STRICT_CONCURRENCY"], ["minimal", "targeted", "complete"].contains(s) {
            out += ["-strict-concurrency=" + s]
        }
        var features: [String] = []
        if isOn(settings["SWIFT_APPROACHABLE_CONCURRENCY"]) { features += approachable }
        for (k, v) in settings.sorted(by: { $0.key < $1.key }) where k.hasPrefix("SWIFT_UPCOMING_FEATURE_") && isOn(v) {
            let raw = String(k.dropFirst("SWIFT_UPCOMING_FEATURE_".count))
            features.append(featureNames[raw] ?? raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined())
        }
        var seen = Set<String>()
        for f in features where seen.insert(f).inserted { out += ["-enable-upcoming-feature", f] }
        if let iso = settings["SWIFT_DEFAULT_ACTOR_ISOLATION"], ["MainActor", "nonisolated"].contains(iso) {
            out += ["-default-isolation", iso]
        }
        if isOn(settings["SWIFT_STRICT_MEMORY_SAFETY"]) { out += ["-strict-memory-safety"] }
        return out
    }
}
