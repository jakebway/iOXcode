import Foundation

enum ColorRenderer {
    static func renditions(for set: LoadedColorSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for entry in set.contents.colors {
            guard let color = entry.color else { continue }
            let (r, g, b, a) = try color.components.asDoubles()
            let gamut: Gamut = {
                if let declared = entry.displayGamut { return declared }
                switch color.colorSpace {
                case "display-p3": return .displayP3
                default: return .sRGB
                }
            }()
            let appearance = entry.appearances?.first { $0.darkLuminosity }
            out.append(Rendition(
                name: set.name,
                idiom: entry.idiom,
                scale: nil,
                appearance: appearance,
                gamut: gamut,
                body: .color(ColorBody(
                    red: r, green: g, blue: b, alpha: a,
                    colorSpaceID: gamut.colorSpaceID
                ))
            ))
        }
        return out
    }
}
