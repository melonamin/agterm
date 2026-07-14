import Testing
@testable import AgtermLinux

@Suite("Resolved Ghostty chrome colors")
struct GhosttyConfigThemeTests {
    @Test("resolved config channels drive the chrome palette")
    func resolvedChannels() {
        let values: [String: GhosttyConfigTheme.RGB] = [
            "background": .init(red: 255, green: 252, blue: 240),
            "foreground": .init(red: 16, green: 15, blue: 15),
            "selection-background": .init(red: 206, green: 205, blue: 195),
            "selection-foreground": .init(red: 32, green: 94, blue: 166),
        ]

        #expect(
            GhosttyConfigTheme.colors(read: { values[$0] })
                == ThemeColors(
                    background: "#FFFCF0",
                    foreground: "#100F0F",
                    selectionBackground: "#CECDC3",
                    selectionForeground: "#205EA6"))
    }
}
