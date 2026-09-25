import AppKit
import SwiftUI

/// Glass theme tokens — light and dark variants follow the system appearance.
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    init?(hexString s: String) {
        guard s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
        self.init(hex: v)
    }
    /// Resolves per appearance, so the whole UI follows the system light/dark setting.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func ns(_ h: UInt32, _ a: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat(h >> 16 & 0xFF) / 255, green: CGFloat(h >> 8 & 0xFF) / 255,
                    blue: CGFloat(h & 0xFF) / 255, alpha: a)
        }
        return Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark, darkAlpha) : ns(light, lightAlpha)
        })
    }
    static let ink = adaptive(light: 0x1D1D1F, dark: 0xF5F5F5)
    static let ink2 = adaptive(light: 0x3A3A3C, dark: 0xD6D6D6)
    static let ink3 = adaptive(light: 0x6E6E73, dark: 0xBDBDBD)
    static let line = adaptive(light: 0xC7C7CC, dark: 0x454545)
    static let lineSubtle = adaptive(light: 0xE0E0E5, dark: 0x373737)
    static let sunken = adaptive(light: 0xF2F2F7, dark: 0x202020)
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x353535, lightAlpha: 0.7)
    static let accent = adaptive(light: 0x2C6EF5, dark: 0x4A86F5)
    static let selBg = adaptive(light: 0x2C6EF5, dark: 0x414141, lightAlpha: 0.16)
    static let selBd = adaptive(light: 0x2C6EF5, dark: 0x666666, lightAlpha: 0.35)
    /// Translucent fill for grouped cards / chips sitting on the glass.
    static let card = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.45, darkAlpha: 0.06)
    static let halo = adaptive(light: 0xFFFFFF, dark: 0x000000, lightAlpha: 0.5, darkAlpha: 0.45)
}

extension ClipItem.Kind {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .color: "paintpalette"
        case .rich: "bold"
        case .file: "doc"
        }
    }
}

/// Dark pill primary / ghost button.
struct PillButton: ButtonStyle {
    var ghost = false
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ghost ? Color.ink : .white)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(ghost ? (c.isPressed ? Color.sunken : .clear) : (c.isPressed ? Color(hex: 0x3167C8) : .accent)))
            .scaleEffect(c.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: c.isPressed)
    }
}

struct PillToggle: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        Capsule().fill(c.isOn ? Color.accent : Color.line)
            .frame(width: 36, height: 20)
            .overlay(alignment: c.isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                    .shadow(color: .ink.opacity(0.2), radius: 1, y: 1)
            }
            .animation(.easeOut(duration: 0.14), value: c.isOn)
            .onTapGesture { c.isOn.toggle() }
    }
}

struct Hover<Content: View>: View {
    var color = Color.sunken
    var radius: CGFloat = 6
    @ViewBuilder var content: Content
    @State private var on = false
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(on ? color : .clear))
            .onHover { on = $0 }
    }
}

/// Soft halo (dark in dark mode, light in light mode) so labels stay readable where bright wallpaper shows through the glass.
extension View {
    func legible() -> some View { shadow(color: .halo, radius: 1.5, y: 0.5) }
}

/// Appearance override from Settings: follow the system, or force light / dark.
enum AppTheme: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system }

    /// Cross-fades every open window into the new appearance instead of snapping.
    @MainActor static func apply(_ t: AppTheme = current, animated: Bool = false) {
        if animated {
            for w in NSApp.windows where w.isVisible {
                guard let layer = w.contentView?.superview?.layer ?? w.contentView?.layer else { continue }
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.45
                fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                layer.add(fade, forKey: "theme")
            }
        }
        switch t {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
