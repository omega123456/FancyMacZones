import AppKit
import Carbon
import Foundation

/// `--self-test` (requirement 25, NFR-7): checks of pure logic with explicit failure counting (not `assert`,
/// which is compiled out of release builds). Returns false if any check failed.
enum SelfTest {
    private static var total = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failures.append(name) }
    }

    static func run() -> Bool {
        let groups: [(String, () -> Void)] = [
            ("templates", templates), ("grid", grid), ("canvas", canvas), ("numbering", numbering),
            ("overlap rules", overlapRules), ("current zone", currentZone), ("directional target", directional),
            ("top band", topBand), ("exposed top edges", exposedTopEdges), ("mission control", missionControl),
            ("coordinates", coordinates), ("json", json), ("display names", displayNames), ("updater", updateVersions),
            ("drag session", dragSession), ("hotkey modifiers", hotKeyModifiers),
        ]
        for (name, group) in groups {
            let before = total
            group()
            print("\(name): \(total - before) checks")
        }
        for f in failures { print("FAIL: \(f)") }
        print("self-test: \(total - failures.count)/\(total) checks passed")
        return failures.isEmpty
    }

    // MARK: Helpers

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }
    private static func same(_ a: [CGRect], _ b: [CGRect]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { same($0, $1) } }
    private static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    private static let area = CGSize(width: 1000, height: 800)
    /// Two 50% columns over two 50% rows, zones 1 2 / 3 4.
    private static let quad = GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 1], [2, 3]])
    /// 3 × 3 pinwheel: 1 1 2 / 3 4 2 / 3 5 5.
    private static let pinwheel = GridLayout(rows: [1.0 / 3, 1.0 / 3, 1.0 / 3], columns: [1.0 / 3, 1.0 / 3, 1.0 / 3],
                                             cells: [[0, 0, 1], [2, 3, 1], [2, 4, 4]])

    // MARK: Templates (requirement 2)

    private static func templates() {
        for kind in TemplateKind.allCases {
            for n in Set([1, kind.defaultCount, kind.range.upperBound]) {
                check("\(kind) at \(n) has \(kind.clamped(n)) zones", kind.zones(count: n).count == kind.clamped(n))
            }
        }
        check("blank has no zones", TemplateKind.blank.zones(count: 3).isEmpty)
        check("counts clamp to the range", TemplateKind.focus.zones(count: 9).count == 6 && TemplateKind.columns.zones(count: 0).count == 1)
        check("columns 3 are equal full-height thirds",
              same(TemplateKind.columns.zones(count: 3), [r(0, 0, 1.0 / 3, 1), r(1.0 / 3, 0, 1.0 / 3, 1), r(2.0 / 3, 0, 1.0 / 3, 1)]))
        check("rows 12 are equal full-width rows",
              same(TemplateKind.rows.zones(count: 12), (0..<12).map { r(0, CGFloat($0) / 12, 1, 1.0 / 12) }))
        check("grid 1 is the whole area", same(TemplateKind.grid.zones(count: 1), [r(0, 0, 1, 1)]))
        check("grid 4 is 2 × 2", same(TemplateKind.grid.zones(count: 4), [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]))
        check("grid 5: leftover cell joins the last row's last zone",
              same(TemplateKind.grid.zones(count: 5), [r(0, 0, 1.0 / 3, 0.5), r(1.0 / 3, 0, 1.0 / 3, 0.5), r(2.0 / 3, 0, 1.0 / 3, 0.5),
                                                       r(0, 0.5, 1.0 / 3, 0.5), r(1.0 / 3, 0.5, 2.0 / 3, 0.5)]))
        check("grid 12 is 3 rows of 4", same(TemplateKind.grid.zones(count: 12), (0..<12).map { r(CGFloat($0 % 4) / 4, CGFloat($0 / 4) / 3, 0.25, 1.0 / 3) }))
        check("priority grid 1 is the whole area", same(TemplateKind.priorityGrid.zones(count: 1), [r(0, 0, 1, 1)]))
        check("priority grid 2 is 2/3 + 1/3", same(TemplateKind.priorityGrid.zones(count: 2), [r(0, 0, 2.0 / 3, 1), r(2.0 / 3, 0, 1.0 / 3, 1)]))
        check("priority grid 3 is 25 / 50 / 25",
              same(TemplateKind.priorityGrid.zones(count: 3), [r(0, 0, 0.25, 1), r(0.25, 0, 0.5, 1), r(0.75, 0, 0.25, 1)]))
        check("priority grid 4 splits the right column first",
              same(TemplateKind.priorityGrid.zones(count: 4), [r(0, 0, 0.25, 1), r(0.25, 0, 0.5, 1), r(0.75, 0, 0.25, 0.5), r(0.75, 0.5, 0.25, 0.5)]))
        check("priority grid 5 then splits the left column",
              same(TemplateKind.priorityGrid.zones(count: 5), [r(0, 0, 0.25, 0.5), r(0.25, 0, 0.5, 1), r(0.75, 0, 0.25, 0.5),
                                                               r(0, 0.5, 0.25, 0.5), r(0.75, 0.5, 0.25, 0.5)]))
        let pg12 = TemplateKind.priorityGrid.zones(count: 12)
        check("priority grid 12: 5 rows left, 6 rows right",
              pg12.filter { $0.minX == 0 }.count == 5 && pg12.filter { $0.minX == 0.75 }.count == 6 && pg12.filter { $0.minX == 0.25 }.count == 1)
        check("focus 1 sits at 10% / 10%, 60% × 60%", same(TemplateKind.focus.zones(count: 1), [r(0.1, 0.1, 0.6, 0.6)]))
        check("focus 6 cascades by 5%", same(TemplateKind.focus.zones(count: 6).last!, r(0.35, 0.35, 0.6, 0.6)))
    }

    // MARK: Grid (requirement 3)

    private static func grid() {
        let g = GridLayout.initial
        let split = g.splitting(0, .horizontal, at: 0.5, area: area)
        check("split: horizontal split of zone 1 renumbers in reading order",
              split == GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 1], [2, 1]]))
        check("split: vertical split inserts a column",
              g.splitting(1, .vertical, at: 0.75, area: area) == GridLayout(rows: [1], columns: [0.5, 0.25, 0.25], cells: [[0, 1, 2]]))
        check("split: a part thinner than 64 pt is refused", g.splitting(0, .vertical, at: 0.06, area: area) == nil
              && g.splitting(0, .vertical, at: 0.064, area: area) != nil)
        let merged = GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 1], [2, 2]])
        check("split: a merged zone reuses its existing line",
              merged.splitting(2, .vertical, at: 0.5, area: area) == quad)

        let v = g.dividers[0]
        check("move: divider moves freely", abs(g.moving(v, to: 0.3, area: area).position(v) - 0.3) < 1e-9)
        check("move: clamped at 64 pt on the left", abs(g.moving(v, to: 0.01, area: area).position(v) - 0.064) < 1e-9)
        check("move: clamped at 64 pt on the right", abs(g.moving(v, to: 0.99, area: area).position(v) - 0.936) < 1e-9)
        // 1 2 / 3 3 / 4 5: the vertical line has two segments that move together.
        let split2 = GridLayout(rows: [0.3, 0.4, 0.3], columns: [0.5, 0.5], cells: [[0, 1], [2, 2], [3, 4]])
        let segs = split2.dividers.filter { $0.orientation == .vertical }
        let moved = split2.moving(segs[0], to: 0.4, area: area)
        check("move: the whole grid line moves", segs.count == 2 && abs(moved.position(segs[1]) - 0.4) < 1e-9)
        check("move: a horizontal divider clamps at 64 pt of the display height",
              abs(split!.moving(split!.dividers.first { $0.orientation == .horizontal }!, to: 0.99, area: area).position(
                split!.dividers.first { $0.orientation == .horizontal }!) - (1 - 64.0 / 800)) < 1e-9)

        check("merge: a rectangular union merges", quad.canMerge([0, 1])
              && quad.merging([0, 1]) == GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 0], [1, 2]]))
        check("merge: an L-shaped union is rejected", !quad.canMerge([0, 1, 2]) && quad.merging([0, 1, 2]) == nil)
        check("merge: a single zone is not a merge", !quad.canMerge([0]))
        check("merge: all four zones leave one cell", quad.merging([0, 1, 2, 3]) == GridLayout(rows: [1], columns: [1], cells: [[0]]))

        let tee = GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[0, 1], [0, 2]])
        let h = tee.dividers.first { $0.orientation == .horizontal }!
        check("delete: divider between rectangular neighbours merges them", tee.canDelete(h)
              && tee.deleting(h) == GridLayout(rows: [1], columns: [0.5, 0.5], cells: [[0, 1]]))
        let v1 = pinwheel.dividers.first { $0.orientation == .vertical && $0.line == 1 }!
        check("delete: refused when the union isn't rectangular", v1.before == [2] && v1.after == [3, 4]
              && !pinwheel.canDelete(v1) && pinwheel.deleting(v1) == nil)
        check("auto removal: a line separating nothing is removed",
              GridLayout(rows: [0.25, 0.75], columns: [1], cells: [[0], [0]]).normalized() == GridLayout(rows: [1], columns: [1], cells: [[0]]))
        check("auto removal: a merge across a line removes it",
              GridLayout(rows: [1], columns: [0.5, 0.5], cells: [[0, 1]]).merging([0, 1]) == GridLayout(rows: [1], columns: [1], cells: [[0]]))

        let order = pinwheel.dividers.map { "\($0.orientation == .vertical ? "V" : "H")\($0.line):\($0.span.lowerBound)" }
        check("tab order: top to bottom, then left to right", order == ["V2:0", "H1:0", "V1:1", "H2:1"])
        check("focus order: zones then dividers", pinwheel.focusOrder.count == 5 + 4 && pinwheel.focusOrder.first == .zone(0))

        check("hit test: 5 pt each side of a divider grabs it", g.hitTest(CGPoint(x: 505, y: 400), area: area) == .divider(v)
              && g.hitTest(CGPoint(x: 495, y: 400), area: area) == .divider(v))
        check("hit test: beyond 5 pt is the zone", g.hitTest(CGPoint(x: 506, y: 400), area: area) == .zone(1)
              && g.hitTest(CGPoint(x: 494, y: 400), area: area) == .zone(0))
        check("hit test: a divider only along its segment",
              pinwheel.hitTest(CGPoint(x: 1000.0 / 3 + 2, y: 100), area: area) == .zone(0))
        check("drag selection: zones touched by the rectangle",
              quad.zones(intersecting: r(100, 100, 500, 100), area: area) == [0, 1])
        check("accessibility labels", Layouts.zoneLabel(2, of: 3) == "Zone 2 of 3" && v.accessibilityLabel == "Vertical divider"
              && h.accessibilityLabel == "Horizontal divider")
    }

    // MARK: Canvas (requirements 4, 28)

    private static func canvas() {
        var c = CanvasLayout(zones: [])
        let first = c.addZone(after: nil, area: area)
        check("add: 30% × 30% centred", same(c.zones[first], r(0.35, 0.35, 0.3, 0.3)) && same(CanvasLayout.initial.zones[0], c.zones[first]))
        let second = c.addZone(after: c.zones[first], area: area)
        check("add: cascades 24 pt from the previous zone", same(c.zones[second], r(374.0 / 1000, 304.0 / 800, 0.3, 0.3)))
        let third = c.addZone(after: r(0.69, 0.69, 0.3, 0.3), area: area)
        check("add: wraps back to centre when the offset would leave the area", same(c.zones[third], r(0.35, 0.35, 0.3, 0.3)))

        // Area points: A = (0, 0, 400, 400), B = (600, 100, 200, 200).
        let ab = CanvasLayout(zones: [r(0, 0, 0.4, 0.5), r(0.6, 0.125, 0.2, 0.25)])
        let b = ab.zones[1]
        func pts(_ d: CanvasDrag) -> CGRect { Layouts.points(d.rect, area: area) }
        check("clamp: resize stops at 64 pt", same(pts(ab.drag(1, from: b, handle: .right, by: CGVector(dx: -190, dy: 0), area: area, snapping: false)), r(600, 100, 64, 200))
              && same(pts(ab.drag(1, from: b, handle: .left, by: CGVector(dx: 500, dy: 0), area: area, snapping: false)), r(736, 100, 64, 200)))
        check("clamp: move stays inside the usable area",
              same(pts(ab.drag(1, from: b, handle: nil, by: CGVector(dx: 5000, dy: -5000), area: area, snapping: false)), r(800, 0, 200, 200)))
        check("clamp: resize stops at the area edge",
              same(pts(ab.drag(1, from: b, handle: .bottomRight, by: CGVector(dx: 900, dy: 900), area: area, snapping: false)), r(600, 100, 400, 700)))
        let snapped = ab.drag(1, from: b, handle: nil, by: CGVector(dx: -195, dy: 0), area: area, snapping: true)
        check("snap: a moved edge within 8 pt snaps and reports its guide",
              same(pts(snapped), r(400, 100, 200, 200)) && snapped.guides == [SnapGuide(orientation: .vertical, position: 400)])
        let resized = ab.drag(1, from: b, handle: .bottom, by: CGVector(dx: 0, dy: 95), area: area, snapping: true)
        check("snap: a resized edge snaps to another zone's edge",
              same(pts(resized), r(600, 100, 200, 300)) && resized.guides == [SnapGuide(orientation: .horizontal, position: 400)])
        let edge = ab.drag(1, from: b, handle: nil, by: CGVector(dx: 195, dy: 0), area: area, snapping: true)
        check("snap: display edges snap", same(pts(edge), r(800, 100, 200, 200)) && edge.guides == [SnapGuide(orientation: .vertical, position: 1000)])
        let free = ab.drag(1, from: b, handle: nil, by: CGVector(dx: -195, dy: 0), area: area, snapping: false)
        check("snap: bypass (⌥) leaves the edge where it is", same(pts(free), r(405, 100, 200, 200)) && free.guides.isEmpty)
        check("snap: beyond 8 pt nothing snaps", ab.drag(1, from: b, handle: nil, by: CGVector(dx: -191, dy: 0), area: area, snapping: true).guides.isEmpty)

        check("handles: hit within half the handle size",
              CanvasLayout.handle(at: CGPoint(x: 300, y: 200), of: r(100, 100, 200, 200)) == .right
              && CanvasLayout.handle(at: CGPoint(x: 104, y: 96), of: r(100, 100, 200, 200)) == .topLeft
              && CanvasLayout.handle(at: CGPoint(x: 150, y: 150), of: r(100, 100, 200, 200)) == nil)

        let stack = CanvasLayout(zones: [r(0, 0, 0.5, 0.5), r(0.25, 0.25, 0.5, 0.5), r(0.8, 0.8, 0.1, 0.1)])
        let hits = stack.zones(at: CGPoint(x: 300, y: 300), area: area)
        check("click cycling: top of the z-order first", hits == [1, 0])
        check("click cycling: first click, then downward, then wrap",
              CanvasLayout.nextSelection(hits: hits, current: nil) == 1 && CanvasLayout.nextSelection(hits: hits, current: 1) == 0
              && CanvasLayout.nextSelection(hits: hits, current: 0) == 1 && CanvasLayout.nextSelection(hits: hits, current: 2) == 1
              && CanvasLayout.nextSelection(hits: [], current: 0) == nil)

        var z = stack
        check("z-order: bring to front", z.bringToFront(0) == 2 && z.zones == [stack.zones[1], stack.zones[2], stack.zones[0]])
        check("z-order: send to back", z.sendToBack(2) == 0 && z.zones == stack.zones)
        z.delete(1)
        check("z-order: delete", z.zones == [stack.zones[0], stack.zones[2]])
    }

    // MARK: Numbering (requirement 6)

    private static func numbering() {
        check("grid: zones numbered in reading order of their top-left cells",
              GridLayout(rows: [0.5, 0.5], columns: [0.5, 0.5], cells: [[5, 2], [7, 2]]).normalized().cells == [[0, 1], [2, 1]])
        check("grid: zone rects follow the numbers", same(pinwheel.zones, [r(0, 0, 2.0 / 3, 1.0 / 3), r(2.0 / 3, 0, 1.0 / 3, 2.0 / 3),
                                                                         r(0, 1.0 / 3, 1.0 / 3, 2.0 / 3), r(1.0 / 3, 1.0 / 3, 1.0 / 3, 1.0 / 3),
                                                                         r(1.0 / 3, 2.0 / 3, 2.0 / 3, 1.0 / 3)]))
        let canvas = CanvasLayout(zones: [r(0.5, 0.5, 0.2, 0.2), r(0, 0, 0.3, 0.3)])
        let layout = CustomLayout(id: UUID(), name: "c", body: .canvas(canvas))
        check("canvas: zones numbered in list order, bottom first", layout.zones == canvas.zones)
    }

    // MARK: Overlap rules (requirement 9)

    private static func overlapRules() {
        let big = r(0, 0, 1000, 800), offCentre = r(450, 350, 500, 400)
        let p = CGPoint(x: 500, y: 400)
        check("smallest zone wins", Layouts.activeZone(at: p, in: [big, offCentre], rule: .smallestArea) == 1)
        check("closest centre wins", Layouts.activeZone(at: p, in: [big, offCentre], rule: .closestCentre) == 0)
        let c = r(0, 0, 200, 200), d = r(100, 0, 200, 200)
        check("smallest: equal areas → closest centre", Layouts.activeZone(at: CGPoint(x: 160, y: 100), in: [c, d], rule: .smallestArea) == 1)
        check("smallest: equal area and distance → lower number", Layouts.activeZone(at: CGPoint(x: 150, y: 100), in: [c, d], rule: .smallestArea) == 0)
        let e = r(0, 0, 200, 200), f = r(50, 50, 100, 100)
        check("closest: equal distance → smaller area", Layouts.activeZone(at: CGPoint(x: 100, y: 100), in: [e, f], rule: .closestCentre) == 1)
        check("closest: equal distance and area → lower number", Layouts.activeZone(at: CGPoint(x: 100, y: 100), in: [e, e], rule: .closestCentre) == 0)
        check("no zone under the cursor → none", Layouts.activeZone(at: CGPoint(x: 900, y: 700), in: [c, d], rule: .smallestArea) == nil)
    }

    // MARK: Current zone (requirement 15)

    private static func currentZone() {
        let usable = r(0, 0, 1920, 1080)
        let place = { (kind: TemplateKind, n: Int) in kind.zones(count: n).map { Layouts.place($0, in: usable) } }
        let cols = place(.columns, 3)
        check("exact match", Layouts.currentZone(of: cols[1], in: cols) == 1)
        let rows3 = place(.rows, 3)
        check("3 rows: bottom window trimmed by 48 pt", Layouts.currentZone(of: r(0, 48, 1920, 312), in: rows3) == 2)
        let rows10 = place(.rows, 10)
        check("10 rows: 108 pt bottom zone trimmed by 48 pt (IoU 0.56) by edge alignment",
              Layouts.iou(r(0, 48, 1920, 60), rows10[9]) < Layouts.minIoU && Layouts.currentZone(of: r(0, 48, 1920, 60), in: rows10) == 9)
        check("edges within 8 pt still align (IoU 0.52)", Layouts.currentZone(of: r(6, 48, 1908, 57), in: rows10) == 9)
        check("an edge 10 pt off doesn't align", Layouts.currentZone(of: r(10, 48, 1910, 60), in: rows10) == nil)
        check("bottom far below the zone doesn't align (IoU 0.53)", Layouts.currentZone(of: r(0, 400, 1920, 680), in: rows3) == nil)
        check("small floating window", Layouts.currentZone(of: r(500, 500, 200, 150), in: cols) == nil)
        let tall = r(0, 0, 960, 1080), quarter = r(0, 540, 960, 540) // same left, right and top edges
        check("overlapping canvas zones: the quarter", Layouts.currentZone(of: quarter, in: [tall, quarter]) == 1)
        check("overlapping canvas zones: the tall one", Layouts.currentZone(of: tall, in: [tall, quarter]) == 0
              && Layouts.currentZone(of: r(0, 48, 960, 1032), in: [tall, quarter]) == 0)
        let halves = place(.columns, 2)
        check("IoU fallback at ≥ 0.6", Layouts.currentZone(of: r(30, 20, 900, 1000), in: halves) == 0)
        check("IoU below 0.6 is floating", Layouts.currentZone(of: r(300, 100, 900, 900), in: halves) == nil)
    }

    // MARK: Directional target (requirement 16)

    private static func directional() {
        let m1 = r(0, 0, 1920, 1080), m2 = r(1920, 0, 1920, 1080), above = r(0, 1080, 1920, 1080)
        func zones(_ layouts: [(TemplateKind, Int)], _ frames: [CGRect]) -> [PlacedZone] {
            var file = LayoutFile()
            for (i, (kind, n)) in layouts.enumerated() {
                file.assign(.template(kind), to: "D\(i)")
                file.setZoneCount(n, for: kind, on: "D\(i)")
            }
            return file.placedZones(frames.enumerated().map { ("D\($0.offset)", $0.element) })
        }
        let target = { (zs: [PlacedZone], from: Int?, ref: CGRect?, dir: Direction) in
            Layouts.directionalTarget(from: ref ?? zs[from!].rect, current: from, in: zs, direction: dir)
        }
        let two = zones([(.columns, 2), (.columns, 2)], [m1, m2])
        check("→ walks M1 Z1 → M1 Z2 → M2 Z1 → M2 Z2 → M1 Z1",
              target(two, 0, nil, .right) == 1 && target(two, 1, nil, .right) == 2 && target(two, 2, nil, .right) == 3 && target(two, 3, nil, .right) == 0)
        check("← wraps the other way", target(two, 0, nil, .left) == 3)
        check("columns: ↑ and ↓ do nothing", target(two, 1, nil, .up) == nil && target(two, 2, nil, .down) == nil)
        let rows = zones([(.rows, 3), (.columns, 2)], [m1, m2])
        check("rows: ↑ and ↓ move and wrap within the display",
              target(rows, 1, nil, .up) == 0 && target(rows, 0, nil, .up) == 2 && target(rows, 2, nil, .down) == 0 && target(rows, 1, nil, .down) == 2)
        let stacked = zones([(.columns, 2), (.columns, 2)], [m1, above])
        check("a stacked display takes part in ↑", target(stacked, 0, nil, .up) == 2 && target(stacked, 2, nil, .up) == 0)
        check("floating window: nearest zone ahead", target(two, nil, r(100, 100, 400, 300), .right) == 0)
        let a = PlacedZone(display: 0, number: 1, rect: r(0, 540, 960, 540))
        let touching = PlacedZone(display: 0, number: 2, rect: r(960, 0, 960, 540))
        let onePoint = PlacedZone(display: 0, number: 2, rect: r(960, 0, 960, 541))
        let twoPoints = PlacedZone(display: 0, number: 2, rect: r(960, 0, 960, 542))
        check("touching edges are not in band", target([a, touching], 0, nil, .right) == nil && target([a, onePoint], 0, nil, .right) == nil
              && target([a, twoPoints], 0, nil, .right) == 1)
        let blank = zones([(.columns, 2), (.blank, 0)], [m1, m2])
        check("a Blank display has no zones and is skipped", blank.count == 2 && target(blank, 1, nil, .right) == 0)
        let tie = [PlacedZone(display: 1, number: 1, rect: r(2000, 0, 100, 100)), PlacedZone(display: 0, number: 2, rect: r(2000, 0, 100, 100))]
        check("ties go to the left-most display", Layouts.directionalTarget(from: r(0, 0, 100, 100), current: nil, in: tie, direction: .right) == 1)
    }

    // MARK: Top band (requirement 11)

    private static func topBand() {
        let screen = r(0, 0, 1920, 1080)
        check("top row is in the band", Layouts.inTopBand(CGPoint(x: 100, y: 1080), screen: screen))
        check("5 pt below the top is in the band", Layouts.inTopBand(CGPoint(x: 100, y: 1075), screen: screen))
        check("more than 5 pt below is not", !Layouts.inTopBand(CGPoint(x: 100, y: 1074.9), screen: screen))
        check("another display's x is not", !Layouts.inTopBand(CGPoint(x: 2000, y: 1080), screen: screen))
    }

    // MARK: Exposed top-edge segments (DD-7), CG coordinates

    private static func exposedTopEdges() {
        let a = r(0, 0, 1920, 1080)
        check("side by side: both tops fully exposed", Layouts.exposedTopEdges([a, r(1920, 0, 1920, 1080)])
              == [TopEdgeSegment(y: 0, x: 0..<1920), TopEdgeSegment(y: 0, x: 1920..<3840)])
        check("partially overlapping display above", Layouts.exposedTopEdges([a, r(1000, -1440, 2560, 1440)])
              == [TopEdgeSegment(y: 0, x: 0..<1000), TopEdgeSegment(y: -1440, x: 1000..<3560)])
        check("display fully above", Layouts.exposedTopEdges([a, r(0, -1080, 1920, 1080)]) == [TopEdgeSegment(y: -1080, x: 0..<1920)])
        check("display above in the middle splits the edge", Layouts.exposedTopEdges([a, r(500, -500, 800, 500)]).prefix(2)
              == [TopEdgeSegment(y: 0, x: 0..<500), TopEdgeSegment(y: 0, x: 1300..<1920)])
    }

    // MARK: Mission Control decision (requirement 12, DD-7)

    private static func missionControl() {
        let edges = Layouts.exposedTopEdges([r(0, 0, 1920, 1080)])
        let mc = { (y: CGFloat, dy: CGFloat, prev: CGFloat?, hold: Double, now: Double, confirmed: Bool) in
            Layouts.missionControl(point: CGPoint(x: 500, y: y), deltaY: dy, previousY: prev, edges: edges, holdUntil: hold, now: now, confirmed: confirmed)
        }
        let flick = mc(0, -30, 0, 0, 10, true)
        check("pinned + flick past 25 pt → rewrite and hold 250 ms", flick.rewriteY == 1 && abs(flick.holdUntil - 10.25) < 1e-9)
        check("pinned, gentle contact → leave", mc(0, -10, 0, 0, 10, true).rewriteY == nil)
        check("inside the hold → rewrite", mc(0, 0, nil, 10.25, 10.1, true).rewriteY == 1)
        check("after the hold, gentle → leave", mc(0, -3, 0, 10.25, 10.3, true).rewriteY == nil)
        check("unconfirmed drag → leave", mc(0, -30, 0, 0, 10, false).rewriteY == nil && mc(0, 0, 0, 10.25, 10.1, false).rewriteY == nil)
        check("first contact only (previous not pinned) → leave", mc(0, -30, 300, 0, 10, true).rewriteY == nil)
        check("not at the edge → leave", mc(40, -30, 0, 0, 10, true).rewriteY == nil)
        let covered = Layouts.exposedTopEdges([r(0, 0, 1920, 1080), r(0, -1080, 1920, 1080)])
        check("edge with a display above → leave",
              Layouts.missionControl(point: CGPoint(x: 500, y: 0), deltaY: -30, previousY: 0, edges: covered, holdUntil: 0, now: 10, confirmed: true).rewriteY == nil)
    }

    // MARK: Coordinates

    private static func coordinates() {
        check("AX → Cocoa flips y", Layouts.cocoaRect(fromAX: r(100, 100, 800, 600), primaryHeight: 1080) == r(100, 380, 800, 600))
        check("AX above primary (negative y) → Cocoa", Layouts.cocoaRect(fromAX: r(0, -1440, 2560, 1440), primaryHeight: 1080) == r(0, 1080, 2560, 1440))
        check("Cocoa → AX round trip", Layouts.axRect(fromCocoa: Layouts.cocoaRect(fromAX: r(10, 20, 30, 40), primaryHeight: 1080), primaryHeight: 1080) == r(10, 20, 30, 40))
        check("CG point → Cocoa", Layouts.cocoaPoint(fromCG: CGPoint(x: 10, y: 0), primaryHeight: 1080) == CGPoint(x: 10, y: 1080))
        check("fractions (top-left) → global Cocoa", same(Layouts.place(r(0, 0, 0.5, 0.5), in: r(1920, 25, 1920, 1030)), r(1920, 540, 960, 515)))
        check("fractions ↔ area points", same(Layouts.fraction(Layouts.points(r(0.1, 0.2, 0.3, 0.4), area: area), area: area), r(0.1, 0.2, 0.3, 0.4)))
        check("display under a point, top row included", Layouts.display(at: CGPoint(x: 2000, y: 1080), frames: [r(0, 0, 1920, 1080), r(1920, 0, 1920, 1080)]) == 1)
    }

    // MARK: JSON and the store (DD-10, NFR-4, requirements 1, 5, 29)

    private static func json() {
        var file = LayoutFile()
        let grid = CustomLayout(id: UUID(), name: "Three Panes", body: .grid(pinwheel))
        let canvas = CustomLayout(id: UUID(), name: "Coding Canvas", body: .canvas(CanvasLayout(zones: [r(0, 0, 0.5, 1), r(0.25, 0.1, 0.5, 0.8)])))
        file.add(grid)
        file.add(canvas)
        file.assign(.custom(grid.id), to: "A")
        file.assign(.custom(grid.id), to: "B")
        file.assign(.template(.columns), to: "C")
        file.setZoneCount(5, for: .columns, on: "C")
        file.setZoneCount(5, for: .priorityGrid, on: "A")
        check("round trip", LayoutFile.decode(file.encoded()) == file)
        check("missing display → Priority Grid 3", file.state("new").layout == .fallback && file.zones(on: "new").count == 3)
        file.setZoneCount(3, for: .columns, on: "C")
        file.setZoneCount(99, for: .rows, on: "C")
        check("counts: default not stored, clamped to the range", file.state("C").zoneCounts == [.rows: 12])

        let unknownID = #"{"version":1,"displays":{"X":{"layout":{"custom":"\#(UUID().uuidString)"}},"Y":{"layout":{"template":"hexagons"}}}}"#
        let unknown = LayoutFile.decode(Data(unknownID.utf8))
        check("unknown custom ID → default", unknown?.state("X").layout == .fallback)
        check("unknown template kind → default", unknown?.state("Y").layout == .fallback)
        let lShape = #"{"version":1,"customLayouts":[{"id":"\#(UUID().uuidString)","name":"bad","kind":"grid","grid":{"rows":[0.5,0.5],"columns":[0.5,0.5],"cells":[[0,0],[0,1]]}}]}"#
        check("invalid custom layout dropped", LayoutFile.decode(Data(lShape.utf8))?.customLayouts.isEmpty == true)
        check("corrupt data → nil", LayoutFile.decode(Data("not json".utf8)) == nil && LayoutFile.decode(Data(#"{"version":2}"#.utf8)) == nil)

        var deleting = file
        deleting.deleteCustom(grid.id)
        check("delete: displays fall back to Priority Grid with their stored count",
              deleting.state("A").layout == .fallback && deleting.state("B").layout == .fallback && deleting.zones(on: "A").count == 5
              && deleting.custom(grid.id) == nil)
        check("uses of a custom layout", file.uuids(using: grid.id) == ["A", "B"])
        var names = LayoutFile()
        names.add(CustomLayout(id: UUID(), name: "Custom Grid 1", body: .grid(.initial)))
        names.add(CustomLayout(id: UUID(), name: "Custom Grid 3", body: .grid(.initial)))
        check("new names use the smallest free n", names.nextName("Custom Grid") == "Custom Grid 2" && names.nextName("Custom Canvas") == "Custom Canvas 1")

        // The store's write path and recovery, on disk in a temporary folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FancyMacZones-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("layouts.json")
        check("missing file → defaults", LayoutStore.load(url).file == LayoutFile() && LayoutStore.load(url).renamedTo == nil)
        let store = LayoutStore(url: url)
        let display = LayoutStore.Display(uuid: "SELFTEST", id: 1, name: "Test", frame: r(0, 0, 1920, 1080), usable: r(0, 0, 1920, 1055))
        store.assign(.template(.rows), to: display)
        store.setZoneCount(4, for: .rows, on: display)
        let draft = store.draft(.canvas(.initial))
        store.add(draft)
        let reloaded = LayoutStore.load(url).file
        check("store: each write is saved", reloaded.state("SELFTEST").layout == .template(.rows) && reloaded.zoneCount(.rows, on: "SELFTEST") == 4
              && reloaded.custom(draft.id)?.name == "Custom Canvas 1")
        check("store: zones in global coordinates", store.zones(on: display).count == 4 && same(store.zones(on: display)[0], r(0, 1055 - 263.75, 1920, 263.75)))
        try? Data("{ corrupt".utf8).write(to: url)
        let recovered = LayoutStore.load(url)
        check("corrupt file → renamed aside with a timestamp, defaults", recovered.file == LayoutFile()
              && recovered.renamedTo.map { FileManager.default.fileExists(atPath: $0.path) } == true
              && recovered.renamedTo?.lastPathComponent.hasPrefix("layouts-corrupt-") == true
              && !FileManager.default.fileExists(atPath: url.path))
        #if DEBUG
        check("dev build uses its own folder", LayoutStore.defaultURL.path.hasSuffix("Application Support/FancyMacZones Dev/layouts.json"))
        #else
        check("production folder", LayoutStore.defaultURL.path.hasSuffix("Application Support/FancyMacZones/layouts.json"))
        #endif
    }

    // MARK: Display names and order (requirement 19)

    private static func displayNames() {
        check("main gets (Main), duplicates numbered left to right",
              LayoutStore.displayNames(["Studio Display", "DELL U2723QE", "DELL U2723QE"], main: 0)
                == ["Studio Display (Main)", "DELL U2723QE 1", "DELL U2723QE 2"])
        check("a duplicate can be the main display",
              LayoutStore.displayNames(["DELL", "DELL"], main: 1) == ["DELL 1", "DELL 2 (Main)"])
        check("unique names unchanged", LayoutStore.displayNames(["A", "B"], main: nil) == ["A", "B"])
        check("order: left to right, then top to bottom",
              LayoutStore.displayOrder([r(1920, 0, 1920, 1080), r(0, 0, 1920, 1080), r(0, 1080, 1920, 1080)]) == [2, 1, 0])
    }

    // MARK: Drag session (DD-1, DD-2, requirements 8, 11)

    private static func dragSession() {
        let window = r(100, 100, 800, 600)
        var s = DragSession(phase: .pending, down: CGPoint(x: 200, y: 110), point: CGPoint(x: 200, y: 110), windowID: 42)
        check("no baseline before 4 pt", !DragSession.wantsRead(s, at: CGPoint(x: 203, y: 110), now: 1))
        check("baseline at 4 pt", DragSession.wantsRead(s, at: CGPoint(x: 204, y: 110), now: 1))
        s = DragSession.afterRead(s, bounds: window, now: 1)
        check("baseline keeps the drag pending", s.phase == .pending && s.baseline == window && s.rechecks == 0)
        check("recheck closer than 50 ms is skipped", !DragSession.wantsRead(s, at: .zero, now: 1.049))
        check("recheck at 50 ms is read", DragSession.wantsRead(s, at: .zero, now: 1.05))
        let moved = DragSession.afterRead(s, bounds: window.offsetBy(dx: 10, dy: 5), now: 1.05)
        check("pending → confirmed: origin changed, size didn't", moved.phase == .confirmed && moved.rechecks == 1)
        check("confirmed reads no more", !DragSession.wantsRead(moved, at: .zero, now: 9))

        let resized = DragSession.afterRead(s, bounds: r(100, 100, 820, 600), now: 1.05)
        check("resize in place is a failed check", resized.phase == .pending && resized.rechecks == 1)
        let leftResize = DragSession.afterRead(s, bounds: r(90, 100, 810, 600), now: 1.05)
        check("resize that moves the origin is a failed check", leftResize.phase == .pending && leftResize.rechecks == 1)
        var failing = s
        for i in 1...5 { failing = DragSession.afterRead(failing, bounds: i % 2 == 0 ? window : r(100, 100, 800 + CGFloat(i), 600), now: 1 + Double(i) * 0.05) }
        check("pending → rejected after 5 failed checks", failing.phase == .rejected && failing.rechecks == 5)
        check("rejected reads no more", !DragSession.wantsRead(failing, at: .zero, now: 9))
        var four = s
        for i in 1...4 { four = DragSession.afterRead(four, bounds: window, now: 1 + Double(i) * 0.05) }
        check("4 failed checks still pending, the 5th may confirm", four.phase == .pending
              && DragSession.afterRead(four, bounds: window.offsetBy(dx: 1, dy: 0), now: 2).phase == .confirmed)
        check("unreadable window → rejected", DragSession.afterRead(s, bounds: nil, now: 1.05).phase == .rejected)

        var combos = 0
        for requested in [false, true] {
            for confirmed in [false, true] {
                for blank in [false, true] {
                    for topBand in [false, true] {
                        let expected: DragSession.Overlay = !confirmed ? .hidden : topBand ? .maximize : requested && !blank ? .zones : .hidden
                        let shown = DragSession.overlay(requested: requested, confirmed: confirmed, blank: blank, topBand: topBand)
                        check("overlay requested=\(requested) confirmed=\(confirmed) blank=\(blank) topBand=\(topBand) → \(expected)", shown == expected)
                        combos += 1
                    }
                }
            }
        }
        check("overlay: all 16 combinations covered", combos == 16)

        var tap = TapState()
        check("right-click without the left button passes", tap.button(.rightMouseDown) == (false, false) && tap.button(.rightMouseUp) == (false, false))
        _ = tap.button(.leftMouseDown)
        var requested = false, allSwallowed = true
        for n in 1...5 {
            let d = tap.button(.rightMouseDown), u = tap.button(.rightMouseUp)
            if d.toggle { requested.toggle() }
            allSwallowed = allSwallowed && d.swallow && u.swallow && !u.toggle
            check("right-click toggle parity after \(n)", requested == (n % 2 == 1))
        }
        check("right-click pairs swallowed while the left button is held", allSwallowed)
        _ = tap.button(.rightMouseDown)
        _ = tap.button(.leftMouseUp)
        check("a swallowed right-down's up is swallowed after left-up", tap.button(.rightMouseUp).swallow)
        var late = TapState()
        _ = late.button(.rightMouseDown)
        _ = late.button(.leftMouseDown)
        check("a right-up whose down passed is not swallowed", !late.button(.rightMouseUp).swallow)
    }

    // MARK: Updater

    private static func updateVersions() {
        check("update: 1.0.10 is newer than 1.0.9", Updater.isNewer("1.0.10", than: "1.0.9"))
        check("update: v-prefixed tag is newer", Updater.isNewer("v1.1.0", than: "1.0.0"))
        check("update: 1.0 equals 1.0.0", !Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("1.0.0", than: "1.0"))
        check("update: older is not newer", !Updater.isNewer("1.9.9", than: "2.0.0"))
    }

    private static func hotKeyModifiers() {
        check("⌃⌘ valid", HotKeyModifiers.isValid([.control, .command]))
        check("⇧ alone invalid", !HotKeyModifiers.isValid(.shift))
        check("nothing invalid", !HotKeyModifiers.isValid([]))
        check("symbols in system order", HotKeyModifiers.symbols([.command, .shift, .option, .control]) == "⌃⌥⇧⌘")
        check("carbon ⌃⌥", HotKeyModifiers.carbon([.control, .option]) == controlKey | optionKey)
        check("title bar: window chrome", TitleBar.isHit(role: kAXWindowRole, isTitle: false))
        check("title bar: toolbar", TitleBar.isHit(role: kAXToolbarRole, isTitle: false))
        check("title bar: title text", TitleBar.isHit(role: kAXStaticTextRole, isTitle: true))
        check("title bar: not a button", !TitleBar.isHit(role: kAXButtonRole, isTitle: false))
        let a = CGRect(x: 10, y: 10, width: 300, height: 200), m = CGRect(x: 0, y: 25, width: 1440, height: 875)
        var r = RestoreFrames(capacity: 2)
        r.save(1, previous: a, maximized: m)
        check("restore: still maximized", r.take(1, current: m) == a)
        check("restore: consumed", r.take(1, current: m) == nil)
        r.save(1, previous: a, maximized: m)
        check("restore: moved since, no restore", r.take(1, current: a) == nil && r.entries.isEmpty)
        r.save(1, previous: a, maximized: m)
        check("restore: size rounded by the app", r.take(1, current: CGRect(x: 0, y: 37, width: 1436, height: 863)) == a)
        r.save(1, previous: a, maximized: m); r.save(2, previous: a, maximized: m); r.save(3, previous: a, maximized: m)
        check("restore: oldest dropped past capacity", r.entries.map(\.id) == [2, 3])
        r.save(2, previous: m, maximized: a)
        check("restore: re-save replaces", r.entries.map(\.id) == [3, 2] && r.take(2, current: a) == m)
        check("carbon ignores caps lock", HotKeyModifiers.carbon([.command, .capsLock]) == cmdKey)
    }
}
