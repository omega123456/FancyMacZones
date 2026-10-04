import AppKit
import SnapshotTesting
import Testing
@testable import FancyMacZones

/// A fixed backdrop under the translucent zones, so the references show them as on a desktop.
final class Backdrop: NSView {
    let color: NSColor
    init(_ size: CGSize, dark: Bool) {
        color = dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : NSColor(srgbRed: 0.9, green: 0.9, blue: 0.92, alpha: 1)
        super.init(frame: CGRect(origin: .zero, size: size))
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

private let strategy = Snapshotting<NSView, NSImage>.image(precision: 0.99, perceptualPrecision: 0.98)

/// Offscreen renders of the overlay, the gallery cards and both editors, compared with the PNGs in __Snapshots__.
/// Nothing is shown on screen: views are drawn with `cacheDisplay(in:to:)`. The accent is pinned by the Harness.
extension Desktop {
    @MainActor @Suite struct SnapshotTests {
        enum Look { case light, dark, contrast }

        static func backdrop(_ size: CGSize, _ look: Look, _ h: Harness) -> Backdrop {
            h.ws.contrast = look == .contrast
            return Backdrop(size, dark: look == .dark)
        }

        // MARK: Zone overlay

        enum OverlayCase: String, CaseIterable {
            case priorityGrid, priorityGridActive, gridActiveDark, columnsDark, focus, rowsContrast, activeContrast
            case maximize, maximizeDark

            var look: Look {
                switch self {
                case .gridActiveDark, .columnsDark, .maximizeDark: .dark
                case .rowsContrast, .activeContrast: .contrast
                default: .light
                }
            }
        }

        @Test(arguments: OverlayCase.allCases)
        func overlay(_ c: OverlayCase) {
            let h = Harness()
            let size = CGSize(width: 640, height: 400)
            let back = Self.backdrop(size, c.look, h)
            let view = ZoneView(frame: back.bounds)
            back.addSubview(view)
            let usable = CGRect(x: 0, y: 0, width: 640, height: 380) // a 20 pt menu bar strip at the top
            func zones(_ kind: TemplateKind) -> [CGRect] { kind.zones(count: kind.defaultCount).map { Layouts.place($0, in: usable) } }
            switch c {
            case .priorityGrid: view.zones = zones(.priorityGrid)
            case .priorityGridActive: view.zones = zones(.priorityGrid); view.active = 1
            case .gridActiveDark: view.zones = zones(.grid); view.active = 3
            case .columnsDark: view.zones = zones(.columns)
            case .focus: view.zones = zones(.focus); view.active = 0
            case .rowsContrast: view.zones = zones(.rows)
            case .activeContrast: view.zones = zones(.columns); view.active = 2
            case .maximize, .maximizeDark: view.zones = zones(.grid); view.maximize = usable
            }
            assertSnapshot(of: back as NSView, as: strategy, named: c.rawValue, testName: "ZoneView")
        }

        // MARK: Gallery cards

        enum CardCase: String, CaseIterable {
            case zones, selected, blank, activeOn, selectedDark, canvasDark
        }

        @Test(arguments: CardCase.allCases)
        func card(_ c: CardCase) {
            let h = Harness()
            let dark = c == .selectedDark || c == .canvasDark
            let grid = TemplateKind.priorityGrid.zones(count: 3)
            let canvas = [CGRect(x: 0.05, y: 0.1, width: 0.5, height: 0.6), CGRect(x: 0.4, y: 0.3, width: 0.5, height: 0.6)]
            let card = LayoutCard(title: c == .activeOn ? "Coding" : "Priority Grid",
                                  activeOn: c == .activeOn ? "Active on: Studio Display (Main), DELL U2720Q" : nil,
                                  zones: c == .canvasDark ? canvas : grid, blank: c == .blank,
                                  aspect: CGSize(width: 1512, height: 945), selected: c == .selected || c == .selectedDark)
            let back = Self.backdrop(CGSize(width: card.frame.width + 8, height: card.frame.height + 8), dark ? .dark : .light, h)
            card.setFrameOrigin(CGPoint(x: 4, y: 4))
            back.addSubview(card)
            assertSnapshot(of: back as NSView, as: strategy, named: c.rawValue, testName: "LayoutCard")
        }

        // MARK: Grid editor

        enum GridCase: String, CaseIterable {
            case initial, initialDark, splitPreview, splitPreviewHorizontal, focusedDivider, mergeSelection, focusedZoneContrast
        }

        @Test(arguments: GridCase.allCases)
        func grid(_ c: GridCase) {
            let h = Harness()
            let size = CGSize(width: 600, height: 360)
            let back = Self.backdrop(size, c == .initialDark ? .dark : c == .focusedZoneContrast ? .contrast : .light, h)
            let threeColumns = GridLayout(rows: [0.5, 0.5], columns: [0.4, 0.3, 0.3], cells: [[0, 1, 2], [0, 3, 4]])
            let editor = GridEditorView(c == .initial || c == .initialDark ? .initial : threeColumns, frame: back.bounds, history: UndoManager())
            back.addSubview(editor)
            let window = host(back)
            defer { window.close() }
            switch c {
            case .initial, .initialDark: break
            case .splitPreview: editor.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 120, y: 200), in: editor))
            case .splitPreviewHorizontal:
                editor.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 90), in: editor, flags: .shift))
            case .focusedDivider: editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 240, y: 90), in: editor))
            case .mergeSelection:
                editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 300, y: 60), in: editor))
                editor.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 500, y: 300), in: editor))
            case .focusedZoneContrast: editor.keyDown(with: key(48, "\t"))
            }
            assertSnapshot(of: back as NSView, as: strategy, named: c.rawValue, testName: "GridEditor")
        }

        // MARK: Canvas editor

        enum CanvasCase: String, CaseIterable {
            case initial, selected, selectedDark, overlapping, snapGuides
        }

        @Test(arguments: CanvasCase.allCases)
        func canvas(_ c: CanvasCase) {
            let h = Harness()
            let size = CGSize(width: 600, height: 360)
            let back = Self.backdrop(size, c == .selectedDark ? .dark : .light, h)
            let two = CanvasLayout(zones: [CGRect(x: 0.05, y: 0.1, width: 0.5, height: 0.6), CGRect(x: 0.4, y: 0.3, width: 0.5, height: 0.6)])
            let editor = CanvasEditorView(c == .initial || c == .selected || c == .selectedDark ? .initial : two,
                                          frame: back.bounds, history: UndoManager())
            back.addSubview(editor)
            let window = host(back)
            defer { window.close() }
            switch c {
            case .initial, .overlapping: break
            case .selected, .selectedDark: editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 300, y: 180), in: editor))
            case .snapGuides: // zone 2 dragged until its left edge is 4 pt from zone 1's (x 30): it snaps there
                editor.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 450, y: 300), in: editor))
                editor.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 244, y: 300), in: editor))
            }
            assertSnapshot(of: back as NSView, as: strategy, named: c.rawValue, testName: "CanvasEditor")
        }
    }
}
