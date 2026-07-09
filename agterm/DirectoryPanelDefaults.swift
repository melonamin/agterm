import Foundation

/// Shared directory seeding for folder-picking panels. `NSOpenPanel.directoryURL` wants a directory that
/// exists; saved settings or stale shell cwd values can disappear, so walk up to the nearest existing
/// directory before falling back to the user's home.
enum DirectoryPanelDefaults {
    static func url(paths: String?...) -> URL {
        for path in paths {
            if let url = existingDirectoryURL(for: path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func existingDirectoryURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        while url.path != "/" {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }
}
