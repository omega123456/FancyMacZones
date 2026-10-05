import AppKit
import Testing
@testable import FancyMacZones

extension Desktop {
    @MainActor @Suite struct LayoutStoreTests {
        let h = Harness()

        @Test func displaysAndCommits() {
            h.screens = [h.main, h.side] // the menu-bar display is first in NSScreen.screens
            let store = LayoutStore()
            #expect(store.displays.map(\.name) == ["Studio Display (Main)", "DELL U2720Q"])
            #expect(store.displays.map(\.uuid) == ["4242", "4243"]) // fake IDs have no display UUID
            let main = store.displays[0], side = store.displays[1]
            #expect(store.layoutName(on: main) == "Priority Grid")
            #expect(store.zones(on: main).count == 3)
            #expect(store.allZones().count == 6)

            var commits = 0
            let token = NotificationCenter.default.addObserver(forName: LayoutStore.didChange, object: store, queue: nil) { _ in
                MainActor.assumeIsolated { commits += 1 }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            store.setZoneCount(5, for: .columns, on: main)
            store.assign(.template(.columns), to: main)
            #expect(store.zoneCount(.columns, on: main) == 5)
            let grid = store.draft(.grid(.initial))
            #expect(grid.name == "Custom Grid 1")
            store.add(grid)
            #expect(store.draft(.canvas(.initial)).name == "Custom Canvas 1")
            store.assign(.custom(grid.id), to: main)
            store.assign(.custom(grid.id), to: side)
            #expect(store.displays(using: grid.id).count == 2)
            store.rename(grid.id, to: "Coding")
            store.replaceBody(grid.id, with: .canvas(.initial))
            #expect(store.customLayouts[0].name == "Coding")
            let copy = store.duplicate(grid.id)
            #expect(copy?.name == "Coding Copy")
            #expect(store.duplicate(UUID()) == nil)
            store.delete(grid.id)
            #expect(store.layout(on: main) == .fallback)
            #expect(commits == 9)

            // Committed changes are on disk; a fresh store reads them back.
            #expect(LayoutStore().customLayouts.map(\.name) == ["Coding Copy"])
            store.replaceAll(with: LayoutFile())
            #expect(LayoutStore().customLayouts.isEmpty)

            // Display changes refresh the list and are announced.
            var changes = 0
            let t2 = NotificationCenter.default.addObserver(forName: LayoutStore.displaysDidChange, object: store, queue: nil) { _ in
                MainActor.assumeIsolated { changes += 1 }
            }
            defer { NotificationCenter.default.removeObserver(t2) }
            h.screens = [h.main, FakeScreen(id: 4244, name: "Studio Display", frame: NSRect(x: -21000, y: -20000, width: 1000, height: 800))]
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(changes == 1)
            #expect(store.displays.map(\.name) == ["Studio Display 1", "Studio Display 2 (Main)"])
        }

        @Test func loadAndSaveFailures() throws {
            let url = LayoutStore.defaultURL
            let fm = FileManager.default
            // Corrupt: renamed aside with a timestamp, defaults used.
            try Data("{".utf8).write(to: url)
            let now = Date(timeIntervalSince1970: 0)
            let (file, aside) = LayoutStore.load(url, now: now)
            #expect(file == LayoutFile())
            #expect(aside?.lastPathComponent.hasPrefix("layouts-corrupt-19700101-") == true)
            #expect(h.log.contains("corrupt file renamed"))

            // Corrupt again in the same second: the rename fails, defaults anyway.
            try Data("{".utf8).write(to: url)
            #expect(LayoutStore.load(url, now: now).renamedTo == nil)
            #expect(h.log.contains("could not be renamed"))

            // Unreadable (a directory): defaults.
            try fm.removeItem(at: url)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(LayoutStore.load(url).file == LayoutFile())
            #expect(h.log.contains("could not read"))

            // A write into a file's "directory" fails and is logged.
            let blocked = h.dir.appendingPathComponent("file")
            try Data().write(to: blocked)
            #expect(!LayoutStore.save(LayoutFile(), to: blocked.appendingPathComponent("layouts.json")))
            #expect(h.log.contains("layouts: save failed"))

            // A valid file loads.
            #expect(LayoutStore.save(LayoutFile(), to: h.dir.appendingPathComponent("ok.json")))
            #expect(LayoutStore.load(h.dir.appendingPathComponent("ok.json")).renamedTo == nil)
            #expect(h.log.contains("layouts: loaded 0 custom, 0 displays"))
        }

        @Test func settings() {
            #expect(Settings.overlapRule == .largestOverlap)
            Settings.overlapRule = .closestCentre
            #expect(Settings.overlapRule == .closestCentre)
            #expect(Settings.dragToTop && Settings.missionControlGuard && Settings.doubleClickMaximize)
            Settings.dragToTop = false
            Settings.missionControlGuard = false
            Settings.doubleClickMaximize = false
            #expect(!Settings.dragToTop && !Settings.missionControlGuard && !Settings.doubleClickMaximize)
            #expect(Settings.moveModifiers == HotKeyModifiers.default)
            Settings.moveModifiers = [.option, .shift, .function] // irrelevant bits are dropped
            #expect(Settings.moveModifiers == [.option, .shift])
            h.defaults.set(Int(NSEvent.ModifierFlags.shift.rawValue), forKey: "moveModifiers") // invalid: Shift alone
            #expect(Settings.moveModifiers == HotKeyModifiers.default)
        }
    }
}
