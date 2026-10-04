import AppKit
import ServiceManagement
import Testing
@testable import FancyMacZones

extension Desktop {
    @MainActor @Suite struct MenuBarTests {
        let h = Harness()

        func items(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

        func choose(_ title: String, in menu: NSMenu) {
            guard let item = menu.items.first(where: { $0.title == title }) else { Issue.record("no \(title)"); return }
            NSApp.sendAction(item.action!, to: item.target, from: item)
        }

        @Test func trustedMenu() throws {
            let store = LayoutStore()
            let bar = MenuBar(store: store)
            bar.trusted = true
            bar.menuNeedsUpdate(bar.menu)
            let all = items(bar.menu)
            #expect(all.first?.hasPrefix("FancyMacZones Dev") == true)
            #expect(all.contains("Layout — Priority Grid")) // one display: the collapsed row
            #expect(all.contains("⌃⌘ ←→↑↓  Move Window to Adjacent Zone"))

            // The layout submenu: templates, then custom layouts by name; choosing one assigns it.
            store.add(CustomLayout(id: UUID(), name: "b", body: .grid(.initial)))
            store.add(CustomLayout(id: UUID(), name: "A", body: .grid(.initial)))
            bar.menuNeedsUpdate(bar.menu)
            let layouts = bar.menu.items.first { $0.title.hasPrefix("Layout") }!.submenu!
            #expect(items(layouts) == ["Blank", "-", "Focus", "Columns", "Rows", "Grid", "Priority Grid", "-", "A", "b"])
            #expect(layouts.items.first { $0.title == "Priority Grid" }?.state == .on)
            choose("Columns", in: layouts)
            #expect(store.layoutName(on: store.displays[0]) == "Columns")
            layouts.items[0].representedObject = nil
            choose("Blank", in: layouts) // not a choice: ignored

            // Overlap rule and toggles.
            let rules = bar.menu.items.first { $0.title == "Overlap Rule" }!.submenu!
            choose("Closest Centre Wins", in: rules)
            #expect(Settings.overlapRule == .closestCentre)
            rules.items[0].representedObject = "nonsense"
            choose("Smallest Zone Wins", in: rules)
            #expect(Settings.overlapRule == .closestCentre)
            choose("Drag to Top to Maximize", in: bar.menu)
            choose("Double-Click Title Bar to Maximize", in: bar.menu)
            choose("Prevent Mission Control While Dragging", in: bar.menu)
            #expect(!Settings.dragToTop && !Settings.doubleClickMaximize && !Settings.missionControlGuard)

            // Launch at Login: registering may need approval in System Settings; on again unregisters.
            choose("Launch at Login", in: bar.menu)
            #expect(h.loginCalls == ["register", "settings"])
            choose("Launch at Login", in: bar.menu) // requires approval: settings again
            h.loginStatus = .enabled
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.menu.items.first { $0.title == "Launch at Login" }?.state == .on)
            choose("Launch at Login", in: bar.menu)
            h.loginError = CocoaError(.featureUnsupported)
            choose("Launch at Login", in: bar.menu)
            #expect(h.loginCalls == ["register", "settings", "settings", "unregister", "register"])
            #expect(h.log.contains("launch at login failed"))

            // Updates: a development build can't update.
            choose("Check for Updates…", in: bar.menu)
            #expect(h.notices == ["Updates unavailable"])
            choose("Automatic Updates", in: bar.menu)
            #expect(!Updater.isEnabled)
            choose("Automatic Updates", in: bar.menu)
            #expect(Updater.isEnabled)

            choose("Quit FancyMacZones", in: bar.menu)
            #expect(h.terminations == 1)

            // Several displays: one row each.
            h.screens = [h.main, h.side]
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            bar.menuNeedsUpdate(bar.menu)
            #expect(items(bar.menu).contains("DELL U2720Q — Priority Grid"))

            // Edit Layouts… opens the editor window.
            choose("Edit Layouts…", in: bar.menu)
            #expect(EditorWindow.shared != nil)
            EditorWindow.shared?.window.close()
        }

        @Test func exportAndImport() throws {
            let store = LayoutStore()
            let bar = MenuBar(store: store)
            bar.trusted = true
            store.add(CustomLayout(id: UUID(), name: "Coding", body: .grid(.initial)))
            bar.menuNeedsUpdate(bar.menu)

            // Cancelled panels do nothing.
            choose("Export Layouts…", in: bar.menu)
            choose("Import Layouts…", in: bar.menu)
            #expect(h.panels.count == 2)
            #expect(h.activations == 2)

            let url = h.dir.appendingPathComponent("export.json")
            h.panelURL = url
            choose("Export Layouts…", in: bar.menu)
            #expect(LayoutStore.load(url).file.customLayouts.map(\.name) == ["Coding"])
            try Data().write(to: h.dir.appendingPathComponent("file")) // a file where the folder would be
            h.panelURL = h.dir.appendingPathComponent("file/x.json")
            choose("Export Layouts…", in: bar.menu)
            #expect(h.alerts.last?.messageText == "Export Failed")

            // Import: confirmed replaces everything; cancelled keeps it; a foreign file is refused.
            store.replaceAll(with: LayoutFile())
            h.panelURL = url
            h.alertResponse = .alertSecondButtonReturn
            choose("Import Layouts…", in: bar.menu)
            #expect(store.customLayouts.isEmpty)
            h.alertResponse = .alertFirstButtonReturn
            choose("Import Layouts…", in: bar.menu)
            #expect(h.alerts.last?.messageText == "Replace All Layouts?")
            #expect(store.customLayouts.map(\.name) == ["Coding"])
            try Data("nope".utf8).write(to: url)
            choose("Import Layouts…", in: bar.menu)
            #expect(h.alerts.last?.messageText == "Import Failed")
        }

        @Test func untrustedMenu() {
            let bar = MenuBar(store: LayoutStore())
            bar.trusted = false
            bar.trusted = true
            bar.trusted = false
            bar.menuNeedsUpdate(bar.menu)
            #expect(items(bar.menu).dropFirst(2) == ["Accessibility Access Needed", "FancyMacZones needs this to move windows.",
                                                     "Open Accessibility Settings…", "-", "Quit FancyMacZones"])
            choose("Open Accessibility Settings…", in: bar.menu)
            #expect(h.ws.opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
        }
    }

    @MainActor @Suite struct AppTests {
        let h = Harness()

        @Test func trustGating() async {
            let app = AppDelegate()
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            #expect(h.ax.prompts == 1)
            #expect(app.menuBar.trusted)
            #expect(h.log.contains("tap installed"))

            // Revoked: everything stops and a 1 s poll waits for the grant.
            h.ax.trusted = false
            app.perform(NSSelectorFromString("accessibilityChanged"))
            await settle(0.4)
            #expect(!app.menuBar.trusted)
            #expect(h.log.contains("accessibility revoked"))
            #expect(h.log.contains("waiting for accessibility (1 s poll)"))
            AX.onAPIDisabled?() // an AX call saw "API disabled": re-checked, still untrusted
            await settle()
            h.ax.trusted = true
            await settle(1.3)
            #expect(app.menuBar.trusted)
            #expect(h.log.contains("accessibility trusted"))

            // Theme changes redraw the overlay.
            h.ws.center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            app.snapper.stop()
        }

        @Test func eventLog() {
            EventLog.write("hello")
            #expect(h.log.contains(" hello\n"))
            EventLog.removeFile()
            #expect(!FileManager.default.fileExists(atPath: EventLog.url.path))
        }
    }
}
