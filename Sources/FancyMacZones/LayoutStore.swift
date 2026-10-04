import AppKit

/// The contents of `layouts.json`, version 1 (Data & State Management). Pure value type: every query and write
/// rule of the store lives here so --self-test can cover it.
struct LayoutFile: Equatable {
    struct DisplayState: Equatable {
        var layout = LayoutRef.fallback
        /// Only counts that differ from the template's default.
        var zoneCounts: [TemplateKind: Int] = [:]
    }

    var customLayouts: [CustomLayout] = []
    /// Keyed by display UUID string. A missing entry means Priority Grid with 3 zones (requirement 1).
    var displays: [String: DisplayState] = [:]

    func state(_ uuid: String) -> DisplayState { displays[uuid] ?? DisplayState() }

    func custom(_ id: UUID) -> CustomLayout? { customLayouts.first { $0.id == id } }

    func zoneCount(_ kind: TemplateKind, on uuid: String) -> Int {
        state(uuid).zoneCounts[kind] ?? kind.defaultCount
    }

    func name(of ref: LayoutRef) -> String {
        switch ref {
        case .template(let kind): kind.title
        case .custom(let id): custom(id)?.name ?? TemplateKind.priorityGrid.title // unknown ID: the fallback
        }
    }

    /// The display's zones as fractions, in number order. An unknown custom ID falls back to Priority Grid.
    func zones(on uuid: String) -> [CGRect] {
        let s = state(uuid)
        switch s.layout {
        case .template(let kind): return kind.zones(count: zoneCount(kind, on: uuid))
        case .custom(let id):
            return custom(id)?.zones ?? TemplateKind.priorityGrid.zones(count: zoneCount(.priorityGrid, on: uuid))
        }
    }

    /// Every display's zones in global Cocoa coordinates, displays in their R-19 order (DD-3). Blank adds none.
    func placedZones(_ displays: [(uuid: String, usable: CGRect)]) -> [PlacedZone] {
        displays.enumerated().flatMap { i, d in
            zones(on: d.uuid).enumerated().map { PlacedZone(display: i, number: $0.offset + 1, rect: Layouts.place($0.element, in: d.usable)) }
        }
    }

    /// Display UUIDs whose layout is this custom layout.
    func uuids(using id: UUID) -> [String] {
        displays.filter { $0.value.layout == .custom(id) }.map(\.key).sorted()
    }

    /// Requirement 5: "Custom Grid n" / "Custom Canvas n" with the smallest n not in use.
    func nextName(_ prefix: String) -> String {
        let used = Set(customLayouts.map(\.name))
        return "\(prefix) \((1...).first { !used.contains("\(prefix) \($0)") }!)"
    }

    // MARK: Writes

    mutating func assign(_ ref: LayoutRef, to uuid: String) {
        if case .custom(let id) = ref, custom(id) == nil { return }
        displays[uuid, default: DisplayState()].layout = ref
    }

    /// Stored only when it differs from the default, clamped to the template's range (requirement 2).
    mutating func setZoneCount(_ count: Int, for kind: TemplateKind, on uuid: String) {
        let n = kind.clamped(count)
        displays[uuid, default: DisplayState()].zoneCounts[kind] = n == kind.defaultCount ? nil : n
    }

    mutating func add(_ layout: CustomLayout) { customLayouts.append(layout) }

    mutating func rename(_ id: UUID, to name: String) {
        guard let i = customLayouts.firstIndex(where: { $0.id == id }) else { return }
        customLayouts[i].name = name
    }

    mutating func replaceBody(_ id: UUID, with body: CustomLayout.Body) {
        guard let i = customLayouts.firstIndex(where: { $0.id == id }) else { return }
        customLayouts[i].body = body
    }

    /// Requirement 5: every display that used it falls back to Priority Grid with that display's stored count.
    mutating func deleteCustom(_ id: UUID) {
        customLayouts.removeAll { $0.id == id }
        for uuid in uuids(using: id) { displays[uuid]?.layout = .fallback }
    }

    // MARK: JSON

    /// nil for corrupt data (not JSON, wrong shape or version). Unknown template kinds, unknown custom IDs and
    /// out-of-range counts fall back to defaults; invalid custom layouts are dropped.
    static func decode(_ data: Data) -> LayoutFile? {
        guard var file = try? JSONDecoder().decode(LayoutFile.self, from: data) else { return nil }
        for (uuid, s) in file.displays {
            if case .custom(let id) = s.layout, file.custom(id) == nil { file.displays[uuid]?.layout = .fallback }
        }
        return file
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

extension LayoutFile: Codable {
    private enum Key: String, CodingKey { case version, customLayouts, displays }

    /// Decodes one array element without failing the whole array.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "unsupported version")
        }
        customLayouts = try c.decodeIfPresent([Lossy<CustomLayout>].self, forKey: .customLayouts)?.compactMap(\.value) ?? []
        displays = try c.decodeIfPresent([String: DisplayState].self, forKey: .displays) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(1, forKey: .version)
        try c.encode(customLayouts, forKey: .customLayouts)
        try c.encode(displays, forKey: .displays)
    }
}

extension LayoutFile.DisplayState: Codable {
    private enum Key: String, CodingKey { case layout, zoneCounts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        layout = (try? c.decode(LayoutRef.self, forKey: .layout)) ?? .fallback
        let raw = (try? c.decode([String: Int].self, forKey: .zoneCounts)) ?? [:]
        for (name, n) in raw {
            guard let kind = TemplateKind(rawValue: name), kind.clamped(n) != kind.defaultCount else { continue }
            zoneCounts[kind] = kind.clamped(n)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(layout, forKey: .layout)
        try c.encode(Dictionary(uniqueKeysWithValues: zoneCounts.map { ($0.key.rawValue, $0.value) }), forKey: .zoneCounts)
    }
}

/// Scalar settings in UserDefaults (DD-10), read on every gesture and whenever the menu opens. Each "disabled"
/// key makes its feature on by default.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var overlapRule: OverlapRule {
        get { defaults.string(forKey: "overlapRule").flatMap(OverlapRule.init) ?? .smallestArea }
        set { defaults.set(newValue.rawValue, forKey: "overlapRule") }
    }

    /// Requirement 11.
    static var dragToTop: Bool {
        get { !defaults.bool(forKey: "dragToTopDisabled") }
        set { defaults.set(!newValue, forKey: "dragToTopDisabled") }
    }

    /// Requirement 12.
    static var missionControlGuard: Bool {
        get { !defaults.bool(forKey: "missionControlGuardDisabled") }
        set { defaults.set(!newValue, forKey: "missionControlGuardDisabled") }
    }
}

/// Owns the persisted layouts (DD-10, ADR 60d109d4) and display identity (requirements 1, 19). Read once at
/// launch; every committed change (requirement 29) is one atomic write followed by `didChange`.
final class LayoutStore {
    static let didChange = Notification.Name("FancyMacZones.layoutsDidChange")
    static let displaysDidChange = Notification.Name("FancyMacZones.displaysDidChange")

    /// A connected display. `name` follows requirement 19; `frame` and `usable` are global Cocoa.
    struct Display: Equatable {
        var uuid: String
        var id: CGDirectDisplayID
        var name: String
        var frame: CGRect
        var usable: CGRect
    }

    #if DEBUG
    private static let folder = "FancyMacZones Dev"
    #else
    private static let folder = "FancyMacZones"
    #endif
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(folder)/layouts.json")

    private(set) var file: LayoutFile
    /// Left to right, then top to bottom (requirement 19).
    private(set) var displays: [Display] = []
    private let url: URL

    init(url: URL = LayoutStore.defaultURL) {
        self.url = url
        file = Self.load(url).file
        refreshDisplays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Queries

    var customLayouts: [CustomLayout] { file.customLayouts }
    func layout(on d: Display) -> LayoutRef { file.state(d.uuid).layout }
    func layoutName(on d: Display) -> String { file.name(of: layout(on: d)) }
    func zoneCount(_ kind: TemplateKind, on d: Display) -> Int { file.zoneCount(kind, on: d.uuid) }

    /// The display's zones in global Cocoa coordinates, in number order.
    func zones(on d: Display) -> [CGRect] { file.zones(on: d.uuid).map { Layouts.place($0, in: d.usable) } }

    /// Every connected display's zones (DD-3).
    func allZones() -> [PlacedZone] { file.placedZones(displays.map { ($0.uuid, $0.usable) }) }

    /// Connected displays using a custom layout ("Active on:", the Delete warning).
    func displays(using id: UUID) -> [Display] {
        let uuids = Set(file.uuids(using: id))
        return displays.filter { uuids.contains($0.uuid) }
    }

    /// An unsaved new layout with the next free name (requirement 5); commit it with `add`.
    func draft(_ body: CustomLayout.Body) -> CustomLayout {
        let prefix = if case .grid = body { "Custom Grid" } else { "Custom Canvas" }
        return CustomLayout(id: UUID(), name: file.nextName(prefix), body: body)
    }

    // MARK: Writes (each one is a commit)

    func assign(_ ref: LayoutRef, to d: Display) { commit { $0.assign(ref, to: d.uuid) } }
    func setZoneCount(_ n: Int, for kind: TemplateKind, on d: Display) { commit { $0.setZoneCount(n, for: kind, on: d.uuid) } }
    func add(_ layout: CustomLayout) { commit { $0.add(layout) } }
    func rename(_ id: UUID, to name: String) { commit { $0.rename(id, to: name) } }
    func replaceBody(_ id: UUID, with body: CustomLayout.Body) { commit { $0.replaceBody(id, with: body) } }
    func delete(_ id: UUID) { commit { $0.deleteCustom(id) } }
    /// Import: the whole file, already validated by `LayoutFile.decode`.
    func replaceAll(with new: LayoutFile) { commit { $0 = new } }

    /// Adds a copy named "‹name› Copy" and returns it.
    @discardableResult
    func duplicate(_ id: UUID) -> CustomLayout? {
        guard let original = file.custom(id) else { return nil }
        let copy = CustomLayout(id: UUID(), name: "\(original.name) Copy", body: original.body)
        add(copy)
        return copy
    }

    private func commit(_ change: (inout LayoutFile) -> Void) {
        change(&file)
        Self.save(file, to: url)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: File

    /// NFR-4: a missing file gives defaults; a corrupt one is renamed aside with a timestamp and defaults are used.
    static func load(_ url: URL, now: Date = Date()) -> (file: LayoutFile, renamedTo: URL?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (LayoutFile(), nil) }
        guard let data = try? Data(contentsOf: url) else {
            EventLog.write("layouts: could not read \(url.path), using defaults")
            return (LayoutFile(), nil)
        }
        if let file = LayoutFile.decode(data) {
            EventLog.write("layouts: loaded \(file.customLayouts.count) custom, \(file.displays.count) displays")
            return (file, nil)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingLastPathComponent().appendingPathComponent("layouts-corrupt-\(f.string(from: now)).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            EventLog.write("layouts: corrupt file renamed to \(aside.lastPathComponent), recovered to defaults")
            return (LayoutFile(), aside)
        } catch {
            EventLog.write("layouts: corrupt file could not be renamed (\(error)), recovered to defaults")
            return (LayoutFile(), nil)
        }
    }

    /// One atomic write (requirement 29). Failures are logged; the in-memory state stays authoritative.
    @discardableResult
    static func save(_ file: LayoutFile, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            EventLog.write("layouts: save failed: \(error)")
            return false
        }
    }

    // MARK: Displays

    @objc private func screensChanged() {
        refreshDisplays()
        NotificationCenter.default.post(name: Self.displaysDidChange, object: self)
    }

    private func refreshDisplays() {
        let screens = NSScreen.screens // first = the display with the menu bar
        let order = Self.displayOrder(screens.map(\.frame))
        let names = Self.displayNames(order.map { screens[$0].localizedName }, main: order.firstIndex(of: 0))
        displays = order.enumerated().map { i, s in
            let screen = screens[s]
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            return Display(uuid: uuid, id: id, name: names[i], frame: screen.frame, usable: screen.visibleFrame)
        }
        EventLog.write("displays: \(displays.map { "\($0.name) \($0.uuid) \($0.frame)" }.joined(separator: "; "))")
    }

    // MARK: Pure helpers (covered by --self-test)

    /// Requirement 19: indices of `frames` (global Cocoa) left to right, then top to bottom.
    static func displayOrder(_ frames: [CGRect]) -> [Int] {
        frames.indices.sorted { a, b in
            frames[a].minX != frames[b].minX ? frames[a].minX < frames[b].minX : frames[a].maxY > frames[b].maxY
        }
    }

    /// Requirement 19: names in display order; identical names get " 1", " 2" left to right, and the main
    /// display (index `main`) gets " (Main)".
    static func displayNames(_ names: [String], main: Int?) -> [String] {
        var seen: [String: Int] = [:]
        return names.enumerated().map { i, name in
            var out = name
            if names.filter({ $0 == name }).count > 1 {
                seen[name, default: 0] += 1
                out += " \(seen[name]!)"
            }
            return i == main ? out + " (Main)" : out
        }
    }
}
