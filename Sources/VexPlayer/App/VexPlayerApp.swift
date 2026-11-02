import AppKit
import SwiftUI

@main
struct VexPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("VexPlayer", id: "launcher") {
            LauncherView()
        }
        .defaultSize(width: 920, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            AppSettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        AppPaths.ensure()
        cleanStaleFrames()
        GamepadManager.shared.start()
        launchFromArguments()
    }

    /// `VexPlayer --launch <name or id>` starts an instance straight away (shortcuts, scripts).
    private func launchFromArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--launch"), i + 1 < args.count else { return }
        let key = args[i + 1]
        let store = InstanceStore.shared
        guard let config = store.instances.first(where: { $0.id == key || $0.name == key }) else { return }
        let session = store.session(for: config)
        if !session.state.isAlive { session.start() }
        PlayerWindows.shared.show(session)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !InstanceStore.shared.sessions.values.contains { $0.state.isAlive }
    }

    /// Quitting saves every running instance (Quickboot) before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alive = InstanceStore.shared.sessions.values.filter { $0.state.isAlive }
        guard !alive.isEmpty else {
            ADB.killServer()
            return .terminateNow
        }
        alive.forEach { $0.stop() }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(60)
            while alive.contains(where: { $0.state.isAlive }) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            alive.forEach { $0.forceStop() }
            ADB.killServer()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func showLauncher() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "launcher" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI recreates the single Window scene when asked via the Window menu item.
            NSApp.windows.first { $0.title == "VexPlayer" }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    private func cleanStaleFrames() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: AppPaths.frames, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
        // Half-finished extractions from an interrupted install.
        for f in (try? fm.contentsOfDirectory(at: AppPaths.downloads, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("extract-") {
            try? fm.removeItem(at: f)
        }
    }
}
