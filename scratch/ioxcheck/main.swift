import Foundation
// Runs the app's Xcode-project importer on a checkout and prints what iOXcode would build.
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let r = XcodeProjectReader.read(projectDir: dir) else { print("NO XCODE PROJECT FOUND"); exit(1) }
let m = r.manifest
let swiftFiles = m.swiftFiles ?? []
let cFiles = m.cFiles ?? []
print("name: \(m.name)  bundle: \(m.bundleId)  minOS: \(m.minOS)  swift: \(m.swiftVersion)  family: \(m.deviceFamily.map { "\($0)" } ?? "default")")
print("infoPlistFile: \(m.infoPlistFile ?? "-")  bridging: \(m.bridgingHeader ?? "-")")
print("swift files: \(swiftFiles.count)  C files: \(cFiles.count)  resources: \((m.resources as [String]? ?? []).count)  sources(synced): \(m.sources)")
print("frameworks: \(m.frameworks)")
print("libraries: \(m.libraries)  linkerFlags: \(m.linkerFlags)  swiftFlags: \(m.swiftFlags)")
for w in r.warnings { print("warning: \(w)") }
for p in m.packages { print("package \(p.name) [\(p.kind)] products=\(p.products) url=\(p.url)") }
for s in m.scripts { print("script: \(s.name) afterCompile=\(s.afterCompile)") }
let missing = swiftFiles.filter { !FileManager.default.fileExists(atPath: r.root.appendingPathComponent($0).path) }
print("missing swift files on disk: \(missing.count)\(missing.isEmpty ? "" : " e.g. \(missing.prefix(5))")")
let mac = swiftFiles.filter { $0.hasPrefix("Mac/") || $0.contains("/Mac/") }
print("files under Mac/: \(mac.count)")
try? JSONEncoder().encode(m).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
