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
    /// Type through VexIME: text follows the Mac's current input source (Russian, CJK, emoji…).
    var macInputMethod: Bool { didSet { defaults.set(macInputMethod, forKey: "macInputMethod") } }
    var extraEmulatorArgs: String { didSet { defaults.set(extraEmulatorArgs, forKey: "extraEmulatorArgs") } }

    private init() {
        defaults.register(defaults: [
            "vsync": true, "showFPS": true, "clipboardSync": true, "invertWheel": false,
            "hiddenQtWindow": false, "flipFrames": false, "stopOnWindowClose": true, "extraEmulatorArgs": "",
            "macInputMethod": true,
        ])
        vsync = defaults.bool(forKey: "vsync")
        showFPS = defaults.bool(forKey: "showFPS")
        clipboardSync = defaults.bool(forKey: "clipboardSync")
        invertWheel = defaults.bool(forKey: "invertWheel")
        hiddenQtWindow = defaults.bool(forKey: "hiddenQtWindow")
        flipFrames = defaults.bool(forKey: "flipFrames")
        stopOnWindowClose = defaults.bool(forKey: "stopOnWindowClose")
        macInputMethod = defaults.bool(forKey: "macInputMethod")
        extraEmulatorArgs = defaults.string(forKey: "extraEmulatorArgs") ?? ""
    }
}
