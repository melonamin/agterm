import Foundation
import agtermCore

enum LinuxProcessStandardIO: Sendable, Equatable {
    case null
}

struct LinuxProcessLaunchRequest: Sendable, Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryPath: String?
    let standardIO: LinuxProcessStandardIO
}

protocol LinuxProcessLaunching: Sendable {
    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws
}

struct FoundationLinuxProcessLauncher: LinuxProcessLaunching {
    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment
        if let path = request.currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        switch request.standardIO {
        case .null:
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { onTermination($0.terminationStatus) }
        try process.run()
    }
}

enum LinuxCustomCommandFailure: Sendable, Equatable {
    case launch(String)
    case exit(Int32)

    func toast(commandName: String) -> String {
        switch self {
        case .launch(let detail): "command failed to launch: \(commandName) — \(detail)"
        case .exit(let status): "command failed (exit \(status)): \(commandName)"
        }
    }
}

enum LinuxCustomCommandProcess {
    static func request(
        command: CustomCommand, context: CommandContext, baseEnvironment: [String: String]
    ) -> LinuxProcessLaunchRequest {
        LinuxProcessLaunchRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", context.expand(command.command)],
            environment: baseEnvironment.merging(context.environment()) { _, commandValue in commandValue },
            currentDirectoryPath: context.sessionPWD.isEmpty ? nil : context.sessionPWD,
            standardIO: .null)
    }

    static func launch(
        command: CustomCommand,
        context: CommandContext,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        launcher: any LinuxProcessLaunching,
        onFailure: @escaping @Sendable (LinuxCustomCommandFailure) -> Void
    ) {
        let request = request(command: command, context: context, baseEnvironment: baseEnvironment)
        do {
            try launcher.launch(request) { status in
                if status != 0 { onFailure(.exit(status)) }
            }
        } catch {
            onFailure(.launch(error.localizedDescription))
        }
    }
}

/// A per-controller generation token. Closing a window invalidates this instance; reopening the same
/// persisted window id creates a different token, so an old process completion cannot reach the new UI.
@MainActor
final class LinuxCustomCommandOrigin {
    let launcher: any LinuxProcessLaunching
    private(set) var isActive = true

    init(launcher: any LinuxProcessLaunching = FoundationLinuxProcessLauncher()) {
        self.launcher = launcher
    }

    func invalidate() { isActive = false }

    func deliverIfActive(_ action: () -> Void) {
        guard isActive else { return }
        action()
    }
}
