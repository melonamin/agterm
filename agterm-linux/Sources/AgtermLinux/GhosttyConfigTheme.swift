import CGtk
import Foundation
import agtermCore

/// Reads chrome colors from libghostty's finalized configuration, after global/scoped files,
/// recursive `config-file` imports, and agterm's UI settings have all been resolved.
enum GhosttyConfigTheme {
    struct RGB: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    static func colors(from config: ghostty_config_t) -> ThemeColors {
        colors { color(from: config, key: $0) }
    }

    static func colors(read: (String) -> RGB?) -> ThemeColors {
        ThemeColors(
            background: read("background").map(hex),
            foreground: read("foreground").map(hex),
            selectionBackground: read("selection-background").map(hex),
            selectionForeground: read("selection-foreground").map(hex)
        )
    }

    private static func color(from config: ghostty_config_t, key: String) -> RGB? {
        var color = ghostty_config_color_s()
        let found = key.withCString {
            ghostty_config_get(config, &color, $0, UInt(key.utf8.count))
        }
        guard found else { return nil }
        return RGB(red: color.r, green: color.g, blue: color.b)
    }

    private static func hex(_ color: RGB) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

@MainActor
extension AppController {
    /// Rebuild the same finalized config used by the terminal when a chrome-only setting changes.
    func applyResolvedWindowThemeColors() {
        let settings = linuxSettingsStore().load()
        let lines = Self.ghosttyLines(for: settings)
        guard let config = GhosttyApp.shared.buildConfig(extraLines: lines) else { return }
        defer { ghostty_config_free(config) }
        applyWindowThemeColors(
            for: settings.activeTheme(isDark: Self.systemIsDark),
            resolvedColors: GhosttyConfigTheme.colors(from: config))
    }
}
