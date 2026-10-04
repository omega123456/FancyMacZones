import AppKit

/// DD-13: a borderless window over the target display's full frame. Borderless windows can't become key
/// without the override; Window → Close (⌘W) finishes the session instead of beeping.
final class FullScreenEditorWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { onClose?() }
    /// Covers the whole display, menu bar strip included (the menu bar stays above it).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One full-screen Grid or Canvas editing session (requirements 27, 28, DD-13): the window, the top control bar,
/// the editor view, one undo manager, and a working copy that is handed back once, on Done, Return, Esc or
/// close (requirement 29: nothing is written while editing).
final class ZoneEditorSession: NSObject, NSWindowDelegate {
    private let window: FullScreenEditorWindow
    private let editor: ZoneEditorView
    private let bar: ControlBar
    private let history = UndoManager()
    private var onFinish: ((CustomLayout.Body) -> Void)?

    init(_ body: CustomLayout.Body, on display: LayoutStore.Display, onFinish: @escaping (CustomLayout.Body) -> Void) {
        self.onFinish = onFinish
        let frame = display.frame
        let area = display.usable.offsetBy(dx: -frame.minX, dy: -frame.minY) // the editing area, window coordinates
        let hint: String
        var leading: [NSView] = []
        switch body {
        case .grid(let g):
            editor = GridEditorView(g, frame: area, history: history)
            hint = "Click to split · Shift to rotate · Drag dividers · Drag across zones to merge · ⌘Z undo"
        case .canvas(let c):
            let canvas = CanvasEditorView(c, frame: area, history: history)
            editor = canvas
            leading = [AddButton(target: canvas, action: #selector(CanvasEditorView.addZone)), ControlBar.separator()]
            hint = "N add · Drag move · Handles resize · ⌥ no snap · Click again to select below"
        }
        let label = NSTextField(labelWithString: hint)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let done = NSButton(title: "Done", target: nil, action: #selector(finish))
        done.bezelStyle = .push
        done.keyEquivalent = "\r" // the default button
        bar = ControlBar(leading + [label, ControlBar.separator(), done], leftInset: leading.isEmpty ? 12 : 8)
        window = FullScreenEditorWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        done.target = self

        // Above normal windows (and the Dock), below the menu bar.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.2) // also makes the uncovered area take clicks
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        window.onClose = { [weak self] in self?.finish() }
        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.addSubview(editor)
        // The control bar: a 36 pt capsule centred 8 pt below the menu bar (the usable area's top).
        let width = min(bar.fittingSize.width, frame.width - 32)
        bar.frame = CGRect(x: ((frame.width - width) / 2).rounded(), y: area.maxY - 8 - 36, width: width, height: 36)
        root.addSubview(bar)
        window.contentView = root
        window.initialFirstResponder = editor
        editor.onDone = { [weak self] in self?.finish() }

        // DD-12 / DD-15: redraw on accent and accessibility-display changes while the session exists.
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(themeChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate()
    }

    /// Done, Return, Esc or close: hand the working copy back once.
    @objc func finish() {
        guard let onFinish else { return }
        self.onFinish = nil
        let body = editor.body
        window.orderOut(nil)
        // On the next turn: the caller releases this session, and we may be inside the window's own event handling.
        DispatchQueue.main.async { onFinish(body) }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }

    @objc private func themeChanged() {
        editor.needsDisplay = true
        bar.needsDisplay = true
    }
}

// MARK: Control bar

/// The top control bar (wireframe → Custom Grid editor): one solid, appearance-aware capsule, 36 pt tall.
private final class ControlBar: NSView {
    init(_ views: [NSView], leftInset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: leftInset, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Editor controls")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { // runs with the effective appearance current
        guard let layer else { return }
        let thick = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer.cornerRadius = 18
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.borderColor = (thick ? NSColor.labelColor : NSColor.separatorColor).cgColor
        layer.borderWidth = 1
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -2)
    }

    /// A 1 pt vertical divider.
    static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 1), box.heightAnchor.constraint(equalToConstant: 16)])
        return box
    }
}

/// The Canvas bar's 28 pt circular "+" (accent fill, white `plus`), read as "Add Zone" (NFR-6).
private final class AddButton: NSButton {
    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setAccessibilityLabel("Add Zone")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28)])
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        NSColor.controlAccentColor.setFill()
        circle.fill()
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.2).setFill()
            circle.fill()
        }
        guard let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold).applying(.init(paletteColors: [.white]))) else { return }
        plus.draw(in: CGRect(x: bounds.midX - plus.size.width / 2, y: bounds.midY - plus.size.height / 2,
                             width: plus.size.width, height: plus.size.height))
    }
}

// MARK: Editor views

/// What the Grid and Canvas views share: a flipped view over the usable area (so view points are the model's
/// "area points"), the session's undo manager, Return / Enter / Esc to finish, Tab cycling, and VoiceOver items
/// (NFR-6). Every geometry change goes through a `Layouts` operation (DD-14).
class ZoneEditorView: NSView, NSMenuItemValidation {
    var onDone: (() -> Void)?
    let history: UndoManager
    private var accessibilityItems: [NSAccessibilityElement]?

    init(frame: CGRect, history: UndoManager) {
        self.history = history
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The working copy, handed to the store on finish.
    var body: CustomLayout.Body { fatalError("subclass") }
    var area: CGSize { bounds.size }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { history }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// Subclass keys; false lets the event go on (a beep).
    func handleKey(_ event: NSEvent) -> Bool { false }
    func cycleFocus(backwards: Bool) {}
    func makeAccessibilityItems() -> [NSAccessibilityElement] { [] }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76, 53: onDone?() // Return, Enter, Esc save and exit (requirements 27, 28)
        case 48: cycleFocus(backwards: event.modifierFlags.contains(.shift))
        default: if !handleKey(event) { super.keyDown(with: event) }
        }
    }

    // ⌘Z / ⇧⌘Z via the hidden Edit menu (DD-12).
    @objc func undo(_ sender: Any?) { history.undo() }
    @objc func redo(_ sender: Any?) { history.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): history.canUndo
        case #selector(redo(_:)): history.canRedo
        default: true
        }
    }

    /// After every model, focus or selection change: redraw and rebuild the VoiceOver items.
    func changed() {
        needsDisplay = true
        accessibilityItems = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func accessibilityChildren() -> [Any]? {
        if accessibilityItems == nil { accessibilityItems = makeAccessibilityItems() }
        return accessibilityItems
    }

    /// A VoiceOver item over `rect` (view points); adjustable when `adjust` is set, pressable when `press` is.
    func accessibilityItem(_ label: String, _ rect: CGRect, role: NSAccessibility.Role = .layoutItem,
                           adjust: ((CGFloat) -> Void)? = nil, press: (() -> Void)? = nil) -> NSAccessibilityElement {
        let e = AccessibilityItem()
        e.adjust = adjust
        e.press = press
        e.setAccessibilityRole(adjust != nil ? .slider : role)
        e.setAccessibilityLabel(label)
        e.setAccessibilityParent(self)
        e.setAccessibilityFrameInParentSpace(rect)
        return e
    }

    /// Tab / ⇧Tab position in a list of `count` stops, wrapping; from nothing, the first or the last.
    static func step(_ index: Int?, count: Int, backwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return backwards ? count - 1 : 0 }
        return (index + (backwards ? count - 1 : 1)) % count
    }
}

private final class AccessibilityItem: NSAccessibilityElement {
    var adjust: ((CGFloat) -> Void)?
    var press: (() -> Void)?
    override func accessibilityPerformIncrement() -> Bool { adjust?(1); return adjust != nil }
    override func accessibilityPerformDecrement() -> Bool { adjust?(-1); return adjust != nil }
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}

/// Requirement 27: the full-screen Custom Grid editor (wireframe → Custom Grid editor).
final class GridEditorView: ZoneEditorView {
    private var grid: GridLayout {
        didSet {
            guard grid != oldValue else { return }
            if let f = focus, !grid.focusOrder.contains(f) { focus = nil }
            changed()
        }
    }
    private var focus: GridHit? { didSet { if focus != oldValue { changed() } } }
    private var selection: Set<Int> = []
    private var hover: CGPoint?
    private var horizontal = false // Shift held: split previews and clicks are horizontal
    private var drag: Drag?

    private enum Drag {
        case divider(Divider, start: GridLayout)
        case press(zone: Int, at: CGPoint)
        case select(from: CGPoint)
    }

    init(_ grid: GridLayout, frame: CGRect, history: UndoManager) {
        self.grid = grid
        super.init(frame: frame, history: history)
        setAccessibilityLabel("Grid editor")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var body: CustomLayout.Body { .grid(grid) }

    /// An undoable change (⌘Z / ⇧⌘Z).
    private func apply(_ new: GridLayout) {
        guard new != grid else { return }
        let old = grid
        history.registerUndo(withTarget: self) { $0.apply(old) }
        grid = new
    }

    private func zoneRect(_ zone: Int) -> CGRect { Layouts.points(grid.rect(zone), area: area) }

    private func segment(_ d: Divider) -> (CGPoint, CGPoint) {
        let (s, e) = grid.segment(d)
        return (CGPoint(x: s.x * area.width, y: s.y * area.height), CGPoint(x: e.x * area.width, y: e.y * area.height))
    }

    private func split(_ zone: Int, at p: CGPoint, _ orientation: Orientation) {
        let position = orientation == .vertical ? p.x / area.width : p.y / area.height
        guard let g = grid.splitting(zone, orientation, at: position, area: area) else { return NSSound.beep() } // < 64 pt
        apply(g)
    }

    /// Moves a divider's grid line by `points` across it (keyboard arrows, VoiceOver adjust).
    private func move(_ d: Divider, by points: CGFloat) {
        apply(grid.moving(d, to: grid.position(d) + points / (d.orientation == .vertical ? area.width : area.height), area: area))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        switch grid.hitTest(p, area: area) {
        case .divider(let d)?:
            focus = .divider(d)
            drag = .divider(d, start: grid)
        case .zone(let z)?:
            focus = .zone(z)
            drag = .press(zone: z, at: p)
        case nil:
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .divider(let d, let start)?: // live, recorded for undo on release
            grid = start.moving(d, to: d.orientation == .vertical ? p.x / area.width : p.y / area.height, area: area)
        case .press(_, let origin)?:
            if hypot(p.x - origin.x, p.y - origin.y) >= 4 {
                drag = .select(from: origin)
                select(from: origin, to: p)
            }
        case .select(let origin)?:
            select(from: origin, to: p)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .divider(_, let start)?:
            let end = grid
            grid = start
            apply(end)
        case .press(let z, let origin)?:
            split(z, at: origin, event.modifierFlags.contains(.shift) ? .horizontal : .vertical)
        case .select?:
            if grid.canMerge(selection) { offerMerge(at: point(event)) }
            selection = []
            changed()
        case nil:
            break
        }
        drag = nil
        needsDisplay = true
    }

    private func select(from a: CGPoint, to b: CGPoint) {
        selection = grid.zones(intersecting: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), area: area)
        needsDisplay = true
    }

    /// The one-item "Merge" popup, offered only when the selection's union is a rectangle.
    private func offerMerge(at p: CGPoint) {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Merge", action: #selector(mergeChosen), keyEquivalent: "")
        item.target = self
        item.representedObject = selection
        menu.popUp(positioning: nil, at: p, in: self)
    }

    @objc private func mergeChosen(_ sender: NSMenuItem) {
        guard let zones = sender.representedObject as? Set<Int>, let g = grid.merging(zones) else { return }
        apply(g)
    }

    override func mouseMoved(with event: NSEvent) {
        hover = point(event)
        horizontal = event.modifierFlags.contains(.shift)
        if case .divider(let d)? = grid.hitTest(hover!, area: area) {
            (d.orientation == .vertical ? NSCursor.columnResize : NSCursor.rowResize).set()
        } else {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        horizontal = event.modifierFlags.contains(.shift)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func cycleFocus(backwards: Bool) {
        let order = grid.focusOrder
        focus = Self.step(focus.flatMap(order.firstIndex), count: order.count, backwards: backwards).map { order[$0] }
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 51, 117: // Delete merges across the focused divider, if the union is a rectangle (requirement 3)
            guard case .divider(let d)? = focus, let g = grid.deleting(d) else { NSSound.beep(); return true }
            let (a, b) = segment(d)
            apply(g)
            focus = grid.hitTest(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), area: area)
            return true
        case 123, 124, 125, 126: // arrows move the focused divider: 10 pt, ⌥ 1 pt
            guard case .divider(let d)? = focus else { return false }
            let along: CGFloat? = d.orientation == .vertical ? [123: -1, 124: 1][event.keyCode] : [126: -1, 125: 1][event.keyCode]
            guard let along else { return false }
            move(d, by: along * (event.modifierFlags.contains(.option) ? 1 : 10))
            return true
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "s", case .zone(let z)? = focus else { return false }
            let r = zoneRect(z) // S splits the focused zone through its middle, ⇧S horizontally
            split(z, at: CGPoint(x: r.midX, y: r.midY), shift ? .horizontal : .vertical)
            return true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let style = ZoneStyle.current(for: effectiveAppearance)
        for z in 0..<grid.zoneCount { // square corners: grid zones tile; the merge selection uses the active fill
            let r = zoneRect(z)
            style.drawZone(r, active: selection.contains(z), cornerRadius: 0, in: ctx)
            let pill = ZoneStyle.Pill.number(z + 1, winner: false)
            style.drawPill(pill, in: style.pillRect(pill, in: r, active: false, centred: true, flipped: true))
        }
        // The split preview: a 2 pt dashed accent line at the cursor across the zone under it.
        if drag == nil, let p = hover, case .zone(let z)? = grid.hitTest(p, area: area) {
            let r = zoneRect(z)
            ctx.setStrokeColor(style.accent)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.strokeLineSegments(between: horizontal ? [CGPoint(x: r.minX, y: p.y), CGPoint(x: r.maxX, y: p.y)]
                                                       : [CGPoint(x: p.x, y: r.minY), CGPoint(x: p.x, y: r.maxY)])
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // Dividers: 2 pt accent lines with a 10 pt white handle (1 pt dark outline) at the centre.
        for d in grid.dividers {
            let (a, b) = segment(d), focused = focus == .divider(d)
            ctx.setStrokeColor(style.accent)
            ctx.setLineWidth(2)
            ctx.strokeLineSegments(between: [a, b])
            let handle = CGRect(x: (a.x + b.x) / 2 - 5, y: (a.y + b.y) / 2 - 5, width: 10, height: 10)
            ctx.addPath(CGPath(roundedRect: handle, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(focused ? style.accent : rgb(0xFFFFFF))
            ctx.setStrokeColor(rgb(0x000000, 0.6))
            ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
            if focused { focusRing(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -6, dy: -6), style, ctx) }
        }
        // The focused zone's 2 pt accent ring, 2 pt inside its border so it stays visible at the display's edges.
        if case .zone(let z)? = focus { focusRing(zoneRect(z).insetBy(dx: style.inactiveBorderWidth + 2, dy: style.inactiveBorderWidth + 2), style, ctx) }
    }

    private func focusRing(_ r: CGRect, _ style: ZoneStyle, _ ctx: CGContext) {
        ctx.setStrokeColor(style.accent)
        ctx.setLineWidth(2)
        ctx.stroke(r.insetBy(dx: 1, dy: 1))
    }

    // MARK: Accessibility (NFR-6)

    override func makeAccessibilityItems() -> [NSAccessibilityElement] {
        let n = grid.zoneCount
        return (0..<n).map { accessibilityItem(Layouts.zoneLabel($0 + 1, of: n), zoneRect($0)) }
            + grid.dividers.map { d in
                let (a, b) = segment(d)
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                return accessibilityItem(d.accessibilityLabel, r.insetBy(dx: -GridLayout.grabTolerance, dy: -GridLayout.grabTolerance),
                                         adjust: { [weak self] sign in self?.move(d, by: sign * 10) })
            }
    }
}

/// Requirement 28: the full-screen Canvas editor (wireframe → Canvas editor).
final class CanvasEditorView: ZoneEditorView {
    private var canvas: CanvasLayout {
        didSet {
            guard canvas != oldValue else { return }
            if let s = selected, s >= canvas.zones.count { selected = nil }
            changed()
        }
    }
    private var selected: Int? { didSet { if selected != oldValue { changed() } } }
    /// The zone added before in this session, for the 24 pt cascade; seeded with the topmost zone so the first
    /// "+" doesn't land on top of it.
    private var lastAdded: CGRect?
    /// Where the last plain click landed: clicking again there cycles downward.
    private var lastClick: CGPoint?
    private var guides: [SnapGuide] = []
    private var drag: Drag?

    private struct Drag {
        var index: Int
        var handle: Handle?
        var origin: CGPoint
        var start: CanvasLayout
        var translation = CGVector.zero
        /// A second click at the same point: select the zone below on release, unless the mouse moved.
        var cycle: Bool
    }

    /// The × in the selected zone's top-right inner corner (UI chrome, like the pill placement): 16 pt, inset 6 pt.
    private static let closeSize: CGFloat = 16, closeInset: CGFloat = 6

    init(_ canvas: CanvasLayout, frame: CGRect, history: UndoManager) {
        self.canvas = canvas
        lastAdded = canvas.zones.last
        super.init(frame: frame, history: history)
        setAccessibilityLabel("Canvas editor")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var body: CustomLayout.Body { .canvas(canvas) }

    private func apply(_ new: CanvasLayout) {
        guard new != canvas else { return }
        let old = canvas
        history.registerUndo(withTarget: self) { $0.apply(old) }
        canvas = new
    }

    private func zoneRect(_ i: Int) -> CGRect { Layouts.points(canvas.zones[i], area: area) }

    private func closeRect(_ zone: CGRect) -> CGRect {
        CGRect(x: zone.maxX - Self.closeInset - Self.closeSize, y: zone.minY + Self.closeInset, width: Self.closeSize, height: Self.closeSize)
    }

    // MARK: Operations

    /// "+" or N: a 30% × 30% zone, centred or cascaded 24 pt from the previous one added in this session.
    @objc func addZone() {
        var c = canvas
        let i = c.addZone(after: lastAdded, area: area)
        lastAdded = c.zones[i]
        apply(c)
        selected = i
    }

    @objc private func deleteSelected() {
        guard let s = selected else { return NSSound.beep() }
        var c = canvas
        c.delete(s)
        selected = nil
        apply(c)
    }

    @objc private func bringToFront() {
        guard let s = selected else { return }
        var c = canvas
        let i = c.bringToFront(s)
        apply(c)
        selected = i
    }

    @objc private func sendToBack() {
        guard let s = selected else { return }
        var c = canvas
        let i = c.sendToBack(s)
        apply(c)
        selected = i
    }

    /// Replaces zone `index` with a move or resize result from `Layouts` (snapping off for the keyboard).
    private func moved(_ c: CanvasLayout, _ index: Int, handle: Handle?, by v: CGVector, snapping: Bool) -> (CanvasLayout, [SnapGuide]) {
        let r = c.drag(index, from: c.zones[index], handle: handle, by: v, area: area, snapping: snapping)
        var out = c
        out.zones[index] = r.rect
        return (out, r.guides)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if let s = selected {
            let r = zoneRect(s)
            if closeRect(r).contains(p) { return deleteSelected() }
            if let h = CanvasLayout.handle(at: p, of: r) {
                drag = Drag(index: s, handle: h, origin: p, start: canvas, cycle: false)
                return
            }
        }
        let hits = canvas.zones(at: p, area: area) // top of the z-order first
        if let s = selected, hits.contains(s) { // keep dragging the selection; a click again at the same point cycles
            let again = lastClick.map { hypot($0.x - p.x, $0.y - p.y) <= 3 } ?? false
            drag = Drag(index: s, handle: nil, origin: p, start: canvas, cycle: again)
        } else {
            selected = CanvasLayout.nextSelection(hits: hits, current: nil)
            drag = selected.map { Drag(index: $0, handle: nil, origin: p, start: canvas, cycle: false) }
        }
        lastClick = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        let p = point(event)
        drag!.translation = CGVector(dx: p.x - drag!.origin.x, dy: p.y - drag!.origin.y)
        track(snapping: !event.modifierFlags.contains(.option))
    }

    override func flagsChanged(with event: NSEvent) { track(snapping: !event.modifierFlags.contains(.option)) }

    /// Live move or resize from the gesture's start; recorded for undo on release. ⌥ turns snapping off.
    private func track(snapping: Bool) {
        guard let d = drag, d.translation != .zero else { return }
        (canvas, guides) = moved(d.start, d.index, handle: d.handle, by: d.translation, snapping: snapping)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        guides = []
        if canvas != d.start {
            let end = canvas
            canvas = d.start
            apply(end)
            lastClick = nil
        } else if d.cycle {
            selected = CanvasLayout.nextSelection(hits: canvas.zones(at: d.origin, area: area), current: selected)
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        if let s = selected, let h = CanvasLayout.handle(at: p, of: zoneRect(s)) {
            let position: NSCursor.FrameResizePosition = switch h {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// Bring to Front, Send to Back and Delete Zone for the zone under the cursor.
    override func menu(for event: NSEvent) -> NSMenu? {
        let hits = canvas.zones(at: point(event), area: area)
        guard !hits.isEmpty else { return nil }
        if selected.map(hits.contains) != true { selected = hits[0] }
        let menu = NSMenu()
        for (title, action) in [("Bring to Front", #selector(bringToFront)), ("Send to Back", #selector(sendToBack)),
                                ("", nil), ("Delete Zone", #selector(deleteSelected))] {
            guard let action else { menu.addItem(.separator()); continue }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: Keyboard

    override func cycleFocus(backwards: Bool) { // through the z-order
        selected = Self.step(selected, count: canvas.zones.count, backwards: backwards)
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 51, 117: deleteSelected()
        case 123, 124, 125, 126:
            // Arrows move 10 pt, ⌥ 1 pt; ⇧ resizes 10 pt, ⌥⇧ 2 pt (requirement 28; never ⌃, which macOS reserves).
            guard let s = selected else { NSSound.beep(); return true }
            let resize = event.modifierFlags.contains(.shift), fine = event.modifierFlags.contains(.option)
            let step: CGFloat = resize ? (fine ? 2 : 10) : (fine ? 1 : 10)
            let v = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                     125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][event.keyCode]!
            apply(moved(canvas, s, handle: resize ? .bottomRight : nil, by: v, snapping: false).0)
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "n" else { return false }
            addZone()
        }
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let style = ZoneStyle.current(for: effectiveAppearance)
        for i in canvas.zones.indices where i != selected { // z-order, translucent: overlaps look darker
            let r = zoneRect(i), pill = ZoneStyle.Pill.number(i + 1, winner: false)
            style.drawZone(r, active: false, in: ctx)
            style.drawPill(pill, in: style.pillRect(pill, in: r, active: false, centred: false, flipped: true))
        }
        if let s = selected { // on top: 3 pt accent border, 8 handles, the ×
            let r = zoneRect(s), pill = ZoneStyle.Pill.number(s + 1, winner: false)
            style.drawZone(r, active: true, in: ctx)
            style.drawPill(pill, in: style.pillRect(pill, in: r, active: true, centred: false, flipped: true))
            let h = CanvasLayout.handleSize
            for handle in Handle.allCases {
                let c = handle.point(on: r)
                ctx.setFillColor(rgb(0xFFFFFF))
                ctx.setStrokeColor(rgb(0x000000, 0.6))
                ctx.setLineWidth(1)
                ctx.addRect(CGRect(x: c.x - h / 2, y: c.y - h / 2, width: h, height: h).insetBy(dx: 0.5, dy: 0.5))
                ctx.drawPath(using: .fillStroke)
            }
            let close = closeRect(r)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: rgb(0x000000, 0.3))
            ctx.setFillColor(style.pillBackground)
            ctx.fillEllipse(in: close)
            ctx.restoreGState()
            if let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold).applying(.init(paletteColors: [style.pillText]))) {
                x.draw(in: CGRect(x: close.midX - x.size.width / 2, y: close.midY - x.size.height / 2, width: x.size.width, height: x.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        // Snap guides: 1 pt accent lines across the display.
        ctx.setStrokeColor(style.accent)
        ctx.setLineWidth(1)
        for g in guides {
            ctx.strokeLineSegments(between: g.orientation == .vertical
                ? [CGPoint(x: g.position, y: 0), CGPoint(x: g.position, y: area.height)]
                : [CGPoint(x: 0, y: g.position), CGPoint(x: area.width, y: g.position)])
        }
    }

    // MARK: Accessibility (NFR-6)

    override func makeAccessibilityItems() -> [NSAccessibilityElement] {
        let n = canvas.zones.count
        var items = canvas.zones.indices.map { i in
            accessibilityItem(Layouts.zoneLabel(i + 1, of: n), zoneRect(i), press: { [weak self] in self?.selected = i })
        }
        if let s = selected {
            items.append(accessibilityItem("Delete Zone", closeRect(zoneRect(s)), role: .button,
                                           press: { [weak self] in self?.deleteSelected() }))
        }
        return items
    }
}
