import Testing
@testable import AgtermLinux

@Suite("Linux split-pane layout")
struct SplitPaneLayoutTests {
    @Test("both renderers keep stable slots through every visibility state")
    func stableSlots() {
        let cases = [
            (isSplit: true, splitFocused: false, primaryVisible: true, splitVisible: true),
            (isSplit: true, splitFocused: true, primaryVisible: true, splitVisible: true),
            (isSplit: false, splitFocused: false, primaryVisible: true, splitVisible: false),
            (isSplit: false, splitFocused: true, primaryVisible: false, splitVisible: true),
        ]

        for item in cases {
            let layout = SplitPaneLayout(isSplit: item.isSplit, splitFocused: item.splitFocused)

            #expect(layout.startSlot == .primary)
            #expect(layout.endSlot == .split)
            #expect(layout.primaryVisible == item.primaryVisible)
            #expect(layout.splitVisible == item.splitVisible)
        }
    }
}
