import CGtk
import Foundation
import agtermCore

@MainActor
final class DashboardRuntime {
    var host: OpaquePointer?
    var frames: [DashboardMember: OpaquePointer] = [:]
    var targets: [DashboardMember: TerminalZoomTarget] = [:]
    var clickContexts: [DashboardClickContext] = []
}

@MainActor
final class DashboardClickContext {
    unowned let controller: AppController
    let member: DashboardMember

    init(controller: AppController, member: DashboardMember) {
        self.controller = controller
        self.member = member
    }
}

@MainActor
extension AppController {
    func toggleDashboard() {
        if dashboard.isOpen {
            closeDashboard()
            return
        }
        guard terminalZoom.target == nil else { return }
        let members = store.dashboardMRUMembers(limit: DashboardLayout.maxCells)
        guard !members.isEmpty else { return }
        openDashboard(members: members, fontMode: .auto)
    }

    func openDashboard(members: [DashboardMember], fontMode: DashboardFontMode) {
        guard !members.isEmpty else { return }
        if terminalZoom.target != nil { setTerminalZoom(.off, target: nil) }
        if dashboard.isOpen { closeDashboard(refocus: false) }
        if quickVisible { setQuick(false) }
        if paletteWindow != nil { closePalette() }
        searchSurface?.endSearch()
        if sessionSwitcher.isActive { endSessionSwitch() }
        dashboard.open(members: members, fontMode: fontMode)
        store.suppressAutoFollow()
        applyDashboardFont()
        mountDashboard()
    }

    func closeDashboard(refocus: Bool = true) {
        guard dashboard.isOpen || dashboardRuntime.host != nil else { return }
        clearDashboardFontOverrides()
        for (member, target) in dashboardRuntime.targets {
            guard let surface = surface(for: target) else { continue }
            _ = g_object_ref(RAW(surface.glArea))
            if let frame = dashboardRuntime.frames[member] { gtk_frame_set_child(cast(frame), nil) }
            gtk_widget_set_can_target(W(surface.glArea), 1)
            gtk_widget_set_focusable(W(surface.glArea), 1)
            reattach(surface.glArea, to: target)
            g_object_unref(RAW(surface.glArea))
            surface.refresh()
        }
        if let host = dashboardRuntime.host, let deckOverlay {
            gtk_overlay_remove_overlay(deckOverlay, W(host))
        }
        dashboardRuntime.host = nil
        dashboardRuntime.frames = [:]
        dashboardRuntime.targets = [:]
        dashboardRuntime.clickContexts = []
        dashboard.close()
        store.resumeAutoFollow()
        gtk_widget_set_visible(W(splitView), 1)
        showActive()
        if refocus { focusedSurface()?.grabFocus() }
    }

    func selectDashboardMember(_ member: DashboardMember) {
        guard dashboard.members.contains(member) else { return }
        store.selectSession(member.session)
        if let session = store.session(withID: member.session) {
            session.splitFocused = member.surface == .split
        }
        closeDashboard(refocus: false)
        if member.surface == .split { focusPane(left: false) } else { focusPane(left: true) }
    }

    func moveDashboardHighlight(_ direction: DashboardLayout.Direction) {
        dashboard.move(direction)
        updateDashboardHighlight()
    }

    func revealSessionDirectory(_ id: UUID) -> Bool {
        guard let path = store.session(withID: id)?.focusedCwd else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        URL(fileURLWithPath: path).absoluteString.withCString {
            _ = g_app_info_launch_default_for_uri($0, nil, nil)
        }
        return true
    }

    func prepareDashboardForReconcile()
        -> (members: [DashboardMember], mode: DashboardFontMode, highlighted: DashboardMember?)? {
        guard dashboard.isOpen else { return nil }
        let existing = Set(store.workspaces.flatMap(\.sessions).flatMap { session -> [DashboardMember] in
            var result = [DashboardMember(session: session.id, surface: .primary)]
            if session.hasSplit { result.append(DashboardMember(session: session.id, surface: .split)) }
            return result
        })
        let survivors = dashboard.members.filter(existing.contains)
        let state = (survivors, dashboard.fontMode,
                     dashboard.highlighted.flatMap { survivors.contains($0) ? $0 : nil })
        closeDashboard(refocus: false)
        return state
    }

    func restoreDashboardAfterReconcile(
        _ state: (members: [DashboardMember], mode: DashboardFontMode, highlighted: DashboardMember?)?) {
        guard let state, !state.members.isEmpty else { return }
        openDashboard(members: state.members, fontMode: state.mode)
        if let highlighted = state.highlighted {
            dashboard.highlight(highlighted)
            updateDashboardHighlight()
        }
    }

    private func mountDashboard() {
        guard let deckOverlay else { return }
        let host = OpaquePointer(gtk_overlay_new())
        let grid = OpaquePointer(gtk_grid_new())
        gtk_widget_add_css_class(W(host), "agterm-dashboard")
        gtk_widget_set_hexpand(W(host), 1)
        gtk_widget_set_vexpand(W(host), 1)
        gtk_widget_set_focusable(W(host), 1)
        gtk_grid_set_row_homogeneous(cast(grid), 1)
        gtk_grid_set_column_homogeneous(cast(grid), 1)
        gtk_grid_set_row_spacing(cast(grid), 8)
        gtk_grid_set_column_spacing(cast(grid), 8)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(grid), 10)
        }
        gtk_overlay_set_child(host, W(grid))

        let (cols, _) = DashboardLayout.grid(count: dashboard.members.count)
        for (index, member) in dashboard.members.enumerated() {
            let target = TerminalZoomTarget.session(member.session, member.surface)
            guard let surface = surface(for: target), detach(surface.glArea, from: target) else { continue }
            let frame = OpaquePointer(gtk_frame_new(nil))
            gtk_widget_add_css_class(W(frame), "agterm-dashboard-cell")
            gtk_widget_set_hexpand(W(frame), 1)
            gtk_widget_set_vexpand(W(frame), 1)
            gtk_widget_set_can_target(W(surface.glArea), 0)
            gtk_widget_set_focusable(W(surface.glArea), 0)
            let cell = OpaquePointer(gtk_overlay_new())
            gtk_overlay_set_child(cell, W(surface.glArea))
            let sessionName = store.session(withID: member.session)?.displayName ?? "Session"
            let paneName = member.surface == .split ? "Right" : "Left"
            let caption = OpaquePointer(gtk_label_new("\(sessionName) · \(paneName)"))
            gtk_widget_add_css_class(W(caption), "agterm-dashboard-caption")
            gtk_widget_set_halign(W(caption), GTK_ALIGN_START)
            gtk_widget_set_valign(W(caption), GTK_ALIGN_END)
            gtk_widget_set_margin_start(W(caption), 8)
            gtk_widget_set_margin_bottom(W(caption), 8)
            gtk_overlay_add_overlay(cell, W(caption))
            gtk_frame_set_child(cast(frame), W(cell))
            g_object_unref(RAW(surface.glArea))
            let click = gtk_gesture_click_new()
            let context = DashboardClickContext(controller: self, member: member)
            dashboardRuntime.clickContexts.append(context)
            connect(click, "pressed", unsafeBitCast(onDashboardCellPressed as @convention(c)
                (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self),
                Unmanaged.passUnretained(context).toOpaque())
            gtk_widget_add_controller(W(frame), click)
            gtk_grid_attach(cast(grid), W(frame), Int32(index % cols), Int32(index / cols), 1, 1)
            dashboardRuntime.frames[member] = frame
            dashboardRuntime.targets[member] = target
        }

        let exit = OpaquePointer(gtk_button_new_from_icon_name("window-close-symbolic"))
        gtk_widget_set_tooltip_text(W(exit), "Exit Dashboard")
        gtk_widget_set_halign(W(exit), GTK_ALIGN_END)
        gtk_widget_set_valign(W(exit), GTK_ALIGN_START)
        gtk_widget_set_margin_top(W(exit), 16)
        gtk_widget_set_margin_end(W(exit), 16)
        gtk_widget_add_css_class(W(exit), "circular")
        connect(exit, "clicked", unsafeBitCast(onDashboardExit, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
        gtk_overlay_add_overlay(host, W(exit))

        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed", unsafeBitCast(onDashboardKey as @convention(c)
            (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque())
        gtk_widget_add_controller(W(host), keys)
        gtk_overlay_add_overlay(deckOverlay, W(host))
        dashboardRuntime.host = host
        gtk_widget_set_visible(W(splitView), 0)
        updateDashboardHighlight()
        _ = gtk_widget_grab_focus(W(host))
    }

    private func applyDashboardFont() {
        clearDashboardFontOverrides()
        let base = linuxSettingsStore().load().fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        let size = dashboard.fontMode.appliedFontSize(memberCount: dashboard.members.count, base: base)
        dashboard.setAppliedFontSize(size)
        guard let size else { return }
        for member in dashboard.members {
            let target = TerminalZoomTarget.session(member.session, member.surface)
            surface(for: target)?.dashboardFontOverride = size
        }
    }

    private func clearDashboardFontOverrides() {
        for surface in Array(surfaces.values) + Array(splitSurfaces.values) where surface.dashboardFontOverride != nil {
            surface.dashboardFontOverride = nil
        }
    }

    private func updateDashboardHighlight() {
        for (member, frame) in dashboardRuntime.frames {
            if member == dashboard.highlighted {
                gtk_widget_add_css_class(W(frame), "selected")
            } else {
                gtk_widget_remove_css_class(W(frame), "selected")
            }
        }
    }
}

private let onDashboardExit: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().closeDashboard()
    }
}

private let onDashboardCellPressed: @convention(c)
    (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, presses, _, _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<DashboardClickContext>.fromOpaque(data).takeUnretainedValue()
        context.controller.dashboard.highlight(context.member)
        context.controller.updateDashboardHighlightFromCallback()
        if presses >= 2 { context.controller.selectDashboardMember(context.member) }
    }
}

private let onDashboardKey: @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, key, _, _, data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        let controller = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
        switch key {
        case 0xFF1B: controller.closeDashboard(); return 1
        case 0xFF51: controller.moveDashboardHighlight(.left); return 1
        case 0xFF52: controller.moveDashboardHighlight(.up); return 1
        case 0xFF53: controller.moveDashboardHighlight(.right); return 1
        case 0xFF54: controller.moveDashboardHighlight(.down); return 1
        case 0xFF0D, 0xFF8D:
            if let member = controller.dashboard.highlighted { controller.selectDashboardMember(member) }
            return 1
        default: return 1
        }
    }
}

@MainActor
extension AppController {
    fileprivate func updateDashboardHighlightFromCallback() { updateDashboardHighlight() }
}
