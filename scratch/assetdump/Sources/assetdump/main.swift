import Foundation
import AssetKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// usage: assetdump <catalog.xcassets> <out.car>
// Stages a copy the same way iOXcode does (no app icon sets, CgBI PNGs normalised), compiles it with AssetKit.
let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let fm = FileManager.default
let stage = fm.temporaryDirectory.appendingPathComponent("stage-\(getpid()).xcassets")
try? fm.removeItem(at: stage)
try fm.copyItem(at: src, to: stage)

var drop: [URL] = []
if let en = fm.enumerator(at: stage, includingPropertiesForKeys: nil) {
    for case let u as URL in en {
        if u.pathExtension == "appiconset" || u.pathExtension == "launchimage" { drop.append(u) }
        if u.pathExtension == "imageset", ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).contains(where: { $0.lowercased().hasSuffix(".pdf") }) { drop.append(u) }
    }
}
for u in drop { try? fm.removeItem(at: u) }

var fixed = 0
if let en = fm.enumerator(at: stage, includingPropertiesForKeys: nil) {
    for case let u as URL in en where u.pathExtension.lowercased() == "png" {
        guard let h = try? FileHandle(forReadingFrom: u) else { continue }
        let head = (try? h.read(upToCount: 16)) ?? Data()
        try? h.close()
        guard head.count == 16, head[12] == 0x43, head[13] == 0x67, head[14] == 0x42, head[15] == 0x49 else { continue }
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
        let tmp = u.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) { try? fm.removeItem(at: u); try? fm.moveItem(at: tmp, to: u); fixed += 1 }
    }
}
print("staged: dropped \(drop.count), converted \(fixed) CgBI")
let res = try await XCAssetCompiler(deploymentTarget: "16.0").compile(catalog: stage)
try res.carData.write(to: out)
print("wrote \(out.path) \(res.carData.count / 1024) KB")
