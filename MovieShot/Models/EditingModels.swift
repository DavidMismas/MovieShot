import Foundation

enum EditorStep: Int, CaseIterable {
    case source
    case preset
    case adjust
    case crop
    case final

    var title: String {
        switch self {
        case .source: return "1. Source"
        case .preset: return "2. Preset"
        case .adjust: return "3. Adjust"
        case .crop: return "4. Crop"
        case .final: return "5. Export"
        }
    }
}

enum CropOption: String, CaseIterable, Identifiable {
    case original
    case fourByFive
    case cinema21by9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .fourByFive: return "4:5"
        case .cinema21by9: return "21:9"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .fourByFive: return 4.0 / 5.0
        case .cinema21by9: return 21.0 / 9.0
        }
    }

    /// When true, the crop is always landscape (width > height), never swapped.
    var forceHorizontal: Bool {
        switch self {
        case .cinema21by9: return true
        default: return false
        }
    }
}

enum MoviePreset: String, CaseIterable, Identifiable {
    case matrix
    case bladeRunner2049
    case sinCity
    case theBatman
    case strangerThings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: return "Matrix"
        case .bladeRunner2049: return "Blade Runner 2049"
        case .sinCity: return "Sin City"
        case .theBatman: return "The Batman"
        case .strangerThings: return "Stranger Things"
        }
    }

    var subtitle: String {
        switch self {
        case .matrix: return "Green cast, cooler mids, high contrast"
        case .bladeRunner2049: return "Warm highlights, teal shadows, bold contrast"
        case .sinCity: return "High contrast B&W, crushed shadows, noir"
        case .theBatman: return "Dark desaturated, teal shadows, crushed blacks"
        case .strangerThings: return "Warm amber tones, muted vintage, nostalgic"
        }
    }
}
