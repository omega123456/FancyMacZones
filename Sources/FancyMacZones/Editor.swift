import AppKit

/// The Edit Layouts window (requirement 26, UI/UX Wireframes → Edit Layouts window): a display sidebar, the
/// template and custom galleries, the Zones stepper and the custom-layout actions. Created on demand and released
/// when closed (DD-12); a single instance. Every action is one store commit (requirement 29).
final class EditorWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate,
                          NSTextFieldDelegate {
    static var shared: EditorWindow?
    private static var menuInstalled = false
    /// Seam: tests use a window that is never moved onto a real display.
    static var windowClass = NSWindow.self
    /// Seam: tests answer the rename and delete sheets.
    static var runSheet: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }

    private let store: LayoutStore
    let window: NSWindow
    private let table = NSTableView()
    private let gallery = GalleryScrollView()
    private let content = FlippedView()
    private let templatesCaption = EditorWindow.caption("Templates")
    private let customCaption = EditorWindow.caption("Custom")
    private let zonesLabel = NSTextField(labelWithString: "Zones")
    private let zonesField = NSTextField()
    private let zonesStepper = ArrowStepper()
    private let zonesBox = BorderedView()
    private let zonesCaption = NSTextField(labelWithString: "")
    private let shortcutRecorder = ModifierRecorder()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var actionButtons: [NSButton] = []
    private var templateCards: [LayoutCard] = []
    private var customCards: [LayoutCard] = []
    private var displays: [LayoutStore.Display] = []
    private var selectedUUID: String?
    private var session: ZoneEditorSession?
    private var reloadPending = false

    /// "Edit Layouts…": opens the window, or brings the existing one (or a running full-screen session) to the front.
    static func show(store: LayoutStore) {
        if !menuInstalled { installMainMenu() }
        let editor = shared ?? EditorWindow(store: store)
        shared = editor
        if let session = editor.session { session.show() } else { editor.window.makeKeyAndOrderFront(nil) }
        Env.activate() // DD-12: the app stays an LSUIElement agent
    }

    private init(store: LayoutStore) {
        self.store = store
        window = Self.windowClass.init(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = "Edit Layouts"
        window.contentMinSize = CGSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let main = Env.screens().first?.visibleFrame { // centred on the main display
            let size = window.frame.size
            window.setFrameOrigin(CGPoint(x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded()))
        }
        buildToolbar()
        buildContent()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(storeChanged), name: LayoutStore.didChange, object: store)
        nc.addObserver(self, selector: #selector(displaysChanged), name: LayoutStore.displaysDidChange, object: store)
        // DD-12 / DD-15: thumbnails follow the accent colour and the accessibility display options.
        nc.addObserver(self, selector: #selector(storeChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
        Env.workspace.notificationCenter.addObserver(self, selector: #selector(storeChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        reload()
        EventLog.write("editor: opened")
    }

    deinit { Env.workspace.notificationCenter.removeObserver(self) }

    func windowWillClose(_ notification: Notification) {
        EventLog.write("editor: closed")
        // Released on the next turn: the close may come from inside a card's mouseDown (double-click).
        DispatchQueue.main.async { if Self.shared === self { Self.shared = nil } }
    }

    // MARK: Hidden main menu (DD-12)

    /// Edit (Undo, Redo, Cut, Copy, Paste, Select All) and Window (Close), so the standard key equivalents work
    /// in the sheets' text fields and the full-screen editors. Never shown: the app is an LSUIElement agent.
    private static func installMainMenu() {
        menuInstalled = true
        let main = NSMenu()
        func item(_ title: String, _ action: String, _ key: String, _ flags: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        submenu("FancyMacZones", []) // item 0 is always the application menu
        submenu("Edit", [item("Undo", "undo:", "z"), item("Redo", "redo:", "z", [.command, .shift]), .separator(),
                         item("Cut", "cut:", "x"), item("Copy", "copy:", "c"), item("Paste", "paste:", "v"),
                         item("Select All", "selectAll:", "a")])
        submenu("Window", [item("Close", "performClose:", "w")])
        NSApp.mainMenu = main
    }

    // MARK: Building

    private static func caption(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.textColor = .secondaryLabelColor
        return f
    }

    private static func button(_ title: String, symbol: String?, _ action: Selector, target: AnyObject) -> NSButton {
        ToolButton(title, symbol: symbol, target: target, action: action)
    }

    private static let toolbarItem = NSToolbarItem.Identifier("newLayout")

    /// New Grid Layout and New Canvas Layout at the trailing end of a unified title bar, with the title leading
    /// (wireframe and visual reference).
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "EditLayouts")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.toolbarItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.toolbarItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let stack = NSStackView(views: [Self.button("New Grid Layout", symbol: "plus", #selector(newGrid), target: self),
                                        Self.button("New Canvas Layout", symbol: "plus", #selector(newCanvas), target: self)])
        stack.spacing = 6
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = stack
        item.isBordered = false
        return item
    }

    private func buildContent() {
        // Sidebar: 180 pt, a solid fill, the "Displays" caption, then one row per display with an accent selection.
        let column = NSTableColumn(identifier: .init("display"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = CGSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = true
        table.setAccessibilityLabel("Displays")
        table.dataSource = self
        table.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = table
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        let sideCaption = NSTextField(labelWithString: "Displays")
        sideCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        sideCaption.textColor = .secondaryLabelColor
        let sidebar = FillView(color: .tertiarySystemFill)
        for v in [sideCaption, sideScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }

        // Gallery: cards flow inside a flipped document view with 14 pt padding.
        gallery.documentView = content
        gallery.hasVerticalScroller = true
        gallery.drawsBackground = false
        gallery.onTile = { [weak self] in self?.arrange() }
        // Zones: the label, then one bordered box holding the number and the ▲▼ arrows, then the caption.
        zonesLabel.font = .systemFont(ofSize: 13)
        zonesField.formatter = { let f = NumberFormatter(); f.allowsFloats = false; return f }()
        zonesField.isBordered = false
        zonesField.drawsBackground = false
        zonesField.focusRingType = .none
        zonesField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        zonesField.alignment = .center
        zonesField.target = self
        zonesField.action = #selector(zoneCountEdited)
        zonesField.delegate = self
        zonesField.setAccessibilityLabel("Zones")
        zonesStepper.target = self
        zonesStepper.action = #selector(zoneCountStepped)
        zonesStepper.setAccessibilityLabel("Zones")
        zonesBox.addSubview(zonesField)
        zonesBox.addSubview(zonesStepper)
        zonesCaption.font = .systemFont(ofSize: 12)
        zonesCaption.textColor = .secondaryLabelColor
        actionButtons = [Self.button("Edit", symbol: "pencil", #selector(editSelected), target: self),
                         Self.button("Rename", symbol: nil, #selector(renameSelected), target: self),
                         Self.button("Duplicate", symbol: "doc.on.doc", #selector(duplicateSelected), target: self),
                         Self.button("Delete", symbol: "trash", #selector(deleteSelected), target: self)]
        for v in [templatesCaption, customCaption, zonesLabel, zonesBox, zonesCaption] + actionButtons {
            content.addSubview(v)
        }

        // Footer: a hairline and the hint text, 12 pt secondary.
        let rule = NSBox()
        rule.boxType = .separator
        // Shortcut row: the recorded modifiers, then the fixed arrows (requirement 14, ADR 7c41d0a2).
        shortcutRecorder.onChange = { [weak self] in self?.updateFooter() }
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Move to adjacent zone:"), shortcutRecorder,
                                              NSTextField(labelWithString: "+ ←→↑↓")])
        shortcutRow.spacing = 6
        updateFooter()
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator
        // A separator box hugs its small intrinsic size; above the window's stay-put priority it would shrink the window.
        divider.setContentHuggingPriority(.defaultLow, for: .vertical)
        rule.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = FillView(color: .controlBackgroundColor) // white, or the dark window colour
        root.frame = CGRect(x: 0, y: 0, width: 760, height: 520)
        for v in [sidebar, divider, gallery, rule, shortcutRow, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rule.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 180),
            // 10 pt top padding plus the caption's own 4 pt, both 8 pt in from the sidebar's padding.
            sideCaption.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sideCaption.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 14),
            sideScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sideScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sideScroll.topAnchor.constraint(equalTo: sideCaption.bottomAnchor, constant: 6),
            sideScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rule.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            gallery.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            gallery.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gallery.topAnchor.constraint(equalTo: root.topAnchor),
            gallery.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            shortcutRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            shortcutRow.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            footer.topAnchor.constraint(equalTo: shortcutRow.bottomAnchor, constant: 6),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
    }

    private func updateFooter() {
        footer.stringValue = "Drag a window and right-click to show zones · \(HotKeyModifiers.symbols(Settings.moveModifiers)) ←→↑↓ "
            + "moves the focused window to the adjacent zone · Drag to the top edge to maximize"
    }

    // MARK: Refreshing

    @objc private func storeChanged() { scheduleReload() }

    @objc private func displaysChanged() {
        session?.finish() // the target display's geometry is gone or changed: commit what was edited
        scheduleReload()
    }

    /// Coalesced to the next turn, so a card or control is never torn down inside its own event handler.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    private var selectedDisplay: LayoutStore.Display? {
        displays.first { $0.uuid == selectedUUID } ?? displays.first
    }

    private func reload() {
        reloadPending = false
        displays = store.displays
        table.reloadData()
        if let i = displays.firstIndex(where: { $0.uuid == selectedDisplay?.uuid }) {
            selectedUUID = displays[i].uuid
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        rebuildCards()
    }

    private func rebuildCards() {
        (templateCards + customCards).forEach { $0.removeFromSuperview() }
        templateCards = []
        customCards = []
        guard let d = selectedDisplay else { arrange(); return }
        let current = store.layout(on: d)
        let aspect = d.usable.size
        for kind in TemplateKind.allCases {
            let ref = LayoutRef.template(kind)
            templateCards.append(card(ref, kind.title, activeOn: nil, zones: kind.zones(count: store.zoneCount(kind, on: d)),
                                      blank: kind == .blank, aspect: aspect, selected: current == ref, display: d))
        }
        for layout in store.customLayouts {
            let ref = LayoutRef.custom(layout.id)
            let users = store.displays(using: layout.id)
            let activeOn = users.count > 1 ? "Active on: " + users.map(\.name).joined(separator: ", ") : nil
            let c = card(ref, layout.name, activeOn: activeOn, zones: layout.zones, blank: false, aspect: aspect,
                         selected: current == ref, display: d)
            c.menu = cardMenu(layout.id)
            customCards.append(c)
        }
        (templateCards + customCards).forEach { content.addSubview($0) }

        // Zones stepper: only for a selected template other than Blank (requirement 26), with its R-2 range.
        if case .template(let kind) = current, kind != .blank {
            let n = store.zoneCount(kind, on: d)
            zonesStepper.minValue = Double(kind.range.lowerBound)
            zonesStepper.maxValue = Double(kind.range.upperBound)
            zonesStepper.integerValue = n
            zonesField.integerValue = n
            zonesCaption.stringValue = "\(kind.title) on \(d.name)"
        }
        arrange()
    }

    private func card(_ ref: LayoutRef, _ title: String, activeOn: String?, zones: [CGRect], blank: Bool, aspect: CGSize,
                      selected: Bool, display d: LayoutStore.Display) -> LayoutCard {
        let c = LayoutCard(title: title, activeOn: activeOn, zones: zones, blank: blank, aspect: aspect, selected: selected)
        c.onPress = { [weak self] double in self?.choose(ref, on: d, close: double) }
        return c
    }

    /// Lays the gallery out for the current width (visual reference: 14 pt padding and section gaps, 12 pt between
    /// cards): captions, card flows, the Zones row and the custom actions.
    private func arrange() {
        let pad: CGFloat = 14, gap: CGFloat = 12, width = gallery.contentSize.width
        var y = pad
        func place(_ v: NSView, x: CGFloat = pad) {
            v.setFrameOrigin(CGPoint(x: x, y: y))
            v.setFrameSize(v.fittingSize)
        }
        // A card's frame carries its outline margin on every side, outside the 120 pt thumbnail.
        func flow(_ cards: [LayoutCard]) {
            let m = LayoutCard.margin
            var x = pad, rowHeight: CGFloat = 0
            for c in cards {
                let w = c.frame.width - 2 * m
                if x > pad, x + w > width - pad { x = pad; y += rowHeight + gap; rowHeight = 0 }
                c.setFrameOrigin(CGPoint(x: x - m, y: y - m))
                x += w + gap
                rowHeight = max(rowHeight, c.frame.height - 2 * m)
            }
            y += rowHeight
        }
        place(templatesCaption)
        y += templatesCaption.frame.height + pad
        flow(templateCards)

        let current = selectedDisplay.map { store.layout(on: $0) }
        let showZones = templateCards.contains { $0.selected } && current != .template(.blank)
        for v in [zonesLabel, zonesBox, zonesCaption] { v.isHidden = !showZones }
        if showZones {
            y += pad
            let h: CGFloat = 24
            let label = zonesLabel.fittingSize, caption = zonesCaption.fittingSize
            zonesLabel.frame = CGRect(x: pad, y: y + (h - label.height) / 2, width: label.width, height: label.height)
            zonesBox.frame = CGRect(x: zonesLabel.frame.maxX + 8, y: y, width: 48, height: h)
            let field = zonesField.fittingSize.height
            zonesField.frame = CGRect(x: 1, y: (h - field) / 2, width: 29, height: field)
            zonesStepper.frame = CGRect(x: 31, y: 1, width: 16, height: h - 2)
            zonesBox.dividerX = 30.5
            zonesCaption.frame = CGRect(x: zonesBox.frame.maxX + 8, y: y + (h - caption.height) / 2,
                                        width: max(width - zonesBox.frame.maxX - 8 - pad, 0), height: caption.height)
            y += h
        }

        y += pad
        place(customCaption)
        y += customCaption.frame.height + pad
        flow(customCards)

        let showActions = customCards.contains { $0.selected }
        actionButtons.forEach { $0.isHidden = !showActions }
        if showActions {
            y += pad
            var x = pad
            for b in actionButtons { place(b, x: x); x += b.frame.width + 6 }
            y += actionButtons[0].frame.height
        }
        y += pad
        let size = CGSize(width: width, height: max(y, gallery.contentSize.height))
        if content.frame.size != size { content.setFrameSize(size) }
    }

    // MARK: Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { displays.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    /// The `display` symbol at 15 pt and the requirement 19 name, wrapping; both turn white on the accent selection.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SidebarCell()
        let label = NSTextField(wrappingLabelWithString: displays[row].name)
        label.font = .systemFont(ofSize: 13)
        let icon = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.preferringMonochrome()))!)
        icon.contentTintColor = .labelColor
        for v in [label, icon] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.textField = label
        cell.imageView = icon
        // 8 pt sidebar padding plus 8 pt row padding; 5 pt above and below the text.
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: 0),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, displays[row].uuid != selectedUUID else { return }
        selectedUUID = displays[row].uuid
        rebuildCards()
    }

    // MARK: Layout choice and Zones stepper

    /// Requirement 26: a click applies the card to the sidebar's display at once; a double-click applies and closes.
    private func choose(_ ref: LayoutRef, on d: LayoutStore.Display, close: Bool) {
        if store.layout(on: d) != ref {
            EventLog.write("editor: \(d.name) → \(ref)")
            store.assign(ref, to: d)
        }
        if close { window.close() }
    }

    @objc private func zoneCountStepped() { setZoneCount(zonesStepper.integerValue) }
    @objc private func zoneCountEdited() { setZoneCount(zonesField.integerValue) }

    /// ↑ and ↓ in the number field step the count, like the arrows beside it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let step = selector == #selector(NSResponder.moveUp(_:)) ? 1 : selector == #selector(NSResponder.moveDown(_:)) ? -1 : 0
        guard step != 0 else { return false }
        setZoneCount(zonesField.integerValue + step)
        return true
    }

    private func setZoneCount(_ n: Int) {
        guard let d = selectedDisplay, case .template(let kind) = store.layout(on: d), kind != .blank else { return }
        let count = kind.clamped(n)
        zonesField.integerValue = count
        zonesStepper.integerValue = count
        if count != store.zoneCount(kind, on: d) { store.setZoneCount(count, for: kind, on: d) }
    }

    // MARK: Custom layouts (requirement 5)

    private var selectedCustom: UUID? {
        guard let d = selectedDisplay, case .custom(let id) = store.layout(on: d) else { return nil }
        return id
    }

    private func cardMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Edit", #selector(editItem)), ("Rename…", #selector(renameItem)),
                                ("Duplicate", #selector(duplicateItem)), ("Delete…", #selector(deleteItem))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
        }
        return menu
    }

    @objc private func editItem(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(edit) }
    @objc private func renameItem(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(rename) }
    @objc private func duplicateItem(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(duplicate) }
    @objc private func deleteItem(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(delete) }
    @objc private func editSelected() { selectedCustom.map(edit) }
    @objc private func renameSelected() { selectedCustom.map(rename) }
    @objc private func duplicateSelected() { selectedCustom.map(duplicate) }
    @objc private func deleteSelected() { selectedCustom.map(delete) }

    private func custom(_ id: UUID) -> CustomLayout? { store.customLayouts.first { $0.id == id } }

    @objc private func newGrid() { startSession(store.draft(.grid(.initial)), isNew: true) }
    @objc private func newCanvas() { startSession(store.draft(.canvas(.initial)), isNew: true) }

    private func edit(_ id: UUID) { custom(id).map { startSession($0, isNew: false) } }

    private func duplicate(_ id: UUID) { store.duplicate(id) }

    private func rename(_ id: UUID) {
        guard let layout = custom(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Layout"
        let field = NSTextField(string: layout.name)
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        Self.runSheet(alert, window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty, name != layout.name else { return }
            self?.store.rename(id, to: name)
        }
    }

    /// Requirement 5: confirmation, naming the displays that use it and their fallback.
    private func delete(_ id: UUID) {
        guard let layout = custom(id) else { return }
        let users = store.displays(using: id)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(layout.name)”?"
        alert.informativeText = users.isEmpty ? "This can’t be undone."
            : "It is active on \(users.map(\.name).joined(separator: ", ")). Displays using it will switch to Priority Grid."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        Self.runSheet(alert, window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            EventLog.write("editor: delete \(layout.name)")
            self?.store.delete(id)
        }
    }

    // MARK: Full-screen session (DD-13)

    /// Opens the Grid or Canvas editor on the sidebar's display and hides this window until it finishes. The
    /// session's result is one commit: `add` for a new layout, `replaceBody` for an edited one (requirement 29).
    private func startSession(_ layout: CustomLayout, isNew: Bool) {
        guard session == nil, let d = selectedDisplay else { return }
        EventLog.write("editor: session \(isNew ? "new" : "edit") \(layout.name) on \(d.name)")
        session = ZoneEditorSession(layout.body, on: d) { [weak self] body in
            guard let self else { return }
            self.session = nil
            if isNew {
                self.store.add(CustomLayout(id: layout.id, name: layout.name, body: body))
            } else if body != layout.body, self.custom(layout.id) != nil {
                self.store.replaceBody(layout.id, with: body)
            }
            EventLog.write("editor: session committed \(layout.name)")
            self.window.makeKeyAndOrderFront(nil)
            Env.activate()
        }
        window.orderOut(nil)
        session?.show()
    }
}

/// Lays out its document view whenever it is tiled (window resizes, scroller changes).
final class GalleryScrollView: NSScrollView {
    var onTile: (() -> Void)?
    override func tile() {
        super.tile()
        onTile?()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A gallery card (wireframe → Cards, visual reference): a 120 pt wide thumbnail at the display's aspect ratio
/// (at most 76 pt tall) drawn from the real zones, the name 4 pt below it, and "Active on: …" for custom layouts
/// used by several displays. The frame carries a margin outside the thumbnail for the 3 pt selection outline.
final class LayoutCard: NSView {
    static let slot = CGSize(width: 120, height: 76)
    static let margin: CGFloat = 3

    let selected: Bool
    var onPress: ((_ double: Bool) -> Void)?
    private let zones: [CGRect]
    private let blank: Bool
    private let thumbnail: CGRect

    init(title: String, activeOn: String?, zones: [CGRect], blank: Bool, aspect: CGSize, selected: Bool) {
        self.zones = zones
        self.blank = blank
        self.selected = selected
        let s = Self.slot, m = Self.margin
        let ratio = aspect.height > 0 ? aspect.width / aspect.height : s.width / s.height
        let height = min((s.width / ratio).rounded(), s.height)
        thumbnail = CGRect(x: m, y: m, width: s.width, height: height)
        super.init(frame: .zero)
        var y = thumbnail.maxY + 4
        for (text, font, color) in [(title, NSFont.systemFont(ofSize: 12), NSColor.labelColor)]
            + (activeOn.map { [($0, NSFont.systemFont(ofSize: 11), NSColor.secondaryLabelColor)] } ?? []) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = color
            label.preferredMaxLayoutWidth = s.width
            label.frame = CGRect(x: m, y: y, width: s.width, height: label.fittingSize.height)
            label.setAccessibilityElement(false)
            addSubview(label)
            y = label.frame.maxY + 4
        }
        setFrameSize(CGSize(width: s.width + 2 * m, height: y - 4 + m))
        // NFR-6: cards read the layout name.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { thumbnail }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: thumbnail, xRadius: 8, yRadius: 8).fill() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func mouseDown(with event: NSEvent) { onPress?(event.clickCount >= 2) }

    /// Space applies, Return applies and closes, like a click and a double-click.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onPress?(false)
        case 36, 76: onPress?(true)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { onPress?(false); return true }

    override func draw(_ dirtyRect: NSRect) {
        let style = ZoneStyle.current(for: effectiveAppearance)
        let box = NSBezierPath(roundedRect: thumbnail.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.tertiarySystemFill.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.stroke()
        if blank {
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                .applying(.preferringMonochrome()).applying(.init(paletteColors: [.secondaryLabelColor]))
            if let glyph = NSImage(systemSymbolName: "rectangle.slash", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                glyph.draw(in: CGRect(x: thumbnail.midX - glyph.size.width / 2, y: thumbnail.midY - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else {
            // Zones 1.5 pt apart from each other and about 4 pt in from the thumbnail edge, with 1 pt borders.
            let screen = thumbnail.insetBy(dx: 3.3, dy: 3)
            let border = NSColor.labelColor.withAlphaComponent(style.dark ? 0.5 : 0.42)
            for z in zones {
                let r = Layouts.points(z, area: screen.size).offsetBy(dx: screen.minX, dy: screen.minY).insetBy(dx: 1.5, dy: 1.5)
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                NSColor(cgColor: style.inactiveFill)?.setFill()
                path.fill()
                border.setStroke()
                path.stroke()
            }
        }
        if selected { // 3 pt accent outline outside the thumbnail's border
            let outline = NSBezierPath(roundedRect: thumbnail.insetBy(dx: -1.5, dy: -1.5), xRadius: 9.5, yRadius: 9.5)
            outline.lineWidth = 3
            NSColor(cgColor: style.accent)?.setStroke()
            outline.stroke()
        }
    }
}

/// A view filled with one (semantic) colour, re-resolved for the current appearance.
private final class FillView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The Zones box: a 1 pt rounded border with a vertical rule between the number and the arrows.
private final class BorderedView: NSView {
    var dividerX: CGFloat = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        box.fill()
        NSColor.separatorColor.setStroke()
        box.stroke()
        NSBezierPath.strokeLine(from: CGPoint(x: dividerX, y: bounds.minY + 1), to: CGPoint(x: dividerX, y: bounds.maxY - 1))
    }
}

/// The ▲▼ arrows of the Zones box: the upper half steps up, the lower half down, within min and max.
final class ArrowStepper: NSControl {
    var minValue: Double = 0
    var maxValue: Double = 0
    private var value = 0
    override var integerValue: Int {
        get { value }
        set { value = newValue; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        step(p.y > bounds.midY ? 1 : -1) // not flipped: the upper half has the larger y
    }

    private func step(_ by: Int) {
        let next = min(max(value + by, Int(minValue)), Int(maxValue))
        guard next != value else { return }
        value = next
        sendAction(action, to: target)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .incrementor }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityPerformIncrement() -> Bool { step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        for (glyph, top) in [("▲", true), ("▼", false)] {
            let s = NSAttributedString(string: glyph, attributes: attrs), size = s.size()
            let y = top ? bounds.midY + 0.5 : bounds.midY - size.height - 0.5
            s.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: y))
        }
    }
}

/// The small bordered buttons of the visual reference: 12 pt text, a 13 pt symbol, a 1 pt border, 6 pt radius.
final class ToolButton: NSButton {
    convenience init(_ title: String, symbol: String?, target: AnyObject, action: Selector) {
        self.init(title: title, target: target, action: action)
        isBordered = false
        font = .systemFont(ofSize: 12)
        contentTintColor = .labelColor
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + (image == nil ? 16 : 20), height: 24)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 6
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.separatorColor.cgColor
            layer.backgroundColor = (isHighlighted ? NSColor.unemphasizedSelectedContentBackgroundColor
                                                   : NSColor.controlBackgroundColor).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A sidebar cell whose symbol turns white on the accent selection, as its label does.
final class SidebarCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { imageView?.contentTintColor = backgroundStyle == .emphasized ? .white : .labelColor }
    }
}

/// Sidebar rows: an accent fill with a 6 pt radius inside the sidebar's 8 pt padding, whether or not the window is key.
final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

/// Records the adjacent-zone modifiers (requirement 14, ADR 7c41d0a2). Click (or press Space/Return while focused)
/// to record, hold the modifiers, release them all to save. Esc cancels; a set without ⌃, ⌥ or ⌘ beeps.
final class ModifierRecorder: NSTextField {
    var onChange: (() -> Void)?
    private var recording = false { didSet { refresh() } }
    private var peak: NSEvent.ModifierFlags = []

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        setAccessibilityRole(.button)
        setAccessibilityLabel("Adjacent zone shortcut modifiers")
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        stringValue = recording ? (peak.isEmpty ? "Type modifiers…" : HotKeyModifiers.symbols(peak))
                                : HotKeyModifiers.symbols(Settings.moveModifiers)
        textColor = recording ? .controlAccentColor : .labelColor
    }

    private func start() {
        window?.makeFirstResponder(self)
        peak = []
        recording = true
    }

    private func stop() {
        recording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }
    override func mouseDown(with event: NSEvent) { start() }
    override func accessibilityPerformPress() -> Bool { start(); return true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return stop() } // Esc
        if !recording, event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" { return start() }
        Env.beep()
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return super.flagsChanged(with: event) }
        let now = event.modifierFlags.intersection(HotKeyModifiers.relevant)
        peak.formUnion(now)
        guard now.isEmpty else { return refresh() }
        defer { peak = [] }
        guard HotKeyModifiers.isValid(peak) else { Env.beep(); return refresh() }
        EventLog.write("editor: adjacent-zone modifiers → \(HotKeyModifiers.symbols(peak))")
        Settings.moveModifiers = peak
        stop()
        onChange?()
    }
}
