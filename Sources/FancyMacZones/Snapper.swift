import AppKit
import ApplicationServices
import Carbon

/// The event-tap callback's own state and its button rules (DD-1, requirement 8). Value type, covered by --self-test.
struct TapState {
    var leftHeld = false
    var swallowRightUp = false  // the right-down was swallowed, so its up is too (NFR-2)
    var previousY: CGFloat?     // the previous drag event's y, CG (DD-7)
    var holdUntil: Double = 0   // Mission Control hold expiry, system uptime (DD-7)

    /// A mouse-button event: whether to swallow it, and whether it toggles "zones requested". Right-clicks are
    /// swallowed in down/up pairs while the left button is held, so the app under the cursor never sees them.
    mutating func button(_ type: CGEventType) -> (swallow: Bool, toggle: Bool) {
        switch type {
        case .leftMouseDown:
            leftHeld = true
            previousY = nil
            return (false, false)
        case .leftMouseUp:
            leftHeld = false
            return (false, false)
        case .rightMouseDown:
            guard leftHeld else { return (false, false) }
            swallowRightUp = true
            return (true, true)
        case .rightMouseUp:
            defer { swallowRightUp = false }
            return (swallowRightUp, false)
        default:
            return (false, false)
        }
    }
}

/// One left-button gesture on the main thread (DD-2, DD-3). The transitions are pure static functions, covered
/// by --self-test.
struct DragSession {
    enum Phase { case idle, pending, confirmed, rejected }
    /// What the overlay shows (requirements 8, 11).
    enum Overlay { case hidden, zones, maximize }

    static let baselineDistance: CGFloat = 4  // DD-2
    static let recheckInterval: Double = 0.05 // DD-2
    static let maxRechecks = 5                // ADR ff615fc0

    var phase = Phase.idle
    var down = CGPoint.zero    // left-down point, CG
    var point = CGPoint.zero   // latest cursor point, CG
    var windowID: CGWindowID = 0
    var pid: pid_t = 0
    var baseline: CGRect?      // WindowServer bounds, CG
    var rechecks = 0
    var lastRead: Double = 0
    var requested = false      // "zones requested" (requirement 8)
    // Fetched on confirmation and cached for this gesture only (DD-3), with the settings (read per gesture).
    var displays: [LayoutStore.Display] = []
    var zones: [PlacedZone] = []
    var primaryHeight: CGFloat = 0
    var rule = OverlapRule.smallestArea
    var dragToTop = true
    var missionControlGuard = true

    /// DD-2: a pending drag reads the window's bounds once it is 4 pt from left-down (the baseline), then on drag
    /// events at least 50 ms after the previous read.
    static func wantsRead(_ s: DragSession, at point: CGPoint, now: Double) -> Bool {
        guard s.phase == .pending else { return false }
        guard s.baseline != nil else { return hypot(point.x - s.down.x, point.y - s.down.y) >= baselineDistance }
        return now - s.lastRead >= recheckInterval
    }

    /// DD-2: the first read is the baseline. Each recheck confirms when the origin changed and the size didn't;
    /// anything else (no move, or a resize) is a failed check, and the 5th failed check rejects the gesture.
    /// A window that can't be read rejects it at once.
    static func afterRead(_ s: DragSession, bounds: CGRect?, now: Double) -> DragSession {
        var s = s
        s.lastRead = now
        guard let bounds else { s.phase = .rejected; return s }
        guard let baseline = s.baseline else { s.baseline = bounds; return s }
        s.rechecks += 1
        if bounds.origin != baseline.origin && bounds.size == baseline.size {
            s.phase = .confirmed
        } else if s.rechecks >= maxRechecks {
            s.phase = .rejected
        }
        return s
    }

    /// Requirements 8 and 11: only a confirmed window drag shows anything. The top band (already false when Drag
    /// to Top is off) takes precedence, whether or not zones are requested; otherwise zones show when requested
    /// on a display that isn't Blank.
    static func overlay(requested: Bool, confirmed: Bool, blank: Bool, topBand: Bool) -> Overlay {
        guard confirmed else { return .hidden }
        if topBand { return .maximize }
        return requested && !blank ? .zones : .hidden
    }
}

/// All window-moving behaviour: the mouse-only event tap (DD-1), the drag session and its confirmation (DD-2),
/// the overlay and top hot spot (requirements 8–11), the Mission Control rewrite (requirement 12, DD-7), drops
/// and frame writes (requirements 10, 13, DD-4) and the Ctrl+Cmd+Arrow hotkeys (requirements 14–17, DD-8).
/// Started while Accessibility is trusted, stopped when it isn't (requirement 20). Main thread only.
final class Snapper {
    private let store: LayoutStore
    private let overlay: ZoneOverlay
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapState = TapState()
    private var session = DragSession()
    /// Exposed top-edge segments, CG (DD-7). Read by the callback; refreshed on display changes.
    private var edges: [TopEdgeSegment] = []
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?

    /// Hotkey IDs index this list (requirement 14).
    private static let arrows: [(key: Int, direction: Direction)] = [
        (kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_UpArrow, .up), (kVK_DownArrow, .down),
    ]

    init(store: LayoutStore, overlay: ZoneOverlay) {
        self.store = store
        self.overlay = overlay
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: LayoutStore.displaysDidChange, object: store)
    }

    /// Requirement 20. Both are idempotent.
    func start() {
        guard tap == nil else { return }
        refreshEdges()
        installTap()
        registerHotKeys()
    }

    func stop() {
        cancel("stopped")
        removeTap()
        unregisterHotKeys()
    }

    // MARK: Tap (DD-1)

    private func installTap() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: Self.callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            EventLog.write("tap unavailable")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = t
        tapSource = source
        tapState = TapState()
        EventLog.write("tap installed")
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        EventLog.write("tap removed")
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<Snapper>.fromOpaque(info).takeUnretainedValue().filter(type, event)
            ? nil : Unmanaged.passUnretained(event)
    }

    /// The callback (DD-1, NFR-2): reads event fields, flips flags, swallows or rewrites, and queues the rest to
    /// the main thread. No AX, no WindowServer, no file I/O. Returns true to swallow the event.
    private func filter(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            guard let tap, AXIsProcessTrusted() else { return false } // a revoked grant never re-enables
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async { EventLog.write("tap re-enabled") }
            return false
        case .leftMouseDragged:
            let now = ProcessInfo.processInfo.systemUptime
            var p = event.location
            let mc = Layouts.missionControl(point: p, deltaY: event.getDoubleValueField(.mouseEventDeltaY),
                                            previousY: tapState.previousY, edges: edges, holdUntil: tapState.holdUntil,
                                            now: now, confirmed: session.phase == .confirmed && session.missionControlGuard)
            tapState.previousY = p.y
            let started = mc.holdUntil != tapState.holdUntil
            tapState.holdUntil = mc.holdUntil
            if let y = mc.rewriteY { // requirement 12: the event's location only, no cursor warp
                p.y = y
                event.location = p
            }
            DispatchQueue.main.async {
                if started { EventLog.write("mission control: push at the top edge rewritten, hold 250 ms") }
                self.dragged(p, now: now)
            }
            return false
        default:
            let (swallow, toggle) = tapState.button(type)
            let p = event.location
            switch type {
            case .leftMouseDown:
                let id = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))
                DispatchQueue.main.async { self.began(p, window: id) }
            case .leftMouseUp:
                DispatchQueue.main.async { self.ended(p) }
            default:
                if toggle { DispatchQueue.main.async { self.toggleZones() } }
            }
            return swallow
        }
    }

    // MARK: Drag session (main thread)

    private func began(_ p: CGPoint, window: CGWindowID) {
        overlay.hide() // only if a left-up was lost while the tap was disabled
        session = DragSession(phase: .pending, down: p, point: p, windowID: window)
    }

    private func dragged(_ p: CGPoint, now: Double) {
        guard session.phase == .pending || session.phase == .confirmed else { return }
        session.point = p
        if DragSession.wantsRead(session, at: p, now: now) { read(now) }
        if session.phase == .confirmed { show() }
    }

    /// DD-2: one WindowServer read. On confirmation, the zones and settings are fetched for this gesture (DD-3).
    private func read(_ now: Double) {
        let first = session.baseline == nil
        // The event field is 0 for other apps' windows in practice, so the baseline then finds the window under
        // the left-down point with one on-screen list read instead (ADR 2026-10-04 window lookup).
        var info: (bounds: CGRect, pid: pid_t)?
        if first, session.windowID == 0, let hit = Self.windowAt(session.down) {
            session.windowID = hit.id
            info = (hit.bounds, hit.pid)
        } else if session.windowID != 0 {
            info = Self.windowInfo(session.windowID)
        }
        let id = session.windowID
        if first, let info { session.pid = info.pid }
        session = DragSession.afterRead(session, bounds: info?.bounds, now: now)
        let bounds = { info.map { "\($0.bounds)" } ?? "unreadable" }
        if first {
            EventLog.write("drag baseline window=\(id) pid=\(session.pid) app=\(NSRunningApplication(processIdentifier: session.pid)?.localizedName ?? "?") bounds=\(bounds())")
        } else {
            EventLog.write("drag recheck \(session.rechecks)/\(DragSession.maxRechecks) bounds=\(bounds())")
        }
        switch session.phase {
        case .confirmed:
            session.displays = store.displays
            session.zones = store.allZones()
            session.primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            session.rule = Settings.overlapRule
            session.dragToTop = Settings.dragToTop
            session.missionControlGuard = Settings.missionControlGuard
            EventLog.write("drag confirmed window=\(id): \(session.zones.count) zones on \(session.displays.count) displays")
        case .rejected:
            EventLog.write("drag rejected window=\(id): \(info == nil ? "window not readable" : "not a window drag")")
        default: break
        }
    }

    private func toggleZones() {
        guard session.phase != .idle else { return }
        session.requested.toggle()
        EventLog.write("zones requested=\(session.requested)")
        if session.phase == .confirmed { show() }
    }

    /// What the cursor (CG) would show and drop into: its display, the overlay state, that display's zones
    /// (global Cocoa) and the active zone (requirement 9).
    private func evaluate(_ p: CGPoint) -> (overlay: DragSession.Overlay, display: LayoutStore.Display, rects: [CGRect], active: Int?)? {
        let c = Layouts.cocoaPoint(fromCG: p, primaryHeight: session.primaryHeight)
        guard let d = Layouts.display(at: c, frames: session.displays.map(\.frame)) else { return nil }
        let display = session.displays[d]
        let rects = session.zones.filter { $0.display == d }.map(\.rect)
        let shown = DragSession.overlay(requested: session.requested, confirmed: session.phase == .confirmed, blank: rects.isEmpty,
                                        topBand: session.dragToTop && Layouts.inTopBand(c, screen: display.frame))
        return (shown, display, rects, shown == .zones ? Layouts.activeZone(at: c, in: rects, rule: session.rule) : nil)
    }

    private func show() {
        guard let e = evaluate(session.point) else { return overlay.hide() }
        switch e.overlay {
        case .maximize: overlay.showMaximize(e.display.usable, on: e.display.frame)
        case .zones: overlay.showZones(e.rects, active: e.active, on: e.display.frame)
        case .hidden: overlay.hide()
        }
    }

    /// Requirement 10: re-evaluated at the release point; the overlay hides either way.
    private func ended(_ p: CGPoint) {
        defer {
            overlay.hide()
            session = DragSession()
        }
        guard session.phase == .confirmed else { return }
        guard let e = evaluate(p) else { return EventLog.write("drop: off every display, normal drag") }
        let target: CGRect, what: String
        switch (e.overlay, e.active) {
        case (.maximize, _):
            target = e.display.usable
            what = "maximize on \(e.display.name)"
        case (.zones, let a?):
            target = e.rects[a]
            what = "zone \(a + 1) on \(e.display.name)"
        default:
            return EventLog.write("drop: no target, normal drag")
        }
        do {
            // Requirement 13: eligibility needs AX, so it is checked only now.
            guard session.pid != getpid(), let (app, window) = try AX.window(pid: session.pid, id: session.windowID),
                  try AX.isStandardWindow(window) else {
                EventLog.write("drop: \(what): window \(session.windowID) not eligible, left alone")
                return
            }
            try write(target, app: app, window: window, primaryHeight: session.primaryHeight)
            EventLog.write("drop: \(what) → \(target)")
        } catch {
            EventLog.write("drop: \(what) failed: \(error)")
        }
    }

    /// NFR-4: a display change mid-gesture cancels it (ignored until left-up).
    private func cancel(_ reason: String) {
        guard session.phase != .idle else { return }
        EventLog.write("gesture cancelled: \(reason)")
        session.phase = .rejected
        overlay.hide()
    }

    @objc private func displaysChanged() {
        refreshEdges()
        cancel("display change")
    }

    private func refreshEdges() {
        let h = NSScreen.screens.first?.frame.height ?? 0
        edges = Layouts.exposedTopEdges(store.displays.map { Layouts.axRect(fromCocoa: $0.frame, primaryHeight: h) })
    }

    /// DD-2: `CGWindowListCopyWindowInfo` limited to one window: its bounds (CG) and owner PID.
    private static func windowInfo(_ id: CGWindowID) -> (bounds: CGRect, pid: pid_t)? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return (bounds, pid)
    }

    /// The topmost normal-level (layer 0) on-screen window containing a CG point, from one front-to-back list read.
    private static func windowAt(_ p: CGPoint) -> (id: CGWindowID, bounds: CGRect, pid: pid_t)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        for info in list as? [[String: Any]] ?? [] {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary), bounds.contains(p),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return (id, bounds, pid)
        }
        return nil
    }

    // MARK: Frame writes (DD-4)

    /// Enhanced UI off during the write and restored after; size → position → size in AX coordinates. One
    /// attempt: AX logs each failed write, and frames are never re-applied (DD-5).
    private func write(_ frame: CGRect, app: AXUIElement, window: AXUIElement, primaryHeight: CGFloat) throws {
        let r = Layouts.axRect(fromCocoa: frame, primaryHeight: primaryHeight)
        let enhanced = try AX.enhancedUserInterface(app) == true
        if enhanced { try AX.setEnhancedUserInterface(app, false) }
        defer { if enhanced { _ = try? AX.setEnhancedUserInterface(app, true) } }
        try AX.set(window, kAXSizeAttribute, r.size)
        try AX.set(window, kAXPositionAttribute, r.origin)
        try AX.set(window, kAXSizeAttribute, r.size)
    }

    // MARK: Hotkeys (DD-8, requirements 14–17)

    private func registerHotKeys() {
        guard hotKeyHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            var id = EventHotKeyID()
            guard let event, let info,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  Snapper.arrows.indices.contains(Int(id.id)) else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Snapper>.fromOpaque(info).takeUnretainedValue().move(Snapper.arrows[Int(id.id)].direction)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        for (i, arrow) in Self.arrows.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(arrow.key), UInt32(controlKey | cmdKey),
                                             EventHotKeyID(signature: 0x464D_5A4E /* FMZN */, id: UInt32(i)),
                                             GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeys.append(ref) } else { EventLog.write("hotkey \(arrow.direction) not registered: \(status)") }
        }
        EventLog.write("hotkeys registered: \(hotKeys.count)/\(Self.arrows.count)")
    }

    private func unregisterHotKeys() {
        guard let handler = hotKeyHandler else { return }
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        RemoveEventHandler(handler)
        hotKeyHandler = nil
        EventLog.write("hotkeys unregistered")
    }

    /// Requirements 14–17: the focused window moves to the adjacent zone across all displays, with global wrap.
    private func move(_ direction: Direction) {
        do {
            guard let (app, window, pid) = try AX.focusedWindow() else {
                return EventLog.write("hotkey \(direction): no focused window")
            }
            let name = { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" } // only when logging
            guard pid != getpid(), try AX.isStandardWindow(window) else {
                return EventLog.write("hotkey \(direction): \(name()) window not eligible, left alone")
            }
            guard let ax = try AX.frame(window) else { return EventLog.write("hotkey \(direction): \(name()) frame unreadable") }
            let h = NSScreen.screens.first?.frame.height ?? 0
            let zones = store.allZones() // DD-3: fetched per gesture
            let frame = Layouts.cocoaRect(fromAX: ax, primaryHeight: h)
            let current = Layouts.currentZone(of: frame, in: zones.map(\.rect))
            guard let t = Layouts.directionalTarget(from: current.map { zones[$0].rect } ?? frame, current: current,
                                                    in: zones, direction: direction) else {
                return EventLog.write("hotkey \(direction): \(name()) no zone in band")
            }
            try write(zones[t].rect, app: app, window: window, primaryHeight: h)
            func label(_ z: PlacedZone) -> String { "zone \(z.number) on \(store.displays[z.display].name)" }
            EventLog.write("hotkey \(direction): \(name()) \(current.map { label(zones[$0]) } ?? "floating") → \(label(zones[t])) \(zones[t].rect)")
        } catch {
            EventLog.write("hotkey \(direction) failed: \(error)")
        }
    }
}
