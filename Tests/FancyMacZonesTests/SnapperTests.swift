import AppKit
import Carbon
import Testing
@testable import FancyMacZones

extension Desktop {
    @MainActor @Suite struct SnapperTests {
        static let pid: pid_t = 91001
        /// A window on the main display, Cocoa.
        static let frame = CGRect(x: -19900, y: -19700, width: 400, height: 300)

        let h = Harness()
        let store: LayoutStore
        let snapper: Snapper
        let window: AXUIElement

        init() {
            store = LayoutStore()
            snapper = Snapper(store: store, overlay: ZoneOverlay())
            h.listWindow(7001, pid: Self.pid, frame: Self.frame)
            window = h.axWindow(7001, pid: Self.pid, frame: Self.frame)
        }

        /// A mouse event at a Cocoa point, as the tap would see it.
        func event(_ type: CGEventType, _ p: CGPoint, window id: CGWindowID = 0, clicks: Int64 = 1, deltaY: Double = 0) -> CGEvent {
            let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: h.cg(p), mouseButton: button)!
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(id))
            e.setIntegerValueField(.mouseEventClickState, value: clicks)
            e.setDoubleValueField(.mouseEventDeltaY, value: deltaY)
            return e
        }

        @discardableResult
        func send(_ type: CGEventType, _ p: CGPoint, window id: CGWindowID = 0, clicks: Int64 = 1, deltaY: Double = 0) async -> Bool {
            let swallowed = snapper.filter(type, event(type, p, window: id, clicks: clicks, deltaY: deltaY))
            await settle(0.06) // main-queue delivery, and the 50 ms recheck interval
            return swallowed
        }

        /// Left-down on the window, a drag past the 4 pt baseline, the window follows, a recheck confirms.
        func confirmedDrag(from p: CGPoint, window id: CGWindowID = 7001) async {
            await send(.leftMouseDown, p, window: id)
            await send(.leftMouseDragged, CGPoint(x: p.x + 10, y: p.y))
            h.listWindow(7001, pid: Self.pid, frame: Self.frame.offsetBy(dx: 30, dy: 0))
            await send(.leftMouseDragged, CGPoint(x: p.x + 30, y: p.y))
        }

        var titlePoint: CGPoint { CGPoint(x: Self.frame.midX, y: Self.frame.maxY - 10) }

        // MARK: Drag sessions

        @Test func dropIntoAZone() async {
            snapper.start()
            snapper.start() // idempotent
            #expect(h.log.contains("tap installed"))
            #expect(h.hotKeys.count == 4)

            let usable = h.main.visibleFrame
            await confirmedDrag(from: CGPoint(x: Self.frame.midX, y: Self.frame.maxY - 10))
            #expect(h.log.contains("drag confirmed window=7001: 3 zones on 1 displays"))
            #expect(h.log.contains("app=?")) // no running app with the fake pid

            // A right-click while dragging is swallowed in a down/up pair and shows the zones.
            let centre = CGPoint(x: usable.midX, y: usable.midY)
            await send(.leftMouseDragged, centre)
            #expect(await send(.rightMouseDown, centre))
            #expect(await send(.rightMouseUp, centre))
            #expect(h.log.contains("zones requested=true"))
            let zones = store.zones(on: store.displays[0])
            await send(.leftMouseUp, centre)
            #expect(h.log.contains("drop: zone 2 on Studio Display (Main) → \(zones[1])"))
            let r = h.cg(zones[1])
            #expect(h.ax.writes(window) == ["size \(Int(r.width))x\(Int(r.height))", "pos \(Int(r.minX)),\(Int(r.minY))",
                                            "size \(Int(r.width))x\(Int(r.height))"])

            // A right-click without a held left button passes through.
            #expect(await send(.rightMouseDown, centre) == false)
            #expect(await send(.rightMouseUp, centre) == false)

            snapper.stop()
            snapper.stop()
            #expect(h.log.contains("tap removed"))
            #expect(h.log.contains("hotkeys unregistered"))
            #expect(h.unregistered == 4)
            #expect(h.tapEnables == [false])
        }

        @Test func dropWithoutTargetsOrOffTheDisplays() async {
            snapper.start()
            // Zones not requested: no target.
            await confirmedDrag(from: titlePoint)
            await send(.leftMouseUp, titlePoint)
            #expect(h.log.contains("drop: no target, normal drag"))

            // Released off every display.
            h.listWindow(7001, pid: Self.pid, frame: Self.frame)
            await confirmedDrag(from: titlePoint)
            await send(.leftMouseDragged, CGPoint(x: 0, y: 0))
            await send(.leftMouseUp, CGPoint(x: 0, y: 0))
            #expect(h.log.contains("drop: off every display, normal drag"))
            #expect(h.ax.sets.isEmpty)

            // The tap lost a left-up: the next left-down starts afresh.
            await send(.leftMouseDown, titlePoint, window: 7001)
            await send(.leftMouseDown, titlePoint, window: 7001)
            await send(.leftMouseUp, titlePoint)
            snapper.stop()
        }

        @Test func dropLeavesIneligibleWindowsAlone() async {
            snapper.start()
            let centre = CGPoint(x: h.main.visibleFrame.midX, y: h.main.visibleFrame.midY)
            func dropInZone() async {
                h.listWindow(7001, pid: Self.pid, frame: Self.frame)
                await confirmedDrag(from: titlePoint)
                await send(.rightMouseDown, centre)
                await send(.rightMouseUp, centre)
                await send(.leftMouseUp, centre)
            }
            h.ax.attrs[window]![kAXSubroleAttribute] = kAXDialogSubrole as CFString
            await dropInZone()
            #expect(h.log.contains("window 7001 not eligible, left alone"))

            // A timeout while writing.
            h.ax.attrs[window]![kAXSubroleAttribute] = kAXStandardWindowSubrole as CFString
            let app = AXUIElementCreateApplication(Self.pid)
            h.ax.attrs[app]!["AXEnhancedUserInterface"] = kCFBooleanTrue // turned off for the write, then back on
            h.ax.failingSets[window] = .cannotComplete
            await dropInZone()
            #expect(h.log.contains("failed: timeout"))
            #expect(h.ax.sets.filter { $0.element == app }.map { $0.value as? Bool } == [false, true])
            snapper.stop()
        }

        @Test func dragsThatAreNotWindowDrags() async {
            snapper.start()
            // The window never moves: rejected after five rechecks.
            await send(.leftMouseDown, titlePoint, window: 7001)
            for i in 1...6 { await send(.leftMouseDragged, CGPoint(x: titlePoint.x + CGFloat(i * 10), y: titlePoint.y)) }
            #expect(h.log.contains("drag recheck 5/5"))
            #expect(h.log.contains("drag rejected window=7001: not a window drag"))
            await send(.leftMouseUp, titlePoint)

            // An unknown window: unreadable.
            await send(.leftMouseDown, titlePoint, window: 9999)
            await send(.leftMouseDragged, CGPoint(x: titlePoint.x + 10, y: titlePoint.y))
            #expect(h.log.contains("drag rejected window=9999: window not readable"))
            await send(.leftMouseUp, titlePoint)

            // The event field is 0: the window under the left-down point, from the on-screen list (layer 0 only).
            h.listWindow(8001, pid: 91002, frame: Self.frame, layer: 25)
            h.windows.insert(h.windows.removeLast(), at: 0)
            h.windows.insert([kCGWindowNumber as String: 8002], at: 0) // malformed entry
            await send(.leftMouseDown, titlePoint, window: 0)
            await send(.leftMouseDragged, CGPoint(x: titlePoint.x + 10, y: titlePoint.y))
            #expect(h.log.contains("drag baseline window=7001 pid=91001"))
            await send(.leftMouseUp, titlePoint)

            // Nothing under the point.
            await send(.leftMouseDown, CGPoint(x: -19990, y: -19990), window: 0)
            await send(.leftMouseDragged, CGPoint(x: -19980, y: -19990))
            #expect(h.log.contains("drag rejected window=0: window not readable"))
            await send(.leftMouseUp, CGPoint(x: -19980, y: -19990))
            snapper.stop()
        }

        @Test func topBandMaximizesAndATitleBarDoubleClickRestores() async {
            snapper.start()
            await confirmedDrag(from: titlePoint)
            let top = CGPoint(x: h.main.frame.midX, y: h.main.frame.maxY - 2)
            await send(.leftMouseDragged, top)
            await send(.leftMouseUp, top, clicks: 1)
            let usable = h.main.visibleFrame
            #expect(h.log.contains("drop: maximize on Studio Display (Main) → \(usable)"))

            // The window now sits in the visible frame; a double-click on its title bar puts it back where the drag began.
            let maximized = h.cg(usable)
            h.ax.attrs[window]![kAXPositionAttribute] = axPoint(maximized.origin)
            h.ax.attrs[window]![kAXSizeAttribute] = axSize(maximized.size)
            h.ax.hit = window
            h.ax.sets = []
            await send(.leftMouseDown, top)
            await send(.leftMouseUp, top, clicks: 2)
            #expect(h.log.contains("double-click: restore window=7001 → \(Self.frame)"))
            #expect(h.ax.writes(window).last == "size 400x300")

            // Drag to Top off: the band shows nothing.
            Settings.dragToTop = false
            h.listWindow(7001, pid: Self.pid, frame: Self.frame)
            await confirmedDrag(from: titlePoint)
            await send(.leftMouseDragged, top)
            await send(.leftMouseUp, top)
            #expect(h.log.contains("drop: no target, normal drag"))
            snapper.stop()
        }

        @Test func missionControlGuard() async {
            snapper.start()
            await confirmedDrag(from: titlePoint)
            let edge = CGPoint(x: h.main.frame.midX, y: h.main.frame.maxY) // CG y on the exposed top edge
            await send(.leftMouseDragged, edge)
            let e = event(.leftMouseDragged, edge, deltaY: -40)
            #expect(!snapper.filter(.leftMouseDragged, e))
            #expect(e.location.y == h.cg(edge).y + 1) // rewritten 1 pt below the edge
            await settle()
            #expect(h.log.contains("mission control: push at the top edge rewritten, hold 250 ms"))
            await send(.leftMouseUp, edge)
            snapper.stop()
        }

        @Test func displayChangeCancelsTheGesture() async {
            snapper.start()
            await confirmedDrag(from: titlePoint)
            h.screens = [h.main, h.side]
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(h.log.contains("gesture cancelled: display change"))
            await send(.leftMouseUp, titlePoint)
            #expect(h.ax.sets.isEmpty)
            snapper.stop()
        }

        @Test func tapLifecycle() async {
            // No tap (untrusted at the system level): logged, nothing else.
            h.tapAvailable = false
            snapper.start()
            #expect(h.log.contains("tap unavailable"))
            snapper.stop()

            h.tapAvailable = true
            snapper.start()
            // The system disabled the tap: re-enabled while trusted, never after the grant is revoked.
            let any = event(.leftMouseDown, titlePoint)
            #expect(!snapper.filter(.tapDisabledByTimeout, any))
            await settle()
            #expect(h.tapEnables == [true])
            #expect(h.log.contains("tap re-enabled"))
            h.ax.trusted = false
            #expect(!snapper.filter(.tapDisabledByUserInput, any))
            #expect(h.tapEnables == [true])

            // The C callback forwards to the filter; events pass unless swallowed.
            let info = Unmanaged.passUnretained(snapper).toOpaque()
            let proxy = OpaquePointer(bitPattern: 1)!
            #expect(Snapper.callback(proxy, .leftMouseUp, any, nil) != nil)
            #expect(Snapper.callback(proxy, .leftMouseUp, any, info) != nil)
            await settle()

            // Modifier changes re-register the hotkeys; a taken hotkey is logged.
            h.hotKeyFailures = [UInt32(kVK_UpArrow)]
            Settings.moveModifiers = [.control, .option]
            #expect(h.log.contains("hotkey up not registered"))
            #expect(h.log.contains("hotkeys registered: 3/4 ⌃⌥"))
            snapper.stop()
            Settings.moveModifiers = [.command] // not registered while stopped
            #expect(!h.log.contains("hotkeys registered: 4/4 ⌘"))
        }

        // MARK: Title-bar double-click

        @Test func doubleClickMaximizesFromTheTitleBar() async {
            snapper.start()
            let app = AXUIElementCreateApplication(Self.pid)
            let toolbar = h.ax.element(of: Self.pid), title = h.ax.element(of: Self.pid), button = h.ax.element(of: Self.pid)
            h.ax.attrs[toolbar] = [kAXRoleAttribute: kAXToolbarRole as CFString, kAXWindowAttribute: window]
            h.ax.attrs[title] = [kAXRoleAttribute: kAXStaticTextRole as CFString, kAXWindowAttribute: window]
            h.ax.attrs[button] = [kAXRoleAttribute: kAXButtonRole as CFString, kAXWindowAttribute: window]
            h.ax.attrs[window]![kAXTitleUIElementAttribute] = title
            func doubleClick(_ hit: AXUIElement?, at p: CGPoint? = nil) async {
                h.ax.hit = hit
                await send(.leftMouseDown, p ?? titlePoint)
                await send(.leftMouseUp, p ?? titlePoint, clicks: 2)
            }

            // A button in the title bar is not chrome; the toolbar background is.
            await doubleClick(button)
            #expect(h.ax.sets.isEmpty)
            await doubleClick(toolbar)
            let usable = h.cg(h.main.visibleFrame)
            #expect(h.ax.writes(window) == ["size 1200x775", "pos \(Int(usable.minX)),\(Int(usable.minY))", "size 1200x775"])
            #expect(h.log.contains("double-click: maximize window=7001 on Studio Display (Main)"))
            #expect(h.log.contains("(1 remembered)"))

            // The window moved since: no restore, it maximizes again (from the title text this time).
            h.ax.attrs[window]![kAXPositionAttribute] = axPoint(h.cg(Self.frame).origin)
            h.ax.attrs[window]![kAXSizeAttribute] = axSize(Self.frame.size)
            h.ax.sets = []
            await doubleClick(title)
            #expect(h.ax.writes(window).count == 3)
            #expect(h.log.components(separatedBy: "double-click: maximize").count == 3)

            // A third click of a quick double-click doesn't count; the fourth does.
            h.ax.sets = []
            h.ax.hit = window
            await send(.leftMouseUp, titlePoint, clicks: 3)
            #expect(h.ax.sets.isEmpty)

            // Without the private window-ID call there is nothing to restore later.
            h.ax.windowIDs[window] = nil
            await doubleClick(window)
            #expect(h.log.contains("double-click: maximize window=? on"))
            h.ax.windowIDs[window] = 7001

            // Off every display: nothing; unreadable frame, ineligible window, timeout: logged.
            await doubleClick(window, at: CGPoint(x: 0, y: 0))
            h.ax.sets = []
            h.ax.attrs[window]![kAXSizeAttribute] = nil
            await doubleClick(window)
            #expect(h.log.contains("double-click: frame unreadable"))
            h.ax.attrs[window]![kAXSubroleAttribute] = kAXFloatingWindowSubrole as CFString
            await doubleClick(window)
            #expect(h.log.contains("double-click: title bar window not eligible"))
            h.ax.hitError = .cannotComplete
            await doubleClick(window)
            #expect(h.log.contains("double-click: maximize failed: timeout"))
            h.ax.hitError = .success

            // Nothing under the point, or an element outside any window.
            await doubleClick(nil)
            await doubleClick(app)
            // macOS minimizes on double-click, or the feature is off: left alone.
            h.defaults.set("Minimize", forKey: "AppleActionOnDoubleClick")
            await doubleClick(window)
            h.defaults.removeObject(forKey: "AppleActionOnDoubleClick")
            Settings.doubleClickMaximize = false
            await doubleClick(window)
            #expect(h.ax.sets.isEmpty)
            snapper.stop()
        }

        // MARK: Hotkeys

        @Test func hotkeysMoveTheFocusedWindow() async {
            snapper.start()
            let zones = store.zones(on: store.displays[0]) // priority grid: left, centre, right
            func place(_ r: CGRect) {
                let ax = h.cg(r)
                h.ax.attrs[window]![kAXPositionAttribute] = axPoint(ax.origin)
                h.ax.attrs[window]![kAXSizeAttribute] = axSize(ax.size)
            }
            snapper.move(.right)
            #expect(h.log.contains("hotkey right: no focused window"))

            h.focus(window, pid: Self.pid)
            place(zones[0])
            snapper.move(.right)
            #expect(h.log.contains("hotkey right: pid 91001 zone 1 on Studio Display (Main) → zone 2 on Studio Display (Main)"))
            place(zones[2])
            snapper.move(.right) // global wrap
            #expect(h.log.contains("zone 3 on Studio Display (Main) → zone 1"))
            snapper.move(.up) // the columns span the full height: nothing else in band
            #expect(h.log.contains("hotkey up: pid 91001 no zone in band"))
            place(CGRect(x: -19990, y: -19300, width: 50, height: 50)) // floating
            snapper.move(.left)
            #expect(h.log.contains("floating →"))

            // Via the Carbon hotkey event, as the system would deliver it.
            var ev: EventRef?
            CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &ev)
            var id = EventHotKeyID(signature: 0x464D_5A4E, id: 0) // left
            SetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &id)
            #expect(SendEventToEventTarget(ev, GetApplicationEventTarget()) == noErr)
            id.id = 9 // not ours
            SetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &id)
            #expect(SendEventToEventTarget(ev, GetApplicationEventTarget()) == OSStatus(eventNotHandledErr))
            ReleaseEvent(ev)
            #expect(h.log.components(separatedBy: "hotkey left:").count == 3)

            // Frame unreadable, ineligible, no zone, failure.
            h.ax.attrs[window]![kAXSizeAttribute] = nil
            snapper.move(.left)
            #expect(h.log.contains("hotkey left: pid 91001 frame unreadable"))
            h.ax.attrs[window]![kAXSubroleAttribute] = kAXDialogSubrole as CFString
            snapper.move(.left)
            #expect(h.log.contains("hotkey left: pid 91001 window not eligible, left alone"))
            h.ax.attrs[window]![kAXSubroleAttribute] = kAXStandardWindowSubrole as CFString
            place(zones[1])
            store.assign(.template(.blank), to: store.displays[0])
            snapper.move(.left)
            #expect(h.log.contains("hotkey left: pid 91001 no zone in band"))
            h.ax.failing[window] = .apiDisabled
            snapper.move(.left)
            #expect(h.log.contains("hotkey left failed: apiDisabled"))
            snapper.stop()
        }
    }
}
