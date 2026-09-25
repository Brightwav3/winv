import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Global hotkeys via Carbon — need no Accessibility permission and cost nothing while idle.
/// id 1 opens history (user-configurable, ⌥V by default); ids ≥ 100 are pinned-item shortcuts.
@MainActor
enum HotKey {
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static let sig = OSType(0x434C_4950) // 'CLIP'

    @discardableResult
    static func register(id: UInt32, key: UInt32, mods: UInt32, _ action: @escaping () -> Void) -> Bool {
        install()
        unregister(id)
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: sig, id: id)
        guard RegisterEventHotKey(key, mods, hk, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    // MARK: Open-history shortcut

    static var main: Shortcut {
        guard let d = UserDefaults.standard.data(forKey: "mainShortcut"),
              let sc = try? JSONDecoder().decode(Shortcut.self, from: d) else { return .defaultMain }
        return sc
    }

    /// Registers the open-history shortcut; falls back to ⌥V if the saved one is unavailable.
    static func registerMain() {
        if !register(id: 1, key: main.key, mods: main.mods, { PanelController.shared.toggle() }) {
            register(id: 1, key: Shortcut.defaultMain.key, mods: Shortcut.defaultMain.mods) { PanelController.shared.toggle() }
        }
    }

    /// Saves a new open-history shortcut. Returns false (keeping the old one) if another app owns the combo.
    static func setMain(_ sc: Shortcut) -> Bool {
        let old = main
        guard register(id: 1, key: sc.key, mods: sc.mods, { PanelController.shared.toggle() }) else {
            register(id: 1, key: old.key, mods: old.mods) { PanelController.shared.toggle() }
            return false
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(sc), forKey: "mainShortcut")
        return true
    }

    /// While recording a new combo, global shortcuts must not swallow the keypress.
    static func suspend() { for id in Array(refs.keys) { unregister(id) } }
    static func resume() { registerMain(); syncPinned(Store.shared.items) }

    static func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        actions[id] = nil
    }

    /// Re-register shortcuts for pinned items after any change.
    static func syncPinned(_ items: [ClipItem]) {
        for id in refs.keys where id >= 100 { unregister(id) }
        for (n, item) in items.enumerated() where item.pinned {
            guard let sc = item.shortcut else { continue }
            let itemID = item.id
            register(id: 100 + UInt32(n), key: sc.key, mods: sc.mods) {
                guard let it = Store.shared.items.first(where: { $0.id == itemID }) else { return }
                Paster.rememberTarget()
                Paster.paste(it)
            }
        }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A recorded key combo (Carbon key code + modifier mask) with a display label.
struct Shortcut: Codable, Equatable {
    var key: UInt32
    var mods: UInt32
    var label: String

    static let defaultMain = Shortcut(key: UInt32(kVK_ANSI_V), mods: UInt32(optionKey), label: "⌥V")

    init(key: UInt32, mods: UInt32, label: String) { self.key = key; self.mods = mods; self.label = label }

    /// Individual key caps for display, e.g. ["⌥", "⌘", "V"].
    var caps: [String] {
        let mods = label.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        return mods + [String(label.dropFirst(mods.count))]
    }

    /// From a key event; requires ⌃, ⌥ or ⌘ so plain typing is never hijacked.
    init?(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var m: UInt32 = 0, l = ""
        if f.contains(.control) { m |= UInt32(controlKey); l += "⌃" }
        if f.contains(.option) { m |= UInt32(optionKey); l += "⌥" }
        if f.contains(.shift) { m |= UInt32(shiftKey); l += "⇧" }
        if f.contains(.command) { m |= UInt32(cmdKey); l += "⌘" }
        guard let ch = e.charactersIgnoringModifiers?.uppercased(), !ch.isEmpty else { return nil }
        key = UInt32(e.keyCode); mods = m; label = l + ch
    }
}

enum Access {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Screen point (Cocoa coordinates) just below the text caret of the focused app,
    /// falling back to the mouse location.
    static func caretPoint() -> NSPoint {
        guard trusted else { return NSEvent.mouseLocation }
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        var range: CFTypeRef?
        var bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused,
              AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let r = range,
              AXUIElementCopyParameterizedAttributeValue(el as! AXUIElement, kAXBoundsForRangeParameterizedAttribute as CFString, r, &bounds) == .success,
              let b = bounds
        else { return NSEvent.mouseLocation }
        var rect = CGRect.zero
        AXValueGetValue(b as! AXValue, .cgRect, &rect)
        guard rect.width + rect.height > 0 else { return NSEvent.mouseLocation }
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: rect.minX, y: h - rect.maxY - 4)  // AX is top-left origin
    }

    /// Simulate ⌘V in the frontmost app.
    static func sendPaste() {
        guard trusted else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

@MainActor
enum Paster {
    /// App that was frontmost before our UI appeared — the paste target.
    static var target: NSRunningApplication?

    static func rememberTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { target = front }
    }

    static func paste(_ item: ClipItem, plain: Bool = Settings.plainDefault) {
        Store.shared.write(item, plain: plain)
        guard Access.trusted else {
            // Without Accessibility we can only copy; ask once per launch for permission.
            if !asked { asked = true; Access.prompt() }
            return
        }
        // Make sure the original app is frontmost (e.g. if our Settings window was active).
        if let app = target, !app.isActive { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Access.sendPaste() }
    }
    private static var asked = false
}
