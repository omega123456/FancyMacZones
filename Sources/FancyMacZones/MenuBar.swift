import AppKit

/// The status item and its menu (requirements 18, 19). The menu is built each time it opens (DD-11); the
/// image changes only when trust changes. Plain NSMenu target/action: this app may activate.
final class MenuBar: NSObject, NSMenuDelegate {
    private let store: LayoutStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    var trusted = false { didSet { if trusted != oldValue { updateImage() } } }

    init(store: LayoutStore) {
        self.store = store
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateImage()
    }

    private func updateImage() {
        let name = trusted ? "rectangle.split.2x2" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FancyMacZones")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if trusted { buildTrusted() } else { buildUntrusted() }
    }

    // MARK: Building

    private func buildTrusted() {
        let displays = store.displays
        if displays.count == 1 { // requirement 19: collapsed single-display row
            add("Layout — \(store.layoutName(on: displays[0]))", to: menu).submenu = layoutMenu(displays[0])
        } else {
            for d in displays { add("\(d.name) — \(store.layoutName(on: d))", to: menu).submenu = layoutMenu(d) }
        }
        if !displays.isEmpty { menu.addItem(.separator()) }

        add("Edit Layouts…", #selector(editLayouts), to: menu) // requirement 18: before "Overlap Rule"
        let rules = NSMenu()
        let rule = Settings.overlapRule
        add("Smallest Zone Wins", #selector(chooseRule), to: rules, on: rule == .smallestArea, object: OverlapRule.smallestArea.rawValue)
        add("Closest Centre Wins", #selector(chooseRule), to: rules, on: rule == .closestCentre, object: OverlapRule.closestCentre.rawValue)
        add("Overlap Rule", to: menu).submenu = rules
        menu.addItem(.separator())

        add("Drag to Top to Maximize", #selector(toggleDragToTop), to: menu, on: Settings.dragToTop)
        add("Prevent Mission Control While Dragging", #selector(toggleMissionControl), to: menu, on: Settings.missionControlGuard)
        menu.addItem(.separator())
        add("⌃⌘ ←→↑↓  Move Window to Adjacent Zone", to: menu).isEnabled = false
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLaunchAtLogin), to: menu, on: LaunchAtLogin.isEnabled)
        add("Automatic Updates", #selector(toggleUpdates), to: menu, on: Updater.isEnabled)
        add("Check for Updates…", #selector(checkForUpdates), to: menu)
        menu.addItem(.separator())
        add("Quit FancyMacZones", #selector(quit), to: menu)
    }

    private func buildUntrusted() {
        add("Accessibility Access Needed", to: menu).isEnabled = false
        add("FancyMacZones needs this to move windows.", to: menu).isEnabled = false
        add("Open Accessibility Settings…", #selector(openAccessibilitySettings), to: menu)
        menu.addItem(.separator())
        add("Quit FancyMacZones", #selector(quit), to: menu)
    }

    /// Blank | Focus … Priority Grid | custom layouts by name (the custom section only when there are any).
    private func layoutMenu(_ d: LayoutStore.Display) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = store.layout(on: d)
        func choice(_ title: String, _ ref: LayoutRef) {
            add(title, #selector(chooseLayout), to: sub, on: current == ref, object: Choice(display: d, layout: ref))
        }
        choice(TemplateKind.blank.title, .template(.blank))
        sub.addItem(.separator())
        for kind in TemplateKind.allCases where kind != .blank { choice(kind.title, .template(kind)) }
        let customs = store.customLayouts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !customs.isEmpty { sub.addItem(.separator()) }
        for c in customs { choice(c.name, .custom(c.id)) }
        return sub
    }

    private struct Choice {
        let display: LayoutStore.Display
        let layout: LayoutRef
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, to menu: NSMenu, on: Bool = false, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.state = on ? .on : .off
        item.representedObject = object
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? Choice else { return }
        EventLog.write("menu: \(c.display.name) → \(c.layout)")
        store.assign(c.layout, to: c.display)
    }

    @objc private func chooseRule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let rule = OverlapRule(rawValue: raw) else { return }
        Settings.overlapRule = rule
    }

    /// Opens the Edit Layouts window, or brings the open one to the front (DD-12).
    @objc private func editLayouts() { EditorWindow.show(store: store) }

    @objc private func toggleDragToTop() { Settings.dragToTop.toggle() }
    @objc private func toggleMissionControl() { Settings.missionControlGuard.toggle() }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
    @objc private func toggleUpdates() { Updater.toggle() }
    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
