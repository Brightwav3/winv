import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("historyOn") private var historyOn = true
    @AppStorage("skipConcealed") private var skipConcealed = true
    @AppStorage("plainDefault") private var plainDefault = false
    @AppStorage("limit") private var limit = 25
    @AppStorage("autoUpdate") private var autoUpdate = true
    @AppStorage("theme") private var theme = AppTheme.system.rawValue
    @Namespace private var themeNS
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var main = HotKey.main
    @State private var taken = false

    var body: some View {
        VStack(spacing: 0) {
            // Title stays in the titlebar row; everything below scrolls.
            Text("WinV settings").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity).frame(height: 28).padding(.top, 18).padding(.bottom, 8)
            ScrollView { groups.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 4) }
                .scrollIndicators(.automatic)
        }
        .frame(width: 560)
        .frame(minHeight: 300, idealHeight: 720)
        .focusEffectDisabled()
        .legible()
    }

    private var pinned: [ClipItem] { Store.shared.items.filter(\.pinned) }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("History") {
                row("Clipboard history", "Save multiple items to paste later.", first: true) {
                    Toggle("", isOn: $historyOn).toggleStyle(PillToggle())
                }
                row("Keep items for", "Pinned items are never removed.") {
                    Menu {
                        ForEach([10, 25, 50, 100, 200], id: \.self) { n in
                            Button("\(n) items") { limit = n; Store.shared.trim() }
                        }
                    } label: { valueBox("\(limit) items") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .focusable(false)
                }
                row("Skip password managers", "Ignore content marked as concealed.") {
                    Toggle("", isOn: $skipConcealed).toggleStyle(PillToggle())
                }
            }
            group("General") {
                row("Shortcut", taken ? "That combo is used by another app. Try another." : "Opens history at the cursor.",
                    first: true) {
                    HStack(spacing: 6) {
                        ShortcutRecorder(label: main.label) { sc in
                            guard let sc else { return }
                            taken = !HotKey.setMain(sc)
                            if !taken { main = sc } else { NSSound.beep() }
                        }
                        if main != .defaultMain {
                            Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(Color.ink3)
                                .onTapGesture { if HotKey.setMain(.defaultMain) { main = .defaultMain; taken = false } }
                                .help("Reset to ⌥V")
                        }
                    }
                }
                row("Appearance", "Follow the system or always use light or dark.") {
                    HStack(spacing: 4) {
                        ForEach(AppTheme.allCases, id: \.self) { t in
                            Text(t.rawValue).font(.system(size: 12, weight: theme == t.rawValue ? .medium : .regular))
                                .foregroundStyle(theme == t.rawValue ? Color.ink : Color.ink2)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background {
                                    if theme == t.rawValue {
                                        RoundedRectangle(cornerRadius: 7).fill(Color.card)
                                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ink.opacity(0.08)))
                                            .matchedGeometryEffect(id: "sel", in: themeNS)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard theme != t.rawValue else { return }
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { theme = t.rawValue }
                                    AppTheme.apply(t, animated: true)
                                }
                        }
                    }
                    .padding(2)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.line))
                }
                row("Paste as plain text by default", "Strip formatting on paste.") {
                    Toggle("", isOn: $plainDefault).toggleStyle(PillToggle())
                }
                row("Open at login", nil) {
                    Toggle("", isOn: $login).toggleStyle(PillToggle())
                        .onChange(of: login) { _, on in
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }
                }
            }
            group("Updates") {
                row("Check for updates automatically", "Notifies you when a new version is out.", first: true) {
                    Toggle("", isOn: $autoUpdate).toggleStyle(PillToggle())
                }
                row("Version \(Updater.shared.current)", Updater.shared.available.map { "WinV \($0.version) is available." }) {
                    Button(Updater.shared.available == nil ? "Check now" : "Update…") {
                        if Updater.shared.available == nil {
                            Task { await Updater.shared.check(userInitiated: true) }
                        } else { UpdateWindow.show() }
                    }
                    .buttonStyle(PillButton(ghost: true))
                    .disabled(Updater.shared.status == .checking)
                }
            }
            group("Pinned shortcuts") {
                if pinned.isEmpty {
                    row("No pinned items", "Pin an item in the history panel to give it a shortcut here.", first: true) {
                        EmptyView()
                    }
                }
                ForEach(Array(pinned.enumerated()), id: \.element.id) { i, item in
                    row(item.text.replacingOccurrences(of: "\n", with: " "), nil, first: i == 0) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(label: item.shortcut?.label) { Store.shared.setShortcut(item.id, $0) }
                            if item.shortcut != nil {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ink3)
                                    .onTapGesture { Store.shared.setShortcut(item.id, nil) }
                                    .help("Remove shortcut")
                            }
                        }
                    }
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 12)).kerning(0.6).foregroundStyle(Color.ink3)
            VStack(spacing: 0, content: rows)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink.opacity(0.08)))
        }
    }

    private func row(_ label: String, _ hint: String?, first: Bool = false,
                     @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14)).foregroundStyle(Color.ink).lineLimit(1)
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Color.ink3) }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Color.ink.opacity(0.07)).frame(height: 1) } }
    }

    private func valueBox(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(Color.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line))
    }
}

/// Click to record a key combo (needs ⌃, ⌥ or ⌘). ⌫ clears (reported as nil), esc cancels.
struct ShortcutRecorder: View {
    var label: String?
    var onChange: (Shortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Text(recording ? "Press keys…" : label ?? "Record")
            .font(.system(size: 13, weight: recording ? .medium : .regular))
            .foregroundStyle(recording ? Color.accent : Color.ink)
            .opacity(!recording && label == nil ? 0.5 : 1)
            .frame(minWidth: 64)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(recording ? Color.accent : Color.line))
            .contentShape(Rectangle())
            .onTapGesture { recording ? stop() : start() }
            .help(recording ? "Press a combo with ⌃, ⌥ or ⌘ · ⌫ clears · esc cancels" : "Click to change")
            .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKey.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case 53: stop()
            case 51, 117: stop(); onChange(nil)
            default:
                guard let sc = Shortcut(e) else { NSSound.beep(); return nil }
                stop(); onChange(sc)
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        HotKey.resume()
    }
}

struct OnboardingView: View {
    var done: () -> Void
    @State private var step = 0

    private let steps: [(icon: String, title: String, body: String, cta: String)] = [
        ("doc.on.clipboard", "Your clipboard, remembered",
         "Everything you copy is saved so you can paste it again later. Pinned items stay until you remove them.", "Continue"),
        ("keyboard", "Open history anywhere",
         "Press this shortcut in any app. The panel opens at your cursor. You can change it in Settings.", "Continue"),
        ("accessibility", "Allow Accessibility access",
         "Needed to paste into the app you are using. Open System Settings › Privacy & Security › Accessibility and turn on WinV.",
         "Open System Settings"),
    ]

    var body: some View {
        let s = steps[step]
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 12).fill(Color.card).frame(width: 48, height: 48)
                .overlay(Image(systemName: s.icon).font(.system(size: 22)).foregroundStyle(Color.ink))
            Text(s.title).font(.system(size: 24, weight: .medium)).foregroundStyle(Color.ink)
            Text(s.body).font(.system(size: 14)).foregroundStyle(Color.ink2).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if step == 1 {
                HStack(spacing: 6) {
                    ForEach(HotKey.main.caps, id: \.self) { k in
                        Text(k).font(.system(size: 14)).foregroundStyle(Color.ink)
                            .frame(minWidth: 36, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.line))
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 8).fill(Color.line).frame(height: 2).padding(.horizontal, 3)
                            }
                    }
                }
            }
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in Circle().fill(i == step ? Color.ink : .line).frame(width: 6, height: 6) }
                }
                Spacer()
                Button("Back") { step = max(0, step - 1) }.buttonStyle(PillButton(ghost: true))
                Button(s.cta) {
                    if step < 2 { step += 1 } else { Access.prompt(); done() }
                }.buttonStyle(PillButton())
            }
            .padding(.top, 8)
        }
        .padding(32).padding(.top, 12)
        .frame(width: 440)
        .focusEffectDisabled()
        .legible()
        .animation(.easeOut(duration: 0.15), value: step)
    }
}

@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func show(_ key: String, title: String, _ view: some View) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = open[key] { w.makeKeyAndOrderFront(nil); return }
        var size = NSHostingView(rootView: view).fittingSize
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        if key == "settings" { size.height = min(720, maxH) } else { size.height = min(size.height, maxH) }
        let w = Glass.window(title: title, size: size, frost: key == "settings", view)
        if key == "settings" {
            w.styleMask.insert(.resizable)
            w.contentMinSize = NSSize(width: size.width, height: 300)
            w.contentMaxSize = NSSize(width: size.width, height: 4000)
        }
        w.isReleasedWhenClosed = false
        // Content sits below the (transparent) titlebar; grow by its height so nothing is clipped.
        if key != "settings" {
            let bar = w.frame.height - w.contentLayoutRect.height
            if bar > 0 { w.setContentSize(NSSize(width: size.width, height: min(size.height + bar, maxH))) }
        }
        w.center()
        w.makeKeyAndOrderFront(nil)
        open[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open[key] = nil }
        }
    }

    static func settings() { show("settings", title: "WinV settings", SettingsView()) }

    static func onboarding() {
        show("onboarding", title: "Welcome to WinV", OnboardingView {
            UserDefaults.standard.set(true, forKey: "onboarded")
            open["onboarding"]?.close()
        })
    }
}
