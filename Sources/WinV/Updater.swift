import AppKit
import SwiftUI
import UserNotifications

/// Self-updater backed by GitHub Releases — no dependencies.
/// Checks the latest release, notifies when a newer version is up, and installs it by
/// mounting the release DMG, swapping the app bundle in place and relaunching.
@Observable @MainActor
final class Updater: NSObject {
    static let shared = Updater()
    static let repo = "Brightwav3/winv"

    struct Release: Equatable {
        var version: String
        var notes: String
        var dmg: URL
        var page: URL
    }

    enum Status: Equatable { case idle, checking, downloading, installing, failed(String) }

    var available: Release?
    var status = Status.idle

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var auto: Bool { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
    private var timer: Timer?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let install = UNNotificationAction(identifier: "install", title: "Install & Relaunch")
        let later = UNNotificationAction(identifier: "later", title: "Later")
        center.setNotificationCategories([UNNotificationCategory(identifier: "update", actions: [install, later],
                                                                 intentIdentifiers: [])])
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in if Updater.auto { await Updater.shared.check(userInitiated: false) } }
        }
        if Self.auto {
            Task { try? await Task.sleep(for: .seconds(5)); await check(userInitiated: false) }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard status != .checking else { return }
        status = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("No release published yet.") }
            let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let dmg = gh.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browser_download_url else {
                throw Failure("The latest release has no DMG.")
            }
            status = .idle
            let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
            guard Self.isNewer(version, than: current) else {
                available = nil
                if userInitiated { alert("You're up to date", "WinV \(current) is the latest version.") }
                return
            }
            let release = Release(version: version, notes: gh.body ?? "", dmg: dmg, page: gh.html_url)
            available = release
            if userInitiated {
                UpdateWindow.show()
            } else if UserDefaults.standard.string(forKey: "skippedVersion") != version,
                      UserDefaults.standard.string(forKey: "notifiedVersion") != version {
                UserDefaults.standard.set(version, forKey: "notifiedVersion")
                notify(release)
            }
        } catch {
            status = .idle
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// Notification when allowed; otherwise fall back to the install prompt so the update isn't missed.
    private func notify(_ r: Release) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                guard granted else { UpdateWindow.show(); return }
                let c = UNMutableNotificationContent()
                c.title = "WinV \(r.version) is available"
                c.body = "You have \(Updater.shared.current). Click to see what's new and install."
                c.categoryIdentifier = "update"
                c.sound = .default
                try? await center.add(UNNotificationRequest(identifier: "update-\(r.version)", content: c, trigger: nil))
            }
        }
    }

    func skip() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "skippedVersion") }
    }

    // MARK: Installing

    func install() async {
        guard let r = available, status != .downloading, status != .installing else { return }
        status = .downloading
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("WinV-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, _) = try await URLSession.shared.download(from: r.dmg)
            let dmg = work.appendingPathComponent("WinV.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            status = .installing
            let mount = work.appendingPathComponent("mnt")
            let staged = work.appendingPathComponent("WinV.app")
            try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-quiet",
                                                    "-mountpoint", mount.path])
            let copy: Result<Void, Error> = await {
                do {
                    let app = mount.appendingPathComponent("WinV.app")
                    guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                        throw Failure("The downloaded app doesn't look like WinV.")
                    }
                    try await Self.run("/usr/bin/ditto", [app.path, staged.path])
                    return .success(())
                } catch { return .failure(error) }
            }()
            try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            try copy.get()

            let dest = Bundle.main.bundleURL
            do { _ = try fm.replaceItemAt(dest, withItemAt: staged) } catch {
                throw Failure("WinV couldn't replace itself at \(dest.path). Download the update manually.")
            }
            relaunch(dest)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw Failure("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)).")
            }
        }.value
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }
}

extension Updater: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case "install": UpdateWindow.show(); await Updater.shared.install()
            case "later": break
            default: UpdateWindow.show()
            }
            done()
        }
    }
}

// MARK: - Install prompt

/// Renders the GitHub release body: headings, bullets, quotes and inline markdown (bold, links, code).
struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { i, raw in
                line(raw.trimmingCharacters(in: .whitespaces), first: i == 0)
            }
        }
        .font(.system(size: 13)).foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ l: String, first: Bool) -> some View {
        if l.isEmpty {
            Color.clear.frame(height: 2)
        } else if l.hasPrefix("#") {
            Text(inline(l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                .font(.system(size: 13, weight: .semibold)).padding(.top, first ? 0 : 4)
        } else if l.hasPrefix("- ") || l.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(Color.ink3)
                Text(inline(String(l.dropFirst(2))))
            }
        } else if l.hasPrefix(">") {
            Text(inline(l.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces)))
                .foregroundStyle(Color.ink2).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.line).frame(width: 2) }
        } else {
            Text(inline(l))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

@MainActor
enum UpdateWindow {
    static func show() { Windows.show("update", title: "Software Update", UpdateView()) }
}

struct UpdateView: View {
    private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? About.icon).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    if let r = updater.available {
                        Text("WinV \(r.version) is available").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text("You have \(updater.current). Install it now? WinV will relaunch.")
                            .font(.system(size: 13)).foregroundStyle(Color.ink2)
                    } else {
                        Text("WinV is up to date").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
                        Text("Version \(updater.current)").font(.system(size: 13)).foregroundStyle(Color.ink2)
                    }
                }
            }
            if let r = updater.available, !r.notes.isEmpty {
                ScrollView {
                    ReleaseNotes(markdown: r.notes).padding(14)
                }
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink.opacity(0.08)))
            }
            HStack(spacing: 8) {
                switch updater.status {
                case .downloading: ProgressView().controlSize(.small); Text("Downloading…").foregroundStyle(Color.ink2)
                case .installing: ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(Color.ink2)
                case .failed(let msg): Text(msg).foregroundStyle(.red).lineLimit(2)
                default: EmptyView()
                }
                Spacer()
                if let r = updater.available {
                    Button("Skip This Version") { updater.skip(); close() }.buttonStyle(PillButton(ghost: true))
                    Button("Later") { close() }.buttonStyle(PillButton(ghost: true))
                    if case .failed = updater.status {
                        Button("Download") { NSWorkspace.shared.open(r.page) }.buttonStyle(PillButton())
                    } else {
                        Button("Install & Relaunch") { Task { await updater.install() } }.buttonStyle(PillButton())
                            .disabled(updater.status == .downloading || updater.status == .installing)
                    }
                } else {
                    Button("OK") { close() }.buttonStyle(PillButton())
                }
            }
            .font(.system(size: 12))
        }
        .padding(24).padding(.top, 12)
        .frame(width: 480)
        .focusEffectDisabled()
        .legible()
    }

    private func close() { NSApp.windows.first { $0.title == "Software Update" }?.close() }
}
