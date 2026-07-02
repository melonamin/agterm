// Owns the single `ghostty_app_t` and the libghostty runtime-config callbacks.
// Mirrors the macOS GhosttyApp/GhosttyCallbacks split, adapted to GLib/GTK:
// wakeups coalesce onto a g_idle main-thread tick; the `.render` action draws on
// the app thread (the Linux embedded apprt sets must_draw_from_app_thread).
//
// `@unchecked Sendable` like the macOS GhosttyCallbacks: the C closures fire off
// whatever thread libghostty calls from. The only mutable state (`tickScheduled`)
// is lock-guarded; `app` is set once on the main thread before any surface exists.
// Surface-touching action handling runs during a tick on the main thread, asserted
// via `MainActor.assumeIsolated`.
import CGtk
import Foundation
import agtermCore

/// The ghostty-resources candidate dirs (highest priority first): a dev env override, the per-user
/// install, then the system package. Shared by the GHOSTTY_RESOURCES_DIR resolution and the themes
/// lookup so they can't diverge (one resolver for both).
nonisolated func ghosttyResourceCandidates() -> [String] {
    let env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var c: [String] = []
    if let dev = env["AGTERM_GHOSTTY_RESOURCES"], !dev.isEmpty { c.append(dev) }
    c.append("\(home)/.local/share/agterm/ghostty")
    c.append("/usr/share/ghostty")
    return c
}

final class GhosttyApp: @unchecked Sendable {
    static let shared = GhosttyApp()
    private(set) var app: ghostty_app_t?

    private let tickLock = NSLock()
    private var tickScheduled = false

    /// The current theme's colors as OSC escape sequences (OSC 11/10/4/…), fed to each surface at creation
    /// because the embedded OpenGL renderer doesn't adopt the config's default colors from the config file.
    /// Set at launch from the persisted theme; refreshed by AppController.previewTheme on every theme change.
    var currentThemeOSC: String = ""

    func start() {
        setGhosttyResourcesEnv()   // export GHOSTTY_RESOURCES_DIR before init + buildConfig read it
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        // Persisted settings (font/size/theme/scroll) are layered on at launch so they survive
        // relaunch. Translucency is omitted: Linux has no window-level compositing yet.
        let saved = SettingsStore().load()
        let lines = AppController.ghosttyLines(for: saved)
        currentThemeOSC = AppSettings.themeOSC(from: lines)
        let cfg = buildConfig(extraLines: lines)

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.scheduleTick() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.handleAction(target, action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.readClipboard(ud, loc, state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, _ in
            MainActor.assumeIsolated {
                guard let s = GhosttyApp.surface(from: ud), let content else { return }
                ghostty_surface_complete_clipboard_request(s, content, state, true)
            }
        }
        rt.write_clipboard_cb = { _, loc, content, len, _ in GhosttyApp.writeClipboard(content, len, loc) }
        rt.close_surface_cb = { ud, _ in
            guard let retained = RetainedGhosttySurface(ud) else { return }
            runOnMain { MainActor.assumeIsolated {
                retained.surface.handleProcessExit()
                retained.release()
            } }
        }

        app = ghostty_app_new(&rt, cfg)
        ghostty_config_free(cfg)
    }

    func tick() { if let a = app { ghostty_app_tick(a) } }

    func updateConfig(_ config: ghostty_config_t) {
        guard let app else { return }
        ghostty_app_update_config(app, config)
    }

    /// Build a ghostty config (bundled defaults + the user's ~/.config/ghostty + the given
    /// extra lines, e.g. `theme = <name>`), finalized and ready for ghostty_surface_update_config.
    /// Caller owns it and must ghostty_config_free it after applying.
    func buildConfig(extraLines: [String]) -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        if let path = Self.writeDefaultsConf() { path.withCString { ghostty_config_load_file(cfg, $0) } }
        ghostty_config_load_default_files(cfg)
        // The agterm-scoped <configDir>/ghostty.conf overrides the bundled defaults + the user's
        // global ghostty config for any key, but the UI settings (extraLines) still win since they
        // load last. Mirrors macOS's 4-layer stack. Skipped when absent.
        if let scoped = Self.scopedGhosttyConfigPath(), FileManager.default.fileExists(atPath: scoped) {
            scoped.withCString { ghostty_config_load_file(cfg, $0) }
        }
        if !extraLines.isEmpty, let extra = Self.writeTempConf(extraLines) {
            extra.withCString { ghostty_config_load_file(cfg, $0) }
        }
        // Expand any `config-file = <path>` includes across the loaded layers (matches macOS ordering:
        // recursive resolution after all load_file calls, before finalize). Without this a user's
        // `config-file` directives are silently ignored on Linux.
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// Build a config for one surface with a final per-session overlay (`background-image*`, solid
    /// `background`, and/or a font-size override). The returned config is owned by the caller.
    func configWithOverlay(_ overlayText: String) -> ghostty_config_t? {
        let base = AppController.ghosttyLines(for: SettingsStore().load())
        let overlay = overlayText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return buildConfig(extraLines: base + overlay)
    }

    /// `<configDir>/ghostty.conf` — the agterm-scoped ghostty config layer, resolved via the shared
    /// ConfigPaths (honors a custom config dir + AGTERM_STATE_DIR isolation).
    private static func scopedGhosttyConfigPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let dir = ConfigPaths.configDirectory(setting: SettingsStore().load().configDirectory,
                                               stateDir: env["AGTERM_STATE_DIR"],
                                               home: FileManager.default.homeDirectoryForCurrentUser)
        return ConfigPaths.ghosttyConfigPath(configDirectory: dir).path
    }

    private static func writeTempConf(_ lines: [String]) -> String? {
        let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("agterm-ghostty-runtime.conf")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Coalesce libghostty wakeups (fired off the main thread, faster than the
    /// loop drains) into a single queued main-thread `ghostty_app_tick`.
    func scheduleTick() {
        tickLock.lock()
        let already = tickScheduled
        tickScheduled = true
        tickLock.unlock()
        guard !already else { return }
        g_idle_add({ _ in
            let s = GhosttyApp.shared
            s.tickLock.lock(); s.tickScheduled = false; s.tickLock.unlock()
            MainActor.assumeIsolated { s.tick() }
            return 0 // G_SOURCE_REMOVE
        }, nil)
    }

    // MARK: - Action routing (runs on the main thread, during a tick)

    private func handleAction(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        MainActor.assumeIsolated {
            switch action.tag {
            case GHOSTTY_ACTION_RENDER:
                Self.wrapper(fromTarget: target)?.queueRender()
                return true
            case GHOSTTY_ACTION_SET_TITLE:
                guard let w = Self.wrapper(fromTarget: target), let ptr = action.action.set_title.title else { return true }
                w.applyTitle(String(cString: ptr))
                return true
            case GHOSTTY_ACTION_PWD:
                guard let w = Self.wrapper(fromTarget: target), let ptr = action.action.pwd.pwd else { return true }
                w.applyPwd(String(cString: ptr))
                return true
            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                guard let w = Self.wrapper(fromTarget: target) else { return false }
                guard w.shouldCloseOnChildExitAction else { return false }
                guard let retained = w.surface.flatMap({ RetainedGhosttySurface(ghostty_surface_userdata($0)) }) else { return false }
                runOnMain { MainActor.assumeIsolated {
                    retained.surface.handleProcessExit()
                    retained.release()
                } }
                return true
            case GHOSTTY_ACTION_CELL_SIZE:
                // fires when the cell pixel size changes (font-size via Ctrl+/-, or a DPI change):
                // a trigger to read + persist the live font size.
                Self.wrapper(fromTarget: target)?.reportFontSize()
                return true
            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                // hide the pointer over the terminal while typing; restore it on movement.
                Self.wrapper(fromTarget: target)?.setMouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
                return true
            case GHOSTTY_ACTION_RING_BELL:
                if let display = gdk_display_get_default() { gdk_display_beep(display) }
                return true
            case GHOSTTY_ACTION_OPEN_URL:
                if let ptr = action.action.open_url.url { _ = g_app_info_launch_default_for_uri(ptr, nil, nil) }
                return true
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                // a non-null url means the pointer is over a hyperlink → show the hand cursor.
                Self.wrapper(fromTarget: target)?.setLinkHover(action.action.mouse_over_link.url != nil)
                return true
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                Self.wrapper(fromTarget: target)?.setMouseShape(action.action.mouse_shape)
                return true
            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                let n = action.action.desktop_notification
                let title = n.title.map { String(cString: $0) } ?? ""
                let body = n.body.map { String(cString: $0) } ?? ""
                if let surface = Self.wrapper(fromTarget: target) {
                    // route through the shared delivery policy: bump the badge + suppress when focused.
                    routeTerminalNotification(sessionID: surface.sessionID,
                                              pane: surface.isSplitPane ? .split : .main, title: title, body: body)
                } else {
                    NotificationManager.send(title: title, body: body)
                }
                return true
            case GHOSTTY_ACTION_START_SEARCH:
                Self.wrapper(fromTarget: target)?.applySearchStart(action.action.start_search.needle.flatMap { String(cString: $0) })
                return true
            case GHOSTTY_ACTION_END_SEARCH:
                Self.wrapper(fromTarget: target)?.applySearchEnd()
                return true
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                let raw = action.action.search_total.total
                Self.wrapper(fromTarget: target)?.applySearchTotal(raw < 0 ? nil : Int(raw))
                return true
            case GHOSTTY_ACTION_SEARCH_SELECTED:
                let raw = action.action.search_selected.selected
                Self.wrapper(fromTarget: target)?.applySearchSelected(raw < 0 ? nil : Int(raw))
                return true
            case GHOSTTY_ACTION_PROGRESS_REPORT:
                // OSC 9;4 (ConEmu/agent long-task progress). nil = clear, -1 = indeterminate, 0-100 = percent.
                let r = action.action.progress_report
                let value: Int?
                if r.state == GHOSTTY_PROGRESS_STATE_REMOVE {
                    value = nil
                } else if r.state == GHOSTTY_PROGRESS_STATE_INDETERMINATE {
                    value = -1
                } else {
                    value = r.progress < 0 ? -1 : Int(r.progress)
                }
                Self.wrapper(fromTarget: target)?.applyProgress(value)
                return true
            case GHOSTTY_ACTION_CONFIG_CHANGE:
                // ghostty reloaded its config (e.g. an external edit it picked up) — re-tint the sidebar in
                // case the theme changed; the surface re-renders itself.
                gController?.applySidebarThemeColor()
                return true
            case GHOSTTY_ACTION_COLOR_CHANGE:
                // a program changed the terminal palette/fg/bg (OSC 4/10/11); ghostty repaints via RENDER.
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Clipboard (GTK4 reads are async)

    private static func gdkClipboard(for loc: ghostty_clipboard_e) -> OpaquePointer? {
        guard let display = gdk_display_get_default() else { return nil }
        if loc == GHOSTTY_CLIPBOARD_SELECTION {
            return gdk_display_get_primary_clipboard(display)
        }
        return gdk_display_get_clipboard(display)
    }

    private static func readClipboard(_ ud: UnsafeMutableRawPointer?, _ loc: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
        let surf: ghostty_surface_t? = MainActor.assumeIsolated { GhosttyApp.surface(from: ud) }
        guard let surface = surf, let clipboard = gdkClipboard(for: loc) else { return false }
        let req = ClipboardRequest(surface: surface, state: state)
        gdk_clipboard_read_text_async(
            clipboard, nil,
            { source, result, data in
                let req = Unmanaged<ClipboardRequest>.fromOpaque(data!).takeRetainedValue()
                guard let source else { return }
                let text = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil)
                let raw = text.map { String(cString: $0) } ?? ""
                // a file-manager copy lands as a file:// uri-list → paste the POSIX paths, like macOS.
                let value = PasteDecoder.posixPaths(fromURIList: raw) ?? raw
                value.withCString { ghostty_surface_complete_clipboard_request(req.surface, $0, req.state, false) }
                if let text { g_free(text) }
            },
            Unmanaged.passRetained(req).toOpaque()
        )
        return true
    }

    private static func writeClipboard(_ content: UnsafePointer<ghostty_clipboard_content_s>?, _ len: Int, _ loc: ghostty_clipboard_e) {
        guard let content, len > 0, let clipboard = gdkClipboard(for: loc) else { return }
        for item in UnsafeBufferPointer(start: content, count: len) {
            guard let data = item.data, let mime = item.mime, String(cString: mime).hasPrefix("text/plain") else { continue }
            gdk_clipboard_set_text(clipboard, data)
            return
        }
    }

    // MARK: - userdata recovery

    @MainActor static func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        wrapper(from: ud)?.surface
    }
    static func wrapper(from ud: UnsafeMutableRawPointer?) -> GhosttySurface? {
        guard let ud else { return nil }
        return Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
    }
    static func wrapper(fromTarget target: ghostty_target_s) -> GhosttySurface? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Bundled config defaults: a portable TERM (we don't ship ghostty's terminfo
    /// yet) and a steady block cursor. User's ~/.config/ghostty/config still wins.
    private static func writeDefaultsConf() -> String? {
        let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("agterm-ghostty-defaults.conf")
        // TERM=xterm-ghostty only when the ghostty resources resolved (so the sibling terminfo exists);
        // otherwise a portable fallback. setGhosttyResourcesEnv() runs before this and exports the var via
        // setenv — read it with getenv (the live C environ), NOT ProcessInfo.environment, which snapshots
        // the environment at process start and would miss the setenv.
        let haveResources = getenv("GHOSTTY_RESOURCES_DIR") != nil
        let contents = "term = \(haveResources ? "xterm-ghostty" : "xterm-256color")\n" + GhosttyDefaults.baseConfLines
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Resolve the ghostty resources dir (shell-integration + themes, with the compiled terminfo DB as its
    /// SIBLING) and export `GHOSTTY_RESOURCES_DIR`, so libghostty derives `TERMINFO=dirname(dir)/terminfo`
    /// and injects shell-integration at shell spawn (cwd/title reporting → OSC 7/133). Mirrors the macOS
    /// GhosttyApp.resolveResources(); candidates are the dev env override, the per-user install, then the
    /// system ghostty package.
    private func setGhosttyResourcesEnv() {
        let resolver = GhosttyResourceResolver(candidates: ghosttyResourceCandidates(),
                                               fileExists: { FileManager.default.fileExists(atPath: $0) })
        let resolved = resolver.resolve()
        if let dir = resolved {
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        } else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
        }
    }
}

final class ClipboardRequest: @unchecked Sendable {
    let surface: ghostty_surface_t
    let state: UnsafeMutableRawPointer?
    init(surface: ghostty_surface_t, state: UnsafeMutableRawPointer?) {
        self.surface = surface
        self.state = state
    }
}

/// Run a closure on the GTK main thread (callbacks may fire off-main).
func runOnMain(_ body: @escaping @Sendable () -> Void) {
    let box = Unmanaged.passRetained(MainClosure(body)).toOpaque()
    g_idle_add({ data in
        let c = Unmanaged<MainClosure>.fromOpaque(data!).takeRetainedValue()
        c.body()
        return 0
    }, box)
}
final class MainClosure: @unchecked Sendable { let body: @Sendable () -> Void; init(_ b: @escaping @Sendable () -> Void) { body = b } }

final class RetainedGhosttySurface: @unchecked Sendable {
    private let retained: Unmanaged<GhosttySurface>

    init?(_ ud: UnsafeMutableRawPointer?) {
        guard let ud else { return nil }
        retained = Unmanaged<GhosttySurface>.fromOpaque(ud).retain()
    }

    @MainActor var surface: GhosttySurface { retained.takeUnretainedValue() }

    func release() {
        retained.release()
    }
}
