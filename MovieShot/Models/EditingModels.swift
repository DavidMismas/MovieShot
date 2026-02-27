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
    case wall
    case cinema21by9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .fourByFive: return "Insta"
        case .wall: return "Wall"
        case .cinema21by9: return "Cine"
        }
    }

    nonisolated var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .fourByFive: return 4.0 / 5.0
        case .wall: return 9.0 / 19.5
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

    /// When true, the crop is always portrait (height > width), never swapped.
    nonisolated var forceVertical: Bool {
        switch self {
        case .wall: return true
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
    case blockbusterTealOrange
    case metroNeonNight
    case noirTealGlow
    case urbanWarmCool
    case electricDusk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: return "MathX"
        case .bladeRunner2049: return "Runner 2094"
        case .studioClean: return "MQHQ"
        case .daylightRun: return "No Time"
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
        case .blockbusterTealOrange: return "Blockbuster T&O"
        case .metroNeonNight: return "Metro Neon"
        case .noirTealGlow: return "Noir Teal Glow"
        case .urbanWarmCool: return "Urban Warm/Cool"
        case .electricDusk: return "Electric Dusk"
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
        case .blockbusterTealOrange: return "Modern teal-orange split, clean cinematic punch"
        case .metroNeonNight: return "Cyber city night, neon cyan-magenta with amber glow"
        case .noirTealGlow: return "Moody noir, deep tones, restrained color, teal bias"
        case .urbanWarmCool: return "Subtle city split-tone, natural and filmic everyday look"
        case .electricDusk: return "Blue-hour atmosphere, electric shadows, sunset highlights"
        }
    }
}
