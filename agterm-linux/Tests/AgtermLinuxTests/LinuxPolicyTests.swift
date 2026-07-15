import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux-owned policy and adapters")
struct LinuxPolicyTests {
    @Test("resource resolution requires complete sibling resources and preserves precedence")
    func resourceResolution() {
        let complete = [
            "/complete/ghostty/shell-integration", "/complete/terminfo/x/xterm-ghostty",
            "/later/ghostty/shell-integration", "/later/terminfo/x/xterm-ghostty"
        ]
        let resolver = GhosttyResourceResolver(
            candidates: ["relative", "/shell-only/ghostty", "/terminfo-only/ghostty",
                         "/complete/ghostty", "/later/ghostty"],
            fileExists: { complete.contains($0) || $0 == "/shell-only/ghostty/shell-integration"
                || $0 == "/terminfo-only/terminfo/x/xterm-ghostty" }
        )
        #expect(resolver.resolve() == "/complete/ghostty")
        #expect(resolver.terminalName == "xterm-ghostty")

        let incomplete = GhosttyResourceResolver(
            candidates: ["", "relative", "/shell-only/ghostty", "/terminfo-only/ghostty"],
            fileExists: { $0 == "/shell-only/ghostty/shell-integration"
                || $0 == "/terminfo-only/terminfo/x/xterm-ghostty" }
        )
        #expect(incomplete.resolve() == nil)
        #expect(incomplete.terminalName == "xterm-256color")
        #expect(GhosttyResourceResolver.terminalName(resolvedResources: "/share/ghostty") == "xterm-ghostty")
    }

    @Test("URI lists become POSIX path payloads")
    func pasteURIList() {
        let payload = "# copied files\nfile:///tmp/one%20two\nfile:///tmp/three\n"
        #expect(PasteDecoder.posixPaths(fromURIList: payload) == "/tmp/one two /tmp/three")
        #expect(ShellEscape.dropPayload("") == nil)
        #expect(ShellEscape.dropPayload("plain") == "plain")
    }

    @Test("Linux proc cmdline decoding is NUL-delimited")
    func procCmdline() {
        #expect(CommandRestore.parseProcCmdline(Data()) == nil)
        #expect(CommandRestore.parseProcCmdline(Data("zsh\0-c\0echo hi\0".utf8)) == ["zsh", "-c", "echo hi"])
    }

    @Test("Linux starter files remain comment-only or denylist-only")
    func starterFiles() {
        #expect(ConfigPaths.starterGhosttyConfig().contains("agterm-scoped ghostty config"))
        #expect(ConfigPaths.starterRestoreDenylist().contains("tmux\nscreen\nzellij"))
        #expect("  value\n".linuxTrimmedOrNil == "value")
        #expect(" \n".linuxTrimmedOrNil == nil)
    }

    @Test("session switcher starts from the previous MRU entry and wraps")
    func sessionSwitcher() {
        let first = UUID()
        let second = UUID()
        var switcher = SessionSwitcherModel()
        #expect(switcher.begin([first]) == nil)
        #expect(switcher.begin([first, second]) == second)
        #expect(switcher.advance() == first)
        switcher.end()
        #expect(!switcher.isActive)
    }

    @Test("delete prompts use native Linux wording")
    func deletePrompts() {
        #expect(DeletePrompt.workspaceMessage(name: "work", sessions: 1).contains("1 session"))
        #expect(DeletePrompt.workspaceMessage(name: "work", sessions: 2).contains("2 sessions"))
        #expect(DeletePrompt.windowMessage(name: "work").contains("all its workspaces and sessions"))
    }

    @Test("session reports and pane focus mutate the owning shared model")
    @MainActor
    func sessionAdapters() {
        let session = Session(initialCwd: "/start")
        session.hasSplit = true
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])

        store.recordPwd("/main", forSession: session.id, isSplit: false)
        store.recordPwd("/split", forSession: session.id, isSplit: true)
        store.recordTitle("main", forSession: session.id, isSplit: false)
        store.recordTitle("split", forSession: session.id, isSplit: true)
        store.setPaneFocus(true, forSession: session.id)

        #expect(session.currentCwd == "/main")
        #expect(session.splitCwd == "/split")
        #expect(session.oscTitle == "main")
        #expect(session.splitTitle == "split")
        #expect(session.splitFocused)
        #expect(LinuxSidebarPolicy.flaggedRowLabel(for: session, in: store) == "main  —  work")
    }

    @Test("notification delivery delegates policy and identity to shared core")
    @MainActor
    func notificationDelivery() {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])
        let windowID = UUID()
        let delivery = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id,
            windowID: windowID,
            pane: .split,
            title: "done",
            body: "ready",
            firingIsFocused: false,
            appActive: true
        ))

        #expect(session.unseenCount == 1)
        #expect(delivery?.identity == TerminalNotification.identity(
            windowID: windowID,
            sessionID: session.id,
            pane: .split
        ))
    }

    @Test("focused OSC suppression precedes unseen mutation while explicit control delivery bypasses it")
    @MainActor
    func notificationSuppressionOrdering() {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])])
        let windowID = UUID()

        let suppressed = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id, windowID: windowID, pane: .main,
            title: "focused", body: "ignored", firingIsFocused: true, appActive: true))
        #expect(suppressed == nil)
        #expect(session.unseenCount == 0)

        let inactive = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id, windowID: windowID, pane: .main,
            title: "inactive", body: "delivered", firingIsFocused: true, appActive: false))
        #expect(inactive != nil)
        #expect(session.unseenCount == 1)

        let explicitControl = store.recordTerminalNotification(TerminalNotificationRecord(
            sessionID: session.id, windowID: windowID, pane: .main,
            title: "control", body: "requested", firingIsFocused: false, appActive: true))
        #expect(explicitControl != nil)
        #expect(session.unseenCount == 2)
    }

    @Test("Linux surface roles map every terminal kind deliberately")
    func surfaceNotificationRoles() {
        #expect(LinuxSurfaceRole.main.notificationPane == .main)
        #expect(LinuxSurfaceRole.split.notificationPane == .split)
        #expect(LinuxSurfaceRole.overlay.notificationPane == .overlay)
        #expect(LinuxSurfaceRole.scratch.notificationPane == .overlay)
        #expect(LinuxSurfaceRole.quick.notificationPane == nil)
        #expect(LinuxSurfaceRole.scratch.statusPane == .scratch)
    }

    @Test("pane identities coalesce independently and stale reveal panes fall back safely")
    func notificationIdentityAndReveal() {
        let windowID = UUID()
        let sessionID = UUID()
        let main = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .main)
        let split = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .split)
        let overlay = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .overlay)
        #expect(Set([main, split, overlay]).count == 3)
        #expect(NotificationManager.notificationID(main) != NotificationManager.notificationID(split))
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .split, sessionExists: true, hasSplit: true, coverActive: false) == .split)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .split, sessionExists: true, hasSplit: false, coverActive: false) == .primary)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .overlay, sessionExists: true, hasSplit: false, coverActive: true) == .overlay)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .overlay, sessionExists: true, hasSplit: false, coverActive: false) == .primary)
        #expect(LinuxNotificationRevealFocus.resolve(
            pane: .main, sessionExists: false, hasSplit: false, coverActive: false) == nil)
    }
}
