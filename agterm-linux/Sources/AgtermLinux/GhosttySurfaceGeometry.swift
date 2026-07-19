enum GhosttySurfaceGeometry {
    struct Size: Equatable {
        let width: UInt32
        let height: UInt32
    }

    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    static func initialBackingSize(gtkWidth: Int32, gtkHeight: Int32, scaleFactor: Int32) -> Size {
        let scale = UInt64(max(1, scaleFactor))
        return Size(
            width: UInt32(clamping: UInt64(max(1, gtkWidth)) * scale),
            height: UInt32(clamping: UInt64(max(1, gtkHeight)) * scale)
        )
    }

    static func resizedViewport(widthPixels: Int32, heightPixels: Int32) -> Size {
        // GtkGLArea::resize reports the physical GL viewport, unlike gtk_widget_get_width/height.
        Size(width: UInt32(max(1, widthPixels)), height: UInt32(max(1, heightPixels)))
    }

    static func pointerPosition(gtkX: Double, gtkY: Double) -> Point {
        // The embedded libghostty API applies its content scale to pointer coordinates internally.
        Point(x: gtkX, y: gtkY)
    }
}
