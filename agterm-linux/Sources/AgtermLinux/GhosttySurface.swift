// A libghostty terminal surface backed by a GtkGLArea. Conforms to agtermCore's
// TerminalSurface seam (the macOS GhosttySurfaceView is the sibling conformer).
// Owns the GtkGLArea widget + the ghostty_surface_t; drives realize/render/resize
// and routes keyboard/focus into libghostty.
import CGtk
import agtermCore
import Foundation

@MainActor
final class GhosttySurface: TerminalSurface {
    /// The GtkGLArea widget (stored as OpaquePointer; cast at GTK call sites).
    let glArea: OpaquePointer
    private(set) var surface: ghostty_surface_t?
    /// The key controller + a GtkIMContext for composed input (dead-keys / compose / CJK): key events are
    /// filtered through the IM, which commits the composed text via the `commit` signal.
    private var keyController: OpaquePointer?
    private var imContext: OpaquePointer?

    /// The owning session's id (so the host can route close/title back to the model).
    let sessionID: UUID
    fileprivate weak var controller: AppController?
    /// True for the split (right) pane, so reported pwd/title and focus changes route to the split
    /// fields (`splitCwd`/`splitTitle`/`splitFocused`) instead of clobbering the primary's.
    private(set) var isSplitPane: Bool
    /// The shell's working directory.
    private let cwd: String
    /// Optional explicit command; nil runs the user's default login shell.
    private let command: String?
    /// Whether command surfaces should linger on ghostty's "press any key" prompt after exit.
    private let waitAfterCommand: Bool
    /// Scratch/overlay/quick terminals are transient covers; their OSC title/PWD must not overwrite the
    /// owning session's primary/split pane state.
    private let reportsPaneState: Bool
    /// Per-session font-size override (points) to seed at creation, restoring a persisted ⌘+/⌘− zoom;
    /// nil uses the config default.
    private let fontSize: Double?
    /// Optional text fed to the shell at startup (restore-running-command re-runs the captured argv);
    /// runs INSIDE the shell so its exit returns to a prompt (unlike `command`).
    private let initialInput: String?
    /// `AGTERM_*` (and any other) env vars to inject into the spawned shell.
    private let env: [String: String]
    /// strdup'd C copies of the injected env keys/values, kept alive for the surface's lifetime
    /// (libghostty copies the env-var STRUCT array during surface_new but keeps the char* pointers),
    /// freed in teardown.
    private var envCStrings: [UnsafeMutablePointer<CChar>] = []
    /// Per-surface overlay configs (session background/font override), retained until a newer overlay
    /// replaces them or the surface is torn down.
    private var ownedConfigs: [ghostty_config_t] = []

    /// Set by the host: the shell process exited.
    var onExit: (() -> Void)?
    private var didHandleProcessExit = false

    init(sessionID: UUID, cwd: String, command: String? = nil, env: [String: String] = [:],
         controller: AppController? = nil, waitAfterCommand: Bool = false,
         isSplitPane: Bool = false, reportsPaneState: Bool = true,
         fontSize: Double? = nil, initialInput: String? = nil) {
        self.sessionID = sessionID
        self.controller = controller
        self.isSplitPane = isSplitPane
        self.cwd = cwd
        self.command = command
        self.waitAfterCommand = waitAfterCommand
        self.reportsPaneState = reportsPaneState
        self.fontSize = fontSize
        self.initialInput = initialInput
        self.env = env
        glArea = OpaquePointer(gtk_gl_area_new())
        gtk_gl_area_set_allowed_apis(GLA(glArea), GDK_GL_API_GL)
        gtk_gl_area_set_has_depth_buffer(GLA(glArea), 0)
        gtk_widget_set_hexpand(W(glArea), 1)
        gtk_widget_set_vexpand(W(glArea), 1)
        gtk_widget_set_focusable(W(glArea), 1)

        // The GtkGLArea OWNS a retained reference to this surface (released on its "destroy"), so the
        // signal handlers' user_data can never outlive the Swift object. With passUnretained, a focus
        // controller firing "leave" during widget teardown dereferenced a freed GhosttySurface (a
        // use-after-free SIGSEGV in `wrap`). The widget lifetime now bounds the object lifetime.
        let me = Unmanaged.passRetained(self).toOpaque()
        connect(glArea, "destroy", unsafeBitCast(surfaceDestroy as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(glArea, "realize", unsafeBitCast(surfaceRealize as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(glArea, "render", unsafeBitCast(surfaceRender as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), me)
        connect(glArea, "resize", unsafeBitCast(surfaceResize as @convention(c) (OpaquePointer?, Int32, Int32, gpointer?) -> Void, to: GCallback.self), me)

        let keyCtl = gtk_event_controller_key_new()
        keyController = keyCtl
        connect(keyCtl, "key-pressed", unsafeBitCast(surfaceKeyPressed as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self), me)
        connect(keyCtl, "key-released", unsafeBitCast(surfaceKeyReleased as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), keyCtl)

        let im = OpaquePointer(gtk_im_multicontext_new())
        imContext = im
        gtk_im_context_set_client_widget(cast(im), W(glArea))
        connect(im, "commit", unsafeBitCast(surfaceIMCommit as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self), me)
        connect(im, "preedit-changed", unsafeBitCast(surfacePreeditChanged as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)

        let focusCtl = gtk_event_controller_focus_new()
        connect(focusCtl, "enter", unsafeBitCast(surfaceFocusEnter as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(focusCtl, "leave", unsafeBitCast(surfaceFocusLeave as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), focusCtl)

        let click = gtk_gesture_click_new()
        gtk_gesture_single_set_button(click, 0)   // report all buttons, not just primary
        connect(click, "pressed", unsafeBitCast(surfaceClicked as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        connect(click, "released", unsafeBitCast(surfaceReleased as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), click)

        let motion = gtk_event_controller_motion_new()
        connect(motion, "motion", unsafeBitCast(surfaceMotion as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        connect(motion, "enter", unsafeBitCast(surfaceMotion as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        connect(motion, "leave", unsafeBitCast(surfaceLeave as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), motion)

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)
        connect(scroll, "scroll", unsafeBitCast(surfaceScroll as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> gboolean, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), scroll)

        // File/text drops insert paths/text at the cursor, matching the macOS drag-drop behavior. Sidebar
        // reorder drags use MOVE, while these targets accept COPY, so internal row drags don't land here.
        let stringDrop = gtk_drop_target_new(GType(64) /* G_TYPE_STRING */, GDK_ACTION_COPY)
        connect(stringDrop, "drop", unsafeBitCast(surfaceDropString as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), stringDrop)

        let fileDrop = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)
        connect(fileDrop, "drop", unsafeBitCast(surfaceDropFiles as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), fileDrop)
    }

    // MARK: - Lifecycle

    func realize() {
        gtk_gl_area_make_current(GLA(glArea))
        guard gtk_gl_area_get_error(GLA(glArea)) == nil else {
            FileHandle.standardError.write(Data("agterm: GtkGLArea failed to create a GL context\n".utf8))
            // Deferred: realize fires DURING window build, before gController is set (becameFrontmost runs
            // after present), so show the message on the next main-loop turn when the controller exists.
            runOnMain { MainActor.assumeIsolated { gController?.showGLError() } }
            return
        }
        createSurface()
    }

    func realizeWidgetIfNeeded() {
        gtk_widget_realize(W(glArea))
    }

    private func createSurface() {
        guard surface == nil, let app = GhosttyApp.shared.app else { return }
        let scale = gtk_widget_get_scale_factor(W(glArea))
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_OPENGL
        cfg.platform.opengl.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform.opengl.make_current = { ud in
            guard let w = GhosttyApp.wrapper(from: ud) else { return }
            gtk_gl_area_make_current(GLA(w.glArea))
        }
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(scale)
        if let fontSize { cfg.font_size = Float(fontSize) }   // restore a persisted per-session zoom
        // Inject the AGTERM_* env: strdup each key/value (kept alive in envCStrings for the surface
        // lifetime) and build the ghostty_env_var_s array. libghostty reads it during surface_new.
        var envVars: [ghostty_env_var_s] = []
        if !env.isEmpty {
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envCStrings.append(keyPtr); envCStrings.append(valuePtr)
                envVars.append(ghostty_env_var_s(key: UnsafePointer(keyPtr), value: UnsafePointer(valuePtr)))
            }
        }
        // working_directory / command buffers only need to outlive ghostty_surface_new
        // (libghostty copies them), so nested withCString around the call is sufficient; the env-var
        // array is supplied via its buffer pointer for the same call.
        envVars.withUnsafeMutableBufferPointer { envBuf in
            if let base = envBuf.baseAddress { cfg.env_vars = base; cfg.env_var_count = envBuf.count }
            withOptionalCString(initialInput) { inputPtr in
                cfg.initial_input = inputPtr
                cwd.withCString { cwdPtr in
                    cfg.working_directory = cwdPtr
                    if let command {
                        cfg.wait_after_command = waitAfterCommand
                        command.withCString { cfg.command = $0; surface = ghostty_surface_new(app, &cfg) }
                    } else {
                        surface = ghostty_surface_new(app, &cfg)
                    }
                }
            }
        }
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        pushSize()
        ghostty_surface_set_focus(surface, true)
        applyColorScheme()   // report the system light/dark scheme (OSC color-scheme queries)
        feed(GhosttyApp.shared.currentThemeOSC)   // push theme colors the embedded GL renderer won't adopt from config
        if controller?.store.session(withID: sessionID)?.backgroundWatermark != nil {
            applyWatermarkFromSession()
        }
    }

    private func pushSize() {
        guard let surface else { return }
        let scale = gtk_widget_get_scale_factor(W(glArea))
        let w = UInt32(max(1, gtk_widget_get_width(W(glArea)) * scale))
        let h = UInt32(max(1, gtk_widget_get_height(W(glArea)) * scale))
        ghostty_surface_set_size(surface, w, h)
    }

    func render() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    func queueRender() {
        guard surface != nil else { return }   // ignore stray RENDER after teardown
        gtk_gl_area_queue_render(GLA(glArea))
    }

    /// Run a libghostty binding action on this surface (font size, search, etc.) —
    /// the same seam macOS's GhosttySurfaceView.performBindingAction uses.
    func performBindingAction(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    /// Inject text as keystrokes (the control channel's session.type): printable runs go
    /// as key-with-text, each newline as a Return keypress (keycode 36 = XKB Return). NOT
    /// ghostty_surface_text, whose bracketed-paste wrapping suppresses Enter.
    func inject(text: String) {
        guard let surface else { return }
        // Split into printable runs + Return keys via the shared segmenter (one typing policy for both
        // platforms); send each run as text and each line break as a real Return key press.
        for segment in KeystrokeSegments.split(text) {
            switch segment {
            case .text(let run):
                run.withCString { ptr in
                    var ke = ghostty_input_key_s()
                    ke.action = GHOSTTY_ACTION_PRESS
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            case .returnKey:
                var ke = ghostty_input_key_s()
                ke.keycode = 36   // Return (XKB)
                ke.action = GHOSTTY_ACTION_PRESS
                _ = ghostty_surface_key(surface, ke)
                ke.action = GHOSTTY_ACTION_RELEASE
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    /// Feed raw bytes into the terminal as if read from the pty — used to push theme colors (OSC 11/10/4/…)
    /// that the embedded OpenGL renderer doesn't adopt from the config. `ghostty_surface_feed` runs them
    /// through the terminal parser under the renderer lock, so it's safe from the main thread.
    func feed(_ bytes: String) {
        guard let surface, !bytes.isEmpty else { return }
        bytes.withCString { ghostty_surface_feed(surface, $0, UInt(bytes.utf8.count)) }
    }

    // MARK: - In-terminal search (libghostty replies via the START/END/TOTAL/SELECTED actions)

    /// Apply a rebuilt ghostty config to this live surface (theme change). The caller owns `config`.
    func applyConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    func applyWatermarkFromSession() {
        guard let surface, let session = controller?.store.session(withID: sessionID) else { return }
        let resolvedImagePath = WatermarkRenderer.materialize(session.backgroundWatermark, sessionID: session.id)
        let windowOpacity = linuxSettingsStore().load().backgroundOpacity ?? 1
        let overlay = WatermarkConfig.overlayText(watermark: session.backgroundWatermark,
                                                  resolvedImagePath: resolvedImagePath,
                                                  fontSize: session.fontSize,
                                                  windowOpacity: windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else { return }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
        let osc = AppSettings.themeOSC(from: overlay.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        if !osc.isEmpty { feed(osc) }
        queueRender()
    }

    func reapplyWatermarkIfNeeded() {
        guard controller?.store.session(withID: sessionID)?.backgroundWatermark != nil else { return }
        applyWatermarkFromSession()
    }

    func startSearch() { performBindingAction("start_search") }
    func endSearch() { performBindingAction("end_search") }
    func sendSearchQuery(_ needle: String) { performBindingAction("search:\(needle)") }
    func navigateSearch(_ direction: SearchDirection) { performBindingAction(direction.ghosttyAction) }

    func applySearchStart(_ needle: String?) { controller?.searchDidStart(sessionID, needle: needle) }
    func applySearchEnd() { controller?.searchDidEnd(sessionID) }
    func applyProgress(_ value: Int?) { controller?.surfaceDidReportProgress(sessionID, percent: value) }
    func applySearchTotal(_ total: Int?) { controller?.searchDidReportTotal(sessionID, total: total) }
    func applySearchSelected(_ selected: Int?) { controller?.searchDidReportSelected(sessionID, selected: selected) }

    /// The current selection text (the control channel's session.copy), or nil if none.
    func readSelection() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let ptr = out.text else { return nil }
        let s = String(cString: ptr)
        return s.isEmpty ? nil : s
    }

    func readScreenText(all: Bool, lines: Int?) -> String? {
        guard let surface else { return nil }
        let tag = (all || lines != nil) ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let ptr = out.text, out.text_len > 0 else { return "" }
        let full = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(out.text_len)), as: UTF8.self)
        guard let n = lines, n > 0 else { return full }
        var rows = full.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return rows.suffix(n).joined(separator: "\n")
    }

    func resize(width: Int32, height: Int32) {
        guard let surface else { return }
        let scale = gtk_widget_get_scale_factor(W(glArea))
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        // GtkGLArea::resize already reports the viewport in device pixels (it emits
        // width*scale, height*scale). Pass them straight through — multiplying by scale
        // again over-sizes the grid on HiDPI, pushing the bottom rows off-screen.
        ghostty_surface_set_size(surface, UInt32(max(1, width)), UInt32(max(1, height)))
    }

    /// Forward a GTK scroll event to libghostty. ghostty's convention is "positive = up,
    /// right" while GTK's is "positive dy = down", so the Y axis is inverted. Mouse wheels
    /// (WHEEL unit) are non-precision ticks; touchpads (SURFACE unit) are precision pixel
    /// scrolls, which ghostty measures against the device-pixel cell height — hence the
    /// scale conversion.
    func scroll(controller: OpaquePointer?, dx: Double, dy: Double) {
        guard let surface else { return }
        var mods: ghostty_input_scroll_mods_t = 0
        var sx = dx, sy = dy
        if let controller, gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_SURFACE {
            let scale = Double(gtk_widget_get_scale_factor(W(glArea)))
            sx *= scale
            sy *= scale
            mods = 1   // precision bit (ghostty ScrollMods.precision)
        }
        // ghostty's convention is "positive = up/right"; GTK's is "positive dy = down",
        // so invert Y. The wheel/touchpad delta drives scrollback the same as macOS.
        ghostty_surface_mouse_scroll(surface, sx, -sy, mods)
    }

    /// The modifier state of the event currently being dispatched on `controller`.
    private func currentMods(_ controller: OpaquePointer?) -> ghostty_input_mods_e {
        guard let controller else { return GHOSTTY_MODS_NONE }
        return ghosttyMods(gtk_event_controller_get_current_event_state(controller).rawValue)
    }

    /// Forward the pointer position (device pixels) so libghostty can build mouse reports
    /// for mouse-tracking TUIs (Claude, vim, htop) and extend drag-selections. Without
    /// this, apps on the alternate screen never see the wheel/clicks. Also serves the
    /// "enter" signal (same shape), so hover state arms as soon as the pointer arrives.
    func mouseMoved(_ controller: OpaquePointer?, x: Double, y: Double) {
        guard let surface else { return }
        let scale = Double(gtk_widget_get_scale_factor(W(glArea)))
        ghostty_surface_mouse_pos(surface, x * scale, y * scale, currentMods(controller))
    }

    /// Pointer left the surface: report an out-of-bounds position so libghostty clears
    /// hover state (link underline, motion-tracking highlights).
    func mouseLeft() {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE)
    }

    func mouseButton(_ gesture: OpaquePointer?, pressed: Bool, x: Double, y: Double) {
        guard let surface else { return }
        let scale = Double(gtk_widget_get_scale_factor(W(glArea)))
        let mods = currentMods(gesture)
        ghostty_surface_mouse_pos(surface, x * scale, y * scale, mods)
        let btn = gesture.map { gtk_gesture_single_get_current_button($0) } ?? 1
        let gbtn: ghostty_input_mouse_button_e = btn == 2 ? GHOSTTY_MOUSE_MIDDLE : (btn == 3 ? GHOSTTY_MOUSE_RIGHT : GHOSTTY_MOUSE_LEFT)
        _ = ghostty_surface_mouse_button(surface, pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE, gbtn, mods)
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Show/hide the mouse pointer over this surface (GHOSTTY_ACTION_MOUSE_VISIBILITY): a blank "none"
    /// cursor when hidden, the inherited default when visible.
    func setMouseVisible(_ visible: Bool) {
        if visible {
            gtk_widget_set_cursor(W(glArea), nil)
        } else {
            gtk_widget_set_cursor(W(glArea), gdk_cursor_new_from_name("none", nil))
        }
    }

    /// Set the link-hover cursor (GHOSTTY_ACTION_MOUSE_OVER_LINK): the hand "pointer" over a hyperlink,
    /// the default otherwise.
    func setLinkHover(_ overLink: Bool) {
        gtk_widget_set_cursor(W(glArea), overLink ? gdk_cursor_new_from_name("pointer", nil) : nil)
    }

    /// Set the pointer shape over this surface (GHOSTTY_ACTION_MOUSE_SHAPE). ghostty's shapes are named
    /// after CSS cursors, which gdk_cursor_new_from_name accepts; map the common ones, default otherwise.
    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let name: String
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: name = "text"
        case GHOSTTY_MOUSE_SHAPE_POINTER: name = "pointer"
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: name = "crosshair"
        case GHOSTTY_MOUSE_SHAPE_WAIT: name = "wait"
        case GHOSTTY_MOUSE_SHAPE_PROGRESS: name = "progress"
        case GHOSTTY_MOUSE_SHAPE_HELP: name = "help"
        case GHOSTTY_MOUSE_SHAPE_MOVE: name = "move"
        case GHOSTTY_MOUSE_SHAPE_GRAB: name = "grab"
        case GHOSTTY_MOUSE_SHAPE_GRABBING: name = "grabbing"
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: name = "not-allowed"
        default: name = "default"
        }
        gtk_widget_set_cursor(W(glArea), name == "default" ? nil : gdk_cursor_new_from_name(name, nil))
    }

    /// Push the current system light/dark scheme to the surface (at create + on style-manager change).
    func applyColorScheme() {
        guard let surface else { return }
        let dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func grabFocus() {
        _ = gtk_widget_grab_focus(W(glArea))
    }

    /// Force libghostty to redraw this surface (e.g. after a split re-layout), mirroring the macOS
    /// `ghostty_surface_refresh` call so a pane never shows a stale frame at the old size.
    func refresh() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    // MARK: - Input

    func keyPressed(keyval: UInt32, keycode: UInt32, state: UInt32) -> Bool {
        guard let surface else { return false }

        let control = (state & (1 << 2)) != 0
        let hasOtherModifiers = (state & ((1 << 0) | (1 << 3) | (1 << 26))) != 0
        let baseScalar = Unicode.Scalar(gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval)))
        let isInterrupt = keyval == 0xFF1B || (control && !hasOtherModifiers && baseScalar?.value == 0x63)
        controller?.clearAttentionStatus(sessionID, pane: isSplitPane ? .right : .left,
                                         isInterrupt: isInterrupt)

        // App-level shortcuts run first via the shared keymap (rebindable built-ins + custom commands +
        // the fixed arrow/page/font fallback). All the dispatch logic lives in AppController.handleKey so
        // this handler stays thin; ghostty still gets its own binds (Ctrl+Shift+C/V) when handleKey passes.
        if controller?.handleKey(keyval: keyval, keycode: keycode, state: state,
                                 sessionID: sessionID, origin: self) == true {
            return true
        }

        // Route through the IM context: a dead-key/compose/CJK sequence is CONSUMED here (its result
        // arrives via the `commit` signal → imCommit). Plain keys pass through (filter returns false) and
        // fall to the raw key path below, so normal typing + control sequences are unchanged.
        if let im = imContext, let ctl = keyController,
           let event = gtk_event_controller_get_current_event(ctl),
           gtk_im_context_filter_keypress(cast(im), event) != 0 {
            return true
        }

        var ke = ghostty_input_key_s()
        ke.action = GHOSTTY_ACTION_PRESS
        ke.keycode = keycode                 // GDK hardware keycode == XKB == ghostty's Linux native code
        ke.mods = ghosttyMods(state)
        ke.consumed_mods = GHOSTTY_MODS_NONE

        let unicode = gdk_keyval_to_unicode(keyval)
        // Ctrl/Alt/Super combos and non-printables: send no text and let libghostty
        // encode from keycode+mods (e.g. Ctrl-C -> ^C, arrows, F-keys).
        let hasCtrlAltSuper = (state & ((1 << 2) | (1 << 3) | (1 << 26))) != 0
        if unicode >= 0x20, unicode != 0x7f, !hasCtrlAltSuper, let scalar = Unicode.Scalar(unicode) {
            ke.unshifted_codepoint = unicode
            return String(scalar).withCString { ptr in
                ke.text = ptr
                return ghostty_surface_key(surface, ke)
            }
        } else {
            ke.unshifted_codepoint = unicode >= 0x20 ? unicode : 0
            ke.text = nil
            return ghostty_surface_key(surface, ke)
        }
    }

    /// The IM context committed composed text (dead-key/compose/CJK result) → send it to the terminal.
    func imCommit(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            var ke = ghostty_input_key_s()
            ke.action = GHOSTTY_ACTION_PRESS
            ke.text = ptr
            _ = ghostty_surface_key(surface, ke)
        }
    }

    /// Tell the IM context the surface gained/lost keyboard focus (so it composes only when focused).
    func imFocus(_ focused: Bool) {
        guard let im = imContext else { return }
        if focused {
            gtk_im_context_focus_in(cast(im))
        } else {
            gtk_im_context_focus_out(cast(im))
        }
    }

    /// The composition-in-progress text changed → show it as ghostty's preedit (underlined CJK/compose
    /// candidate). An empty string clears it (on commit/cancel).
    func imPreeditChanged() {
        guard let surface, let im = imContext else { return }
        var str: UnsafeMutablePointer<CChar>?
        var cursor: Int32 = 0
        gtk_im_context_get_preedit_string(cast(im), &str, nil, &cursor)
        if let str {
            ghostty_surface_preedit(surface, str, UInt(strlen(str)))
            g_free(UnsafeMutableRawPointer(str))
        }
    }

    // MARK: - Actions from libghostty

    func applyTitle(_ title: String) {
        guard reportsPaneState, !title.isEmpty else { return }
        controller?.sessionDidReportTitle(sessionID, title, isSplit: isSplitPane)
    }

    func applyPwd(_ pwd: String) {
        guard reportsPaneState else { return }
        controller?.sessionDidReportPwd(sessionID, pwd, isSplit: isSplitPane)
    }

    /// CELL_SIZE fired (a font-size change via Ctrl+/-, or a DPI change): read the live font size and
    /// persist it on the session so a relaunch restores the zoom. setFontSize no-ops when unchanged,
    /// so a pure DPI change doesn't write. Per-session (both panes share the size).
    func reportFontSize() {
        guard let size = currentFontSize() else { return }
        guard size > 0 else { return }
        controller?.sessionDidReportFontSize(sessionID, size)
    }

    func currentFontSize() -> Double? {
        guard let surface else { return nil }
        let size = Double(ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size)
        return size > 0 ? size : nil
    }

    func handleProcessExit() {
        guard !didHandleProcessExit else { return }
        didHandleProcessExit = true
        let exit = onExit
        onExit = nil
        exit?()
    }

    var shouldCloseOnChildExitAction: Bool { command != nil && !waitAfterCommand }

    func promoteToPrimary(onExit: (() -> Void)?) {
        isSplitPane = false
        self.onExit = onExit
    }

    /// The live foreground-process argv (via `/proc/<pid>/cmdline`), or nil at the shell prompt — the
    /// Linux analogue of macOS's KERN_PROCARGS2 capture, used for `tree` introspection / restore.
    func foregroundCommand() -> [String]? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              let argv = CommandRestore.parseProcCmdline(data),
              !CommandRestore.isIdleShell(argv: argv) else { return nil }
        return argv
    }

    // MARK: - TerminalSurface

    func teardown() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = []
        for ptr in envCStrings { free(ptr) }
        envCStrings = []
    }
}

// MARK: - GTK signal trampolines (recover the GhosttySurface from the trailing user_data)

private func wrap(_ data: gpointer?) -> GhosttySurface? {
    guard let data else { return nil }
    return Unmanaged<GhosttySurface>.fromOpaque(data).takeUnretainedValue()
}

/// Releases the retained surface reference the GtkGLArea owned (balances the `passRetained` at connect
/// time). Fired when the widget is destroyed — the LAST signal, so the object stays valid through any
/// focus-leave/etc. emitted during teardown.
private let surfaceDestroy: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    if let data { Unmanaged<GhosttySurface>.fromOpaque(data).release() }
}
private let surfaceRealize: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { wrap(data)?.realize() }
}
private let surfaceRender: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean = { _, _, data in
    MainActor.assumeIsolated { wrap(data)?.render() }
    return 1
}
private let surfaceResize: @convention(c) (OpaquePointer?, Int32, Int32, gpointer?) -> Void = { _, w, h, data in
    MainActor.assumeIsolated { wrap(data)?.resize(width: w, height: h) }
}
private let surfaceKeyPressed: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, keyval, keycode, state, data in
    MainActor.assumeIsolated { (wrap(data)?.keyPressed(keyval: keyval, keycode: keycode, state: state) ?? false) ? 1 : 0 }
}
/// Ctrl release commits the Ctrl-Tab session-switch cycle (the only key release agterm reacts to; ghostty
/// tracks its own key state internally).
private let surfaceKeyReleased: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void = { _, keyval, _, _, _ in
    if keyval == 0xFFE3 || keyval == 0xFFE4 {   // Control_L / Control_R
        MainActor.assumeIsolated { gController?.endSessionSwitch() }
    }
}
private let surfaceFocusEnter: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let surface = wrap(data) else { return }
        surface.setFocus(true)
        surface.imFocus(true)
        // Tell the controller which pane took focus so a split session's displayName/title/cwd track it.
        surface.controller?.surfaceDidFocus(surface.sessionID, isSplit: surface.isSplitPane)
    }
}
private let surfaceFocusLeave: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        wrap(data)?.setFocus(false)
        wrap(data)?.imFocus(false)
        wrap(data)?.controller?.resetLeader()   // abandon any half-typed custom-command leader when the terminal blurs
    }
}
/// The IM context committed composed text (dead-key / compose / CJK result).
private let surfaceIMCommit: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, text, data in
    guard let text else { return }
    let s = String(cString: text)
    MainActor.assumeIsolated { wrap(data)?.imCommit(s) }
}
private let surfacePreeditChanged: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { wrap(data)?.imPreeditChanged() }
}
private let surfaceClicked: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
    MainActor.assumeIsolated {
        wrap(data)?.grabFocus()
        wrap(data)?.mouseButton(gesture, pressed: true, x: x, y: y)
    }
}
private let surfaceReleased: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
    MainActor.assumeIsolated { wrap(data)?.mouseButton(gesture, pressed: false, x: x, y: y) }
}
private let surfaceMotion: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = { ctl, x, y, data in
    MainActor.assumeIsolated { wrap(data)?.mouseMoved(ctl, x: x, y: y) }
}
private let surfaceLeave: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { wrap(data)?.mouseLeft() }
}
private let surfaceScroll: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> gboolean = { ctl, dx, dy, data in
    MainActor.assumeIsolated { wrap(data)?.scroll(controller: ctl, dx: dx, dy: dy) }
    return 1
}
private let surfaceDropString: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value), let surface = wrap(data) else { return 0 }
        let payload = String(cString: cstr)
        // Defensive guard for in-app sidebar drags if a compositor offers COPY anyway.
        if UUID(uuidString: payload) != nil { return 0 }
        if payload.hasPrefix("w:"), UUID(uuidString: String(payload.dropFirst(2))) != nil { return 0 }
        guard let text = ShellEscape.dropPayload(payload) else { return 0 }
        surface.grabFocus()
        surface.inject(text: text)
        return 1
    }
}
private let surfaceDropFiles: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
    MainActor.assumeIsolated {
        guard let value, let boxed = g_value_get_boxed(value), let surface = wrap(data) else { return 0 }
        let fileList = OpaquePointer(boxed)
        guard let files = gdk_file_list_get_files(fileList) else { return 0 }
        defer { g_slist_free(files) }

        var parts: [String] = []
        var node: UnsafeMutablePointer<GSList>? = files
        while let current = node {
            if let rawFile = current.pointee.data {
                let file = OpaquePointer(rawFile)
                if let cpath = g_file_get_path(file) {
                    let path = String(cString: cpath)
                    g_free(cpath)
                    parts.append(ShellEscape.path(path))
                } else if let curi = g_file_get_uri(file) {
                    let uri = String(cString: curi)
                    g_free(curi)
                    parts.append(ShellEscape.path(uri))
                }
            }
            node = current.pointee.next
        }

        let text = parts.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return 0 }
        surface.grabFocus()
        surface.inject(text: text)
        return 1
    }
}
