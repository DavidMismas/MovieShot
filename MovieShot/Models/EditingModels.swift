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

    nonisolated var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .fourByFive: return 4.0 / 5.0
        case .cinema21by9: return 21.0 / 9.0
        }
    }

    /// When true, the crop is always landscape (width > height), never swapped.
    nonisolated var forceHorizontal: Bool {
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
    case dune
    case drive
    case madMax
    case revenant
    case inTheMoodForLove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: return "MathX"
        case .bladeRunner2049: return "Runner 2094"
        case .sinCity: return "Hell City"
        case .theBatman: return "Darkman"
        case .strangerThings: return "Weirder Things"
        case .dune: return "Arrakis Dust"
        case .drive: return "Neon Night"
        case .madMax: return "Fury Heat"
        case .revenant: return "Natural Cold"
        case .inTheMoodForLove: return "Mood for Love"
        }
    }

    /// Free presets: matrix, bladeRunner2049. All others require Pro.
    var isProLocked: Bool {
        switch self {
        case .matrix, .bladeRunner2049: return false
        default: return true
        }
    }

    var subtitle: String {
        switch self {
        case .matrix: return "Green cast, cooler mids, high contrast"
        case .bladeRunner2049: return "Orange highlights, teal-purple shadows, wide dynamic range"
        case .sinCity: return "High contrast B&W, crushed shadows, noir"
        case .theBatman: return "Dark desaturated, teal shadows, crushed blacks"
        case .strangerThings: return "Kodachrome amber, teal shadows, vivid 80s palette"
        case .dune: return "Dusty amber desert, cool shadows, cinematic haze"
        case .drive: return "Magenta-cyan neon, glossy blacks, night contrast"
        case .madMax: return "Aggressive orange-teal, gritty contrast, heat"
        case .revenant: return "Cold desaturated earth, natural dramatic tone"
        case .inTheMoodForLove: return "Rich tungsten reds, jade greens, soft glow"
        }
    }
}
