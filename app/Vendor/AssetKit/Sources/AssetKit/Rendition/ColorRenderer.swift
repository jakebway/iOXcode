import Foundation

enum ColorRenderer {
    static func renditions(for set: LoadedColorSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for entry in set.contents.colors {
            guard let color = entry.color else { continue }
            let isDark = entry.appearances?.contains { $0.darkLuminosity } ?? false
            let (r, g, b, a): (Double, Double, Double, Double)
            if let comps = color.components {
                (r, g, b, a) = try comps.asDoubles()
            } else if let ref = color.reference {
                (r, g, b, a) = SystemColors.value(ref, dark: isDark)
            } else { continue }
            let gamut: Gamut = {
                if let declared = entry.displayGamut { return declared }
                switch color.colorSpace ?? "srgb" {
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

/// iOS's named dynamic colors (`"reference": "systemBackgroundColor"` in a colorset), as fixed sRGB values for light and dark.
enum SystemColors {
    static func value(_ name: String, dark: Bool) -> (Double, Double, Double, Double) {
        func v(_ l: (Double, Double, Double, Double), _ d: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) { dark ? d : l }
        switch name {
        case "systemBackgroundColor": return v((1, 1, 1, 1), (0, 0, 0, 1))
        case "secondarySystemBackgroundColor": return v((0.949, 0.949, 0.969, 1), (0.110, 0.110, 0.118, 1))
        case "tertiarySystemBackgroundColor": return v((1, 1, 1, 1), (0.173, 0.173, 0.180, 1))
        case "systemGroupedBackgroundColor": return v((0.949, 0.949, 0.969, 1), (0, 0, 0, 1))
        case "secondarySystemGroupedBackgroundColor": return v((1, 1, 1, 1), (0.110, 0.110, 0.118, 1))
        case "tertiarySystemGroupedBackgroundColor": return v((0.949, 0.949, 0.969, 1), (0.173, 0.173, 0.180, 1))
        case "labelColor": return v((0, 0, 0, 1), (1, 1, 1, 1))
        case "secondaryLabelColor": return v((0.235, 0.235, 0.263, 0.6), (0.922, 0.922, 0.961, 0.6))
        case "tertiaryLabelColor": return v((0.235, 0.235, 0.263, 0.3), (0.922, 0.922, 0.961, 0.3))
        case "quaternaryLabelColor": return v((0.235, 0.235, 0.263, 0.18), (0.922, 0.922, 0.961, 0.16))
        case "placeholderTextColor": return v((0.235, 0.235, 0.263, 0.3), (0.922, 0.922, 0.961, 0.3))
        case "separatorColor": return v((0.235, 0.235, 0.263, 0.29), (0.329, 0.329, 0.345, 0.6))
        case "opaqueSeparatorColor": return v((0.776, 0.776, 0.784, 1), (0.220, 0.220, 0.227, 1))
        case "linkColor", "systemBlueColor", "tintColor": return v((0, 0.478, 1, 1), (0.039, 0.518, 1, 1))
        case "systemRedColor": return v((1, 0.231, 0.188, 1), (1, 0.271, 0.227, 1))
        case "systemGreenColor": return v((0.204, 0.780, 0.349, 1), (0.188, 0.820, 0.345, 1))
        case "systemOrangeColor": return v((1, 0.584, 0, 1), (1, 0.624, 0.039, 1))
        case "systemYellowColor": return v((1, 0.800, 0, 1), (1, 0.839, 0.039, 1))
        case "systemPinkColor": return v((1, 0.176, 0.333, 1), (1, 0.216, 0.373, 1))
        case "systemPurpleColor": return v((0.686, 0.322, 0.871, 1), (0.749, 0.353, 0.949, 1))
        case "systemTealColor": return v((0.188, 0.690, 0.780, 1), (0.251, 0.784, 0.878, 1))
        case "systemIndigoColor": return v((0.345, 0.337, 0.839, 1), (0.369, 0.361, 0.902, 1))
        case "systemGrayColor": return (0.557, 0.557, 0.576, 1)
        case "systemGray2Color": return v((0.682, 0.682, 0.698, 1), (0.388, 0.388, 0.400, 1))
        case "systemGray3Color": return v((0.780, 0.780, 0.800, 1), (0.282, 0.282, 0.290, 1))
        case "systemGray4Color": return v((0.820, 0.820, 0.839, 1), (0.227, 0.227, 0.235, 1))
        case "systemGray5Color": return v((0.898, 0.898, 0.918, 1), (0.173, 0.173, 0.180, 1))
        case "systemGray6Color": return v((0.949, 0.949, 0.969, 1), (0.110, 0.110, 0.118, 1))
        case "whiteColor", "lightTextColor": return (1, 1, 1, name == "lightTextColor" ? 0.6 : 1)
        case "blackColor", "darkTextColor": return (0, 0, 0, 1)
        case "clearColor": return (0, 0, 0, 0)
        default: return v((0.5, 0.5, 0.5, 1), (0.5, 0.5, 0.5, 1))
        }
    }
}
