import AppKit
import Foundation

/// Bridges macOS accessibility display-option changes into agterm's app-local notification center.
/// AppKit posts this notification on `NSWorkspace.notificationCenter` (not the default center), while
/// agterm's window and sidebar consumers use lifecycle-scoped tokens on the default center.
///
/// Consumers read the settled values directly from `NSWorkspace` when handling the bridged event:
/// `WindowAppearance` handles Reduce Transparency and `StatusIconView` handles Reduce Motion. Native
/// SwiftUI consumers use the matching accessibility environment values and update independently.
@MainActor
final class SystemAccessibilityObserver {
    private var displayOptionsObserver: NSObjectProtocol?

    /// Register once for the process. The scene `.task` runs for every window, so this must be
    /// idempotent like `SystemAppearanceObserver.start()`. No initial post is needed because consumers
    /// read the current preference during their normal first render or window attachment.
    func start() {
        guard displayOptionsObserver == nil else { return }
        let workspace = NSWorkspace.shared
        displayOptionsObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: workspace,
            queue: .main
        ) { _ in
            // NotificationCenter's callback is @Sendable even with a main queue. Hop explicitly so this
            // remains correct under Swift 6 isolation and matches SystemAppearanceObserver's convention.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .agtermAccessibilityDisplayOptionsChanged, object: nil)
            }
        }
    }

    isolated deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }
}
