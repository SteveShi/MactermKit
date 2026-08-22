import Foundation

public struct GhosttyThemeDefinition: Sendable, Hashable, Identifiable {
    public var id: String {
        name
    }

    public let name: String
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let cursorText: String?
    public let selectionBackground: String?
    public let selectionForeground: String?
    public let palette: [Int: String]

    public init(
        name: String,
        background: String,
        foreground: String,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [Int: String] = [:]
    ) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    /// Whether this theme appears to be a dark theme based on background luminance.
    public var isDark: Bool {
        let hex = background.hasPrefix("#") ? background.dropFirst() : background[...]
        guard hex.count >= 6, let rgb = UInt32(hex.prefix(6), radix: 16) else { return true }
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 128
    }
}
