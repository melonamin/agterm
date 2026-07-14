import Foundation
import agtermCore

enum FontBindingAction {
    static let increase = "increase_font_size:1"
    static let decrease = "decrease_font_size:1"
    static let reset = "reset_font_size"
}

enum GhosttyDefaults {
    static let baseConfLines = """
    cursor-style = block

    """
}

extension String {
    var linuxTrimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AppSettings {
    static let themeResetOSC = "\u{1B}]110\u{7}\u{1B}]111\u{7}"

    static let agtermThemeLines = [
        "background = #303030",
        "foreground = #ffffff",
        "selection-background = #5b5b5b",
        "selection-foreground = #dfdfff",
    ]

    static func themeOSC(from lines: [String]) -> String {
        let colors = ThemeColorResolver.colors(fromLines: lines)
        var osc = ""
        if let background = colors.background {
            osc += "\u{1B}]11;\(background)\u{7}"
        }
        if let foreground = colors.foreground {
            osc += "\u{1B}]10;\(foreground)\u{7}"
        }
        return osc
    }
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

extension ConfigPaths {
    static func defaultNewSessionCwd() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func starterGhosttyConfig() -> String {
        """
        # agterm-scoped ghostty config. This file is loaded after the bundled defaults.
        # Put agterm-only terminal settings here.

        """
    }

    static func starterRestoreDenylist() -> String {
        """
        # Commands that should not be automatically re-run by restore-running-command.
        tmux
        screen
        zellij

        """
    }
}

extension ShellEscape {
    static func dropPayload(_ payload: String) -> String? {
        if let paths = PasteDecoder.posixPaths(fromURIList: payload) {
            return paths
        }
        return payload.isEmpty ? nil : payload
    }
}

extension CommandRestore {
    static func parseProcCmdline(_ data: Data) -> [String]? {
        let parts = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return parts.isEmpty ? nil : parts
    }
}

struct NotificationDelivery: Sendable, Equatable {
    let title: String
    let body: String
    let identity: String
}

struct TerminalNotificationRecord: Sendable, Equatable {
    let sessionID: UUID
    let windowID: UUID
    let pane: PaneRole
    let title: String
    let body: String
    let firingIsFocused: Bool
    let appActive: Bool
}

extension AppStore {
    @discardableResult
    func addWorkspaceSeeded(name: String, cwd: String) -> Workspace {
        let workspace = addWorkspace(name: name)
        _ = addSession(toWorkspace: workspace.id, cwd: cwd)
        return workspace
    }

    @discardableResult
    func clearAttentionStatusOnInput(sessionID: UUID, pane: StatusPane = .left, isInterrupt: Bool = false) -> Bool {
        guard let session = session(withID: sessionID),
              session.agentIndicator.clearedBy(pane: pane, isInterrupt: isInterrupt)
        else { return false }
        setAgentIndicator(AgentIndicator(), forSession: sessionID)
        return true
    }

    func setPaneFocus(_ toSplit: Bool, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID), session.hasSplit else { return }
        if session.splitFocused != toSplit { session.splitFocused = toSplit }
    }

    func recordPwd(_ pwd: String, forSession sessionID: UUID, isSplit: Bool) {
        guard let session = session(withID: sessionID) else { return }
        if isSplit {
            if session.splitCwd != pwd { session.splitCwd = pwd }
        } else if session.currentCwd != pwd {
            session.currentCwd = pwd
        }
    }

    func recordTitle(_ title: String, forSession sessionID: UUID, isSplit: Bool) {
        guard let session = session(withID: sessionID) else { return }
        if isSplit {
            if session.splitTitle != title { session.splitTitle = title }
        } else if session.oscTitle != title {
            session.oscTitle = title
        }
    }

    @discardableResult
    func recordTerminalNotification(_ record: TerminalNotificationRecord) -> NotificationDelivery? {
        guard let session = session(withID: record.sessionID) else { return nil }
        session.unseenCount += 1
        guard TerminalNotification.shouldDeliver(firingIsFocused: record.firingIsFocused, appActive: record.appActive) else {
            return nil
        }
        return NotificationDelivery(
            title: record.title,
            body: record.body,
            identity: TerminalNotification.identity(
                windowID: record.windowID,
                sessionID: record.sessionID,
                pane: record.pane
            )
        )
    }

    func toggleFlag(forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        setFlag(!session.flagged, forSession: id)
    }

    func toggleSidebarMode() {
        setSidebarMode(sidebarMode == .tree ? .flagged : .tree)
    }

    func flaggedRowLabel(for session: Session) -> String {
        if let workspace = workspace(forSession: session.id) {
            return "\(session.displayName)  —  \(workspace.name)"
        }
        return session.displayName
    }
}

struct GhosttyResourceResolver {
    let candidates: [String]
    let fileExists: (String) -> Bool

    func resolve() -> String? {
        candidates.first { fileExists($0 + "/shell-integration") }
    }
}

struct ThemeColors: Equatable, Sendable {
    let background: String?
    let foreground: String?
    let selectionBackground: String?
    let selectionForeground: String?
}

enum ThemeColorResolver {
    static func colors(fromLines lines: [String]) -> ThemeColors {
        func value(_ key: String) -> String? {
            var found: String?
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                    found = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return found
        }
        return ThemeColors(
            background: value("background"),
            foreground: value("foreground"),
            selectionBackground: value("selection-background"),
            selectionForeground: value("selection-foreground")
        )
    }

    static func colors(forTheme theme: String?, themesDir: String?, fallbackLines: [String]) -> ThemeColors {
        if let theme, !theme.isEmpty, let dir = themesDir {
            let path = (dir as NSString).appendingPathComponent(theme)
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return colors(fromLines: content.components(separatedBy: "\n"))
            }
        }
        return colors(fromLines: fallbackLines)
    }

    static func shiftedHex(_ hex: String, amount: Double) -> String {
        guard amount != 0 else { return hex }
        let h = hex.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return hex }
        let digits = String(h.dropFirst())
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return hex }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        func shift(_ c: Double) -> Int {
            let v = amount >= 0 ? c * (1 - amount) : c + (1 - c) * (-amount)
            return max(0, min(255, Int((v * 255).rounded())))
        }
        return String(format: "#%02X%02X%02X", shift(r), shift(g), shift(b))
    }
}

enum DeletePrompt {
    static func workspaceMessage(name: String, sessions: Int) -> String {
        let sessionClause = sessions == 1 ? "1 session" : "\(sessions) sessions"
        return "Delete “\(name)” and its \(sessionClause)? This can't be undone."
    }

    static func windowMessage(name: String) -> String {
        "Delete the window “\(name)” and all its workspaces and sessions? This can't be undone."
    }
}

enum PasteDecoder {
    static func posixPaths(fromURIList text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("file://") }) else { return nil }
        let paths = lines.compactMap { URL(string: $0)?.path }
        guard paths.count == lines.count else { return nil }
        return paths.joined(separator: " ")
    }
}

struct SessionSwitcherModel: Equatable, Sendable {
    private var candidates: [UUID] = []
    private var index = 0

    var isActive: Bool { !candidates.isEmpty }
    var current: UUID? { candidates.indices.contains(index) ? candidates[index] : nil }
    var ordered: [UUID] { candidates }

    mutating func begin(_ mru: [UUID]) -> UUID? {
        guard mru.count >= 2 else {
            candidates = []
            index = 0
            return nil
        }
        candidates = mru
        index = 1
        return current
    }

    mutating func advance() -> UUID? {
        guard !candidates.isEmpty else { return nil }
        index = (index + 1) % candidates.count
        return current
    }

    mutating func end() {
        candidates = []
        index = 0
    }
}
