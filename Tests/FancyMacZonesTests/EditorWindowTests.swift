import AppKit
import Testing
@testable import FancyMacZones

extension Desktop {
    @MainActor @Suite struct EditorWindowTests {
        let h = Harness()
        let store: LayoutStore

        init() {
            h.screens = [h.main, h.side]
            store = LayoutStore()
        }

        var editor: EditorWindow { EditorWindow.shared! }
        var content: NSView { editor.window.contentView! }
        var cards: [LayoutCard] { subviews(content, LayoutCard.self) }
        func card(_ title: String) -> LayoutCard { cards.first { $0.accessibilityLabel() == title }! }
        var main: LayoutStore.Display { store.displays[0] }

        func press(_ card: LayoutCard, double: Bool = false) {
            card.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: card, clicks: double ? 2 : 1))
        }

        /// The full-screen session's window, if one is showing.
        var sessionWindow: NSWindow? { NSApp.windows.last { $0 is FullScreenEditorWindow && $0.isVisible } }

        func finishSession(editing: (ZoneEditorView) -> Void = { _ in }) async {
            guard let w = sessionWindow, let v = subviews(w.contentView, ZoneEditorView.self).first else {
                Issue.record("no session")
                return
            }
            editing(v)
            v.keyDown(with: key(53)) // Esc saves and exits
            await settle()
        }

        @Test func galleryAndZoneCount() async {
            EditorWindow.show(store: store)
            EditorWindow.show(store: store) // the same window, to the front
            #expect(h.activations == 2)
            let w = editor.window
            #expect(w.isVisible && w.frame.minX < -10000) // centred on the fake main display
            #expect(cards.count == 6)
            #expect(cards.filter(\.selected).map { $0.accessibilityLabel() } == ["Priority Grid"])

            // The Zones box: ▲ / ▼ halves, VoiceOver, the number field (typed, ↑ / ↓), clamped to the range.
            let stepper = subviews(content, ArrowStepper.self)[0]
            let field = subviews(content, NSTextField.self).first { $0.accessibilityLabel() == "Zones" && $0.isEditable }!
            stepper.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 8, y: stepper.bounds.maxY - 2), in: stepper))
            #expect(store.zoneCount(.priorityGrid, on: main) == 4)
            stepper.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 8, y: 2), in: stepper))
            #expect(store.zoneCount(.priorityGrid, on: main) == 3)
            #expect(stepper.accessibilityPerformIncrement())
            #expect(stepper.accessibilityValue() as? Int == 4)
            #expect(stepper.accessibilityRole() == .incrementor && stepper.isAccessibilityElement())
            #expect(stepper.accessibilityPerformDecrement())
            field.integerValue = 99
            NSApp.sendAction(field.action!, to: field.target, from: field)
            #expect(store.zoneCount(.priorityGrid, on: main) == 12)
            #expect(field.integerValue == 12)
            stepper.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 8, y: stepper.bounds.maxY - 2), in: stepper)) // at max
            #expect(editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
            #expect(editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
            #expect(!editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
            #expect(store.zoneCount(.priorityGrid, on: main) == 12)
            await settle()

            // Cards: a click applies, Space applies, VoiceOver presses; Blank hides the Zones box.
            press(card("Columns"))
            #expect(store.layoutName(on: main) == "Columns")
            card("Rows").keyDown(with: key(49, " "))
            #expect(store.layoutName(on: main) == "Rows")
            #expect(card("Rows").accessibilityPerformPress())
            await settle()
            #expect(card("Rows").selected)
            press(card("Blank"))
            await settle()
            #expect(subviews(content, ArrowStepper.self)[0].superview!.isHidden)
            field.integerValue = 5
            NSApp.sendAction(field.action!, to: field.target, from: field) // Blank: no count
            let c = card("Grid")
            #expect(c.acceptsFirstResponder && c.canBecomeKeyView && c.focusRingMaskBounds.width == 120)
            c.drawFocusRingMask()

            // The sidebar: the second display, its own layout; cells and selected rows draw.
            let table = subviews(content, NSTableView.self)[0]
            #expect(table.numberOfRows == 2)
            table.selectRowIndexes([1], byExtendingSelection: false)
            await settle()
            #expect(cards.filter(\.selected).map { $0.accessibilityLabel() } == ["Priority Grid"])
            press(card("Grid"))
            #expect(store.layoutName(on: store.displays[1]) == "Grid")
            table.selectRowIndexes([1], byExtendingSelection: false) // unchanged
            let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as! SidebarCell
            cell.backgroundStyle = .emphasized
            #expect(cell.imageView?.contentTintColor == .white)
            cell.backgroundStyle = .normal
            let row = table.rowView(atRow: 1, makeIfNecessary: true)!
            #expect(row.isEmphasized)
            row.isEmphasized = false
            row.display()

            // Appearance and theme changes redraw; resizing re-flows the gallery.
            w.appearance = NSAppearance(named: .darkAqua)
            h.ws.center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            w.setContentSize(CGSize(width: 640, height: 440))
            content.layoutSubtreeIfNeeded()
            content.display()
            await settle()

            // A display goes away: the sidebar follows.
            h.screens = [h.main]
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await settle()
            #expect(table.numberOfRows == 1)

            // Return on a card (like a double-click) applies and closes; the window is released.
            card("Focus").keyDown(with: key(36, "\r"))
            #expect(!w.isVisible)
            await settle()
            #expect(EditorWindow.shared == nil)
        }

        @Test func customLayouts() async {
            let layout = CustomLayout(id: UUID(), name: "Coding", body: .grid(.initial))
            store.add(layout)
            store.assign(.custom(layout.id), to: store.displays[0])
            store.assign(.custom(layout.id), to: store.displays[1])
            EditorWindow.show(store: store)
            #expect(cards.count == 7)
            #expect(subviews(card("Coding"), NSTextField.self).map(\.stringValue)
                    == ["Coding", "Active on: Studio Display (Main), DELL U2720Q"])
            let buttons = subviews(content, ToolButton.self)
            #expect(buttons.filter { !$0.isHidden }.map(\.title) == ["Edit", "Rename", "Duplicate", "Delete"])
            buttons.forEach { $0.updateLayer(); _ = $0.intrinsicContentSize }

            // Rename: the sheet's field; cancelled, empty and unchanged names do nothing.
            func rename(to name: String, _ response: NSApplication.ModalResponse = .alertFirstButtonReturn) {
                h.alertResponse = response
                h.onSheet = { ($0.accessoryView as? NSTextField)?.stringValue = name }
                editor.perform(NSSelectorFromString("renameSelected"))
            }
            rename(to: "Writing", .alertSecondButtonReturn)
            rename(to: "  ")
            rename(to: "Coding")
            #expect(store.customLayouts[0].name == "Coding")
            rename(to: " Writing ")
            #expect(store.customLayouts[0].name == "Writing")
            h.onSheet = nil

            // The card's context menu: Duplicate, Delete… (named displays fall back), Edit, Rename….
            await settle()
            let menu = card("Writing").menu!
            #expect(menu.items.map(\.title) == ["Edit", "Rename…", "Duplicate", "Delete…"])
            NSApp.sendAction(menu.items[2].action!, to: menu.items[2].target, from: menu.items[2])
            #expect(store.customLayouts.map(\.name) == ["Writing", "Writing Copy"])
            editor.perform(NSSelectorFromString("duplicateSelected"))
            #expect(store.customLayouts.count == 3)
            h.alertResponse = .alertSecondButtonReturn
            NSApp.sendAction(menu.items[3].action!, to: menu.items[3].target, from: menu.items[3])
            #expect(store.customLayouts.count == 3)
            h.alertResponse = .alertFirstButtonReturn
            editor.perform(NSSelectorFromString("deleteSelected"))
            #expect(h.alerts.last?.informativeText.contains("Studio Display (Main), DELL U2720Q") == true)
            #expect(store.customLayouts.map(\.name) == ["Writing Copy", "Writing Copy"])
            #expect(store.layoutName(on: main) == "Priority Grid")
            let copy = store.customLayouts[1].id
            editor.perform(NSSelectorFromString("deleteItem:"), with: menu.items[3]) // the deleted one again: nothing
            NSApp.sendAction(menu.items[1].action!, to: menu.items[1].target, from: menu.items[1])
            NSApp.sendAction(menu.items[0].action!, to: menu.items[0].target, from: menu.items[0])
            #expect(sessionWindow == nil)
            // Nothing selected: the toolbar actions do nothing.
            for s in ["editSelected", "renameSelected", "duplicateSelected", "deleteSelected"] { editor.perform(Selector((s))) }
            #expect(store.customLayouts.count == 2)

            // Delete of an unused layout: just "can't be undone".
            store.delete(copy)
            await settle()

            // Edit a layout in the full-screen editor: the window hides; an edit commits once on finish.
            let id = store.customLayouts[0].id
            store.assign(.custom(id), to: main)
            await settle()
            editor.perform(NSSelectorFromString("editSelected"))
            #expect(!editor.window.isVisible)
            #expect(sessionWindow != nil)
            EditorWindow.show(store: store) // brings the session forward instead
            editor.perform(NSSelectorFromString("newGrid")) // one session at a time
            await finishSession { $0.keyDown(with: key(48, "\t")); $0.keyDown(with: key(1, "s")) }
            #expect(editor.window.isVisible)
            guard case .grid(let g) = store.customLayouts[0].body else { Issue.record("not a grid"); return }
            #expect(g.zoneCount == 3)
            editor.perform(NSSelectorFromString("editItem:"), with: card("Writing Copy").menu!.items[0])
            await finishSession() // unchanged: no commit
            #expect(h.log.components(separatedBy: "editor: session committed").count == 3)

            // New Grid / New Canvas from the toolbar add a layout when finished.
            let toolbar = editor.window.toolbar!
            #expect(editor.toolbarDefaultItemIdentifiers(toolbar) == editor.toolbarAllowedItemIdentifiers(toolbar))
            let item = editor.toolbar(toolbar, itemForItemIdentifier: toolbar.items.last?.itemIdentifier ?? .init("newLayout"),
                                      willBeInsertedIntoToolbar: true)!
            let newButtons = subviews(item.view, ToolButton.self)
            #expect(newButtons.map(\.title) == ["New Grid Layout", "New Canvas Layout"])
            NSApp.sendAction(newButtons[0].action!, to: newButtons[0].target, from: newButtons[0])
            await finishSession()
            NSApp.sendAction(newButtons[1].action!, to: newButtons[1].target, from: newButtons[1])
            await finishSession()
            #expect(store.customLayouts.map(\.name) == ["Writing Copy", "Custom Grid 1", "Custom Canvas 1"])

            // A display change during a session commits it.
            editor.perform(NSSelectorFromString("newGrid"))
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await settle()
            #expect(store.customLayouts.count == 4)
            editor.window.close()
            await settle()
        }

        @Test func modifierRecorder() async {
            EditorWindow.show(store: store)
            let recorder = subviews(content, ModifierRecorder.self)[0]
            let footer = { subviews(content, NSTextField.self).map(\.stringValue).first { $0.hasPrefix("Drag a window") }! }
            #expect(recorder.stringValue == "⌃⌘")
            #expect(recorder.acceptsFirstResponder)

            recorder.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: recorder))
            #expect(recorder.stringValue == "Type modifiers…")
            recorder.flagsChanged(with: flags(.control))
            recorder.flagsChanged(with: flags([.control, .option]))
            #expect(recorder.stringValue == "⌃⌥")
            recorder.flagsChanged(with: flags([]))
            #expect(Settings.moveModifiers == [.control, .option])
            #expect(recorder.stringValue == "⌃⌥")
            #expect(footer().contains("⌃⌥ ←→↑↓"))

            // Shift alone isn't a hotkey: a beep, still recording; Esc cancels.
            #expect(recorder.accessibilityPerformPress())
            recorder.flagsChanged(with: flags(.shift))
            recorder.flagsChanged(with: flags([]))
            #expect(h.beeps == 1)
            recorder.keyDown(with: key(0, "a"))
            #expect(h.beeps == 2)
            recorder.keyDown(with: key(53))
            #expect(recorder.stringValue == "⌃⌥")

            // Space or Return starts recording from the keyboard; losing focus stops it.
            recorder.keyDown(with: key(49, " "))
            #expect(recorder.stringValue == "Type modifiers…")
            _ = recorder.resignFirstResponder()
            #expect(recorder.stringValue == "⌃⌥")
            recorder.keyDown(with: key(36, "\r"))
            editor.window.makeFirstResponder(nil)
            recorder.flagsChanged(with: flags(.command)) // not recording: passed on
            editor.window.close()
            await settle()
        }
    }
}
