# X11 / Wayland support matrix

`agterm-linux` is a GTK4 / libadwaita app, so GDK abstracts the display backend. It runs on **both**
Wayland (the native, preferred backend) and X11 (via XWayland or a native X server). GDK auto-selects
Wayland on a Wayland session; force X11 with `GDK_BACKEND=x11 agterm-linux`.

## Matrix

| Behavior | Wayland | X11 | Notes |
|---|:---:|:---:|---|
| Window + chrome (CSD header/footer) | ✅ | ✅ | GTK4 client-side decorations with a full-height native resizable sidebar divider; Hyprland omits client-side window buttons and leaves those actions to compositor bindings |
| GL terminal rendering (GtkGLArea + libghostty) | ✅ | ✅ | **verified** — typed output (`echo X11RENDERTEST`) renders on both; no GL-context errors |
| Control channel (`agtermctl` over the unix socket) | ✅ | ✅ | backend-independent — **verified** (`session.new` / `session.type` reflect on screen under both) |
| Primary selection (copy-on-select, middle-click paste) | ✅ | ✅ | GTK abstracts `wl_primary_selection` (Wayland) / `PRIMARY` (X11); copy-on-select drives the same `ghostty` path on both |
| IME (compose / dead-keys / CJK) | ✅ | ✅ | `GtkIMMulticontext` → the Wayland `text-input` protocol or X11 XIM/ibus — verified on Wayland; X11 routes through the same `imContext` |
| HiDPI scaling | ✅ | ✅ | `gtk_widget_get_scale_factor` (Wayland fractional / X11 `Xft.dpi`); the surface is built at the device scale on both |
| Background translucency | ✅ | ✅ | the app makes the window node transparent + ghostty renders `background-opacity`; the **compositor composites** it on both |
| Background **blur** | compositor | compositor | NOT app-controllable on either — Hyprland (Wayland) / a compositing WM like picom (X11) blurs translucent windows if configured |

## Known deltas

- **Wayland is preferred** (native; no XWayland translation layer). X11 runs through XWayland on a
  Wayland session, which is a compatibility path — fine for everyday use but a layer of indirection.
- **Blur is the compositor's job on both** — there is no app-controllable blur protocol on Wayland, and
  on X11 it depends on a compositing window manager. The app only requests translucency.
- **Window decorations**: GTK4 uses CSD on both. Under Hyprland the header and footer remain, but their
  close/minimize/maximize buttons are omitted to follow the compositor's window-management convention.
  A tiling WM that forces SSD on X11 may draw its own title bar around the CSD.

## Verified

Launch + render (chrome + GL terminal), a control-channel mutation reflecting on screen, zero GL-context
errors, and zero crashes — under both the Wayland backend and `GDK_BACKEND=x11`.
