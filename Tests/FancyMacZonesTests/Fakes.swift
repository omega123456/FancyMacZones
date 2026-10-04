import AppKit
import Carbon
import ServiceManagement
import Testing
@testable import FancyMacZones

/// Every test that swaps the global seams (`Env`, `AX.backend`, …) is nested in this suite, so none run concurrently.
@Suite(.serialized) struct Desktop {}

/// A display far off the real desktop: overlay panels and editor windows created for it are real windows nobody sees.
final class FakeScreen: NSScreen {
    let id: CGDirectDisplayID
    let name: String
    var rect: NSRect
    var visible: NSRect

    init(id: CGDirectDisplayID, name: String = "Studio Display", frame: NSRect, visible: NSRect? = nil) {
        self.id = id
        self.name = name
        rect = frame
        self.visible = visible ?? frame
        super.init()
    }

    override var frame: NSRect { rect }
    override var visibleFrame: NSRect { visible }
    override var localizedName: String { name }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] { [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: id)] }
}

/// A titled window AppKit never constrains onto a real display (it stays on the fake one, off the desktop).
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Own notification center (system workspace events never arrive), no real URL opens.
final class FakeWorkspace: NSWorkspace {
    let center = NotificationCenter()
    var opened: [URL] = []
    var contrast = false, solid = false

    override var notificationCenter: NotificationCenter { center }
    override var accessibilityDisplayShouldIncreaseContrast: Bool { contrast }
    override var accessibilityDisplayShouldReduceTransparency: Bool { solid }
    override func open(_ url: URL) -> Bool { opened.append(url); return true }
}

/// An in-memory Accessibility world behind `AX.backend`. Elements are distinct AXUIElement refs (application
/// elements of unused pids); `pids` says which app each belongs to.
final class FakeAX {
    var attrs: [AXUIElement: [String: CFTypeRef]] = [:]
    var failing: [AXUIElement: AXError] = [:] // every call on the element returns this
    var failingSets: [AXUIElement: AXError] = [:] // only writes return this
    var windowIDs: [AXUIElement: CGWindowID] = [:]
    var pids: [AXUIElement: pid_t] = [:]
    var sets: [(element: AXUIElement, attribute: String, value: CFTypeRef)] = []
    var hit: AXUIElement?       // the element at any point
    var hitError = AXError.success
    var trusted = true
    var prompts = 0
    private var next: pid_t = 95_000

    static let missing: CFTypeRef = { var e = AXError.noValue; return AXValueCreate(.axError, &e)! }()
    static let systemWide = AXUIElementCreateSystemWide()

    func element(of pid: pid_t) -> AXUIElement {
        next += 1
        let el = AXUIElementCreateApplication(next)
        pids[el] = pid
        return el
    }

    var backend: AX.Backend {
        var b = AX.Backend()
        b.copy = { [unowned self] el, attr in
            if let e = failing[el] { return (e, nil) }
            guard let v = attrs[el]?[attr] else { return (.noValue, nil) }
            return (.success, v)
        }
        b.copyMultiple = { [unowned self] el, list in
            if let e = failing[el] { return (e, nil) }
            guard let a = attrs[el] else { return (.failure, nil) }
            return (.success, list.map { a[$0] ?? Self.missing } as CFArray)
        }
        b.set = { [unowned self] el, attr, v in
            if let e = failing[el] ?? failingSets[el] { return e }
            sets.append((el, attr, v))
            attrs[el, default: [:]][attr] = v
            return .success
        }
        b.elementAt = { [unowned self] _ in (hitError, hitError == .success ? hit : nil) }
        b.windowID = { [unowned self] in windowIDs[$0] }
        b.pid = { [unowned self] in pids[$0] }
        b.isTrusted = { [unowned self] prompt in
            if prompt { prompts += 1 }
            return trusted
        }
        return b
    }

    /// The frames written to `el`, as AX rects (size → position → size).
    func writes(_ el: AXUIElement) -> [String] {
        sets.filter { $0.element == el }.map { s in
            if let p = AX.point(s.value) { return "pos \(Int(p.x)),\(Int(p.y))" }
            if let z = AX.size(s.value) { return "size \(Int(z.width))x\(Int(z.height))" }
            return "\(s.attribute)=\(s.value)"
        }
    }
}

func axPoint(_ p: CGPoint) -> CFTypeRef { var p = p; return AXValueCreate(.cgPoint, &p)! }
func axSize(_ s: CGSize) -> CFTypeRef { var s = s; return AXValueCreate(.cgSize, &s)! }

/// Lets main-queue work (async deliveries, coalesced reloads, timers) run.
func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }

/// Installs fresh fakes behind every seam. One per test.
@MainActor
final class Harness {
    let ws = FakeWorkspace()
    let ax = FakeAX()
    /// Primary display: menu bar strip of 25 pt at the top, Dock-free.
    let main = FakeScreen(id: 4242, frame: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                          visible: NSRect(x: -20000, y: -20000, width: 1200, height: 775))
    /// To the right of the main display, same top edge.
    let side = FakeScreen(id: 4243, name: "DELL U2720Q", frame: NSRect(x: -18800, y: -19800, width: 800, height: 600))
    var screens: [NSScreen]
    /// The WindowServer list, front to back; CG bounds.
    var windows: [[String: Any]] = []
    var defaults: UserDefaults
    var activations = 0, terminations = 0, beeps = 0
    var panels: [NSSavePanel] = []
    var panelURL: URL?
    var alerts: [NSAlert] = []
    var alertResponse = NSApplication.ModalResponse.alertFirstButtonReturn
    /// Runs on each sheet before it is answered (e.g. to type into the rename field).
    var onSheet: ((NSAlert) -> Void)?
    var popUps: [NSMenu] = []
    var tapEnables: [Bool] = []
    var tapAvailable = true
    var hotKeys: [UInt32] = []   // registered key codes
    var hotKeyFailures = Set<UInt32>()
    var unregistered = 0
    var loginStatus = SMAppService.Status.notRegistered
    var loginCalls: [String] = []
    var loginError: Error?
    var notices: [String] = []
    var asks: [String] = []
    var relaunches: [URL] = []
    let dir: URL

    init() {
        _ = NSApplication.shared
        screens = [main]
        // Windows from earlier tests are gone for good.
        EditorWindow.shared?.window.close()
        EditorWindow.shared = nil
        for w in NSApp.windows { w.orderOut(nil) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FancyMacZonesTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "local.fancymaczones.tests")!
        defaults.removePersistentDomain(forName: "local.fancymaczones.tests")

        Env.workspace = ws
        Env.screens = { [unowned self] in screens }
        Env.defaults = defaults
        Env.activate = { [unowned self] in activations += 1 }
        Env.terminate = { [unowned self] in terminations += 1 }
        Env.beep = { [unowned self] in beeps += 1 }
        AX.backend = ax.backend
        AX.onAPIDisabled = nil
        AX.isWindowIDAvailable = true
        Snapper.createTap = { [unowned self] _, _, _ in tapAvailable ? Harness.dummyPort() : nil }
        Snapper.enableTap = { [unowned self] _, on in tapEnables.append(on) }
        Snapper.windowList = { [unowned self] option, id in
            option.contains(.optionIncludingWindow) ? windows.filter { $0[kCGWindowNumber as String] as? CGWindowID == id } : windows
        }
        Snapper.registerHotKey = { [unowned self] key, _, id in
            if hotKeyFailures.contains(key) { return (OSStatus(eventHotKeyExistsErr), nil) }
            hotKeys.append(key)
            return (noErr, OpaquePointer(bitPattern: Int(id.id) + 1))
        }
        Snapper.unregisterHotKey = { [unowned self] _ in unregistered += 1 }
        MenuBar.showsStatusItem = false
        MenuBar.runPanel = { [unowned self] panel in panels.append(panel); return panelURL }
        MenuBar.runAlert = { [unowned self] alert in alerts.append(alert); return alertResponse }
        EditorWindow.runSheet = { [unowned self] alert, _, done in
            alerts.append(alert)
            onSheet?(alert)
            done(alertResponse)
        }
        EditorWindow.windowClass = OffscreenWindow.self
        GridEditorView.popUp = { [unowned self] menu, _, _ in popUps.append(menu) }
        LaunchAtLogin.service = .init(
            status: { [unowned self] in loginStatus },
            register: { [unowned self] in
                loginCalls.append("register")
                if let loginError { throw loginError }
                loginStatus = .requiresApproval
            },
            unregister: { [unowned self] in loginCalls.append("unregister"); loginStatus = .notRegistered },
            openSettings: { [unowned self] in loginCalls.append("settings") })
        ZoneStyle.accent = { NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1) }
        Updater.isInstallable = false
        Updater.current = "1.0.0"
        Updater.bundleURL = dir.appendingPathComponent("FancyMacZones.app")
        Updater.notice = { [unowned self] header, _ in notices.append(header) }
        Updater.ask = { [unowned self] version, _ in asks.append(version) }
        Updater.verify = { _ in }
        Updater.relaunch = { [unowned self] in relaunches.append($0) }
        LayoutStore.defaultURL = dir.appendingPathComponent("layouts.json")
        EventLog.url = dir.appendingPathComponent("events.log")
        EventLog.enable()
    }

    var log: String { (try? String(contentsOf: EventLog.url, encoding: .utf8)) ?? "" }

    static func dummyPort() -> CFMachPort {
        CFMachPortCreate(nil, { _, _, _, _ in }, nil, nil)!
    }

    /// Cocoa ↔ CG for the primary display.
    var primaryHeight: CGFloat { main.frame.height }
    func cg(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    func cg(_ r: CGRect) -> CGRect { Layouts.axRect(fromCocoa: r, primaryHeight: primaryHeight) }

    /// A WindowServer entry (layer 0 unless given) at a Cocoa frame.
    func listWindow(_ id: CGWindowID, pid: pid_t, frame: CGRect, layer: Int = 0) {
        windows.removeAll { $0[kCGWindowNumber as String] as? CGWindowID == id }
        windows.append([kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
                        kCGWindowBounds as String: cg(frame).dictionaryRepresentation])
    }

    /// A standard AX window of `pid`, listed in its app's AXWindows, at a Cocoa frame.
    @discardableResult
    func axWindow(_ id: CGWindowID, pid: pid_t, frame: CGRect, subrole: String = kAXStandardWindowSubrole) -> AXUIElement {
        let el = ax.element(of: pid)
        ax.windowIDs[el] = id
        let r = cg(frame)
        ax.attrs[el] = [kAXPositionAttribute: axPoint(r.origin), kAXSizeAttribute: axSize(r.size),
                        kAXSubroleAttribute: subrole as CFString, kAXRoleAttribute: kAXWindowRole as CFString,
                        "AXFullScreen": kCFBooleanFalse]
        let app = AXUIElementCreateApplication(pid)
        ax.pids[app] = pid
        let list = (ax.attrs[app]?[kAXWindowsAttribute] as? [AnyObject]) ?? []
        ax.attrs[app, default: [:]][kAXWindowsAttribute] = (list + [el]) as CFArray
        return el
    }

    /// Makes `window` the focused window of the frontmost app `pid`.
    func focus(_ window: AXUIElement, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        ax.pids[app] = pid
        ax.attrs[FakeAX.systemWide, default: [:]][kAXFocusedApplicationAttribute] = app
        ax.attrs[app, default: [:]][kAXFocusedWindowAttribute] = window
    }

    /// Writes a layouts.json for the next `LayoutStore()`.
    func writeLayouts(_ file: LayoutFile) {
        LayoutStore.save(file, to: LayoutStore.defaultURL)
    }
}

/// A view hosted in a borderless window that is never ordered on screen, so events can target it.
@MainActor
func host(_ view: NSView, appearance: NSAppearance.Name = .aqua) -> NSWindow {
    let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: view.frame.maxX, height: view.frame.maxY),
                     styleMask: .borderless, backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: appearance)
    let root = NSView(frame: CGRect(origin: .zero, size: w.frame.size))
    root.addSubview(view)
    w.contentView = root
    return w
}

/// A mouse event at a point in the view's coordinates.
@MainActor
func mouse(_ type: NSEvent.EventType, at p: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                       windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}

/// A mouse-exited event for the view.
@MainActor
func exited(_ view: NSView) -> NSEvent {
    NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
}

/// A key-down for `keyCode` (with `characters` for letter keys).
@MainActor
func key(_ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], in view: NSView? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: view?.window?.windowNumber ?? 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

/// A flags-changed event with `flags` held.
@MainActor
func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
}

/// Every subview of `view` of type `T`, depth first.
@MainActor
func subviews<T: NSView>(_ view: NSView?, _: T.Type) -> [T] {
    guard let view else { return [] }
    return view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + subviews($0, T.self) }
}
