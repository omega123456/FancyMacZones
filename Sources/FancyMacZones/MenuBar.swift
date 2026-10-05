import AppKit
import UniformTypeIdentifiers

/// The status item and its menu (requirements 18, 19). The menu is built each time it opens (DD-11); the
/// image changes only when trust changes. Plain NSMenu target/action: this app may activate.
final class MenuBar: NSObject, NSMenuDelegate {
    private let store: LayoutStore
    #if DEBUG
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) // room for "DEV"
    #else
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    #endif
    let menu = NSMenu()

    // Seams: tests hide the status item and answer the modal panels and alerts.
    static var showsStatusItem = true
    static var runPanel: (NSSavePanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil }
    static var runAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    var trusted = false { didSet { if trusted != oldValue { updateImage() } } }

    init(store: LayoutStore) {
        self.store = store
        super.init()
        item.isVisible = Self.showsStatusItem
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        #if DEBUG
        item.button?.title = "DEV"
        item.button?.imagePosition = .imageLeading
        #endif
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
        #if DEBUG
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        add("FancyMacZones Dev \(version) (debug)", to: menu).isEnabled = false
        menu.addItem(.separator())
        #endif
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
        add("Export Layouts…", #selector(exportLayouts), to: menu)
        add("Import Layouts…", #selector(importLayouts), to: menu)
        let rules = NSMenu()
        let rule = Settings.overlapRule
        add("Largest Overlap Wins", #selector(chooseRule), to: rules, on: rule == .largestOverlap, object: OverlapRule.largestOverlap.rawValue)
        add("Smallest Zone Wins", #selector(chooseRule), to: rules, on: rule == .smallestArea, object: OverlapRule.smallestArea.rawValue)
        add("Closest Centre Wins", #selector(chooseRule), to: rules, on: rule == .closestCentre, object: OverlapRule.closestCentre.rawValue)
        add("Overlap Rule", to: menu).submenu = rules
        menu.addItem(.separator())

        add("Drag to Top to Maximize", #selector(toggleDragToTop), to: menu, on: Settings.dragToTop)
        add("Double-Click Title Bar to Maximize", #selector(toggleDoubleClickMaximize), to: menu, on: Settings.doubleClickMaximize)
        add("Prevent Mission Control While Dragging", #selector(toggleMissionControl), to: menu, on: Settings.missionControlGuard)
        menu.addItem(.separator())
        add("\(HotKeyModifiers.symbols(Settings.moveModifiers)) ←→↑↓  Move Window to Adjacent Zone", to: menu).isEnabled = false
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

    /// Writes the whole `layouts.json` (custom layouts and per-display assignments) to a file the user picks.
    @objc private func exportLayouts() {
        Env.activate() // DD-12: the app stays an LSUIElement agent
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FancyMacZones Layouts.json"
        guard let url = Self.runPanel(panel) else { return }
        guard LayoutStore.save(store.file, to: url) else { return alert("Export Failed", "Could not write \(url.lastPathComponent).") }
        EventLog.write("menu: exported layouts to \(url.lastPathComponent)")
    }

    /// Replaces every layout and assignment with an exported file, after confirmation. Assignments for
    /// displays that aren't connected are kept and apply when that display is.
    @objc private func importLayouts() {
        Env.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard let url = Self.runPanel(panel) else { return }
        guard let data = try? Data(contentsOf: url), let file = LayoutFile.decode(data) else {
            return alert("Import Failed", "\(url.lastPathComponent) is not a FancyMacZones layouts file.")
        }
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Replace All Layouts?"
        confirm.informativeText = "Your custom layouts and display assignments will be replaced by the \(file.customLayouts.count) custom layouts in \(url.lastPathComponent). This can’t be undone."
        confirm.addButton(withTitle: "Replace").hasDestructiveAction = true
        confirm.addButton(withTitle: "Cancel")
        guard Self.runAlert(confirm) == .alertFirstButtonReturn else { return }
        EventLog.write("menu: imported layouts from \(url.lastPathComponent)")
        store.replaceAll(with: file)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        _ = Self.runAlert(a)
    }

    @objc private func toggleDragToTop() { Settings.dragToTop.toggle() }
    @objc private func toggleDoubleClickMaximize() { Settings.doubleClickMaximize.toggle() }
    @objc private func toggleMissionControl() { Settings.missionControlGuard.toggle() }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
    @objc private func toggleUpdates() { Updater.toggle() }
    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func quit() { Env.terminate() }

    @objc private func openAccessibilitySettings() {
        Env.workspace.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
