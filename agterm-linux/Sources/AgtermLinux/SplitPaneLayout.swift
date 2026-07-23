struct SplitPaneLayout: Equatable {
    enum Slot: Equatable {
        case primary
        case split
    }

    let startSlot: Slot
    let endSlot: Slot
    let primaryVisible: Bool
    let splitVisible: Bool

    init(isSplit: Bool, splitFocused: Bool) {
        // Stable slots are the critical GTK invariant: visibility may change, parentage may not.
        startSlot = .primary
        endSlot = .split
        primaryVisible = isSplit || !splitFocused
        splitVisible = isSplit || splitFocused
    }
}
