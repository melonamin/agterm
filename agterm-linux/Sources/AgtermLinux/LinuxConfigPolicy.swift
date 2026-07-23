import Foundation
import agtermCore

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
