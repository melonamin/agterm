# Linux terminal selection offset research

## Outcome

The Linux selection offset is caused by inconsistent initial and subsequent terminal surface sizing on
scaled displays.
The pointer path is consistent with Ghostty's GTK frontend and should keep multiplying GTK widget coordinates
by the content scale.
The incorrect path is `GhosttySurface.pushSize()`, which multiplies the GTK widget width and height by that
scale before passing them to `ghostty_surface_set_size`.

On a 2x display, libghostty therefore starts with a surface grid approximately twice the visible height.
A pointer at the middle of the widget maps to the middle of that oversized grid, so the selected row appears
well below the pointer.
The regular `GtkGLArea::resize` path passes width and height through unchanged and should repair the mismatch
after the first real window resize.

## Evidence

- The reported environment is Wayland on a 5120x2880 monitor with `GDK_SCALE=2`.
- GTK event controllers and gestures report positions in the attached widget's coordinate system.
  GTK also documents widget allocation sizes as widget units rather than device pixels.
  See [GTK coordinate systems](https://docs.gtk.org/gtk4/coordinates.html).
- `GtkGLArea::resize` reports viewport width and height and fires once on realization and after realized-size
  changes.
  See [`Gtk.GLArea::resize`](https://docs.gtk.org/gtk4/signal.GLArea.resize.html).
- The pinned Ghostty GTK frontend multiplies pointer coordinates by the widget scale factor, but stores and
  forwards `GtkGLArea::resize` width and height without multiplying them.
  It also initializes the core surface from the first resize specifically to avoid an incorrect PTY size.
  See Ghostty's pinned [`surface.zig`](https://github.com/ghostty-org/ghostty/blob/4dcb09ada0c0909717d92547623b26eafa50ca8a/src/apprt/gtk/class/surface.zig).
- The Linux port currently ignores resize callbacks until `surface` exists, creates the libghostty surface
  from `realize`, and immediately calls `pushSize()` with `gtk_widget_get_width/height * scale`.
- Later Linux resize callbacks pass their dimensions through without scaling.
  The initial and steady-state paths therefore disagree only when the scale factor is greater than one.

## Minimal fix proposal

Make initial sizing use the same units as the resize callback:

1. Remove the scale multiplication from `pushSize()` and pass `gtk_widget_get_width()` and
   `gtk_widget_get_height()` directly to `ghostty_surface_set_size`.
2. Correct the `resize` comment: GTK reports viewport/widget units here, not already-scaled device pixels.
3. Keep `ghostty_surface_set_content_scale` and the pointer-coordinate multiplication unchanged.

The still-closer Ghostty-host design would cache the first resize and initialize the core surface from that
callback.
That is a larger lifecycle change and is unnecessary for the focused correction.

## Regression strategy

- Extract the size conversion into a small host-free Linux helper and unit-test scale 1 and scale 2 to prove
  that initial and resize dimensions remain identical.
- In an isolated app/state/socket instance, drag-select before resizing at scale 2 and verify that the selected
  row remains under the pointer.
- Repeat after resize, at scale 1, and in main, split, scratch, quick, overlay, dashboard, and zoom surfaces.
- Recheck terminal rows/columns through `agtermctl tree --json` or PTY size output so the correction does not
  alter shell geometry unexpectedly.

No selection fix is included in the v0.15.2 parity work until the isolated before/after observation confirms
that a resize currently repairs the offset.
