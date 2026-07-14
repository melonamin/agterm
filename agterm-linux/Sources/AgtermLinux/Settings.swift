// Linux window-level settings application.
// Preferences construction and mutations are split across Settings*Page.swift and
// LinuxSettingsController.swift so the GTK adapter stays reviewable.
import CGtk
import agtermCore

@MainActor
extension AppController {
    func applyToolbarMode() {
        let mode = linuxSettingsStore().load().effectiveToolbarMode
        let visible: gboolean = mode == .hidden ? 0 : 1
        if let sidebarHeader { gtk_widget_set_visible(W(sidebarHeader), visible) }
        if let contentHeader { gtk_widget_set_visible(W(contentHeader), visible) }
        if let bar = bottomBar {
            let padding: Int32 = mode == .normal ? 14 : 4
            gtk_widget_set_margin_top(W(bar), padding)
            gtk_widget_set_margin_bottom(W(bar), padding)
        }
    }

    func applyWindowTranslucency(settings: AppSettings? = nil) {
        let translucent = ((settings ?? linuxSettingsStore().load()).backgroundOpacity ?? 1) < 1
        "agterm-translucent".withCString {
            if translucent {
                gtk_widget_add_css_class(W(window), $0)
            } else {
                gtk_widget_remove_css_class(W(window), $0)
            }
        }
    }
}
