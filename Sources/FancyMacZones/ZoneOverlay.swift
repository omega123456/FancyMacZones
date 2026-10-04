import AppKit

/// sRGB colour from a 0xRRGGBB literal.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Zone colours and metrics (UI/UX Wireframes → Zone overlay), macOS-native per DD-15 / ADR b945ef79: system
/// accent, light or dark appearance, Increase Contrast and Reduce Transparency. Resolved per draw, so theme and
/// accessibility-display changes only need a redraw. Shared by the overlay and the editors.
struct ZoneStyle {
    var dark = false
    var contrast = false            // Increase Contrast
    var reduceTransparency = false  // fills stay translucent; borders thicken as for Increase Contrast
    var accent = rgb(0x0A84FF)
    var label = rgb(0x000000, 0.85)

    static let cornerRadius: CGFloat = 8
    static let pillInset: CGFloat = 8   // inside the border
    static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
    private static let pillPadding = CGSize(width: 18, height: 4)
    private static let pillGap: CGFloat = 8
    private static let symbol = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)

    /// Seam: snapshot tests pin the accent so references don't follow the system setting.
    static var accent: () -> NSColor = { .controlAccentColor }

    static func current(for appearance: NSAppearance) -> ZoneStyle {
        let ws = Env.workspace
        var s = ZoneStyle()
        s.dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        s.contrast = ws.accessibilityDisplayShouldIncreaseContrast
        s.reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        appearance.performAsCurrentDrawingAppearance {
            s.accent = Self.accent().cgColor
            s.label = NSColor.labelColor.cgColor
        }
        return s
    }

    private var thick: Bool { contrast || reduceTransparency }

    var inactiveFill: CGColor { dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08) }
    var inactiveBorder: CGColor { label.copy(alpha: thick ? 1 : 0.5)! }
    var inactiveBorderWidth: CGFloat { thick ? 3 : 2 }
    var activeFill: CGColor { accent.copy(alpha: 0.35)! }
    var activeBorder: CGColor { accent }
    var activeBorderWidth: CGFloat { thick ? 4 : 3 }
    /// Solid pills keep the number at ≥ 4.5:1 over any content (NFR-6).
    var pillBackground: CGColor { dark ? rgb(0x2C2C2E) : rgb(0xFFFFFF) }
    var pillText: NSColor { dark ? NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255, alpha: 1) : NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1) }

    /// A zone's fill and border; the border is drawn inside `rect`. Grid zones pass a 0 radius (they tile).
    func drawZone(_ rect: CGRect, active: Bool, cornerRadius: CGFloat = ZoneStyle.cornerRadius, in ctx: CGContext) {
        let w = active ? activeBorderWidth : inactiveBorderWidth
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(active ? activeFill : inactiveFill)
        ctx.fillPath()
        let inner = rect.insetBy(dx: w / 2, dy: w / 2)
        guard inner.width > 0, inner.height > 0 else { return }
        let ir = max(min(r - w / 2, inner.width / 2, inner.height / 2), 0)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: ir, cornerHeight: ir, transform: nil))
        ctx.setStrokeColor(active ? activeBorder : inactiveBorder)
        ctx.setLineWidth(w)
        ctx.strokePath()
    }

    /// What a pill shows: a zone number (the winner adds `checkmark.circle.fill`), or the maximize glyph.
    enum Pill: Equatable {
        case number(Int, winner: Bool)
        case maximize
    }

    func pillSize(_ pill: Pill) -> CGSize {
        let height = ceil(Self.pillFont.ascender - Self.pillFont.descender) + 2 * Self.pillPadding.height
        var width = 2 * Self.pillPadding.width
        switch pill {
        case .number(let n, let winner):
            width += ceil(numberString(n).size().width)
            if winner, let check = image("checkmark.circle.fill") { width += check.size.width + Self.pillGap }
        case .maximize:
            width += image("arrow.up.left.and.arrow.down.right")?.size.width ?? 0
        }
        return CGSize(width: max(width, height), height: height)
    }

    /// The pill's rect: inside the zone's top-left (inset 8 pt inside the border), or centred. `flipped` is the
    /// drawing view's `isFlipped`.
    func pillRect(_ pill: Pill, in zone: CGRect, active: Bool, centred: Bool, flipped: Bool) -> CGRect {
        let s = pillSize(pill)
        if centred { return CGRect(x: zone.midX - s.width / 2, y: zone.midY - s.height / 2, width: s.width, height: s.height) }
        let inset = Self.pillInset + (active ? activeBorderWidth : inactiveBorderWidth)
        return CGRect(x: zone.minX + inset, y: flipped ? zone.minY + inset : zone.maxY - inset - s.height,
                      width: s.width, height: s.height)
    }

    /// Draws into the current NSGraphicsContext (text and symbols need it).
    func drawPill(_ pill: Pill, in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.setFillColor(pillBackground)
        ctx.fillPath()
        ctx.restoreGState()
        var x = rect.minX + Self.pillPadding.width
        func drawImage(_ img: NSImage) {
            img.draw(in: CGRect(x: x, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += img.size.width + Self.pillGap
        }
        switch pill {
        case .number(let n, let winner):
            if winner, let check = image("checkmark.circle.fill", colors: [.white, NSColor(cgColor: accent) ?? .controlAccentColor]) {
                drawImage(check)
            }
            let text = numberString(n), size = text.size()
            text.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
        case .maximize:
            if let glyph = image("arrow.up.left.and.arrow.down.right", colors: [pillText]) {
                x = rect.midX - glyph.size.width / 2
                drawImage(glyph)
            }
        }
    }

    private func numberString(_ n: Int) -> NSAttributedString {
        NSAttributedString(string: "\(n)", attributes: [.font: Self.pillFont, .foregroundColor: pillText])
    }

    private func image(_ name: String, colors: [NSColor] = [.labelColor]) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbol.applying(.init(paletteColors: colors)))
    }
}

/// Draws zones with number pills, the active zone last with the winner's checkmark, or the maximize preview
/// (UI/UX Wireframes → Zone overlay, Maximize preview). Rects are in this (unflipped) view's coordinates.
final class ZoneView: NSView {
    var zones: [CGRect] = [] { didSet { if zones != oldValue { needsDisplay = true } } }
    var active: Int? { didSet { if active != oldValue { needsDisplay = true } } }
    /// When set, only the maximize preview is drawn (requirement 11 takes precedence over zones).
    var maximize: CGRect? { didSet { if maximize != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Accent colour or accessibility display options changed (DD-15).
    func themeChanged() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let style = ZoneStyle.current(for: effectiveAppearance)
        #if DEBUG
        defer { drawDevStamp(in: ctx) } // on top of zones and the maximize preview
        #endif
        if let maximize {
            style.drawZone(maximize, active: true, in: ctx)
            style.drawPill(.maximize, in: style.pillRect(.maximize, in: maximize, active: true, centred: true, flipped: false))
            return
        }
        for (i, zone) in zones.enumerated() where i != active {
            style.drawZone(zone, active: false, in: ctx)
            let pill = ZoneStyle.Pill.number(i + 1, winner: false)
            style.drawPill(pill, in: style.pillRect(pill, in: zone, active: false, centred: false, flipped: false))
        }
        if let active, zones.indices.contains(active) { // drawn last, on top
            style.drawZone(zones[active], active: true, in: ctx)
            let pill = ZoneStyle.Pill.number(active + 1, winner: true)
            style.drawPill(pill, in: style.pillRect(pill, in: zones[active], active: true, centred: false, flipped: false))
        }
    }

    #if DEBUG
    /// FancyMacZones Dev stamp at the top right, 48 pt down to clear the menu bar (notched displays included).
    private static let devStamp = NSAttributedString(string: "DEV", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                                 .foregroundColor: NSColor.white])

    private func drawDevStamp(in ctx: CGContext) {
        let s = Self.devStamp.size()
        let pill = CGRect(x: bounds.maxX - 12 - ceil(s.width) - 16, y: bounds.maxY - 48 - 20, width: ceil(s.width) + 16, height: 20)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(rgb(0xCA5010)) // WinBar Dev's stamp colour; white text stays ≥ 4.5:1
        ctx.fillPath()
        Self.devStamp.draw(at: NSPoint(x: pill.midX - s.width / 2, y: pill.midY - s.height / 2))
    }
    #endif
}

/// The single overlay panel (DD-9): borderless, non-activating, click-through, at the floating level and on every
/// Space. Created on first show, re-framed to the full frame of the cursor's display, ordered out on release or
/// cancel. Rects are global Cocoa.
final class ZoneOverlay {
    private var panel: NSPanel?
    private let view = ZoneView(frame: .zero)

    /// Requirement 8: the display's zones, with the active zone (if any) drawn last with its checkmark.
    func showZones(_ zones: [CGRect], active: Int?, on screen: CGRect) {
        view.maximize = nil
        view.zones = zones.map { $0.offsetBy(dx: -screen.minX, dy: -screen.minY) }
        view.active = active
        show(on: screen)
    }

    /// Requirement 11: the maximize preview over the display's usable area.
    func showMaximize(_ usable: CGRect, on screen: CGRect) {
        view.maximize = usable.offsetBy(dx: -screen.minX, dy: -screen.minY)
        show(on: screen)
    }

    func hide() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }

    /// Accent colour or accessibility display options changed (DD-15).
    func themeChanged() { view.themeChanged() }

    private func show(on screen: CGRect) {
        let panel = self.panel ?? makePanel(screen)
        if panel.frame != screen { panel.setFrame(screen, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ screen: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        view.autoresizingMask = [.width, .height]
        p.contentView = view
        panel = p
        return p
    }
}
