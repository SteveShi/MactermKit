import Foundation

public enum GhosttyThemeCatalog {
    public static let allThemes: [GhosttyThemeDefinition] = [
        .dracula,
        .gitHub_Dark,
        .gitHub_Light,
        .gruvbox_Dark,
        .doom_One
    ]

    public static func theme(named name: String) -> GhosttyThemeDefinition? {
        allThemes.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    public static func search(_ query: String) -> [GhosttyThemeDefinition] {
        allThemes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

public extension GhosttyThemeDefinition {
    static let dracula = GhosttyThemeDefinition(
        name: "Dracula",
        background: "282a36",
        foreground: "f8f8f2",
        cursorColor: "f8f8f2",
        cursorText: "282a36",
        selectionBackground: "44475a",
        selectionForeground: "ffffff",
        palette: [0: "21222c", 1: "ff5555", 2: "50fa7b", 3: "f1fa8c", 4: "bd93f9", 5: "ff79c6", 6: "8be9fd", 7: "f8f8f2", 8: "6272a4", 9: "ff6e6e", 10: "69ff94", 11: "ffffa5", 12: "d6acff", 13: "ff92df", 14: "a4ffff", 15: "ffffff"]
    )

    static let gitHub_Dark = GhosttyThemeDefinition(
        name: "GitHub Dark",
        background: "101216",
        foreground: "8b949e",
        cursorColor: "c9d1d9",
        cursorText: "101216",
        selectionBackground: "3b5070",
        selectionForeground: "ffffff",
        palette: [0: "000000", 1: "f78166", 2: "56d364", 3: "e3b341", 4: "6ca4f8", 5: "db61a2", 6: "2b7489", 7: "ffffff", 8: "4d4d4d", 9: "f78166", 10: "56d364", 11: "e3b341", 12: "6ca4f8", 13: "db61a2", 14: "2b7489", 15: "ffffff"]
    )

    static let gitHub_Light = GhosttyThemeDefinition(
        name: "GitHub Light",
        background: "ffffff",
        foreground: "1f2328",
        cursorColor: "0969da",
        cursorText: "3c9cff",
        selectionBackground: "1f2328",
        selectionForeground: "ffffff",
        palette: [0: "24292f", 1: "cf222e", 2: "116329", 3: "4d2d00", 4: "0969da", 5: "8250df", 6: "1b7c83", 7: "6e7781", 8: "57606a", 9: "a40e26", 10: "1a7f37", 11: "633c01", 12: "218bff", 13: "a475f9", 14: "3192aa", 15: "8c959f"]
    )

    static let gruvbox_Dark = GhosttyThemeDefinition(
        name: "Gruvbox Dark",
        background: "282828",
        foreground: "ebdbb2",
        cursorColor: "ebdbb2",
        cursorText: "282828",
        selectionBackground: "665c54",
        selectionForeground: "ebdbb2",
        palette: [0: "282828", 1: "cc241d", 2: "98971a", 3: "d79921", 4: "458588", 5: "b16286", 6: "689d6a", 7: "a89984", 8: "928374", 9: "fb4934", 10: "b8bb26", 11: "fabd2f", 12: "83a598", 13: "d3869b", 14: "8ec07c", 15: "ebdbb2"]
    )

    static let doom_One = GhosttyThemeDefinition(
        name: "Doom One",
        background: "282c34",
        foreground: "bbc2cf",
        cursorColor: "51afef",
        cursorText: "1b1b1b",
        selectionBackground: "42444b",
        selectionForeground: "bbc2cf",
        palette: [0: "000000", 1: "ff6c6b", 2: "98be65", 3: "ecbe7b", 4: "a9a1e1", 5: "c678dd", 6: "51afef", 7: "bbc2cf", 8: "595959", 9: "ff6655", 10: "99bb66", 11: "ecbe7b", 12: "a9a1e1", 13: "c678dd", 14: "51afef", 15: "bfbfbf"]
    )
}
