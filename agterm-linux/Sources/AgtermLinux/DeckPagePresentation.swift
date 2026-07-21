import CGtk

@MainActor
func makeTerminalDeck() -> OpaquePointer {
    guard let deck = OpaquePointer(gtk_overlay_new()),
          let base = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)) else {
        preconditionFailure("GTK failed to allocate the terminal deck")
    }
    gtk_widget_set_hexpand(W(base), 1)
    gtk_widget_set_vexpand(W(base), 1)
    gtk_overlay_set_child(deck, W(base))
    return deck
}

struct DeckPagePresentation: Equatable {
    let childVisible: Bool
    let opacity: Double
    let canTarget: Bool

    init(isActive: Bool, dashboardOpen: Bool) {
        childVisible = isActive || dashboardOpen
        opacity = isActive || dashboardOpen ? 1 : 0
        canTarget = isActive && !dashboardOpen
    }
}
