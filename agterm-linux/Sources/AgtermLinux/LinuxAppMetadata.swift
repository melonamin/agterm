import Foundation

enum LinuxAppMetadata {
    static let version: String = {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["AGTERM_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.isEmpty {
            return value
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let installed = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/agterm/VERSION")
        if let value = try? String(contentsOf: installed, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return "dev"
    }()
}
