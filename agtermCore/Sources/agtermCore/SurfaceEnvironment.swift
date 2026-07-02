import Foundation

/// Pure builders for the `AGTERM_*` environment values injected into spawned shells.
/// The platform surface owns shell creation; this keeps the variable set testable.
public enum SurfaceEnvironment {
    /// Environment for a session-owned surface: main pane, split pane, overlay, or scratch.
    public static func session(sessionID: UUID, windowID: UUID?, workspaceID: UUID?,
                               socketPath: String) -> [String: String] {
        var env = [
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": sessionID.uuidString,
            "AGTERM_SOCKET": socketPath,
        ]
        if let windowID {
            env["AGTERM_WINDOW_ID"] = windowID.uuidString
        }
        if let workspaceID {
            env["AGTERM_WORKSPACE_ID"] = workspaceID.uuidString
        }
        return env
    }

    /// Environment for a window's quick terminal, which is not part of the session tree.
    public static func quickTerminal(windowID: UUID, socketPath: String) -> [String: String] {
        [
            "AGTERM_ENABLED": "1",
            "AGTERM_WINDOW_ID": windowID.uuidString,
            "AGTERM_SOCKET": socketPath,
        ]
    }
}
