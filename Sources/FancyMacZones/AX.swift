import ApplicationServices
import Foundation

/// Calls that must abort the current batch of reads for an app.
enum AXFailure: Error {
    case timeout       // kAXErrorCannotComplete: the 0.25 s messaging timeout hit (or the app is busy)
    case apiDisabled   // Accessibility trust was revoked
}

/// Minimal Accessibility vocabulary. No business logic.
/// Reads return nil for ordinary failures (missing attribute, no value) and throw only
/// `AXFailure`, so callers can abandon an unresponsive app with one `catch`.
enum AX {
    /// Called (synchronously) whenever any AX call reports "API disabled".
    static var onAPIDisabled: (() -> Void)?

    /// The Accessibility C calls everything below goes through. Tests replace it with a fake Accessibility world.
    struct Backend {
        var copy: (AXUIElement, String) -> (AXError, CFTypeRef?) = { el, attr in
            var value: CFTypeRef?
            return (AXUIElementCopyAttributeValue(el, attr as CFString, &value), value)
        }
        var copyMultiple: (AXUIElement, [String]) -> (AXError, CFArray?) = { el, attrs in
            var out: CFArray?
            return (AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out), out)
        }
        var set: (AXUIElement, String, CFTypeRef) -> AXError = { AXUIElementSetAttributeValue($0, $1 as CFString, $2) }
        var elementAt: (CGPoint) -> (AXError, AXUIElement?) = { p in
            var el: AXUIElement?
            return (AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el), el)
        }
        var windowID: (AXUIElement) -> CGWindowID? = { el in
            var id: CGWindowID = 0
            guard let fn = getWindowFn, fn(el, &id) == .success, id != 0 else { return nil }
            return id
        }
        var pid: (AXUIElement) -> pid_t? = { el in
            var pid: pid_t = 0
            return AXUIElementGetPid(el, &pid) == .success ? pid : nil
        }
        var isTrusted: (_ prompt: Bool) -> Bool = { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": $0] as CFDictionary) }
    }
    static var backend = Backend()

    static func isTrusted(_ prompt: Bool = false) -> Bool { backend.isTrusted(prompt) }

    @discardableResult
    static func check(_ err: AXError) throws -> Bool {
        switch err {
        case .success: return true
        case .cannotComplete: throw AXFailure.timeout
        case .apiDisabled:
            onAPIDisabled?()
            throw AXFailure.apiDisabled
        default: return false
        }
    }

    // MARK: Private window-ID mapping (optional: DD-4 falls back to the app's focused window)

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindowFn: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static var isWindowIDAvailable = getWindowFn != nil

    static func windowID(_ el: AXUIElement) -> CGWindowID? { backend.windowID(el) }

    // MARK: Attribute reads

    static func raw(_ el: AXUIElement, _ attr: String) throws -> CFTypeRef? {
        let (err, value) = backend.copy(el, attr)
        return try check(err) ? value : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) throws -> String? { try raw(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) throws -> Bool? { try raw(el, attr) as? Bool }
    static func element(_ el: AXUIElement, _ attr: String) throws -> AXUIElement? { asElement(try raw(el, attr)) }
    static func elements(_ el: AXUIElement, _ attr: String) throws -> [AXUIElement] {
        (try raw(el, attr) as? [AnyObject])?.compactMap { asElement($0) } ?? []
    }

    /// Several attributes in one IPC round trip. nil if the whole call failed;
    /// individual attributes that failed come back as nil entries.
    static func values(_ el: AXUIElement, _ attrs: [String]) throws -> [CFTypeRef?]? {
        let (err, out) = backend.copyMultiple(el, attrs)
        guard try check(err), let array = out as? [AnyObject], array.count == attrs.count else { return nil }
        return array.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(v, to: AXValue.self)) == .axError { return nil }
            return v
        }
    }

    static func asElement(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        var p = CGPoint.zero
        return axValue(v).map { AXValueGetValue($0, .cgPoint, &p) } == true ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        var s = CGSize.zero
        return axValue(v).map { AXValueGetValue($0, .cgSize, &s) } == true ? s : nil
    }

    private static func axValue(_ v: CFTypeRef?) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXValue.self)
    }

    // MARK: Windows (DD-4, requirement 13)

    /// The window's frame in AX (top-left global) coordinates, position and size in one call.
    static func frame(_ window: AXUIElement) throws -> CGRect? {
        guard let v = try values(window, [kAXPositionAttribute, kAXSizeAttribute]),
              let origin = point(v[0]), let size = size(v[1]) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The deepest element at a point in AX (top-left global) coordinates.
    static func element(at p: CGPoint) throws -> AXUIElement? {
        let (err, el) = backend.elementAt(p)
        return try check(err) ? el : nil
    }

    /// The focused window of the frontmost app: system-wide → focused application → focused window. Electron apps
    /// can answer neither, so fall back to the frontmost app, then its main window, then its first window.
    static func focusedWindow() throws -> (app: AXUIElement, window: AXUIElement, pid: pid_t)? {
        let frontmost = Env.workspace.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
        guard let app = try element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) ?? frontmost,
              let window = try element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
                ?? elements(app, kAXWindowsAttribute).first,
              let pid = backend.pid(app) else { return nil }
        return (app, window, pid)
    }

    /// The `kAXWindows` entry of `pid` with window ID `id`. Without `_AXUIElementGetWindow`, the app's focused window.
    static func window(pid: pid_t, id: CGWindowID) throws -> (app: AXUIElement, window: AXUIElement)? {
        let app = AXUIElementCreateApplication(pid)
        let window = isWindowIDAvailable
            ? try elements(app, kAXWindowsAttribute).first { windowID($0) == id }
            : try element(app, kAXFocusedWindowAttribute)
        return window.map { (app, $0) }
    }

    /// Requirement 13 (AX part): an `AXStandardWindow` that is not full screen. The own-process check is the caller's.
    static func isStandardWindow(_ window: AXUIElement) throws -> Bool {
        guard let v = try values(window, [kAXSubroleAttribute, "AXFullScreen"]) else { return false }
        return v[0] as? String == kAXStandardWindowSubrole && v[1] as? Bool != true
    }

    /// DD-4: read before a frame write, set to false during it, then restored.
    static func enhancedUserInterface(_ app: AXUIElement) throws -> Bool? { try bool(app, "AXEnhancedUserInterface") }

    // MARK: Writes

    /// Writes log every failure (ordinary ones would otherwise vanish as `false`).
    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: Bool) throws -> Bool {
        try checkLogged(backend.set(el, attr, (value ? kCFBooleanTrue : kCFBooleanFalse)!), "set \(attr)")
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CGSize) throws -> Bool {
        var v = value
        return try checkLogged(backend.set(el, attr, AXValueCreate(.cgSize, &v)!), "set \(attr)")
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CGPoint) throws -> Bool {
        var v = value
        return try checkLogged(backend.set(el, attr, AXValueCreate(.cgPoint, &v)!), "set \(attr)")
    }

    @discardableResult
    static func setEnhancedUserInterface(_ app: AXUIElement, _ on: Bool) throws -> Bool {
        try set(app, "AXEnhancedUserInterface", on)
    }

    private static func checkLogged(_ err: AXError, _ what: String) throws -> Bool {
        if err != .success { EventLog.write("ax \(what) failed: AXError \(err.rawValue)") }
        return try check(err)
    }
}
