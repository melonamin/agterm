import CGtk
import Foundation
import agtermCore

@MainActor
enum LinuxAgentIntegrations {
    private struct InstallFailure: Error { let message: String }

    static func installHooks(in controller: AppController) {
        do {
            let notes = try installHooks()
            controller.presentIntegrationResult(title: "Agent Status Hooks Installed", text: notes.joined(separator: "\n"))
        } catch let error as InstallFailure {
            controller.presentIntegrationResult(title: "Install Failed", text: error.message)
        } catch {
            controller.presentIntegrationResult(title: "Install Failed", text: error.localizedDescription)
        }
    }

    static func installSkill(in controller: AppController) {
        do {
            let notes = try installSkill()
            controller.presentIntegrationResult(title: "Agent Skill Installed", text: notes.joined(separator: "\n"))
        } catch let error as InstallFailure {
            controller.presentIntegrationResult(title: "Install Failed", text: error.message)
        } catch {
            controller.presentIntegrationResult(title: "Install Failed", text: error.localizedDescription)
        }
    }

    private static func resource(_ name: String) -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let installed = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/agterm/\(name)")
        if FileManager.default.fileExists(atPath: installed.path) { return installed }
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let checkout = root.appendingPathComponent("agterm/Resources/\(name)")
        return FileManager.default.fileExists(atPath: checkout.path) ? checkout : nil
    }

    private static func bundledCLI() -> String? {
        let directory = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        for name in ["agtermctl", "agtermctl-linux", "agtermctl.bin"] {
            let candidate = directory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func installHooks() throws -> [String] {
        guard let source = resource("agent-status") else {
            throw InstallFailure(message: "The agent-status scripts are not bundled in this build.")
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let destination = home.appendingPathComponent(".config/agterm/agent-status")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
        try bakeCLIPath(in: destination)

        var notes: [String] = ["Scripts installed to \(destination.path)."]
        let claudeDir = home.appendingPathComponent(".claude")
        let claudeSettings = claudeDir.appendingPathComponent("settings.json")
        do {
            let existingClaude = try readIfPresent(claudeSettings)
            let merged = try AgentHooksInstall.mergeClaudeSettings(existing: existingClaude,
                                                                    scriptDir: destination.path)
            if merged.changed {
                try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
                try backup(existingClaude, at: claudeSettings)
                try writePreservingSymlink(merged.json, to: claudeSettings)
            }
            notes.append("Claude Code hooks configured.")
        } catch AgentHooksInstall.MergeError.malformedExistingSettings {
            notes.append("Claude Code settings are invalid JSON; left untouched.")
        } catch {
            notes.append("Claude Code settings could not be read; left untouched.")
        }

        for relative in [".zshrc", ".bashrc", ".config/fish/config.fish"] {
            let url = home.appendingPathComponent(relative)
            if relative.hasSuffix("config.fish"),
               !fm.fileExists(atPath: url.deletingLastPathComponent().path) { continue }
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let script = relative.hasSuffix("config.fish")
                ? AgentHooksInstall.fishIntegrationRelativePath : AgentHooksInstall.integrationRelativePath
            let appended = AgentHooksInstall.appendShellRC(existing: old, scriptDir: destination.path,
                                                            scriptName: script)
            if appended.changed { try writePreservingSymlink(appended.contents, to: url) }
        }
        notes.append("Shell integration configured; open a new terminal to load it.")

        let codexDir = home.appendingPathComponent(".codex")
        if fm.fileExists(atPath: codexDir.path) {
            let config = codexDir.appendingPathComponent("config.toml")
            do {
                let existing = try readIfPresent(config) ?? ""
                switch AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: destination.path) {
                case .merged(let contents):
                    try backup(existing.isEmpty ? nil : existing, at: config)
                    try writePreservingSymlink(contents, to: config)
                    notes.append("Codex lifecycle hooks configured; review them with /hooks.")
                case .unchanged:
                    notes.append("Codex lifecycle hooks were already configured.")
                case .hooksExist:
                    notes.append("Codex already has custom hooks; config.toml was left untouched.\n\n"
                        + AgentHooksInstall.codexHooksBlock(scriptDir: destination.path))
                case .unparseable:
                    notes.append("Codex config.toml is invalid TOML; it was left untouched.\n\n"
                        + AgentHooksInstall.codexHooksBlock(scriptDir: destination.path))
                }
            } catch {
                notes.append("Codex config.toml could not be read; it was left untouched.")
            }
        } else {
            notes.append("No ~/.codex directory found; Codex hooks were skipped.")
        }
        return notes
    }

    private static func bakeCLIPath(in destination: URL) throws {
        guard let tool = bundledCLI() else { return }
        let marker = "# >>> agterm agtermctl path (installer-baked) >>>"
        for name in [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName] {
            let url = destination.appendingPathComponent(name)
            var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            if let index = lines.firstIndex(of: marker) {
                lines.remove(at: index)
                if index < lines.count { lines.remove(at: index) }
            }
            let index = lines.first?.hasPrefix("#!") == true ? 1 : 0
            lines.insert("[ -n \"${AGTERMCTL:-}\" ] || AGTERMCTL=\(AgentHooksInstall.shellQuote(tool))", at: index)
            lines.insert(marker, at: index)
            try writePreservingSymlink(lines.joined(separator: "\n"), to: url)
        }
    }

    private static func installSkill() throws -> [String] {
        guard let source = resource("agent-skill") else {
            throw InstallFailure(message: "The agterm agent skill is not bundled in this build.")
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let targets = SkillInstall.installTargets(home: home,
            claudeExists: fm.fileExists(atPath: home + "/.claude"),
            codexExists: fm.fileExists(atPath: home + "/.codex"))
        var installed: [String] = []
        var skipped: [String] = []
        for target in targets {
            let destination = URL(fileURLWithPath: target.skillDirectory)
            let exists = (try? fm.attributesOfItem(atPath: destination.path)) != nil
            let skill = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
            guard SkillInstall.mayOverwrite(directoryExists: exists, existingSKILL: skill) else {
                skipped.append("\(target.agent): an unrelated agterm skill was left untouched")
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
            installed.append("\(target.agent): \(destination.path)")
        }
        guard !installed.isEmpty else {
            throw InstallFailure(message: skipped.joined(separator: "\n"))
        }
        return ["Installed for:"] + installed + (skipped.isEmpty ? [] : ["Skipped:"] + skipped)
    }

    private static func readIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func backup(_ existing: String?, at url: URL) throws {
        guard let existing else { return }
        try AgentHooksInstall.writeFile(existing, toPath: AgentHooksInstall.backupPath(for: url.path),
                                        posixMode: AgentHooksInstall.posixMode(ofFile: url.path))
    }

    private static func writePreservingSymlink(_ text: String, to url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let target = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
            ? url.resolvingSymlinksInPath() : url
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AgentHooksInstall.writeFile(text, toPath: target.path,
                                        posixMode: AgentHooksInstall.posixMode(ofFile: target.path))
    }
}

@MainActor
extension AppController {
    func presentIntegrationResult(title: String, text: String) {
        let dialog = OpaquePointer(title.withCString { heading in
            text.withCString { body in adw_alert_dialog_new(heading, body) }
        })
        "ok".withCString { id in
            "OK".withCString { label in adw_alert_dialog_add_response(cast(dialog), id, label) }
        }
        "ok".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        adw_dialog_present(cast(dialog), W(window))
    }
}
