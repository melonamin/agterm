// Low-level GTK4 C-interop helpers. GTK's GObject types import into Swift as
// distinct typed pointers; these reinterpret a stored OpaquePointer to the type
// a given GTK function expects (GObject pointers are layout-compatible).
import CGtk
import agtermCore

@inline(__always) func W(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkWidget>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GLBR(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkListBoxRow>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GLA(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkGLArea>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func WIN(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkWindow>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func APPW(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func ADWAPP(_ p: OpaquePointer?) -> UnsafeMutablePointer<AdwApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GAPP(_ p: OpaquePointer?) -> UnsafeMutablePointer<GApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GOBJ(_ p: OpaquePointer?) -> UnsafeMutablePointer<GObject>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func POPOVER(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkPopover>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func BUTTON(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkButton>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func RAW(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

/// Normalize a GTK constructor result (which inconsistently imports as optional or
/// non-optional `UnsafeMutablePointer<GtkWidget>`) to the `OpaquePointer?` we store.
@inline(__always) func op(_ p: UnsafeMutablePointer<GtkWidget>?) -> OpaquePointer? { p.map { OpaquePointer($0) } }

/// Connect a GObject signal, passing `data` to the handler's trailing argument.
/// `handler` is a non-capturing `@convention(c)` function cast to `GCallback`.
func connect(_ instance: OpaquePointer?, _ signal: String, _ handler: GCallback?, _ data: UnsafeMutableRawPointer? = nil) {
    signal.withCString { _ = g_signal_connect_data(RAW(instance), $0, handler, data, nil, GConnectFlags(rawValue: 0)) }
}

// GDK modifier bit masks (GdkModifierType).
private let GDK_SHIFT: UInt32 = 1 << 0
private let GDK_CONTROL: UInt32 = 1 << 2
private let GDK_ALT: UInt32 = 1 << 3
private let GDK_SUPER: UInt32 = 1 << 26

/// Translate a GdkModifierType bitfield to ghostty's modifier flags.
func ghosttyMods(_ state: UInt32) -> ghostty_input_mods_e {
    var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if state & GDK_SHIFT != 0 { m |= GHOSTTY_MODS_SHIFT.rawValue }
    if state & GDK_CONTROL != 0 { m |= GHOSTTY_MODS_CTRL.rawValue }
    if state & GDK_ALT != 0 { m |= GHOSTTY_MODS_ALT.rawValue }
    if state & GDK_SUPER != 0 { m |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(rawValue: m)
}

/// Translate a GTK key press (`keyval` + `GdkModifierType state`) into the shared, host-free
/// `agtermCore.Chord` the keymap matcher consumes — or `nil` when the press is not a bindable base key
/// (a bare modifier, Escape, or a function/navigation key with no unicode), so the caller can run its
/// arrow/page fallback or pass the key through to libghostty.
///
/// Mirrors the macOS `NSEvent -> Chord` contract: the base key is the UNSHIFTED, lowercased character
/// (so `Shift+D` yields `key == "d"` with `.shift` in `mods`), and the modifier set is built EXACTLY
/// (CapsLock/NumLock and other bits dropped) because the matcher compares `mods` by OptionSet equality.
func chord(fromKeyval keyval: UInt32, state: UInt32) -> Chord? {
    var mods: Modifier = []
    if state & GDK_CONTROL != 0 { mods.insert(.control) }
    if state & GDK_SHIFT != 0 { mods.insert(.shift) }
    if state & GDK_ALT != 0 { mods.insert(.option) }
    if state & GDK_SUPER != 0 { mods.insert(.command) }

    // The named keys parseKeybind accepts (with their keypad variants); Escape is the leader-abort and
    // is intentionally not a bindable base key.
    switch keyval {
    case 0xFF09: return Chord(mods: mods, key: "tab")
    case 0x20, 0xFF80: return Chord(mods: mods, key: "space")
    case 0xFF0D, 0xFF8D: return Chord(mods: mods, key: "return")
    case 0xFF08, 0xFFFF: return Chord(mods: mods, key: "delete")
    case 0xFF1B: return nil
    default: break
    }

    // GDK reports the shifted symbol as the keyval. Fold the common keyboard pairs back to their base
    // key so `shift+/`, `shift+=`, and `shift+5` match the same keymap vocabulary as macOS.
    let unshiftedKeyval: UInt32
    if mods.contains(.shift) {
        unshiftedKeyval = [
            0x21: 0x31, 0x40: 0x32, 0x23: 0x33, 0x24: 0x34, 0x25: 0x35,
            0x5E: 0x36, 0x26: 0x37, 0x2A: 0x38, 0x28: 0x39, 0x29: 0x30,
            0x5F: 0x2D, 0x2B: 0x3D, 0x7B: 0x5B, 0x7D: 0x5D, 0x7C: 0x5C,
            0x3A: 0x3B, 0x22: 0x27, 0x3C: 0x2C, 0x3E: 0x2E, 0x3F: 0x2F,
            0x7E: 0x60,
        ][keyval] ?? keyval
    } else {
        unshiftedKeyval = keyval
    }
    let u = gdk_keyval_to_unicode(gdk_keyval_to_lower(unshiftedKeyval))
    guard u >= 0x20, u != 0x7F, let scalar = Unicode.Scalar(u) else { return nil }
    let key = String(scalar).lowercased()
    guard key.count == 1, key != " " else { return nil }
    return Chord(mods: mods, key: key)
}
