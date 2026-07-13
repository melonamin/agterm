import CGtk
import agtermCore

@MainActor
extension AppController {
    func clearInvalidTerminalZoom() {
        guard let target = terminalZoom.target,
              !TerminalZoomController.isTargetValid(target, in: store, quickTerminalVisible: quickVisible) else {
            return
        }
        setTerminalZoom(.off, target: target)
    }

    func setTerminalZoom(_ mode: ControlToggleMode, target: TerminalZoomTarget?) {
        let old = terminalZoom.target
        terminalZoom.set(mode, target: target)
        let new = terminalZoom.target
        guard old != new else { return }
        if let old { restoreZoomedSurface(old) }
        if let new, !hostZoomedSurface(new) {
            terminalZoom.clear()
        }
        let zoomed = terminalZoom.target != nil
        gtk_widget_set_visible(W(splitView), zoomed ? 0 : 1)
        if let host = zoomHost { gtk_widget_set_visible(W(host), zoomed ? 1 : 0) }
        if !zoomed { showActive() }
    }

    private func surface(for target: TerminalZoomTarget) -> GhosttySurface? {
        switch target {
        case .quick: return quickSurface
        case .session(let id, .primary): return surfaces[id]
        case .session(let id, .split): return splitSurfaces[id]
        case .session(let id, .scratch): return scratchSurfaces[id]
        case .session(let id, .overlay): return overlaySurfaces[id]
        }
    }

    private func hostZoomedSurface(_ target: TerminalZoomTarget) -> Bool {
        guard let surface = surface(for: target), detach(surface.glArea, from: target),
              let deckOverlay else { return false }
        let host = OpaquePointer(gtk_overlay_new())
        gtk_widget_set_halign(W(host), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(host), GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(W(host), 1)
        gtk_widget_set_vexpand(W(host), 1)
        gtk_overlay_set_child(host, W(surface.glArea))

        let exit = OpaquePointer(gtk_button_new_from_icon_name("view-restore-symbolic"))
        gtk_widget_set_tooltip_text(W(exit), "Exit Terminal Zoom")
        gtk_widget_set_halign(W(exit), GTK_ALIGN_END)
        gtk_widget_set_valign(W(exit), GTK_ALIGN_START)
        gtk_widget_set_margin_top(W(exit), 8)
        gtk_widget_set_margin_end(W(exit), 8)
        gtk_widget_add_css_class(W(exit), "circular")
        connect(exit, "clicked", unsafeBitCast(onTerminalZoomExit, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
        gtk_overlay_add_overlay(host, W(exit))
        gtk_overlay_add_overlay(deckOverlay, W(host))
        zoomHost = host
        surface.grabFocus()
        surface.refresh()
        g_object_unref(RAW(surface.glArea))
        return true
    }

    private func detach(_ widget: OpaquePointer, from target: TerminalZoomTarget) -> Bool {
        _ = g_object_ref(RAW(widget))
        switch target {
        case .quick:
            guard let frame = quickFrame else { g_object_unref(RAW(widget)); return false }
            gtk_frame_set_child(cast(frame), nil)
            gtk_widget_set_visible(W(frame), 0)
        case .session(let id, .primary):
            guard let paned = sessionPanes[id] else { g_object_unref(RAW(widget)); return false }
            gtk_paned_set_start_child(paned, nil)
        case .session(let id, .split):
            guard let paned = sessionPanes[id] else { g_object_unref(RAW(widget)); return false }
            gtk_paned_set_end_child(paned, nil)
        case .session(let id, .scratch), .session(let id, .overlay):
            guard let stack = sessionStacks[id] else { g_object_unref(RAW(widget)); return false }
            if let frame = floatingOverlayFrames[id], target == .session(id, .overlay) {
                gtk_frame_set_child(cast(frame), nil)
            } else {
                gtk_stack_remove(stack, W(widget))
            }
        }
        return true
    }

    private func restoreZoomedSurface(_ target: TerminalZoomTarget) {
        guard let surface = surface(for: target), let host = zoomHost, let deckOverlay else { return }
        _ = g_object_ref(RAW(surface.glArea))
        gtk_overlay_set_child(host, nil)
        gtk_overlay_remove_overlay(deckOverlay, W(host))
        zoomHost = nil
        switch target {
        case .quick:
            if let frame = quickFrame {
                gtk_frame_set_child(cast(frame), W(surface.glArea))
                gtk_widget_set_visible(W(frame), quickVisible ? 1 : 0)
            }
        case .session(let id, .primary):
            if let paned = sessionPanes[id] { gtk_paned_set_start_child(paned, W(surface.glArea)) }
        case .session(let id, .split):
            if let paned = sessionPanes[id] { gtk_paned_set_end_child(paned, W(surface.glArea)) }
        case .session(let id, .scratch):
            if let stack = sessionStacks[id] {
                "scratch".withCString { _ = gtk_stack_add_named(stack, W(surface.glArea), $0) }
            }
        case .session(let id, .overlay):
            if let frame = floatingOverlayFrames[id] {
                gtk_frame_set_child(cast(frame), W(surface.glArea))
            } else if let stack = sessionStacks[id] {
                "overlay".withCString { _ = gtk_stack_add_named(stack, W(surface.glArea), $0) }
            }
        }
        g_object_unref(RAW(surface.glArea))
        surface.refresh()
    }
}

private let onTerminalZoomExit: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let controller = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
        controller.setTerminalZoom(.off, target: nil)
    }
}
