import AppKit
import SwiftUI
import Carbon.HIToolbox

@main
struct ClipboardApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("WinV", systemImage: "doc.on.clipboard") { MenuContent() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppTheme.apply()
        Watcher.shared.start()
        HotKey.registerMain()
        HotKey.syncPinned(Store.shared.items)
        Updater.shared.start()
        if !UserDefaults.standard.bool(forKey: "onboarded") { Windows.onboarding() }
    }
}

struct MenuContent: View {
    private var store = Store.shared
    @AppStorage("mainShortcut") private var mainShortcut = Data()   // refreshes the label on change

    var body: some View {
        let _ = Paster.rememberTarget()
        if let r = Updater.shared.available {
            Button("Update to WinV \(r.version)…") { UpdateWindow.show() }
            Divider()
        }
        Text("Recent")
        ForEach(Array(store.items.prefix(4).enumerated()), id: \.element.id) { i, item in
            Button(String(item.text.prefix(40)).replacingOccurrences(of: "\n", with: " ")) { Paster.paste(item) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
        }
        Divider()
        if !Access.trusted {
            Button("Allow pasting (Accessibility)…") { Access.prompt() }
        }
        Button("Open history (\(HotKey.main.label))") { PanelController.shared.show() }
        Button(store.paused ? "Resume recording" : "Pause recording") { store.paused.toggle() }
        Button("Clear history") { store.clear() }
        Divider()
        Button("About WinV") { About.show() }
        Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
        Button("Settings…") { Windows.settings() }.keyboardShortcut(",")
        Button("Quit WinV") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Standard macOS About panel (uses the bundled app icon; generated one as fallback).
@MainActor
enum About {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let center = { let s = NSMutableParagraphStyle(); s.alignment = .center; return s }()
        let credits = NSMutableAttributedString(
            string: "Clipboard history for your Mac.\nPress \(HotKey.main.label) anywhere to open it.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: center])
        credits.append(NSAttributedString(string: "Support WinV ☕", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://buymeacoffee.com/brightwave")!,
            .paragraphStyle: center]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WinV",
            .applicationIcon: NSApp.applicationIconImage ?? icon,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026",
        ])
    }

    /// Rounded-square icon: blue gradient with the clipboard glyph.
    static let icon: NSImage = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
        let rect = r.insetBy(dx: 20, dy: 20)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 50, yRadius: 50)
        NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.60, blue: 1, alpha: 1),
                            NSColor(srgbRed: 0.16, green: 0.36, blue: 0.90, alpha: 1)])?.draw(in: shape, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: 110, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = glyph.size
            glyph.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}
