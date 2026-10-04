import AppKit
import ApplicationServices
import ServiceManagement

@main
enum FancyMacZonesMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") { exit(SelfTest.run() ? 0 : 1) } // before any UI
        if args.contains("--log-events") { EventLog.enable() } else { EventLog.removeFile() }
        let app = NSApplication.shared // LSUIElement: no Dock icon, no main menu
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// `--log-events`: millisecond-timestamped plain-text lines in ~/Library/Logs/FancyMacZones/events.log
/// (FancyMacZones Dev: ~/Library/Logs/FancyMacZones Dev/events.log), cleared at each launch. The file only exists
/// while the flag is used (requirement 25).
enum EventLog {
    private static var handle: FileHandle?
    #if DEBUG
    private static let folder = "FancyMacZones Dev"
    #else
    private static let folder = "FancyMacZones"
    #endif
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(folder)/events.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func enable() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil) // truncates
        handle = try? FileHandle(forWritingTo: url)
    }

    static func removeFile() { try? FileManager.default.removeItem(at: url) }

    static func write(_ line: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data("\(formatter.string(from: Date())) \(line())\n".utf8))
    }
}

/// Launch at Login via SMAppService.mainApp; the status is always read live, never mirrored (requirement 21).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Enabled → unregister. Requires approval → open Login Items. Otherwise → register
    /// (and open Login Items if the system then asks for approval).
    static func toggle() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            EventLog.write("launch at login failed: \(error)")
        }
        EventLog.write("launch at login status=\(service.status.rawValue)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: LayoutStore!
    private(set) var menuBar: MenuBar!
    private(set) var snapper: Snapper!
    private let overlay = ZoneOverlay()
    private var grantPoll: Timer?
    private var trusted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        EventLog.write("FancyMacZones started pid=\(getpid())")
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25) // global AX timeout (NFR-4)
        store = LayoutStore()
        menuBar = MenuBar(store: store)
        snapper = Snapper(store: store, overlay: overlay)
        // DD-15: the overlay redraws on accent and accessibility-display changes (appearance is per view).
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(themeChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        Updater.start() // independent of Accessibility trust
        AX.onAPIDisabled = { [weak self] in
            DispatchQueue.main.async { self?.updateTrust(AXIsProcessTrusted()) }
        }
        // Agent app: distributed notifications must be delivered immediately, not on activation.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityChanged),
            name: Notification.Name("com.apple.accessibility.api"), object: nil,
            suspensionBehavior: .deliverImmediately)
        updateTrust(AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)) // requirement 20
    }

    @objc private func themeChanged() { overlay.themeChanged() }

    @objc private func accessibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateTrust(AXIsProcessTrusted())
        }
    }

    /// Requirement 20. Trusted → start the tap and hotkeys, stop the grant poll. Untrusted → stop them, poll every 1 s.
    private func updateTrust(_ trusted: Bool) {
        menuBar.trusted = trusted
        if trusted { snapper.start() } else { snapper.stop() }
        defer { self.trusted = trusted }
        if trusted {
            grantPoll?.invalidate()
            grantPoll = nil
            if !self.trusted { EventLog.write("accessibility trusted") }
        } else {
            if self.trusted { EventLog.write("accessibility revoked") }
            if grantPoll == nil {
                EventLog.write("waiting for accessibility (1 s poll)")
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    if AXIsProcessTrusted() { self?.updateTrust(true) }
                }
                timer.tolerance = 0.2
                RunLoop.main.add(timer, forMode: .common)
                grantPoll = timer
            }
        }
    }
}
