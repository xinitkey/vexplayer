import Foundation
import Observation

/// Global preferences (UserDefaults-backed).
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    /// Vsync on: smooth, +≤1 frame latency. Off: present as soon as a frame arrives.
    var vsync: Bool { didSet { defaults.set(vsync, forKey: "vsync") } }
    var showFPS: Bool { didSet { defaults.set(showFPS, forKey: "showFPS") } }
    var clipboardSync: Bool { didSet { defaults.set(clipboardSync, forKey: "clipboardSync") } }
    var invertWheel: Bool { didSet { defaults.set(invertWheel, forKey: "invertWheel") } }
    /// Run the Qt build with a hidden window instead of the headless build (fallback for GPU issues).
    var hiddenQtWindow: Bool { didSet { defaults.set(hiddenQtWindow, forKey: "hiddenQtWindow") } }
    var flipFrames: Bool { didSet { defaults.set(flipFrames, forKey: "flipFrames") } }
    var stopOnWindowClose: Bool { didSet { defaults.set(stopOnWindowClose, forKey: "stopOnWindowClose") } }
    /// Minimized, covered or closed instances run at background priority (efficiency cores, below the user's apps).
    var backgroundWhenHidden: Bool {
        didSet {
            defaults.set(backgroundWhenHidden, forKey: "backgroundWhenHidden")
            NotificationCenter.default.post(name: .vexBackgroundPolicyChanged, object: nil)
        }
    }
    /// Freeze the VM of a minimized window: 0 % CPU. Off by default, online games may drop the connection.
    var pauseWhenMinimized: Bool { didSet { defaults.set(pauseWhenMinimized, forKey: "pauseWhenMinimized") } }
    /// Type through VexIME: text follows the Mac's current input source (Russian, CJK, emoji…).
    var macInputMethod: Bool { didSet { defaults.set(macInputMethod, forKey: "macInputMethod") } }
    var extraEmulatorArgs: String { didSet { defaults.set(extraEmulatorArgs, forKey: "extraEmulatorArgs") } }
    /// "" follows macOS; a code from `interfaceLanguages` overrides it for VexPlayer only.
    /// macOS reads AppleLanguages from the app's own defaults domain at launch, hence the restart.
    var interfaceLanguage: String {
        didSet {
            if interfaceLanguage.isEmpty {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([interfaceLanguage], forKey: "AppleLanguages")
            }
        }
    }
    /// The language this process started with: a different choice needs a restart.
    let launchInterfaceLanguage: String
    static let interfaceLanguages = ["en", "ru"]

    private init() {
        defaults.register(defaults: [
            "vsync": true, "showFPS": true, "clipboardSync": true, "invertWheel": false,
            "hiddenQtWindow": false, "flipFrames": false, "stopOnWindowClose": true, "extraEmulatorArgs": "",
            "macInputMethod": true, "backgroundWhenHidden": true, "pauseWhenMinimized": false,
        ])
        vsync = defaults.bool(forKey: "vsync")
        showFPS = defaults.bool(forKey: "showFPS")
        clipboardSync = defaults.bool(forKey: "clipboardSync")
        invertWheel = defaults.bool(forKey: "invertWheel")
        hiddenQtWindow = defaults.bool(forKey: "hiddenQtWindow")
        flipFrames = defaults.bool(forKey: "flipFrames")
        stopOnWindowClose = defaults.bool(forKey: "stopOnWindowClose")
        backgroundWhenHidden = defaults.bool(forKey: "backgroundWhenHidden")
        pauseWhenMinimized = defaults.bool(forKey: "pauseWhenMinimized")
        macInputMethod = defaults.bool(forKey: "macInputMethod")
        extraEmulatorArgs = defaults.string(forKey: "extraEmulatorArgs") ?? ""
        // Only our own domain counts: `defaults.array(forKey:)` would return the system-wide list.
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let own = (domain?["AppleLanguages"] as? [String])?.first
        let language = own.flatMap { code in Self.interfaceLanguages.first { code.hasPrefix($0) } } ?? ""
        interfaceLanguage = language
        launchInterfaceLanguage = language
    }
}

extension Notification.Name {
    static let vexBackgroundPolicyChanged = Notification.Name("vexBackgroundPolicyChanged")
}
