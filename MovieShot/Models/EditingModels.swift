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
    case studioClean
    case daylightRun
    case sinCity
    case theBatman
    case strangerThings
    case dune
    case drive
    case madMax
    case revenant
    case inTheMoodForLove
    case seven
    case vertigo
    case orderOfPhoenix
    case hero
    case laLaLand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: return "MathX"
        case .bladeRunner2049: return "Runner 2094"
        case .studioClean: return "Studio Clean"
        case .daylightRun: return "Daylight Run"
        case .sinCity: return "Hell City"
        case .theBatman: return "Darkman"
        case .strangerThings: return "Weird Things"
        case .dune: return "Arrakis Dust"
        case .drive: return "Night Drive"
        case .madMax: return "Fury Heat"
        case .revenant: return "Risen One"
        case .inTheMoodForLove: return "Mood for Love"
        case .seven: return "Seven Sins"
        case .vertigo: return "Spiral"
        case .orderOfPhoenix: return "Dark Order"
        case .hero: return "Ying Xiong"
        case .laLaLand: return "La La"
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
        case .matrix: return "Green cast, cool mids, high contrast"
        case .bladeRunner2049: return "Orange highs, teal-purple shadows, wide range"
        case .studioClean: return "Neutral true color, lifted blacks, clean detail"
        case .daylightRun: return "Film-inspired daylight pop, rich but natural color"
        case .sinCity: return "Noir B&W, crushed shadows, hard contrast"
        case .theBatman: return "Dark desaturated tone, teal shadows, deep blacks"
        case .strangerThings: return "Amber highlights, teal shadows, vivid 80s tone"
        case .dune: return "Dusty amber desert, cool shadows, soft haze"
        case .drive: return "Magenta-cyan neon, glossy blacks, night contrast"
        case .madMax: return "Aggressive orange-teal, gritty heat contrast"
        case .revenant: return "Cold desaturated earth tones, natural drama"
        case .inTheMoodForLove: return "Rich tungsten reds, jade greens, soft glow"
        case .seven: return "Bleach-bypass grit, cyan shadows, heavy grain"
        case .vertigo: return "Technicolor reds, eerie greens, dreamy fog"
        case .orderOfPhoenix: return "Blue-teal cast, crushed shadows, dark desat"
        case .hero: return "Vivid saturated primaries, epic color contrast"
        case .laLaLand: return "Pastel dreamscape, warm magic hour, soft grain"
        }
    }
}
