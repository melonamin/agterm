// Preferences (AdwPreferencesDialog): a thin GTK surface over the shared agtermCore.AppSettings model.
// Each control mutates AppSettings, persists via SettingsStore, and applies — ghostty-backed keys
// (copy-on-select, scroll speed) rebuild the config + reload live surfaces; app-level keys
// (notification banners) take effect through the live SettingsStore read. The settings MODEL,
// persistence, and ghostty-line emission all live host-free in agtermCore; this is platform glue only.
import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func showSettings() {
        let s = SettingsStore().load()
        let dialog = OpaquePointer(adw_preferences_dialog_new())
        "preferences".withCString { gtk_widget_set_name(W(dialog), $0) }   // automation id
        let page = OpaquePointer(adw_preferences_page_new())
        let group = OpaquePointer(adw_preferences_group_new())
        "General".withCString { adw_preferences_page_set_title(cast(page), $0) }
        "General".withCString { adw_preferences_group_set_title(cast(group), $0) }

        let copyRow = OpaquePointer(adw_switch_row_new())
        "Copy on select".withCString { adw_preferences_row_set_title(cast(copyRow), $0) }
        adw_switch_row_set_active(copyRow, s.copyOnSelect == true ? 1 : 0)
        connect(copyRow, "notify::active", unsafeBitCast(onCopyOnSelectToggled as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(copyRow))

        let bannerRow = OpaquePointer(adw_switch_row_new())
        "Notification banners".withCString { adw_preferences_row_set_title(cast(bannerRow), $0) }
        adw_switch_row_set_active(bannerRow, (s.notificationsEnabled ?? true) ? 1 : 0)
        connect(bannerRow, "notify::active", unsafeBitCast(onBannersToggled as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(bannerRow))

        let badgeRow = OpaquePointer(adw_switch_row_new())
        "Notification badge".withCString { adw_preferences_row_set_title(cast(badgeRow), $0) }
        adw_switch_row_set_active(badgeRow, (s.notificationBadgeEnabled ?? true) ? 1 : 0)
        connect(badgeRow, "notify::active", unsafeBitCast(onBadgeToggled as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(badgeRow))

        let attentionRow = OpaquePointer(adw_switch_row_new())
        "Show attention indicator".withCString { adw_preferences_row_set_title(cast(attentionRow), $0) }
        adw_switch_row_set_active(attentionRow, (s.attentionButtonEnabled ?? false) ? 1 : 0)
        connect(attentionRow, "notify::active", unsafeBitCast(onAttentionButtonToggled as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(attentionRow))

        let compactRow = OpaquePointer(adw_switch_row_new())
        "Compact toolbar".withCString { adw_preferences_row_set_title(cast(compactRow), $0) }
        adw_switch_row_set_active(compactRow, (s.compactToolbar ?? true) ? 1 : 0)
        connect(compactRow, "notify::active", unsafeBitCast(onCompactToolbarToggled as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(compactRow))

        let restoreRow = OpaquePointer(adw_switch_row_new())
        "Restore running command".withCString { adw_preferences_row_set_title(cast(restoreRow), $0) }
        "Re-run each pane's foreground command on the next launch".withCString { adw_action_row_set_subtitle(cast(restoreRow), $0) }
        adw_switch_row_set_active(restoreRow, (s.restoreRunningCommand ?? false) ? 1 : 0)
        connect(restoreRow, "notify::active", unsafeBitCast(onRestoreToggled as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(restoreRow))

        let scrollRow = OpaquePointer(adw_spin_row_new_with_range(1, 10, 1))
        "Scroll speed".withCString { adw_preferences_row_set_title(cast(scrollRow), $0) }
        adw_spin_row_set_value(scrollRow, s.mouseScrollMultiplier ?? 3)
        connect(scrollRow, "notify::value", unsafeBitCast(onScrollSpeedChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group), W(scrollRow))

        adw_preferences_page_add(cast(page), cast(group))
        adw_preferences_dialog_add(cast(dialog), cast(page))

        // Appearance page: font size (theme + opacity controls to follow).
        let page2 = OpaquePointer(adw_preferences_page_new())
        "Appearance".withCString { adw_preferences_page_set_title(cast(page2), $0) }
        let group2 = OpaquePointer(adw_preferences_group_new())
        let fontRow = OpaquePointer(adw_spin_row_new_with_range(8, 32, 1))
        "Font size".withCString { adw_preferences_row_set_title(cast(fontRow), $0) }
        adw_spin_row_set_value(fontRow, s.fontSize ?? 13)
        connect(fontRow, "notify::value", unsafeBitCast(onFontSizeChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group2), W(fontRow))

        // Font family: a searchable combo over the installed monospace fonts (Pango enumeration).
        let fonts = monospaceFonts()
        if !fonts.isEmpty {
            let fmodel = gtk_string_list_new(nil)
            for f in fonts { f.withCString { gtk_string_list_append(fmodel, $0) } }
            let fontFamilyRow = OpaquePointer(adw_combo_row_new())
            "Font".withCString { adw_preferences_row_set_title(cast(fontFamilyRow), $0) }
            adw_combo_row_set_model(cast(fontFamilyRow), fmodel)
            "string".withCString { prop in
                let expr = gtk_property_expression_new(gtk_string_object_get_type(), nil, prop)
                adw_combo_row_set_expression(cast(fontFamilyRow), expr)
            }
            adw_combo_row_set_enable_search(cast(fontFamilyRow), 1)
            if let cur = s.fontFamily, let idx = fonts.firstIndex(of: cur) { adw_combo_row_set_selected(cast(fontFamilyRow), UInt32(idx)) }
            connect(fontFamilyRow, "notify::selected", unsafeBitCast(onFontFamilyChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
            adw_preferences_group_add(cast(group2), W(fontFamilyRow))
        }

        // Background opacity: terminal translucency (the compositor blurs it if configured). 100% = opaque.
        let opacityRow = OpaquePointer(adw_spin_row_new_with_range(30, 100, 5))
        "Background opacity".withCString { adw_preferences_row_set_title(cast(opacityRow), $0) }
        "Terminal translucency — the Wayland compositor blurs it if configured".withCString { adw_action_row_set_subtitle(cast(opacityRow), $0) }
        adw_spin_row_set_value(opacityRow, (s.backgroundOpacity ?? 1) * 100)
        connect(opacityRow, "notify::value", unsafeBitCast(onBackgroundOpacityChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group2), W(opacityRow))

        // Sidebar tint: 0..10, 5 = neutral (sidebar matches the terminal), <5 lighter, >5 darker.
        let tintRow = OpaquePointer(adw_spin_row_new_with_range(0, 10, 1))
        "Sidebar tint".withCString { adw_preferences_row_set_title(cast(tintRow), $0) }
        adw_spin_row_set_value(tintRow, Double(s.sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift))
        connect(tintRow, "notify::value", unsafeBitCast(onSidebarTintChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group2), W(tintRow))

        // Theme: a searchable combo over the bundled ghostty themes (shared bundledThemes listing).
        let themes = Self.bundledThemes()
        if !themes.isEmpty {
            let model = gtk_string_list_new(nil)
            for t in themes { t.withCString { gtk_string_list_append(model, $0) } }
            let themeRow = OpaquePointer(adw_combo_row_new())
            "Theme".withCString { adw_preferences_row_set_title(cast(themeRow), $0) }
            adw_combo_row_set_model(cast(themeRow), model)
            // AdwComboRow needs an expression to render + search GtkStringList items; without it the row
            // shows the GObject repr ("0x…") and search is dead. Read each item's `string` property.
            "string".withCString { prop in
                let expr = gtk_property_expression_new(gtk_string_object_get_type(), nil, prop)
                adw_combo_row_set_expression(cast(themeRow), expr)
            }
            adw_combo_row_set_enable_search(cast(themeRow), 1)
            if let cur = s.theme, let idx = themes.firstIndex(of: cur) { adw_combo_row_set_selected(cast(themeRow), UInt32(idx)) }
            connect(themeRow, "notify::selected", unsafeBitCast(onThemeChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
            adw_preferences_group_add(cast(group2), W(themeRow))
        }

        // Agent status glyph colors: a color button per status (the current value, default = Adwaita).
        let statusGroup = OpaquePointer(adw_preferences_group_new())
        "Agent Status".withCString { adw_preferences_group_set_title(cast(statusGroup), $0) }
        addStatusColorRow(statusGroup, "Active", s.activeStatusColorHex ?? "#3584e4",
                          unsafeBitCast(onActiveColorChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        addStatusColorRow(statusGroup, "Blocked", s.blockedStatusColorHex ?? "#e5a50a",
                          unsafeBitCast(onBlockedColorChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        addStatusColorRow(statusGroup, "Completed", s.completedStatusColorHex ?? "#2ec27e",
                          unsafeBitCast(onCompletedColorChanged as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))

        adw_preferences_page_add(cast(page2), cast(group2))
        adw_preferences_page_add(cast(page2), cast(statusGroup))
        adw_preferences_dialog_add(cast(dialog), cast(page2))

        // Key Mapping page: the config directory holding keymap.conf + a reload action.
        let page3 = OpaquePointer(adw_preferences_page_new())
        "Key Mapping".withCString { adw_preferences_page_set_title(cast(page3), $0) }
        let group3 = OpaquePointer(adw_preferences_group_new())
        let dirRow = OpaquePointer(adw_action_row_new())
        "Config directory".withCString { adw_preferences_row_set_title(cast(dirRow), $0) }
        configDirectory().path.withCString { adw_action_row_set_subtitle(cast(dirRow), $0) }
        adw_preferences_group_add(cast(group3), W(dirRow))
        let reloadRow = OpaquePointer(adw_action_row_new())
        "Reload Keymap".withCString { adw_preferences_row_set_title(cast(reloadRow), $0) }
        connect(reloadRow, "activated", unsafeBitCast(onReloadKeymapRow as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_preferences_group_add(cast(group3), W(reloadRow))
        adw_preferences_page_add(cast(page3), cast(group3))
        adw_preferences_dialog_add(cast(dialog), cast(page3))

        adw_dialog_present(cast(dialog), W(windowPointer))
    }

    /// Load → set one field → save: the shared `SettingsStore` round-trip every setter funnels through, so
    /// the persistence path lives in ONE place (the rest of each setter is just its apply side effect).
    private func persist<V>(_ keyPath: WritableKeyPath<AppSettings, V>, _ value: V) {
        var s = SettingsStore().load()
        s[keyPath: keyPath] = value
        try? SettingsStore().save(s)
    }

    /// copy-on-select is a ghostty key → persist + rebuild the config + apply to live surfaces.
    /// compact-toolbar is app chrome (not ghostty); compact is the default → ON maps back to nil. Re-applies
    /// the footer padding on every open window (the setting is global).
    func setCompactToolbar(_ on: Bool) {
        persist(\.compactToolbar, on ? nil : false)
        for ctl in gWindows.values { ctl.applyCompactToolbar() }
    }

    /// restore-running-command is an app-level key (read at quit-capture + launch-restore); no surface
    /// reload. Off (false) maps back to nil to keep settings.json minimal.
    func setRestoreRunningCommand(_ on: Bool) {
        persist(\.restoreRunningCommand, on ? true : nil)
    }

    func setCopyOnSelect(_ on: Bool) {
        persist(\.copyOnSelect, on)
        reloadConfig()
    }

    /// the banner toggle is read live by NotificationManager.bannersEnabled → persist only.
    func setNotificationsEnabled(_ on: Bool) {
        persist(\.notificationsEnabled, on)
    }

    /// the badge toggle gates the sidebar unseen-count pill → persist + re-render the rows.
    func setNotificationBadge(_ on: Bool) {
        persist(\.notificationBadgeEnabled, on)
        for ctl in gWindows.values {
            ctl.badgeEnabled = on
            ctl.rebuildSidebar()
        }
    }

    /// optional title-bar attention indicator; default off maps back to nil like macOS.
    func setAttentionButtonEnabled(_ on: Bool) {
        persist(\.attentionButtonEnabled, on ? true : nil)
        for ctl in gWindows.values { ctl.updateAttentionButton() }
    }

    /// font size is a ghostty key → persist + rebuild + apply (resets per-session zoom, like macOS).
    func setFontSize(_ v: Double) {
        persist(\.fontSize, v)
        reloadConfig()
        library.resetSessionFontSizesAllWindows()
    }

    /// scroll multiplier is a ghostty key; 3 is the default → map it back to nil to keep settings.json minimal.
    func setScrollSpeed(_ v: Double) {
        persist(\.mouseScrollMultiplier, v == 3 ? nil : v)
        reloadConfig()
    }

    /// One AdwActionRow + a GtkColorDialogButton showing/editing a status glyph color.
    private func addStatusColorRow(_ group: OpaquePointer?, _ title: String, _ hex: String, _ handler: GCallback?) {
        let btn = OpaquePointer(gtk_color_dialog_button_new(gtk_color_dialog_new()))
        var rgba = GdkRGBA()
        hex.withCString { _ = gdk_rgba_parse(&rgba, $0) }
        gtk_color_dialog_button_set_rgba(btn, &rgba)
        gtk_widget_set_valign(W(btn), GTK_ALIGN_CENTER)
        connect(btn, "notify::rgba", handler)
        let row = OpaquePointer(adw_action_row_new())
        title.withCString { adw_preferences_row_set_title(cast(row), $0) }
        adw_action_row_add_suffix(cast(row), W(btn))
        adw_preferences_group_add(cast(group), W(row))
    }

    enum StatusColorKind { case active, blocked, completed }
    /// A status color button changed → read its rgba, persist the hex, re-apply the status CSS (the live
    /// glyphs re-color via the reloaded provider — no per-row sweep needed, unlike macOS).
    func setStatusColor(_ kind: StatusColorKind, fromButton btn: OpaquePointer?) {
        guard let btn, let rgba = gtk_color_dialog_button_get_rgba(btn) else { return }
        let hex = String(format: "#%02X%02X%02X",
                         Int((rgba.pointee.red * 255).rounded()),
                         Int((rgba.pointee.green * 255).rounded()),
                         Int((rgba.pointee.blue * 255).rounded()))
        switch kind {
        case .active: persist(\.activeStatusColorHex, hex)
        case .blocked: persist(\.blockedStatusColorHex, hex)
        case .completed: persist(\.completedStatusColorHex, hex)
        }
        installStatusColorCSS()
    }

    /// background opacity: re-emit `background-opacity` to ghostty (reloadConfig) AND toggle the window's
    /// transparent class so the alpha reaches the compositor. 100% maps back to nil (opaque, the default).
    func setBackgroundOpacity(_ percent: Double) {
        persist(\.backgroundOpacity, percent >= 100 ? nil : percent / 100)
        reloadConfig()
        for ctl in gWindows.values { ctl.applyWindowTranslucency() }
    }

    /// sidebar tint is an app-level key (not ghostty); 5 is neutral → map back to nil. Re-applies only the
    /// sidebar CSS (no surface reload — it's purely chrome).
    func setSidebarTint(_ v: Double) {
        let strength = Int(v)
        persist(\.sidebarBackgroundShift, strength == AppSettings.defaultSidebarBackgroundShift ? nil : strength)
        applySidebarThemeColor()
    }

    /// theme combo selection → apply the bundled theme at `idx` (persists + rebuilds + reloads surfaces).
    /// Font family combo → persist + rebuild + apply (a ghostty key, like font size).
    func setFontFamilyAtIndex(_ idx: Int) {
        let fonts = monospaceFonts()
        guard idx >= 0, idx < fonts.count else { return }
        persist(\.fontFamily, fonts[idx])
        reloadConfig()
    }

    func applyThemeAtIndex(_ idx: Int) {
        let themes = Self.bundledThemes()
        guard idx >= 0, idx < themes.count else { return }
        applyTheme(themes[idx])
    }
}

private let onCopyOnSelectToggled: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setCopyOnSelect(adw_switch_row_get_active(row) != 0) }
}
private let onRestoreToggled: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setRestoreRunningCommand(adw_switch_row_get_active(row) != 0) }
}
private let onCompactToolbarToggled: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setCompactToolbar(adw_switch_row_get_active(row) != 0) }
}
private let onBannersToggled: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setNotificationsEnabled(adw_switch_row_get_active(row) != 0) }
}
private let onBadgeToggled: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setNotificationBadge(adw_switch_row_get_active(row) != 0) }
}
private let onAttentionButtonToggled: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setAttentionButtonEnabled(adw_switch_row_get_active(row) != 0) }
}
private let onReloadKeymapRow: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { _ = gController?.reloadKeymapDiagnostics() }
}
private let onFontSizeChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setFontSize(adw_spin_row_get_value(row)) }
}
private let onSidebarTintChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setSidebarTint(adw_spin_row_get_value(row)) }
}
private let onBackgroundOpacityChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setBackgroundOpacity(adw_spin_row_get_value(row)) }
}
private let onActiveColorChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { btn, _, _ in
    MainActor.assumeIsolated { gController?.setStatusColor(.active, fromButton: btn) }
}
private let onBlockedColorChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { btn, _, _ in
    MainActor.assumeIsolated { gController?.setStatusColor(.blocked, fromButton: btn) }
}
private let onCompletedColorChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { btn, _, _ in
    MainActor.assumeIsolated { gController?.setStatusColor(.completed, fromButton: btn) }
}
private let onScrollSpeedChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setScrollSpeed(adw_spin_row_get_value(row)) }
}
private let onThemeChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.applyThemeAtIndex(Int(adw_combo_row_get_selected(cast(row)))) }
}
private let onFontFamilyChanged: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { gController?.setFontFamilyAtIndex(Int(adw_combo_row_get_selected(cast(row)))) }
}
