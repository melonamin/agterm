import agtermCore

enum FontBindingAction {
    static let increase = "increase_font_size:1"
    static let decrease = "decrease_font_size:1"
    static let reset = "reset_font_size"
}

extension BuiltinAction {
    var linuxDefaultChord: Chord? {
        switch self {
        case .newWindow: return Chord(mods: [.control, .shift], key: "n")
        case .newWorkspace: return Chord(mods: [.control, .shift], key: "w")
        case .newSession: return Chord(mods: [.control, .shift], key: "t")
        case .openDirectory: return Chord(mods: [.control, .shift], key: "o")
        case .closeSession: return Chord(mods: [.control, .shift], key: "q")
        case .toggleSplit: return Chord(mods: [.control, .shift], key: "d")
        case .dashboard: return Chord(mods: [.control, .shift], key: "m")
        case .toggleScratch: return Chord(mods: [.control, .shift], key: "j")
        case .toggleSearch: return Chord(mods: [.control, .shift], key: "f")
        case .toggleSidebar: return Chord(mods: [.control, .shift], key: "s")
        case .toggleFlag: return Chord(mods: [.control, .shift], key: "g")
        case .quickTerminal: return Chord(mods: [.control], key: "`")
        case .sessionPalette: return Chord(mods: [.control], key: "p")
        case .commandPalette: return Chord(mods: [.control, .shift], key: "p")
        // Ctrl+Shift+O belongs to Open Directory on Linux. Keep the custom-command palette keyless so
        // restoring a reserved Open Directory override cannot create a default-vs-default collision.
        case .customCommandPalette: return nil
        case .showAttention: return Chord(mods: [.control, .shift], key: "i")
        default: return nil
        }
    }
}
