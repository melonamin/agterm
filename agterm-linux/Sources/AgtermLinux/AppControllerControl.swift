import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    // MARK: - Control channel dispatch (a core subset of the macOS ControlServer)

    func handleControl(_ req: ControlRequest) -> ControlResponse {
        func ok(_ id: UUID? = nil) -> ControlResponse { ControlResponse(ok: true, result: ControlResult(id: id?.uuidString)) }
        func err(_ m: String) -> ControlResponse { ControlResponse(ok: false, error: m) }

        // The Linux-local dispatcher owns the migrated synchronous commands; the rest fall through to the
        // inline switch below. Keep it in the Linux target so GTK control-flow needs do not leak into
        // upstream macOS-only core code.
        if let resp = LinuxControlDispatcher(actions: self).dispatch(req) { return resp }

        switch req.cmd {
        case .sessionType:
            guard let text = req.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
            return typeSessionSync(req.target, window: req.args?.window,
                                   options: ControlSessionTypeOptions(text: text,
                                                                      select: req.args?.select ?? false,
                                                                      pane: req.args?.pane))
        case .sessionSearch:
            guard let id = resolveSession(req.target) else { return sessionResolveError(req.target) }
            if req.args?.to == "close" {
                if searchSessionID == id { searchSurface?.endSearch() }
                return ok(id)
            }   // close needs no counter
            selectSession(id)
            guard let owner = searchTargetSurface(for: id) else { return err("session not realized") }
            searchSurface = owner
            owner.startSearch()   // action fires inline -> search bar is shown synchronously
            let hasQuery = req.args?.text.map { !$0.isEmpty } ?? false
            if let text = req.args?.text, !text.isEmpty {
                searchTotal = nil
                searchSelected = nil
                text.withCString { gtk_editable_set_text(searchEntry, $0) }
                owner.sendSearchQuery(text)
            }
            switch req.args?.to {                                  // navigate matches the next/prev half of macOS
            case "next": owner.navigateSearch(.next)
            case "prev", "previous": owner.navigateSearch(.previous)
            default: break
            }
            // SEARCH_TOTAL arrives in a LATER ghostty tick, so the count is nil if we return immediately.
            // Settle-poll: drain the main loop until the total lands (or a short timeout). Re-entering the
            // default context fires the queued tick -> searchDidReportTotal. Only when a needle was set.
            if hasQuery {
                for _ in 0..<20 {
                    while g_main_context_iteration(nil, 0) != 0 {}   // drain queued events incl. the ghostty tick
                    if searchTotal != nil { break }
                    usleep(3000)   // 3 ms; ~60 ms worst case
                }
            }
            let display = searchDisplayText()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString,
                                                                   text: display.isEmpty ? nil : display,
                                                                   count: searchTotal))
        case .quick:
            guard let mode = ControlToggleMode.parse(req.args?.mode, on: "show", off: "hide") else {
                return err("invalid quick mode: \(req.args?.mode ?? "toggle")")
            }
            setQuick(mode.desiredValue(current: quickVisible))
            return ok()
        case .quickType:
            guard let text = req.args?.text else { return err("quick.type requires text") }
            return typeQuickSync(text: text)
        case .quickText:
            return readQuickTextSync(all: req.args?.all ?? false, lines: req.args?.lines)
        case .windowNew:
            let info = library.newWindow(name: req.args?.name?.linuxTrimmedOrNil)
            openWindow(info.id)
            return ok(info.id)
        case .windowList:
            return ControlResponse(ok: true, result: ControlResult(windows: library.controlWindowNodes()))
        case .windowSelect:
            guard case .resolved(let id) = library.resolveWindow(req.target ?? "active") else {
                return resolveError("window", target: req.target, candidates: library.windows.map(\.id))
            }
            openWindow(id)
            return ok(id)
        case .windowClose:
            guard case .resolved(let id) = library.resolveWindow(req.target ?? "active") else {
                return resolveError("window", target: req.target, candidates: library.windows.map(\.id))
            }
            guard let ctl = gWindows[id] else {
                library.closeWindow(id)
                return ok(id)
            }
            gtk_window_close(WIN(ctl.windowPointer))
            return ok(id)
        case .windowDelete:
            guard case .resolved(let id) = library.resolveWindow(req.target ?? "active") else {
                return resolveError("window", target: req.target, candidates: library.windows.map(\.id))
            }
            guard library.canRemoveWindow else { return err("cannot delete last window") }
            if let ctl = gWindows[id] {
                gtk_window_close(WIN(ctl.windowPointer))
            }
            library.removeWindow(id)
            return ok(id)
        case .windowMove:
            // GTK4/Wayland gives no programmatic window positioning; the compositor owns it.
            return err("window.move is not supported on this platform (the compositor controls window position)")
        default:
            return err("command not yet supported on Linux: \(req.cmd.rawValue)")
        }
    }

    func resolveSession(_ target: String?) -> UUID? {
        let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
        if case let .resolved(id) = ControlResolve.resolve(target ?? "active", candidates: candidates, active: store.selectedSessionID) { return id }
        return nil
    }

    /// The resolution error for a failed inline session resolve: an ambiguous prefix vs not-found,
    /// mirroring the shared dispatcher's notFound so the inline arm emits the SAME distinction.
    private func resolveError(_ noun: String, target: String?, candidates: [UUID]) -> ControlResponse {
        if let target, case let .ambiguous(hits) = ControlResolve.resolve(target, candidates: candidates, active: nil) {
            return ControlResponse(ok: false, error: ControlResolve.ambiguousMessage(noun: noun, target: target, hits: hits))
        }
        return ControlResponse(ok: false, error: ControlResolve.notFoundMessage(noun: noun, target: target ?? "active"))
    }

    private func sessionResolveError(_ target: String?) -> ControlResponse {
        resolveError("session", target: target, candidates: store.workspaces.flatMap { $0.sessions.map(\.id) })
    }

    /// Open a brand-new window (the New Window palette action).
    func openNewWindow() { openWindow(gLibrary.newWindow().id) }

    func reopenRecentClosed() {
        if library.reopenLatestRecentClosed(into: store) { reconcile() }
    }

    func undoPendingClose() {
        if store.undoPendingClose() { reconcile() }
    }

    /// Keep GTK/libghostty surface ownership intact while agtermCore holds a soft-close record.
    /// The core finalizer tears down the terminal after the grace interval; this later reconcile
    /// removes the now-dead deck page and adapter dictionaries unless the close was undone.
    func reconcileSoftClose(preserving ids: [UUID]) {
        reconcile(preservingSurfaceIDs: Set(ids))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_100_000_000)
            self?.reconcile()
        }
    }

    func closeSessionFromGUI(_ id: UUID) {
        if linuxSettingsStore().load().closeGraceUndoEnabled ?? true {
            if store.softCloseSession(id) { reconcileSoftClose(preserving: [id]) }
        } else {
            closeSession(id)
        }
    }

    func toggleWindowFullscreen() {
        requestWindowFullscreenToggle()
    }

    /// Queue a native fullscreen toggle through the compositor's asynchronous state transition.
    /// A second request while the first is pending flips the desired state but waits for the
    /// `notify::fullscreened` acknowledgement before issuing the inverse GTK call.
    func requestWindowFullscreenToggle() {
        let current = gtk_window_is_fullscreen(WIN(windowPointer)) != 0
        fullscreenDesired = !(fullscreenDesired ?? current)
        driveFullscreenTransition()
    }

    func fullscreenStateDidChange() {
        cancelFullscreenTransitionTimeout()
        fullscreenTransitionInFlight = false
        guard let desired = fullscreenDesired else { return }
        let current = gtk_window_is_fullscreen(WIN(windowPointer)) != 0
        if current == desired {
            fullscreenDesired = nil
        } else {
            driveFullscreenTransition()
        }
    }

    func fullscreenTransitionDidTimeout() {
        fullscreenTransitionTimeout = 0
        fullscreenTransitionInFlight = false
        fullscreenDesired = nil
    }

    func cancelFullscreenTransitionTimeout() {
        if fullscreenTransitionTimeout != 0 {
            g_source_remove(fullscreenTransitionTimeout)
            fullscreenTransitionTimeout = 0
        }
    }

    private func driveFullscreenTransition() {
        guard let desired = fullscreenDesired else { return }
        let current = gtk_window_is_fullscreen(WIN(windowPointer)) != 0
        if current == desired {
            fullscreenDesired = nil
            return
        }
        guard !fullscreenTransitionInFlight else { return }
        fullscreenTransitionInFlight = true
        cancelFullscreenTransitionTimeout()
        fullscreenTransitionTimeout = g_timeout_add(
            3_000,
            onFullscreenTransitionTimeout,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if desired {
            gtk_window_fullscreen(WIN(windowPointer))
        } else {
            gtk_window_unfullscreen(WIN(windowPointer))
        }
    }

    func toggleTerminalZoom() {
        _ = setSurfaceZoom("active", window: windowID.uuidString, mode: .toggle)
    }

    func resolveWorkspace(_ target: String?) -> UUID? {
        guard let target else { return nil }
        let candidates = store.workspaces.map(\.id)
        if case let .resolved(id) = ControlResolve.resolve(target, candidates: candidates, active: store.currentWorkspaceID) { return id }
        return nil
    }

    func activeSurface() -> GhosttySurface? {
        store.selectedSessionID.flatMap { focusedSurface(for: $0) }
    }

    /// The surface of the session's currently FOCUSED pane (the split pane when a split is shown and
    /// focused, else the primary). Font/binding keys target this so they hit the focused pane like the
    /// macOS first responder, rather than always the primary.
    func focusedSurface() -> GhosttySurface? {
        store.selectedSessionID.flatMap { focusedSurface(for: $0) }
    }

    func focusedSurface(for id: UUID) -> GhosttySurface? {
        guard let s = store.session(withID: id) else { return nil }
        return s.splitFocused ? (splitSurfaces[id] ?? surfaces[id]) : surfaces[id]
    }

    func searchTargetSurface(for id: UUID) -> GhosttySurface? {
        guard let s = store.session(withID: id) else { return nil }
        if s.overlayActive, let overlay = overlaySurfaces[id] { return overlay }
        if s.scratchActive, let scratch = scratchSurfaces[id] { return scratch }
        return focusedSurface(for: id)
    }

    var configurableSurfaces: [GhosttySurface] {
        Array(surfaces.values) + Array(splitSurfaces.values) + Array(scratchSurfaces.values)
            + Array(overlaySurfaces.values) + (quickSurface.map { [$0] } ?? [])
    }
}
