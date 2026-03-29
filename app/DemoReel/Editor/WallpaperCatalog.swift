import Foundation

struct WallpaperInfo: Identifiable {
    let id: String
    let displayName: String
    let category: String
}

let wallpaperCatalog: [WallpaperInfo] = [
    // macOS
    WallpaperInfo(id: "big-sur-day", displayName: "Big Sur Day", category: "macOS"),
    WallpaperInfo(id: "big-sur-night", displayName: "Big Sur Night", category: "macOS"),
    WallpaperInfo(id: "monterey-light", displayName: "Monterey Light", category: "macOS"),
    WallpaperInfo(id: "monterey-dark", displayName: "Monterey Dark", category: "macOS"),
    WallpaperInfo(id: "ventura-light", displayName: "Ventura Light", category: "macOS"),
    WallpaperInfo(id: "ventura-dark", displayName: "Ventura Dark", category: "macOS"),
    WallpaperInfo(id: "sonoma-light", displayName: "Sonoma Light", category: "macOS"),
    WallpaperInfo(id: "sonoma-dark", displayName: "Sonoma Dark", category: "macOS"),
    WallpaperInfo(id: "sonoma-horizon", displayName: "Sonoma Horizon", category: "macOS"),
    WallpaperInfo(id: "sequoia-light", displayName: "Sequoia Light", category: "macOS"),
    WallpaperInfo(id: "sequoia-dark", displayName: "Sequoia Dark", category: "macOS"),
    WallpaperInfo(id: "sequoia-sunrise", displayName: "Sequoia Sunrise", category: "macOS"),
    WallpaperInfo(id: "tahoe-light", displayName: "Tahoe Light", category: "macOS"),
    WallpaperInfo(id: "tahoe-dark", displayName: "Tahoe Dark", category: "macOS"),

    // Abstract
    WallpaperInfo(id: "abstract-1", displayName: "Abstract 1", category: "Abstract"),
    WallpaperInfo(id: "abstract-2", displayName: "Abstract 2", category: "Abstract"),
    WallpaperInfo(id: "abstract-3", displayName: "Abstract 3", category: "Abstract"),
    WallpaperInfo(id: "abstract-4", displayName: "Abstract 4", category: "Abstract"),
    WallpaperInfo(id: "abstract-shapes", displayName: "Abstract Shapes", category: "Abstract"),
    WallpaperInfo(id: "abstract-shapes-2", displayName: "Abstract Shapes 2", category: "Abstract"),
    WallpaperInfo(id: "chroma-1", displayName: "Chroma 1", category: "Abstract"),
    WallpaperInfo(id: "chroma-2", displayName: "Chroma 2", category: "Abstract"),
    WallpaperInfo(id: "color-burst-1", displayName: "Color Burst 1", category: "Abstract"),
    WallpaperInfo(id: "color-burst-2", displayName: "Color Burst 2", category: "Abstract"),
    WallpaperInfo(id: "color-burst-3", displayName: "Color Burst 3", category: "Abstract"),
]

let wallpaperCategories: [String] = ["macOS", "Abstract"]
