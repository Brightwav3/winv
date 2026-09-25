import AppKit
import Observation

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, link, image, color, rich, file }

    var id = UUID()
    var kind: Kind
    var text: String            // display + plain-text paste value
    var source: String?         // app it was copied from
    var date = Date()
    var pinned = false
    var rtf: Data?              // rich text payload
    var files: [String]?        // file paths
    var image: String?          // file name in images dir
    var size: String?           // "1440×900"
    var shortcut: Shortcut?     // global paste shortcut (pinned items only)

    var meta: String {
        let ago = Self.ago(date)
        switch kind {
        case .image: return ["Image", size, ago].compactMap { $0 }.joined(separator: " · ")
        case .rich:  return ["Rich text", source, ago].compactMap { $0 }.joined(separator: " · ")
        case .file:
            let n = files?.count ?? 0
            return ["\(n) file\(n == 1 ? "" : "s")", source, ago].compactMap { $0 }.joined(separator: " · ")
        default:     return [source, ago].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func ago(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default: return "\(s / 86400)d ago"
        }
    }
}

/// History + persistence. Everything is a flat JSON file plus raw image blobs;
/// writes are coalesced so bursts of copies cost a single disk write.
@Observable @MainActor
final class Store {
    static let shared = Store()

    private(set) var items: [ClipItem] = []
    var paused = false

    let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("images"), withIntermediateDirectories: true)
        return d
    }()
    private var file: URL { dir.appendingPathComponent("history.json") }
    func imageURL(_ name: String) -> URL { dir.appendingPathComponent("images").appendingPathComponent(name) }

    private var saveScheduled = false

    private init() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = list.filter(\.pinned) + list.filter { !$0.pinned }
        }
    }

    /// Order invariant: pinned items first (in the order they were pinned or dragged),
    /// then the rest. ⌘1–9 paste by this order.
    private var pinnedCount: Int { items.lazy.filter(\.pinned).count }

    // MARK: mutations

    func add(_ item: ClipItem) {
        // Same content copied again → bump to top instead of duplicating (keep pin).
        // A pinned duplicate keeps its place.
        var item = item
        if let i = items.firstIndex(where: { $0.kind == item.kind && $0.text == item.text }) {
            if items[i].pinned { items[i].date = item.date; save(); return }
            if item.image == nil { item.image = items[i].image } else { dropImage(items[i]) }
            items.remove(at: i)
        }
        items.insert(item, at: pinnedCount)
        trim()
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.pinned.toggle()
        if !item.pinned { item.shortcut = nil }
        // Newly pinned goes under the existing pins; unpinned goes to the top of the rest.
        items.insert(item, at: pinnedCount)
        save()
    }

    /// Drag-to-reorder: moves `id` into `target`'s slot. Items stay within their group (pinned / not).
    func move(_ id: UUID, to target: UUID) {
        guard id != target,
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }),
              items[from].pinned == items[to].pinned else { return }
        items.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        save()
    }

    func setShortcut(_ id: UUID, _ sc: Shortcut?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let sc { for j in items.indices where items[j].shortcut == sc { items[j].shortcut = nil } }
        items[i].shortcut = sc
        save()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        dropImage(items.remove(at: i))
        save()
    }

    /// Pinned items survive "Clear all".
    func clear() {
        items.filter { !$0.pinned }.forEach(dropImage)
        items.removeAll { !$0.pinned }
        save()
    }

    func trim() {
        let limit = Settings.limit
        var unpinned = 0
        items.removeAll { item in
            guard !item.pinned else { return false }
            unpinned += 1
            if unpinned > limit { dropImage(item); return true }
            return false
        }
    }

    private func dropImage(_ item: ClipItem) {
        if let img = item.image { try? FileManager.default.removeItem(at: imageURL(img)) }
    }

    private func save() {
        HotKey.syncPinned(items)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            saveScheduled = false
            let snapshot = items
            DispatchQueue.global(qos: .utility).async { [file] in
                try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            }
        }
    }

    // MARK: paste

    /// Put an item back on the general pasteboard.
    func write(_ item: ClipItem, plain: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .file:
            pb.writeObjects((item.files ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        case .image:
            if let name = item.image, let data = try? Data(contentsOf: imageURL(name)) {
                pb.setData(data, forType: name.hasSuffix(".png") ? .png : .tiff)
            }
        case .rich where !plain:
            if let rtf = item.rtf { pb.setData(rtf, forType: .rtf) }
            pb.setString(item.text, forType: .string)
        default:
            pb.setString(item.text, forType: .string)
        }
        Watcher.shared.skip(pb.changeCount)
    }
}

/// Polls `changeCount` — a single integer read — which is the only mechanism
/// macOS offers for observing the pasteboard. Content is read only on change.
@MainActor
final class Watcher {
    static let shared = Watcher()
    private var last = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { Watcher.shared.tick() }
        }
        timer?.tolerance = 0.25   // lets the system coalesce wakeups
    }

    func skip(_ count: Int) { last = count }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        let store = Store.shared
        guard Settings.historyOn, !store.paused, let item = capture(pb) else { return }
        store.add(item)
    }

    private static let concealed: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    private func capture(_ pb: NSPasteboard) -> ClipItem? {
        let types = Set(pb.types?.map(\.rawValue) ?? [])
        if Settings.skipConcealed, !types.isDisjoint(with: Self.concealed) { return nil }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .file, text: urls.map(\.lastPathComponent).joined(separator: ", "),
                            source: source, files: urls.map(\.path))
        }

        if let str = pb.string(forType: .string) {
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if t.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil {
                return ClipItem(kind: .color, text: t.uppercased(), source: source)
            }
            if !t.contains(where: \.isWhitespace), let u = URL(string: t), let s = u.scheme, ["http", "https"].contains(s) {
                return ClipItem(kind: .link, text: t, source: source)
            }
            if let rtf = pb.data(forType: .rtf), rtf.count < 512_000 {
                return ClipItem(kind: .rich, text: str, source: source, rtf: rtf)
            }
            return ClipItem(kind: .text, text: str, source: source)
        }

        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            guard let data = pb.data(forType: type) else { continue }
            let id = UUID()
            let name = "\(id.uuidString).\(ext)"
            var size: String?
            if let rep = NSBitmapImageRep(data: data) { size = "\(rep.pixelsWide)×\(rep.pixelsHigh)" }
            let url = Store.shared.imageURL(name)
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url) }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm"
            return ClipItem(id: id, kind: .image, text: "Image \(f.string(from: Date()))",
                            source: source, image: name, size: size)
        }
        return nil
    }
}

enum Settings {
    static var d: UserDefaults { .standard }
    static var historyOn: Bool { d.object(forKey: "historyOn") as? Bool ?? true }
    static var skipConcealed: Bool { d.object(forKey: "skipConcealed") as? Bool ?? true }
    static var plainDefault: Bool { d.bool(forKey: "plainDefault") }
    static var limit: Int { let v = d.integer(forKey: "limit"); return v > 0 ? v : 25 }
}
