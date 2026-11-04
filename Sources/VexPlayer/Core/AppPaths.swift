import Foundation

/// All on-disk locations. Everything VexPlayer owns lives under
/// ~/Library/Application Support/VexPlayer so it never collides with Android Studio.
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VexPlayer", isDirectory: true)
    }()

    /// ANDROID_SDK_ROOT: emulator/, platform-tools/, system-images/, licenses/
    static var sdk: URL { root.appendingPathComponent("sdk", isDirectory: true) }
    /// ANDROID_AVD_HOME: <id>.ini + <id>.avd/
    static var avdHome: URL { root.appendingPathComponent("avd", isDirectory: true) }
    static var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    static var keymaps: URL { root.appendingPathComponent("keymaps", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    /// Shared-memory frame files the emulator writes screen frames into.
    static var frames: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vexplayer-frames", isDirectory: true)
    }

    static var emulatorDir: URL { sdk.appendingPathComponent("emulator", isDirectory: true) }
    static var emulatorBinary: URL { emulatorDir.appendingPathComponent("emulator") }
    static var qemuImg: URL { emulatorDir.appendingPathComponent("qemu-img") }
    static var platformTools: URL { sdk.appendingPathComponent("platform-tools", isDirectory: true) }
    static var adbBinary: URL { platformTools.appendingPathComponent("adb") }

    static var screenshots: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VexPlayer", isDirectory: true)
    }
    static var recordings: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VexPlayer", isDirectory: true)
    }

    /// Where the emulator drops its discovery files (pid_<pid>.ini with grpc port + token).
    static var discoveryDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true),
            FileManager.default.temporaryDirectory.appendingPathComponent("avd/running", isDirectory: true),
        ]
    }

    static func ensure() {
        for dir in [root, sdk, avdHome, downloads, keymaps, logs, frames] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Our own adb server port so we never fight with Android Studio / Homebrew adb over 5037.
    static let adbServerPort = 5039

    static func sdkEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SDK_ROOT"] = sdk.path
        env["ANDROID_HOME"] = sdk.path
        env["ANDROID_AVD_HOME"] = avdHome.path
        env["ANDROID_ADB_SERVER_PORT"] = String(adbServerPort)
        env["ANDROID_EMU_ENABLE_CRASH_REPORTING"] = "0"
        // On SIGINT the emulator launcher kills qemu after 20 s by default, cutting off a Quickboot save of a big
        // guest (7–13 s, more with two instances running) and leaving an empty ram.bin behind.
        env["ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL"] = String(Int(emulatorStopTimeout))
        return env
    }

    /// How long a graceful stop may take (sync, Quickboot save, exit) before the emulator is killed.
    static let emulatorStopTimeout: TimeInterval = 120
}

extension URL {
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
