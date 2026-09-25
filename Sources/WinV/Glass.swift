import AppKit
import SwiftUI

/// Translucent Liquid Glass surface (light or dark, following the system) for SwiftUI content.
/// Older macOS releases fall back to a behind-window HUD material.
@MainActor
enum Glass {
    static func surface(_ view: some View, cornerRadius: CGFloat, frost: Bool = false) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []

        let ambient = AmbientView()
        let glass: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = cornerRadius
            // Translucent tint per appearance: desktop shows through while text keeps contrast.
            g.tintColor = frost ? Glass.frostTint : Glass.tint
            g.contentView = host
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.masksToBounds = true
            host.autoresizingMask = [.width, .height]
            v.addSubview(host)
            glass = v
        }
        glass.autoresizingMask = [.width, .height]
        if frost {
            // Extra behind-window blur under the glass: more diffuse, frosted look.
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            ambient.addSubview(blur)
        }
        ambient.frost = frost
        ambient.addSubview(glass)
        ambient.wantsLayer = true
        ambient.layer?.cornerRadius = cornerRadius
        ambient.layer?.masksToBounds = true
        return ambient
    }

    static let tint = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 0.42) : NSColor(white: 1.0, alpha: 0.45)
    }

    /// Heavier tint for frosted windows (Settings).
    static let frostTint = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.12, alpha: 0.55) : NSColor(white: 1.0, alpha: 0.60)
    }

    /// Edge-to-edge window: transparent titlebar, traffic lights kept, content under them.
    static func window(title: String, size: NSSize, frost: Bool = false, _ view: some View) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.isOpaque = false
        w.backgroundColor = .clear
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        // An empty unified toolbar gives the taller macOS 26 titlebar with the
        // larger, inset traffic lights instead of the classic compact ones.
        let bar = NSToolbar(identifier: "glass.\(title)")
        bar.showsBaselineSeparator = false
        w.toolbar = bar
        w.toolbarStyle = .unified
        w.contentView = surface(view, cornerRadius: 16, frost: frost)
        return w
    }
}

/// Faint translucent wash behind the glass — never opaque, so the desktop transmits.
private final class AmbientView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var frost = false
    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        // Layer-backed glass caches its tint; re-assign so it resolves for the new appearance.
        if #available(macOS 26.0, *), let g = subviews.last as? NSGlassEffectView {
            g.tintColor = frost ? Glass.frostTint : Glass.tint
        }
    }
    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSGradient(colors: dark
            ? [NSColor(white: 0.14, alpha: 0.26), NSColor(white: 0.08, alpha: 0.19)]
            : [NSColor(white: 1.0, alpha: 0.26), NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 0.19)]
        )?.draw(in: bounds, angle: 90)
        NSGradient(colors: [NSColor(srgbRed: 0.29, green: 0.53, blue: 0.96, alpha: 0.10), .clear])?
            .draw(fromCenter: NSPoint(x: bounds.maxX * 0.8, y: 0), radius: 0,
                  toCenter: NSPoint(x: bounds.maxX * 0.8, y: 0), radius: bounds.width * 0.7, options: [])
    }
}
