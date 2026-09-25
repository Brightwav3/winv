import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Non-activating floating panel: it takes keyboard focus for search while the
/// app you were typing in stays frontmost, so ⌘V lands back there.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); MainActor.assumeIsolated { PanelController.shared.close() } }
    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { PanelController.shared.close() } }
}

@MainActor
final class PanelController {
    static let shared = PanelController()
    private var panel: HistoryPanel?
    private var monitor: Any?
    let model = PanelModel()

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        Paster.rememberTarget()
        let p = panel ?? makePanel()
        panel = p
        model.reset()
        let size = NSSize(width: 360, height: 520)
        var origin = Access.caretPoint()
        origin.y -= size.height
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(Access.caretPoint()) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
            origin.y = min(max(origin.y, v.minY + 8), v.maxY - size.height - 8)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        p.makeKeyAndOrderFront(nil)
        model.cmdHeld = NSEvent.modifierFlags.contains(.command)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            if e.type == .flagsChanged { self?.model.cmdHeld = e.modifierFlags.contains(.command); return e }
            return self?.model.handle(e) == true ? nil : e
        }
    }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        panel?.orderOut(nil)
    }

    private func makePanel() -> HistoryPanel {
        let p = HistoryPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = Glass.surface(HistoryView(model: model), cornerRadius: 16)
        p.setContentSize(NSSize(width: 360, height: 520))
        return p
    }
}

@Observable @MainActor
final class PanelModel {
    enum Filter: String, CaseIterable { case all = "All", pinned = "Pinned", text = "Text", images = "Images" }
    var query = ""
    var filter = Filter.all
    var selected: UUID?
    var historyOn = Settings.historyOn
    var recording: UUID?      // pinned item waiting for a shortcut key combo
    var dragging: UUID?       // row being dragged to reorder
    var cmdHeld = false       // shows the ⌘1–9 hints

    func reset() {
        query = ""; filter = .all; recording = nil; dragging = nil
        historyOn = Settings.historyOn
        selected = visible.first?.id
    }

    var visible: [ClipItem] {
        var list = Store.shared.items
        if !query.isEmpty { list = list.filter { $0.text.localizedCaseInsensitiveContains(query) } }
        switch filter {
        case .all: break
        case .pinned: list = list.filter(\.pinned)
        case .text: list = list.filter { [.text, .rich, .link].contains($0.kind) }
        case .images: list = list.filter { $0.kind == .image }
        }
        return list   // Store keeps pinned items first
    }

    /// ⌘1–9 always refer to the first nine items in the whole history.
    func quickIndex(_ id: UUID) -> Int? {
        Store.shared.items.prefix(9).firstIndex { $0.id == id }
    }

    func paste(_ item: ClipItem, plain: Bool = Settings.plainDefault) {
        PanelController.shared.close()
        Paster.paste(item, plain: plain)
    }

    /// Returns true when the key was consumed.
    func handle(_ e: NSEvent) -> Bool {
        if let id = recording {
            switch Int(e.keyCode) {
            case 53: recording = nil                                   // esc cancels
            case 51, 117: Store.shared.setShortcut(id, nil); recording = nil // ⌫ clears
            default:
                guard let sc = Shortcut(e) else { NSSound.beep(); return true }
                Store.shared.setShortcut(id, sc); recording = nil
            }
            return true
        }
        let list = visible
        let idx = list.firstIndex { $0.id == selected }
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case 125: // ↓
            if let i = idx { selected = list[min(i + 1, list.count - 1)].id } else { selected = list.first?.id }
        case 126: // ↑
            if let i = idx { selected = list[max(i - 1, 0)].id }
        case 36, 76: // ↩
            if let i = idx { paste(list[i], plain: e.modifierFlags.contains(.shift) || Settings.plainDefault) }
        case 53: // esc
            PanelController.shared.close()
        case 51 where query.isEmpty || cmd: // ⌫ removes when not editing search
            guard let i = idx else { return false }
            let next = list.indices.contains(i + 1) ? list[i + 1].id : (i > 0 ? list[i - 1].id : nil)
            Store.shared.remove(list[i].id)
            selected = next
        case 35 where cmd: // ⌘P
            if let i = idx { Store.shared.togglePin(list[i].id) }
        case 18...26 where cmd: // ⌘1…⌘9
            let map: [Int: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            let all = Store.shared.items
            if let n = map[Int(e.keyCode)], all.indices.contains(n) { paste(all[n]) } else { return false }
        default:
            return false
        }
        return true
    }
}

struct HistoryView: View {
    @Bindable var model: PanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.historyOn { content } else { off }
        }
        .frame(width: 360, height: 520, alignment: .top)
        .focusEffectDisabled()
        .legible()
        .onAppear { searchFocused = true }
    }

    @ViewBuilder private var content: some View {
        // One integrated top bar: search, clear and filters share a single glass group.
        GlassGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.ink3)
                        TextField("", text: $model.query, prompt: Text("Search clipboard").foregroundStyle(Color.ink3))
                            .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Color.ink)
                            .focused($searchFocused)
                            .onChange(of: model.query) { model.selected = model.visible.first?.id }
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .glassPill()
                    Button("Clear all") { Store.shared.clear(); model.selected = model.visible.first?.id }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .focusable(false).focusEffectDisabled()
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(Color(nsColor: .systemRed)))
                        .contentShape(Capsule())
                }
                HStack(spacing: 6) {
                    ForEach(PanelModel.Filter.allCases, id: \.self) { f in
                        Text(f.rawValue).font(.system(size: 12, weight: model.filter == f ? .medium : .regular))
                            .padding(.horizontal, 10).frame(height: 24)
                            .foregroundStyle(model.filter == f ? Color.ink : Color.ink2)
                            .glassPill(active: model.filter == f)
                            .contentShape(Capsule())
                            .onTapGesture { model.filter = f; model.selected = model.visible.first?.id }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)

        let list = model.visible
        if list.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(Color.ink3)
                Text("Nothing here yet").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
                Text(Store.shared.items.isEmpty
                     ? "Copy text, images or files and they'll appear here. Press \(HotKey.main.label) any time to open history."
                     : "No items match.")
                    .font(.system(size: 12)).foregroundStyle(Color.ink2).multilineTextAlignment(.center).lineSpacing(3)
            }
            .padding(.horizontal, 28)
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(list) { item in
                            Row(item: item, selected: item.id == model.selected,
                                recording: model.recording == item.id,
                                quick: model.cmdHeld ? model.quickIndex(item.id) : nil,
                                record: { model.recording = model.recording == item.id ? nil : item.id },
                                paste: { model.paste(item) })
                            .id(item.id)
                            .opacity(model.dragging == item.id ? 0.4 : 1)
                            .onDrag {
                                model.dragging = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDrop(target: item.id, model: model))
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: model.selected) { _, id in proxy.scrollTo(id) }
            }
        }

        HStack {
            Text("↩ Paste · ⇧↩ Paste as plain text")
            Spacer()
            Text("⌘1–9 · ⌘P Pin")
            SettingsGear()
        }
        .font(.system(size: 12)).foregroundStyle(Color.ink3)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var off: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.xmark").font(.system(size: 30)).foregroundStyle(Color.ink3)
            Text("Clipboard history is off").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
            Text("Turn it on to keep more than one item.").font(.system(size: 12)).foregroundStyle(Color.ink2)
            Button("Turn on") {
                UserDefaults.standard.set(true, forKey: "historyOn")
                model.historyOn = true
            }.buttonStyle(PillButton())
        }
        .padding(.horizontal, 28)
        .frame(maxHeight: .infinity)
    }
}

/// Live reordering: rows shift as the dragged row passes over them.
private struct ReorderDrop: DropDelegate {
    let target: UUID
    let model: PanelModel

    func dropEntered(info: DropInfo) {
        guard let id = model.dragging, id != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { Store.shared.move(id, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { model.dragging = nil; return true }
}

private struct Row: View {
    let item: ClipItem
    let selected: Bool
    let recording: Bool
    let quick: Int?           // position for ⌘1–9
    let record: () -> Void
    let paste: () -> Void
    @State private var hover = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(item.kind == .color || item.kind == .link ? .system(size: 13, design: .monospaced) : .system(size: 13))
                    .foregroundStyle(Color.ink).lineLimit(2).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.meta).font(.system(size: 12)).foregroundStyle(Color.ink3)
            }
            HStack(spacing: 2) {
                if let n = quick {
                    Text("⌘\(n + 1)").font(.system(size: 11)).foregroundStyle(Color.ink3).padding(.trailing, 4)
                        .frame(height: 24)
                }
                if item.pinned && (item.shortcut != nil || recording) { shortcutButton }
                icon(item.pinned ? "pin.fill" : "pin", color: item.pinned ? .accent : .ink3, help: "Pin") {
                    Store.shared.togglePin(item.id)
                }
                icon("xmark", color: .ink3, help: "Remove") { Store.shared.remove(item.id) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.selBg.opacity(0.8) : hover ? Color.ink.opacity(0.06) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.selBd.opacity(0.55) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: paste)   // single click pastes immediately
    }

    /// Pinned items can carry a global shortcut that pastes them from any app.
    private var shortcutButton: some View {
        Hover(color: .ink.opacity(0.08)) {
            Group {
                if recording {
                    Text("Press keys…").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accent)
                        .padding(.horizontal, 6)
                } else if let sc = item.shortcut {
                    Text(sc.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink)
                        .padding(.horizontal, 6)
                } else {
                    Image(systemName: "keyboard").font(.system(size: 12)).foregroundStyle(Color.ink3)
                        .frame(width: 24)
                }
            }
            .frame(height: 24)
            .background(recording || item.shortcut != nil
                        ? RoundedRectangle(cornerRadius: 6).stroke(recording ? Color.accent : Color.line) : nil)
            .contentShape(Rectangle())
            .onTapGesture(perform: record)
        }
        .help(recording ? "Press a combo with ⌃, ⌥ or ⌘ · ⌫ clears · esc cancels" : "Set shortcut")
    }

    private var previewURL: URL? {
        switch item.kind {
        case .image:
            item.image.map { Store.shared.imageURL($0) }
        case .file:
            item.files?.first.map { URL(fileURLWithPath: $0) }
        default:
            nil
        }
    }

    @ViewBuilder private var thumb: some View {
        let bg: Color = item.kind == .color ? (Color(hexString: item.text) ?? .sunken)
            : Color.raised
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(bg)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if item.kind == .file, let path = item.files?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else if item.kind != .color {
                Image(systemName: item.kind.symbol).font(.system(size: 14)).foregroundStyle(Color.ink2)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: previewURL?.absoluteString) {
            thumbnail = nil
            guard let url = previewURL else { return }

            // Image blobs are written in the background when captured, so retry briefly
            // if the row appears before that write finishes.
            for _ in 0..<12 {
                if Task.isCancelled { return }
                if let loaded = await Self.loadThumbnail(at: url) {
                    if Task.isCancelled { return }
                    thumbnail = loaded
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func loadThumbnail(at url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: NSSize(width: 64, height: 64),
                scale: 2,
                representationTypes: .all
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }

    private func icon(_ name: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Hover(color: .ink.opacity(0.08)) {
            Image(systemName: name).font(.system(size: 12)).foregroundStyle(color)
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .onTapGesture(perform: action)
        }
        .help(help)
    }
}

/// Liquid Glass capsules for top-bar controls (macOS 26+), translucent fill before that.
private struct GlassPill: ViewModifier {
    var active = false
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(active ? .regular.tint(Color.accent.opacity(0.35)).interactive() : .regular.interactive(),
                                in: Capsule())
        } else {
            content.background(Capsule().fill(active ? Color.selBg : Color.card))
        }
    }
}

extension View {
    func glassPill(active: Bool = false) -> some View { modifier(GlassPill(active: active)) }
}

/// Lets neighbouring glass shapes blend and morph together.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

/// Tiny vector gear (8 teeth, hollow hub) — drawn as a path, no image assets.
struct Gear: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2, inner = outer * 0.74, hole = outer * 0.32
        let teeth = 8
        var p = Path()
        for i in 0..<(teeth * 4) {
            // tooth top, tooth top, root, root — gives square-ish teeth
            let a = (Double(i) + 0.5) / Double(teeth * 4) * 2 * .pi - .pi / 2
            let rad = (i % 4 < 2) ? outer : inner
            let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
        return p
    }
}

private struct SettingsGear: View {
    @State private var hover = false
    var body: some View {
        Gear()
            .fill(hover ? Color.ink : Color.ink3, style: FillStyle(eoFill: true))
            .frame(width: 13, height: 13)
            .padding(4)
            .background(Circle().fill(hover ? Color.ink.opacity(0.10) : .clear))
            .contentShape(Circle())
            .onHover { hover = $0 }
            .onTapGesture {
                PanelController.shared.close()
                Windows.settings()
            }
            .help("Settings")
    }
}
