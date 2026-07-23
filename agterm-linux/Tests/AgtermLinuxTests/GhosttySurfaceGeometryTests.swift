import Testing
@testable import AgtermLinux

@Suite("embedded libghostty surface geometry")
struct GhosttySurfaceGeometryTests {
    @Test("GTK viewport dimensions convert to backing pixels")
    func viewportUsesContentScale() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 1
        ) == .init(width: 960, height: 540))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 2
        ) == .init(width: 1_920, height: 1_080))
    }

    @Test("GtkGLArea resize dimensions are already backing pixels")
    func resizeViewportPassesThrough() {
        #expect(GhosttySurfaceGeometry.resizedViewport(
            widthPixels: 1_920, heightPixels: 1_080
        ) == .init(width: 1_920, height: 1_080))
    }

    @Test("GTK pointer coordinates remain unscaled at the embedded API boundary")
    func pointerStaysInWidgetCoordinates() {
        #expect(GhosttySurfaceGeometry.pointerPosition(
            gtkX: 320.5, gtkY: 180.25
        ) == .init(x: 320.5, y: 180.25))
    }

    @Test("non-positive viewport inputs clamp to one")
    func clampsNonPositiveDimensionsAndScale() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: -12, scaleFactor: 0
        ) == .init(width: 1, height: 1))
        #expect(GhosttySurfaceGeometry.resizedViewport(
            widthPixels: 0, heightPixels: -12
        ) == .init(width: 1, height: 1))
    }
}
