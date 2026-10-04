import AppKit
import Testing
@testable import FancyMacZones

extension Desktop {
    @MainActor @Suite struct ZoneEditorTests {
        let h = Harness()
        static let frame = CGRect(x: 0, y: 0, width: 600, height: 360)

        /// Each gesture is its own event: yield a run-loop turn so the undo manager closes its group.
        func click(_ e: NSView, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) async {
            e.mouseDown(with: mouse(.leftMouseDown, at: p, in: e, flags: flags))
            e.mouseUp(with: mouse(.leftMouseUp, at: p, in: e, flags: flags))
            await settle(0)
        }

        func drag(_ e: NSView, _ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) async {
            e.mouseDown(with: mouse(.leftMouseDown, at: a, in: e))
            e.mouseDragged(with: mouse(.leftMouseDragged, at: b, in: e, flags: flags))
            e.mouseUp(with: mouse(.leftMouseUp, at: b, in: e))
            await settle(0)
        }

        func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

        // MARK: Grid

        @Test func gridMouse() async {
            let e = GridEditorView(.initial, frame: Self.frame, history: UndoManager())
            let w = host(e)
            defer { w.close() }
            var grid: GridLayout { if case .grid(let g) = e.body { g } else { fatalError() } }

            await click(e, CGPoint(x: 150, y: 180)) // splits the left zone at x 150
            await click(e, CGPoint(x: 450, y: 180), flags: .shift) // splits the right zone horizontally
            #expect(grid.zoneCount == 4)
            #expect(grid.columns == [0.25, 0.25, 0.5])
            e.undo(nil)
            #expect(grid.zoneCount == 3)
            #expect(e.validateMenuItem(item(#selector(ZoneEditorView.redo(_:)))))
            e.redo(nil)
            #expect(grid.zoneCount == 4)
            #expect(!e.validateMenuItem(item(#selector(ZoneEditorView.redo(_:)))))
            #expect(e.validateMenuItem(item(#selector(ZoneEditorView.undo(_:)))))
            #expect(e.validateMenuItem(item(#selector(NSText.copy(_:)))))

            // Too small to split: a beep, nothing changes.
            await click(e, CGPoint(x: 20, y: 180))
            #expect(h.beeps == 1)
            #expect(grid.zoneCount == 4)

            // Dragging the divider at x 150 moves it, live, as one undo step.
            await drag(e, CGPoint(x: 150, y: 100), CGPoint(x: 210, y: 100))
            #expect(abs(grid.columns[0] - 0.35) < 1e-6)
            e.undo(nil)
            #expect(abs(grid.columns[0] - 0.25) < 1e-6)

            // Selecting across the two right zones offers Merge.
            e.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 450, y: 90), in: e))
            e.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 452, y: 90), in: e)) // < 4 pt: still a press
            e.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 450, y: 200), in: e))
            e.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 450, y: 270), in: e))
            e.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 450, y: 270), in: e))
            await settle(0)
            #expect(h.popUps.count == 1)
            let merge = h.popUps[0].items[0]
            #expect(merge.title == "Merge")
            e.perform(merge.action, with: merge)
            await settle(0)
            #expect(grid.zoneCount == 3)
            merge.representedObject = nil
            e.perform(merge.action, with: merge) // stale: ignored
            #expect(grid.zoneCount == 3)

            // An L-shaped selection can't merge: no popup.
            await click(e, CGPoint(x: 450, y: 180), flags: .shift)
            await drag(e, CGPoint(x: 100, y: 180), CGPoint(x: 450, y: 270))
            #expect(h.popUps.count == 1)

            // Stray drags and releases with no gesture.
            e.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 10, y: 10), in: e))
            e.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 10, y: 10), in: e))
            e.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: -50, y: -50), in: e))
            e.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: -50, y: -50), in: e))

            // Hover: the split preview, the resize cursor over a divider, Shift to rotate.
            e.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 50), in: e))
            e.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 180), in: e))
            e.flagsChanged(with: flags(.shift))
            e.mouseExited(with: exited(e))
            e.display()
        }

        @Test func gridKeyboardAndAccessibility() async {
            let e = GridEditorView(.initial, frame: Self.frame, history: UndoManager())
            let w = host(e)
            defer { w.close() }
            var done = 0
            e.onDone = { done += 1 }
            var grid: GridLayout { if case .grid(let g) = e.body { g } else { fatalError() } }

            e.keyDown(with: key(48, "\t")) // focus: zone 1
            e.keyDown(with: key(1, "s")) // split through its middle
            #expect(grid.columns == [0.25, 0.25, 0.5])
            e.keyDown(with: key(1, "S", flags: .shift)) // the focused zone 1, horizontally
            #expect(grid.zoneCount == 4)
            #expect(!e.handleKey(key(7, "x")))
            e.keyDown(with: key(51)) // Delete on a zone: beep
            #expect(h.beeps == 1)

            // Tab backwards from the first stop wraps to the last: a divider.
            e.keyDown(with: key(48, "\t")) // first stop
            e.keyDown(with: key(48, "\t", flags: .shift))
            e.keyDown(with: key(48, "\t", flags: .shift))
            // Arrows move a focused divider; Delete merges across it.
            await click(e, CGPoint(x: 300, y: 180)) // the middle vertical divider
            e.keyDown(with: key(124))
            #expect(abs(grid.columns[0] + grid.columns[1] - (0.5 + 10.0 / 600)) < 1e-6)
            e.keyDown(with: key(123, flags: .option))
            #expect(abs(grid.columns[0] + grid.columns[1] - (0.5 + 9.0 / 600)) < 1e-6)
            #expect(!e.handleKey(key(126))) // up/down don't move a vertical divider
            #expect(!e.handleKey(key(1, "s")))
            let zones = grid.zoneCount
            e.keyDown(with: key(51))
            #expect(grid.zoneCount < zones)

            // Return, Enter and Esc finish.
            for code: UInt16 in [36, 76, 53] { e.keyDown(with: key(code)) }
            #expect(done == 3)

            // VoiceOver: one item per zone and per divider; dividers adjust in 10 pt steps.
            let items = e.accessibilityChildren() as! [NSAccessibilityElement]
            #expect(items.count == grid.zoneCount + grid.dividers.count)
            #expect(items.first?.accessibilityLabel() == "Zone 1 of \(grid.zoneCount)")
            let slider = items.first { $0.accessibilityRole() == .slider }!
            let before = grid
            #expect(slider.accessibilityPerformIncrement())
            #expect(grid != before)
            #expect(slider.accessibilityPerformDecrement())
            #expect(!items[0].accessibilityPerformIncrement())
            #expect(!items[0].accessibilityPerformDecrement())
            #expect(!items[0].accessibilityPerformPress())
            #expect(e.accessibilityChildren()?.count == items.count) // cached until the next change
        }

        // MARK: Canvas

        @Test func canvasMouse() async {
            let e = CanvasEditorView(.initial, frame: Self.frame, history: UndoManager())
            let w = host(e)
            defer { w.close() }
            var canvas: CanvasLayout { if case .canvas(let c) = e.body { c } else { fatalError() } }
            func points(_ i: Int) -> CGRect { // rounded: fractions carry float noise
                let r = Layouts.points(canvas.zones[i], area: Self.frame.size)
                return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
            }

            // The initial zone: 210…390 × 126…234. A click selects it; a drag moves it, as one undo step.
            await click(e, CGPoint(x: 300, y: 180))
            await drag(e, CGPoint(x: 300, y: 180), CGPoint(x: 320, y: 190))
            #expect(points(0).origin == CGPoint(x: 230, y: 136))
            e.undo(nil)
            #expect(points(0).origin == CGPoint(x: 210, y: 126))
            e.redo(nil)

            // ⌥ during a drag turns snapping off; released near the display edge it would have snapped.
            e.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 300, y: 180), in: e))
            e.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 75, y: 180), in: e, flags: .option))
            e.flagsChanged(with: flags(.option))
            e.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 75, y: 180), in: e))
            #expect(points(0).minX == 5)

            // The bottom-right handle resizes.
            let r = points(0)
            await drag(e, CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX + 150, y: r.maxY + 20))
            #expect(points(0).size == CGSize(width: r.width + 150, height: r.height + 20))

            // Hover over a handle and elsewhere.
            e.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: points(0).minX, y: points(0).minY), in: e))
            e.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 590, y: 350), in: e))
            e.mouseExited(with: exited(e))

            // A second zone over the first: clicking the overlap again at the same point selects the one below.
            e.addZone()
            #expect(canvas.zones.count == 2)
            let overlap = CGPoint(x: points(1).minX + 5, y: points(1).minY + 30)
            #expect(points(0).contains(overlap))
            await click(e, overlap) // already selected (the new zone): drag start
            await click(e, overlap) // again: cycles below
            e.display()
            #expect(e.accessibilityChildren()?.count == 3) // two zones and the selected zone's ×

            // Right-click: Bring to Front / Send to Back / Delete Zone on the zone under the cursor.
            #expect(e.menu(for: mouse(.rightMouseDown, at: CGPoint(x: 595, y: 355), in: e)) == nil)
            let menu = e.menu(for: mouse(.rightMouseDown, at: overlap, in: e))!
            #expect(menu.items.map(\.title) == ["Bring to Front", "Send to Back", "", "Delete Zone"])
            let bottom = canvas.zones[0]
            e.perform(menu.items[0].action)
            #expect(canvas.zones[1] == bottom)
            e.perform(menu.items[1].action)
            #expect(canvas.zones[0] == bottom)

            // The × deletes the selected zone; empty space deselects.
            let sel = points(0)
            await click(e, CGPoint(x: sel.maxX - 14, y: sel.minY + 14))
            #expect(canvas.zones.count == 1)
            await click(e, CGPoint(x: 595, y: 5))
            e.perform(menu.items[0].action) // nothing selected: ignored
            e.perform(menu.items[1].action)
            e.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 10, y: 10), in: e))
            e.flagsChanged(with: flags([]))
            #expect(canvas.zones.count == 1)
        }

        @Test func canvasKeyboardAndAccessibility() async {
            let e = CanvasEditorView(.initial, frame: Self.frame, history: UndoManager())
            let w = host(e)
            defer { w.close() }
            var canvas: CanvasLayout { if case .canvas(let c) = e.body { c } else { fatalError() } }
            func points(_ i: Int) -> CGRect { // rounded: fractions carry float noise
                let r = Layouts.points(canvas.zones[i], area: Self.frame.size)
                return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
            }

            e.keyDown(with: key(124)) // nothing selected: beep
            #expect(h.beeps == 1)
            e.keyDown(with: key(48, "\t")) // selects zone 1
            e.keyDown(with: key(124))
            e.keyDown(with: key(125, flags: .option))
            #expect(points(0).origin == CGPoint(x: 220, y: 127))
            e.keyDown(with: key(123, flags: .shift)) // ⇧ resizes from the bottom-right
            e.keyDown(with: key(126, flags: [.shift, .option]))
            #expect(points(0).size == CGSize(width: 170, height: 106))
            #expect(!e.handleKey(key(7, "x")))

            e.keyDown(with: key(45, "n"))
            e.keyDown(with: key(45, "N", flags: .shift))
            #expect(canvas.zones.count == 3)
            #expect(points(2).origin == CGPoint(x: points(1).minX + 24, y: points(1).minY + 24)) // cascaded
            e.keyDown(with: key(48, "\t", flags: .shift))
            e.keyDown(with: key(51)) // deletes the selection
            #expect(canvas.zones.count == 2)
            e.keyDown(with: key(117)) // nothing selected now: beep
            #expect(h.beeps == 2)

            // VoiceOver: pressing a zone selects it; the × item deletes it.
            var items = e.accessibilityChildren() as! [NSAccessibilityElement]
            #expect(items.count == 2)
            #expect(items[1].accessibilityPerformPress())
            items = e.accessibilityChildren() as! [NSAccessibilityElement]
            #expect(items.last?.accessibilityLabel() == "Delete Zone")
            #expect(items.last!.accessibilityPerformPress())
            #expect(canvas.zones.count == 1)
        }

        // MARK: Session

        @Test func sessionHandsTheBodyBackOnce() async {
            let d = LayoutStore.Display(uuid: "4242", id: 4242, name: "Studio Display (Main)", frame: h.main.frame, usable: h.main.visibleFrame)
            var results: [CustomLayout.Body] = []
            let grid = ZoneEditorSession(.grid(.initial), on: d) { results.append($0) }
            grid.show()
            #expect(h.activations == 1)
            guard let window = NSApp.windows.last(where: { $0 is FullScreenEditorWindow && $0.isVisible }) as? FullScreenEditorWindow else {
                Issue.record("no editor window: \(NSApp.windows.map { "\(type(of: $0)) \($0.isVisible)" })")
                return
            }
            #expect(window.frame == h.main.frame) // never constrained onto a real display
            #expect(window.canBecomeKey && window.canBecomeMain)
            #expect(grid.windowWillReturnUndoManager(window) != nil)
            h.ws.center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            window.contentView?.display()
            window.performClose(nil) // ⌘W finishes
            grid.finish()
            await settle()
            #expect(results == [.grid(.initial)])
            #expect(!window.isVisible)

            // Canvas: Done is the bar's default button; Return in the editor finishes too.
            let canvas = ZoneEditorSession(.canvas(.initial), on: d) { results.append($0) }
            canvas.show()
            guard let cw = NSApp.windows.last(where: { $0 is FullScreenEditorWindow && $0.isVisible }) else { Issue.record("no canvas window"); return }
            #expect(subviews(cw.contentView, AddButton.self).count == 1)
            let add = subviews(cw.contentView, AddButton.self)[0]
            NSApp.sendAction(add.action!, to: add.target, from: add) // never performClick: its tracking loop can end the test run
            add.display()
            subviews(cw.contentView, ControlBar.self).forEach { $0.updateLayer() }
            let editor = subviews(cw.contentView, CanvasEditorView.self)[0]
            editor.keyDown(with: key(36, "\r"))
            await settle()
            guard case .canvas(let c)? = results.last else { Issue.record("no canvas"); return }
            #expect(c.zones.count == 2)
            _ = grid
        }
    }
}
