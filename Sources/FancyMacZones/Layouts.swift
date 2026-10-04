import CoreGraphics
import Foundation

// The pure layout model (DD-14, ADR efee8860): every geometry, editing and decision rule lives here as value
// types and static functions covered by --self-test. Views and Snapper only translate input into these
// operations and draw the results. A missing operation is escalated to the owner, never added in view code.
//
// Coordinate spaces used below:
// - Fractions: zones are stored as fractions of a display's usable area (`NSScreen.visibleFrame`) with a
//   top-left origin (requirement 6).
// - Area points: points from the usable area's top-left corner, y down (a flipped view over the usable area).
//   Editor operations take an `area` size to turn the 64 pt minimum, the 8 pt snap and the 5 pt grab into fractions.
// - Global Cocoa: bottom-left origin at the primary display, y up (NSScreen frames). Zones for Snapper.
// - Global AX / CG: top-left origin at the primary display, y down (AX frames, CGEvent locations, CGDisplayBounds).

// MARK: Shapes

/// Requirement 2. Raw values are the `layouts.json` names.
enum TemplateKind: String, CaseIterable, Codable {
    case blank, focus, columns, rows, grid, priorityGrid

    var title: String {
        switch self {
        case .blank: "Blank"
        case .focus: "Focus"
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .priorityGrid: "Priority Grid"
        }
    }

    var defaultCount: Int {
        switch self {
        case .blank: 0
        case .grid: 4
        default: 3
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .blank: 0...0
        case .focus: 1...6
        default: 1...12
        }
    }

    func clamped(_ count: Int) -> Int { min(max(count, range.lowerBound), range.upperBound) }

    /// Zones for `count` (clamped to `range`), numbered in reading order of their top-left corners, except Focus,
    /// whose overlapping zones are numbered in stacking order like a canvas (requirement 6).
    func zones(count: Int) -> [CGRect] {
        let n = clamped(count), f = CGFloat(n)
        switch self {
        case .blank:
            return []
        case .columns:
            return (0..<n).map { CGRect(x: CGFloat($0) / f, y: 0, width: 1 / f, height: 1) }
        case .rows:
            return (0..<n).map { CGRect(x: 0, y: CGFloat($0) / f, width: 1, height: 1 / f) }
        case .focus:
            return (0..<n).map { CGRect(x: 0.1 + 0.05 * CGFloat($0), y: 0.1 + 0.05 * CGFloat($0), width: 0.6, height: 0.6) }
        case .grid:
            // ⌊√N⌋ rows of ⌈N ÷ rows⌉ columns; leftover cells of the last row join that row's last zone.
            let rows = Int(Double(n).squareRoot()), cols = (n + rows - 1) / rows
            var out: [CGRect] = []
            for r in 0..<rows {
                let inRow = r < rows - 1 ? cols : n - (rows - 1) * cols
                for c in 0..<inRow {
                    let span = c == inRow - 1 ? cols - c : 1
                    out.append(CGRect(x: CGFloat(c) / CGFloat(cols), y: CGFloat(r) / CGFloat(rows),
                                      width: CGFloat(span) / CGFloat(cols), height: 1 / CGFloat(rows)))
                }
            }
            return out
        case .priorityGrid:
            if n == 1 { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
            if n == 2 { return [CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1), CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)] }
            // 25% | 50% | 25%; each zone beyond 3 adds a row to a side column, right first, then left.
            let right = 1 + (n - 2) / 2, left = 1 + (n - 3) / 2
            func column(_ x: CGFloat, _ w: CGFloat, _ k: Int) -> [CGRect] {
                (0..<k).map { CGRect(x: x, y: CGFloat($0) / CGFloat(k), width: w, height: 1 / CGFloat(k)) }
            }
            let all = column(0, 0.25, left) + column(0.25, 0.5, 1) + column(0.75, 0.25, right)
            return all.sorted { a, b in abs(a.minY - b.minY) > 1e-9 ? a.minY < b.minY : a.minX < b.minX }
        }
    }
}

/// A display's layout choice: a template or a custom layout (`{ "template": kind }` / `{ "custom": id }`).
enum LayoutRef: Hashable {
    case template(TemplateKind)
    case custom(UUID)

    /// Requirement 1: a display seen for the first time gets Priority Grid.
    static let fallback = LayoutRef.template(.priorityGrid)
}

extension LayoutRef: Codable {
    private enum Key: String, CodingKey { case template, custom }

    /// Unknown kinds and malformed values decode to the fallback (Data & State Management).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let kind = try? c.decode(String.self, forKey: .template) {
            self = TemplateKind(rawValue: kind).map(LayoutRef.template) ?? .fallback
        } else if let id = try? c.decode(UUID.self, forKey: .custom) {
            self = .custom(id)
        } else {
            self = .fallback
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .template(let kind): try c.encode(kind.rawValue, forKey: .template)
        case .custom(let id): try c.encode(id, forKey: .custom)
        }
    }
}

/// Requirement 5: a named Custom Grid or Custom Canvas.
struct CustomLayout: Equatable, Identifiable {
    enum Body: Equatable {
        case grid(GridLayout)
        case canvas(CanvasLayout)
    }

    var id: UUID
    var name: String
    var body: Body

    var zones: [CGRect] {
        switch body {
        case .grid(let g): g.zones
        case .canvas(let c): c.zones
        }
    }
}

extension CustomLayout: Codable {
    private enum Key: String, CodingKey { case id, name, kind, grid, canvas }

    /// Throws for an unknown kind or an invalid body; `LayoutFile` drops such entries.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        switch try c.decode(String.self, forKey: .kind) {
        case "grid":
            let g = try c.decode(GridLayout.self, forKey: .grid)
            guard g.isValid else { throw DecodingError.dataCorruptedError(forKey: .grid, in: c, debugDescription: "invalid grid") }
            body = .grid(g.normalized())
        case "canvas":
            let canvas = try c.decode(CanvasLayout.self, forKey: .canvas)
            guard canvas.isValid else { throw DecodingError.dataCorruptedError(forKey: .canvas, in: c, debugDescription: "invalid canvas") }
            body = .canvas(canvas)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        switch body {
        case .grid(let g):
            try c.encode("grid", forKey: .kind)
            try c.encode(g, forKey: .grid)
        case .canvas(let canvas):
            try c.encode("canvas", forKey: .kind)
            try c.encode(canvas, forKey: .canvas)
        }
    }
}

/// A zone placed on a display for Snapper (DD-3): `display` is the display's index in left-to-right, then
/// top-to-bottom order (requirement 19), `number` counts from 1, `rect` is in global Cocoa coordinates.
struct PlacedZone: Equatable {
    var display: Int
    var number: Int
    var rect: CGRect
}

/// Requirement 9. Raw values are the `overlapRule` UserDefaults values.
enum OverlapRule: String {
    case smallestArea = "smallest"
    case closestCentre = "centre"
}

/// Arrow directions in global Cocoa coordinates (up = +y).
enum Direction {
    case left, right, up, down
}

/// A vertical line runs top to bottom (it separates left from right).
enum Orientation {
    case vertical, horizontal
}

/// The part of a display's top edge with no display directly above it (DD-7), in CG coordinates (y down):
/// `y` is the edge (the display's top), `x` the exposed range.
struct TopEdgeSegment: Equatable {
    var y: CGFloat
    var x: Range<CGFloat>
}

// MARK: Custom Grid (requirement 3)

/// A maximal straight segment where zones meet (requirement 3).
struct Divider: Hashable {
    var orientation: Orientation
    /// Grid line index: between `columns[line - 1]` and `columns[line]` (vertical) or the same for rows.
    var line: Int
    /// The rows (vertical) or columns (horizontal) the segment runs along.
    var span: Range<Int>
    /// Zone indices left of / above the segment, and right of / below it.
    var before: [Int]
    var after: [Int]

    /// NFR-6 VoiceOver label.
    var accessibilityLabel: String { orientation == .vertical ? "Vertical divider" : "Horizontal divider" }
}

/// What a point or a Tab stop in the Grid editor refers to. Zones are indices (number - 1).
enum GridHit: Hashable {
    case zone(Int)
    case divider(Divider)
}

/// Row and column fractions plus a cell → zone map. Every operation returns a `normalized()` grid: lines that
/// separate nothing are removed and zone indices follow reading order of their top-left cells (index = number - 1).
struct GridLayout: Equatable, Codable {
    /// Row heights top to bottom and column widths left to right, each summing to 1.
    var rows: [CGFloat]
    var columns: [CGFloat]
    /// rows × columns zone indices; each zone's cells form one rectangle.
    var cells: [[Int]]

    /// Requirement 5: New Grid starts as 2 equal columns.
    static let initial = GridLayout(rows: [1], columns: [0.5, 0.5], cells: [[0, 1]])

    static let minSide: CGFloat = 64     // requirement 3, points on the display being edited
    static let grabTolerance: CGFloat = 5 // points each side of a divider
    private static let minTrack: CGFloat = 1 // points: a row or column never collapses onto its neighbour

    var zoneCount: Int { (cells.joined().max() ?? -1) + 1 }

    var zones: [CGRect] { (0..<zoneCount).map(rect) }

    /// Cell rows and columns covered by `zone`.
    func block(_ zone: Int) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        var r0 = Int.max, r1 = -1, c0 = Int.max, c1 = -1
        for (r, row) in cells.enumerated() {
            for (c, z) in row.enumerated() where z == zone {
                r0 = min(r0, r); r1 = max(r1, r); c0 = min(c0, c); c1 = max(c1, c)
            }
        }
        return r1 < 0 ? nil : (r0...r1, c0...c1)
    }

    func rect(_ zone: Int) -> CGRect {
        guard let b = block(zone) else { return .zero }
        let x = Self.edges(columns), y = Self.edges(rows)
        return CGRect(x: x[b.columns.lowerBound], y: y[b.rows.lowerBound],
                      width: x[b.columns.upperBound + 1] - x[b.columns.lowerBound],
                      height: y[b.rows.upperBound + 1] - y[b.rows.lowerBound])
    }

    /// Positive tracks summing to 1, a full matrix, and rectangular zones.
    var isValid: Bool {
        guard !rows.isEmpty, !columns.isEmpty, rows.allSatisfy({ $0 > 0 }), columns.allSatisfy({ $0 > 0 }),
              abs(rows.reduce(0, +) - 1) < 1e-3, abs(columns.reduce(0, +) - 1) < 1e-3,
              cells.count == rows.count, cells.allSatisfy({ $0.count == columns.count }) else { return false }
        return Set(cells.joined()).allSatisfy { z in
            guard z >= 0, let b = block(z) else { return false }
            return b.rows.allSatisfy { r in b.columns.allSatisfy { cells[r][$0] == z } }
        }
    }

    /// Removes lines that separate nothing, renumbers zones in reading order and rescales tracks to sum to 1.
    func normalized() -> GridLayout {
        var g = self
        var r = 1
        while r < g.rows.count {
            if g.cells[r] == g.cells[r - 1] {
                g.rows[r - 1] += g.rows.remove(at: r)
                g.cells.remove(at: r)
            } else { r += 1 }
        }
        var c = 1
        while c < g.columns.count {
            if g.cells.allSatisfy({ $0[c] == $0[c - 1] }) {
                g.columns[c - 1] += g.columns.remove(at: c)
                for i in g.cells.indices { g.cells[i].remove(at: c) }
            } else { c += 1 }
        }
        var number: [Int: Int] = [:] // row-major first sight = the zone's top-left cell
        for row in g.cells { for z in row where number[z] == nil { number[z] = number.count } }
        g.cells = g.cells.map { $0.map { number[$0]! } }
        let rs = g.rows.reduce(0, +), cs = g.columns.reduce(0, +)
        g.rows = g.rows.map { $0 / rs }
        g.columns = g.columns.map { $0 / cs }
        return g
    }

    // MARK: Dividers

    /// Every divider in Tab order: top to bottom, then left to right (by segment start).
    var dividers: [Divider] {
        let vertical = verticalDividers
        let horizontal = transposed().verticalDividers.map { d -> Divider in var d = d; d.orientation = .horizontal; return d }
        return (vertical + horizontal).sorted { a, b in
            let p = segment(a).start, q = segment(b).start
            return abs(p.y - q.y) > 1e-9 ? p.y < q.y : p.x < q.x
        }
    }

    /// Divider endpoints in fractions (top-left origin).
    func segment(_ d: Divider) -> (start: CGPoint, end: CGPoint) {
        let x = Self.edges(columns), y = Self.edges(rows)
        switch d.orientation {
        case .vertical: return (CGPoint(x: x[d.line], y: y[d.span.lowerBound]), CGPoint(x: x[d.line], y: y[d.span.upperBound]))
        case .horizontal: return (CGPoint(x: x[d.span.lowerBound], y: y[d.line]), CGPoint(x: x[d.span.upperBound], y: y[d.line]))
        }
    }

    /// The divider's grid line as a fraction: x for vertical, y for horizontal.
    func position(_ d: Divider) -> CGFloat {
        d.orientation == .vertical ? Self.edges(columns)[d.line] : Self.edges(rows)[d.line]
    }

    /// Requirement 27 Tab / ⇧Tab order: zones by number, then dividers.
    var focusOrder: [GridHit] { (0..<zoneCount).map(GridHit.zone) + dividers.map(GridHit.divider) }

    /// A divider within the 5 pt grab tolerance (the nearest if several), else the zone under `point` (area points).
    func hitTest(_ point: CGPoint, area: CGSize) -> GridHit? {
        guard point.x >= 0, point.y >= 0, point.x <= area.width, point.y <= area.height else { return nil }
        var best: (Divider, CGFloat)?
        for d in dividers {
            let (s, e) = segment(d)
            let along = d.orientation == .vertical ? point.y : point.x
            let lo = d.orientation == .vertical ? s.y * area.height : s.x * area.width
            let hi = d.orientation == .vertical ? e.y * area.height : e.x * area.width
            let dist = d.orientation == .vertical ? abs(point.x - s.x * area.width) : abs(point.y - s.y * area.height)
            if along >= lo, along <= hi, dist <= Self.grabTolerance, dist < (best?.1 ?? .infinity) { best = (d, dist) }
        }
        if let best { return .divider(best.0) }
        let x = Self.edges(columns), y = Self.edges(rows)
        let c = (x.lastIndex { $0 * area.width <= point.x } ?? 0).clamped(to: 0...(columns.count - 1))
        let r = (y.lastIndex { $0 * area.height <= point.y } ?? 0).clamped(to: 0...(rows.count - 1))
        return .zone(cells[r][c])
    }

    /// Zones a drag-selection rectangle (area points) touches, for requirement 27's merge selection.
    func zones(intersecting selection: CGRect, area: CGSize) -> Set<Int> {
        let s = Layouts.fraction(selection.standardized, area: area)
        return Set((0..<zoneCount).filter { rect($0).intersects(s) || (s.isEmpty && rect($0).contains(s.origin)) })
    }

    // MARK: Editing

    /// Splits `zone` with a line at `position` (a fraction: x for `.vertical`, y for `.horizontal`).
    /// nil if either part would be thinner than 64 pt.
    func splitting(_ zone: Int, _ orientation: Orientation, at position: CGFloat, area: CGSize) -> GridLayout? {
        switch orientation {
        case .vertical: splitVertical(zone, position, Self.minSide / area.width)?.normalized()
        case .horizontal: transposed().splitVertical(zone, position, Self.minSide / area.height)?.transposed().normalized()
        }
    }

    /// Moves the divider's whole grid line to `position` (a fraction), clamped so no zone touching the line
    /// becomes thinner than 64 pt. Unchanged if the display is too small for any position.
    func moving(_ d: Divider, to position: CGFloat, area: CGSize) -> GridLayout {
        switch d.orientation {
        case .vertical: moveVertical(d.line, position, Self.minSide / area.width, Self.minTrack / area.width).normalized()
        case .horizontal:
            transposed().moveVertical(d.line, position, Self.minSide / area.height, Self.minTrack / area.height).transposed().normalized()
        }
    }

    /// Two or more zones whose union is a rectangle.
    func canMerge(_ zones: Set<Int>) -> Bool { mergeBox(zones) != nil }

    func merging(_ zones: Set<Int>) -> GridLayout? {
        guard let box = mergeBox(zones), let target = zones.min() else { return nil }
        var g = self
        for r in box.rows { for c in box.columns { g.cells[r][c] = target } }
        return g.normalized()
    }

    /// Requirement 3: deleting a divider merges the zones on both sides, only if their union is a rectangle.
    func canDelete(_ d: Divider) -> Bool { canMerge(Set(d.before + d.after)) }

    func deleting(_ d: Divider) -> GridLayout? { merging(Set(d.before + d.after)) }

    // MARK: Private

    /// Track boundaries: 0, prefix sums…, total.
    private static func edges(_ tracks: [CGFloat]) -> [CGFloat] {
        var out: [CGFloat] = [0]
        for t in tracks { out.append(out.last! + t) }
        return out
    }

    private func transposed() -> GridLayout {
        GridLayout(rows: columns, columns: rows,
                   cells: columns.indices.map { c in rows.indices.map { r in cells[r][c] } })
    }

    private var verticalDividers: [Divider] {
        var out: [Divider] = []
        for line in 1..<max(columns.count, 1) {
            var r = 0
            while r < rows.count {
                guard cells[r][line - 1] != cells[r][line] else { r += 1; continue }
                let start = r
                while r < rows.count, cells[r][line - 1] != cells[r][line] { r += 1 }
                func unique(_ c: Int) -> [Int] {
                    var seen: [Int] = []
                    for row in start..<r where !seen.contains(cells[row][c]) { seen.append(cells[row][c]) }
                    return seen
                }
                out.append(Divider(orientation: .vertical, line: line, span: start..<r, before: unique(line - 1), after: unique(line)))
            }
        }
        return out
    }

    private func splitVertical(_ zone: Int, _ x: CGFloat, _ minW: CGFloat) -> GridLayout? {
        guard let b = block(zone) else { return nil }
        let e = Self.edges(columns)
        let x0 = e[b.columns.lowerBound], x1 = e[b.columns.upperBound + 1]
        guard x - x0 >= minW - 1e-9, x1 - x >= minW - 1e-9 else { return nil }
        var g = self
        let line: Int
        if let k = (b.columns.lowerBound + 1..<b.columns.upperBound + 1).first(where: { abs(e[$0] - x) < 1e-9 }) {
            line = k // an existing line inside a merged zone
        } else {
            let c = b.columns.first { e[$0] < x && x < e[$0 + 1] }!
            g.columns[c] = x - e[c]
            g.columns.insert(e[c + 1] - x, at: c + 1)
            for r in g.cells.indices { g.cells[r].insert(g.cells[r][c], at: c + 1) }
            line = c + 1
        }
        let new = g.zoneCount
        for r in b.rows { for c in line..<g.columns.count where g.cells[r][c] == zone { g.cells[r][c] = new } }
        return g
    }

    private func moveVertical(_ line: Int, _ x: CGFloat, _ minW: CGFloat, _ minTrack: CGFloat) -> GridLayout {
        guard line > 0, line < columns.count else { return self }
        let e = Self.edges(columns)
        var lo = e[line - 1] + minTrack, hi = e[line + 1] - minTrack
        for z in 0..<zoneCount {
            guard let b = block(z) else { continue }
            if b.columns.upperBound == line - 1 { lo = max(lo, e[b.columns.lowerBound] + minW) }
            if b.columns.lowerBound == line { hi = min(hi, e[b.columns.upperBound + 1] - minW) }
        }
        guard lo <= hi else { return self }
        let p = min(max(x, lo), hi)
        var g = self
        g.columns[line - 1] = p - e[line - 1]
        g.columns[line] = e[line + 1] - p
        return g
    }

    private func mergeBox(_ zones: Set<Int>) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard zones.count >= 2 else { return nil }
        let blocks = zones.compactMap(block)
        guard blocks.count == zones.count else { return nil }
        let rows = blocks.map(\.rows.lowerBound).min()!...blocks.map(\.rows.upperBound).max()!
        let columns = blocks.map(\.columns.lowerBound).min()!...blocks.map(\.columns.upperBound).max()!
        for r in rows { for c in columns where !zones.contains(cells[r][c]) { return nil } }
        return (rows, columns)
    }
}

// MARK: Custom Canvas (requirement 4)

/// One of the eight resize handles of a canvas zone (requirement 28).
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// The handle's centre on `rect` (area points, y down).
    func point(on rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
    }
}

/// A snap guide line to draw across the display (area points): x for `.vertical`, y for `.horizontal`.
struct SnapGuide: Equatable {
    var orientation: Orientation
    var position: CGFloat
}

/// Result of a canvas move or resize: the new zone (fractions) and the guides of the edges that snapped.
struct CanvasDrag: Equatable {
    var rect: CGRect
    var guides: [SnapGuide]
}

/// Free rectangles in z-order, bottom first (zone number = index + 1). Zones may overlap and leave gaps.
struct CanvasLayout: Equatable {
    var zones: [CGRect]

    /// Requirement 5: New Canvas starts with one centred 30% × 30% zone.
    static let initial = CanvasLayout(zones: [CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)])

    static let minSide: CGFloat = 64      // requirement 4
    static let snapDistance: CGFloat = 8  // requirement 28
    static let cascade: CGFloat = 24      // requirement 28
    static let handleSize: CGFloat = 10   // UI/UX Wireframes → Canvas editor

    var isValid: Bool {
        zones.allSatisfy { $0.width > 0 && $0.height > 0 && $0.minX >= -1e-6 && $0.minY >= -1e-6 && $0.maxX <= 1 + 1e-6 && $0.maxY <= 1 + 1e-6 }
    }

    /// Requirement 28: adds a 30% × 30% zone, centred, or offset 24 pt from `previous` (the zone added before it
    /// in this session), back to centre if the offset would leave the usable area. Returns its index (the top).
    @discardableResult
    mutating func addZone(after previous: CGRect?, area: CGSize) -> Int {
        let w = area.width * 0.3, h = area.height * 0.3
        let centre = CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
        var r = centre
        if let previous {
            let p = Layouts.points(previous, area: area)
            r.origin = CGPoint(x: p.minX + Self.cascade, y: p.minY + Self.cascade)
            if r.maxX > area.width + 1e-6 || r.maxY > area.height + 1e-6 { r = centre }
        }
        zones.append(Layouts.fraction(r, area: area))
        return zones.count - 1
    }

    /// Moves (`handle` nil) or resizes zone `index` from `original` (its rect when the gesture began) by
    /// `translation` (area points). Clamped to the usable area and the 64 pt minimum, then, unless `snapping`
    /// is off (⌥), edges within 8 pt of a display edge or another zone's edge snap to it.
    func drag(_ index: Int, from original: CGRect, handle: Handle?, by translation: CGVector,
              area: CGSize, snapping: Bool) -> CanvasDrag {
        let others = zones.indices.filter { $0 != index }.map { Layouts.points(zones[$0], area: area) }
        let xs: [CGFloat] = [0, area.width] + others.flatMap { r -> [CGFloat] in [r.minX, r.maxX] }
        let ys: [CGFloat] = [0, area.height] + others.flatMap { r -> [CGFloat] in [r.minY, r.maxY] }
        let minW = min(Self.minSide, area.width), minH = min(Self.minSide, area.height)
        let o = Layouts.points(original, area: area)
        var guides: [SnapGuide] = []
        func nearest(_ v: CGFloat, _ targets: [CGFloat]) -> CGFloat? {
            guard snapping, let t = targets.min(by: { abs($0 - v) < abs($1 - v) }), abs(t - v) <= Self.snapDistance else { return nil }
            return t
        }
        var r: CGRect
        if let h = handle {
            // The area bound is applied last, so it wins over the minimum on a display too small for it.
            var x0 = o.minX, x1 = o.maxX, y0 = o.minY, y1 = o.maxY
            if h.movesLeft {
                x0 = max(min(x0 + translation.dx, x1 - minW), 0)
                if let s = nearest(x0, xs), s <= x1 - minW { x0 = s; guides.append(SnapGuide(orientation: .vertical, position: s)) }
            }
            if h.movesRight {
                x1 = min(max(x1 + translation.dx, x0 + minW), area.width)
                if let s = nearest(x1, xs), s >= x0 + minW { x1 = s; guides.append(SnapGuide(orientation: .vertical, position: s)) }
            }
            if h.movesTop {
                y0 = max(min(y0 + translation.dy, y1 - minH), 0)
                if let s = nearest(y0, ys), s <= y1 - minH { y0 = s; guides.append(SnapGuide(orientation: .horizontal, position: s)) }
            }
            if h.movesBottom {
                y1 = min(max(y1 + translation.dy, y0 + minH), area.height)
                if let s = nearest(y1, ys), s >= y0 + minH { y1 = s; guides.append(SnapGuide(orientation: .horizontal, position: s)) }
            }
            r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        } else {
            r = o
            r.origin.x = (o.minX + translation.dx).clamped(to: 0...max(area.width - o.width, 0))
            r.origin.y = (o.minY + translation.dy).clamped(to: 0...max(area.height - o.height, 0))
            // The closer of the two edges on each axis wins; a snap that would leave the area is ignored.
            func edgeSnap(_ lo: CGFloat, _ hi: CGFloat, _ targets: [CGFloat]) -> (shift: CGFloat, at: CGFloat)? {
                let a = nearest(lo, targets).map { (shift: $0 - lo, at: $0) }, b = nearest(hi, targets).map { (shift: $0 - hi, at: $0) }
                guard let a, let b else { return a ?? b }
                return abs(a.shift) <= abs(b.shift) ? a : b
            }
            let sx = edgeSnap(r.minX, r.maxX, xs)
            if let sx, r.minX + sx.shift >= 0, r.maxX + sx.shift <= area.width {
                r.origin.x += sx.shift
                guides.append(SnapGuide(orientation: .vertical, position: sx.at))
            }
            let sy = edgeSnap(r.minY, r.maxY, ys)
            if let sy, r.minY + sy.shift >= 0, r.maxY + sy.shift <= area.height {
                r.origin.y += sy.shift
                guides.append(SnapGuide(orientation: .horizontal, position: sy.at))
            }
        }
        return CanvasDrag(rect: Layouts.fraction(r, area: area), guides: guides)
    }

    /// The handle of `rect` (area points) under `point`, within half the 10 pt handle size.
    static func handle(at point: CGPoint, of rect: CGRect) -> Handle? {
        Handle.allCases.first { h in
            let p = h.point(on: rect)
            return abs(point.x - p.x) <= handleSize / 2 && abs(point.y - p.y) <= handleSize / 2
        }
    }

    /// Zone indices under `point` (area points), top of the z-order first: the click-again cycling order.
    func zones(at point: CGPoint, area: CGSize) -> [Int] {
        zones.indices.reversed().filter { Layouts.points(zones[$0], area: area).contains(point) }
    }

    /// Requirement 28 click cycling: the first hit, or the hit below the current selection (wrapping).
    static func nextSelection(hits: [Int], current: Int?) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let current, let i = hits.firstIndex(of: current) else { return hits[0] }
        return hits[(i + 1) % hits.count]
    }

    mutating func delete(_ index: Int) { zones.remove(at: index) }

    /// Returns the zone's new index.
    @discardableResult
    mutating func bringToFront(_ index: Int) -> Int {
        zones.append(zones.remove(at: index))
        return zones.count - 1
    }

    @discardableResult
    mutating func sendToBack(_ index: Int) -> Int {
        zones.insert(zones.remove(at: index), at: 0)
        return 0
    }
}

extension CanvasLayout: Codable {
    /// `{ "zones": [{x, y, w, h}] }` (Data & State Management).
    private struct JSONRect: Codable { var x, y, w, h: CGFloat }
    private enum Key: String, CodingKey { case zones }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        zones = try c.decode([JSONRect].self, forKey: .zones).map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(zones.map { JSONRect(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) }, forKey: .zones)
    }
}

// MARK: Decisions and conversions

enum Layouts {
    static let topBand: CGFloat = 5                  // requirement 11
    static let edgeTolerance: CGFloat = 8            // requirement 15
    static let minIoU: CGFloat = 0.6                 // requirement 15
    static let bandOverlap: CGFloat = 1              // requirement 16
    static let missionControlPush: CGFloat = 25      // DD-7, Rectangle's missionControlDraggingAllowedOffscreenDistance
    static let missionControlHold: Double = 0.25     // DD-7, Rectangle's missionControlDraggingDisallowedDuration

    /// NFR-6 VoiceOver label of a zone.
    static func zoneLabel(_ number: Int, of count: Int) -> String { "Zone \(number) of \(count)" }

    // MARK: Coordinates

    /// Fractions → a rect inside `usable` in a y-up space (global Cocoa zones, or thumbnails in an unflipped view).
    static func place(_ f: CGRect, in usable: CGRect) -> CGRect {
        CGRect(x: usable.minX + f.minX * usable.width, y: usable.maxY - f.maxY * usable.height,
               width: f.width * usable.width, height: f.height * usable.height)
    }

    /// Fractions → area points (y down).
    static func points(_ f: CGRect, area: CGSize) -> CGRect {
        CGRect(x: f.minX * area.width, y: f.minY * area.height, width: f.width * area.width, height: f.height * area.height)
    }

    /// Area points → fractions.
    static func fraction(_ r: CGRect, area: CGSize) -> CGRect {
        CGRect(x: r.minX / area.width, y: r.minY / area.height, width: r.width / area.width, height: r.height / area.height)
    }

    /// AX uses top-left global coordinates and Cocoa bottom-left; the flip is its own inverse (WinBar's `cocoaRect`).
    static func cocoaRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func axRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A CGEvent location (top-left global) → Cocoa.
    static func cocoaPoint(fromCG p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Index of the display frame containing `point` (top and right edges included, so the top row counts).
    static func display(at point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY }
    }

    // MARK: Snapping decisions

    /// Requirement 9: the zone containing `point`; among several, by the overlap rule, then its tie-breaks,
    /// then the lower zone number. `rects` are in number order and in the same space as `point`.
    static func activeZone(at point: CGPoint, in rects: [CGRect], rule: OverlapRule) -> Int? {
        func key(_ i: Int) -> [CGFloat] {
            let r = rects[i]
            let area = r.width * r.height, dist = hypot(point.x - r.midX, point.y - r.midY)
            return rule == .smallestArea ? [area, dist, CGFloat(i)] : [dist, area, CGFloat(i)]
        }
        return rects.indices.filter { rects[$0].contains(point) }.min { less(key($0), key($1)) }
    }

    /// Requirement 15: the zone a window (global Cocoa) is already in. Edge alignment first (left, right and top
    /// within 8 pt, bottom inside the zone down to 8 pt below it, so a window trimmed from below still counts),
    /// best IoU among several; then the top-left corner within 8 pt (a window whose minimum or fixed size refused
    /// the zone's size still lands there), best IoU among several; otherwise the best IoU if at least 0.6;
    /// otherwise nil (floating).
    static func currentZone(of window: CGRect, in zones: [CGRect]) -> Int? {
        let t = edgeTolerance
        let aligned = zones.indices.filter { i in
            let z = zones[i]
            return abs(window.minX - z.minX) <= t && abs(window.maxX - z.maxX) <= t && abs(window.maxY - z.maxY) <= t
                && window.minY >= z.minY - t && window.minY < z.maxY
        }
        if let best = bestIoU(window, aligned, zones) { return best.index }
        let cornered = zones.indices.filter { abs(window.minX - zones[$0].minX) <= t && abs(window.maxY - zones[$0].maxY) <= t }
        if let best = bestIoU(window, cornered, zones) { return best.index }
        if let best = bestIoU(window, Array(zones.indices), zones), best.iou >= minIoU { return best.index }
        return nil
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height, union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Requirement 16: the next zone from `reference` (the current zone's rect, or the floating window's frame)
    /// in `direction`, over every display's zones (global Cocoa), never `current`. Candidates must overlap the
    /// reference's perpendicular extent by more than 1 pt. The nearest one more than 1 pt ahead wins; with none
    /// ahead, the in-band candidate farthest the other way (wrap). Ties: perpendicular centre distance, then
    /// display order, then zone number.
    static func directionalTarget(from reference: CGRect, current: Int?, in zones: [PlacedZone], direction: Direction) -> Int? {
        let horizontal = direction == .left || direction == .right
        let sign: CGFloat = direction == .right || direction == .up ? 1 : -1
        func along(_ r: CGRect) -> CGFloat { horizontal ? r.midX : r.midY }
        func across(_ r: CGRect) -> CGFloat { horizontal ? r.midY : r.midX }
        func overlap(_ r: CGRect) -> CGFloat {
            horizontal ? min(r.maxY, reference.maxY) - max(r.minY, reference.minY)
                       : min(r.maxX, reference.maxX) - max(r.minX, reference.minX)
        }
        let inBand = zones.indices.filter { $0 != current && overlap(zones[$0].rect) > bandOverlap }
        let ahead = inBand.filter { (along(zones[$0].rect) - along(reference)) * sign > bandOverlap }
        func ties(_ i: Int) -> [CGFloat] {
            [abs(across(zones[i].rect) - across(reference)), CGFloat(zones[i].display), CGFloat(zones[i].number)]
        }
        if !ahead.isEmpty {
            return ahead.min { less([abs(along(zones[$0].rect) - along(reference))] + ties($0),
                                    [abs(along(zones[$1].rect) - along(reference))] + ties($1)) }
        }
        return inBand.min { less([along(zones[$0].rect) * sign] + ties($0), [along(zones[$1].rect) * sign] + ties($1)) }
    }

    /// Requirement 11: the cursor (global Cocoa) is within 5 pt of the top edge of its display's full frame.
    static func inTopBand(_ point: CGPoint, screen: CGRect) -> Bool {
        point.x >= screen.minX && point.x <= screen.maxX && point.y >= screen.maxY - topBand && point.y <= screen.maxY
    }

    /// DD-7: each display's top edge minus the x-ranges of displays directly above it. CG frames (y down),
    /// e.g. `CGDisplayBounds`.
    static func exposedTopEdges(_ displays: [CGRect]) -> [TopEdgeSegment] {
        var out: [TopEdgeSegment] = []
        for (i, d) in displays.enumerated() {
            var free = [d.minX..<d.maxX]
            for (j, o) in displays.enumerated() where j != i && abs(o.maxY - d.minY) < 1 {
                free = free.flatMap { r -> [Range<CGFloat>] in
                    let lo = max(r.lowerBound, o.minX), hi = min(r.upperBound, o.maxX)
                    guard lo < hi else { return [r] }
                    return [r.lowerBound..<lo, hi..<r.upperBound].filter { !$0.isEmpty }
                }
            }
            out += free.map { TopEdgeSegment(y: d.minY, x: $0) }
        }
        return out
    }

    /// DD-7 / requirement 12, decided inside the tap callback (CG coordinates, y down; `deltaY` < 0 is upward).
    /// During a confirmed drag, a cursor pinned on an exposed top edge (within 1 pt) is rewritten to 1 pt below
    /// it when the previous drag event was pinned too and this one pushes up more than 25 pt, which starts a
    /// 250 ms hold; during the hold every pinned event is rewritten. Gentle contact is left alone (requirement 11).
    static func missionControl(point: CGPoint, deltaY: CGFloat, previousY: CGFloat?, edges: [TopEdgeSegment],
                               holdUntil: Double, now: Double, confirmed: Bool) -> (rewriteY: CGFloat?, holdUntil: Double) {
        guard confirmed, let edge = edges.first(where: { $0.x.contains(point.x) && abs(point.y - $0.y) < 1 }) else {
            return (nil, holdUntil)
        }
        if now < holdUntil { return (edge.y + 1, holdUntil) }
        if let previousY, abs(previousY - edge.y) < 1, deltaY < -missionControlPush {
            return (edge.y + 1, now + missionControlHold)
        }
        return (nil, holdUntil)
    }

    // MARK: Private

    /// Lexicographic comparison with a tolerance, so float noise never decides a tie.
    private static func less(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        for (x, y) in zip(a, b) where abs(x - y) > 1e-6 { return x < y }
        return false
    }

    private static func bestIoU(_ window: CGRect, _ candidates: [Int], _ zones: [CGRect]) -> (index: Int, iou: CGFloat)? {
        var best: (index: Int, iou: CGFloat)?
        for i in candidates {
            let v = iou(window, zones[i])
            if v > (best?.iou ?? -1) + 1e-9 { best = (i, v) }
        }
        return best
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
