import CGtk
import agtermCore

@MainActor
extension AppController {
    /// Build the desktop split as a real GtkPaned so the divider spans the complete window and owns
    /// a native horizontal-resize gesture. The shared store already persists the per-window width.
    func buildSidebarSplit(sidebar: OpaquePointer?, content: OpaquePointer?) -> OpaquePointer {
        guard let sidebar, let content,
              let paned = OpaquePointer(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)) else {
            fatalError("failed to construct sidebar split")
        }
        splitView = paned
        gtk_widget_add_css_class(W(paned), "agterm-sidebar-split")
        gtk_widget_add_css_class(W(sidebar), "agterm-sidebar-column")
        gtk_widget_set_size_request(W(sidebar), Int32(AppStore.sidebarWidthMin), -1)
        gtk_paned_set_start_child(paned, W(sidebar))
        gtk_paned_set_end_child(paned, W(content))
        gtk_paned_set_resize_start_child(paned, 0)
        gtk_paned_set_shrink_start_child(paned, 0)
        gtk_paned_set_resize_end_child(paned, 1)
        gtk_paned_set_shrink_end_child(paned, 1)
        gtk_paned_set_position(paned, Int32(store.sidebarWidth.rounded()))
        gtk_widget_set_visible(W(sidebar), store.sidebarVisible ? 1 : 0)
        connect(paned, "notify::position", unsafeBitCast(onSidebarPanedPosition, to: GCallback.self),
                Unmanaged.passUnretained(self).toOpaque())
        return paned
    }

    func applySidebarVisibility() {
        guard let sidebar = gtk_paned_get_start_child(splitView) else { return }
        gtk_widget_set_visible(sidebar, store.sidebarVisible ? 1 : 0)
        if store.sidebarVisible {
            gtk_paned_set_position(splitView, Int32(store.sidebarWidth.rounded()))
        }
    }

    func captureSidebarWidth(_ paned: OpaquePointer?) {
        guard let paned, store.sidebarVisible else { return }
        let proposed = Double(gtk_paned_get_position(paned))
        let width = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, proposed))
        if proposed != width {
            gtk_paned_set_position(paned, Int32(width.rounded()))
            return
        }
        guard abs(store.sidebarWidth - width) >= 1 else { return }
        store.sidebarWidth = width
        layoutSaveDebouncer.schedule(after: 0.4) { [weak self] in self?.store.save() }
    }
}

private let onSidebarPanedPosition: @convention(c) (
    OpaquePointer?, OpaquePointer?, gpointer?
) -> Void = { paned, _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().captureSidebarWidth(paned)
    }
}
