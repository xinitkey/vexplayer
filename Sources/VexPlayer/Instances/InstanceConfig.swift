import Foundation

enum GPUMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Guest ANGLE turns GLES into Vulkan; gfxstream → MoltenVK → Metal. GLES 3.1, no deprecated macOS OpenGL.
    case angleVulkan = "angle_vulkan"
    /// Guest GLES translated to macOS OpenGL 4.1 (deprecated): GLES 3.0 only.
    case host
    case swiftshader = "swiftshader_indirect"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .angleVulkan: return String(localized: "Metal through Vulkan · GLES 3.1 (recommended)")
        case .host: return String(localized: "Metal through OpenGL · GLES 3.0")
        case .swiftshader: return String(localized: "Software rendering (compatibility)")
        }
    }
    /// Value for `-gpu` / hw.gpu.mode.
    var emulatorGPU: String { self == .swiftshader ? "swiftshader_indirect" : "host" }
    /// GuestAngle: GLES via ANGLE on Vulkan. VulkanSnapshots: without it Quickboot refuses to save
    /// (UNSUPPORTED_VK_APP) because the whole UI uses Vulkan. -HostComposition: Android composes the
    /// layers itself; host composition draws blurred layers (the tablet taskbar) as streaks.
    /// -VulkanQueueSubmitWithCommands: its ordered submits sometimes leave gfxstream decoder threads
    /// busy-waiting forever (3+ host cores burnt while Android idles, after cold boots and restores alike).
    var features: [String] {
        self == .angleVulkan ? ["GuestAngle", "VulkanSnapshots", "-HostComposition", "-VulkanQueueSubmitWithCommands"] : []
    }
    /// Older images ship a guest ANGLE that MoltenVK can't run, so they use OpenGL instead. Android 13 asks
    /// for a Vulkan extension MoltenVK lacks: SurfaceFlinger aborts ("no suitable EGLConfig found") and
    /// Android boot-loops. Android 14 boots, but Metal rejects its text pipelines (uint vertex attributes
    /// read as float), so no text is drawn anywhere; the emulator also reports GLES 2.0 to apps there.
    static let minGuestAngleAPI = 35
}

/// The image as Google ships it, or with what a game doesn't need switched off (see LiteEdition).
enum ImageEdition: String, CaseIterable, Sendable {
    case full, lite, minimal
}

struct DisplayPreset: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let dpi: Int

    static let all: [DisplayPreset] = [
        .init(id: "tablet1080", title: String(localized: "Tablet 1920×1080 · 280 dpi (for games)"), width: 1920, height: 1080, dpi: 280),
        .init(id: "tablet1440", title: String(localized: "Tablet 2560×1440 · 360 dpi"), width: 2560, height: 1440, dpi: 360),
        .init(id: "tablet900", title: String(localized: "Tablet 1600×900 · 240 dpi (economical)"), width: 1600, height: 900, dpi: 240),
        .init(id: "phone1080", title: String(localized: "Phone 1080×1920 · 420 dpi"), width: 1080, height: 1920, dpi: 420),
        .init(id: "phone2400", title: String(localized: "Phone 1080×2400 · 440 dpi"), width: 1080, height: 2400, dpi: 440),
        .init(id: "phone720", title: String(localized: "Phone 720×1280 · 320 dpi"), width: 720, height: 1280, dpi: 320),
    ]
}

/// Persistent description of one Android instance (stored as vex.json inside the AVD folder).
struct InstanceConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String                       // AVD name, e.g. "vex_3"
    var name: String
    var imagePath: String                // "system-images;android-36;google_apis_playstore;arm64-v8a"
    var cpuCores: Int = InstanceConfig.defaultCores
    var ramMB: Int = InstanceConfig.defaultRAM
    var width: Int = 1920
    var height: Int = 1080
    var dpi: Int = 280
    var refreshRate: Int = 60
    var gpuMode: GPUMode = .angleVulkan
    var dataSizeGB: Int = 32
    var audioEnabled = true
    var microphoneEnabled = false
    var fastBoot = true                  // Quickboot: save RAM snapshot on exit → boots in seconds
    var rootOnBoot = false               // `adb root` after boot (Google APIs images only)
    /// DeviceProfile.id: present as a regular phone (Google APIs images only, see DeviceProfile).
    var deviceProfile: String?
    /// Lite edition of the image (see LiteEdition). Chosen at creation, like the image itself.
    var lite: Bool?
    /// Minimal edition: Lite plus no Google services (see LiteEdition.minimalPackages). `lite` is set too,
    /// so older VexPlayer builds still treat the instance as Lite.
    var minimal: Bool?
    var createdAt = Date()

    var isLite: Bool { lite == true }
    var isMinimal: Bool { minimal == true }
    var edition: ImageEdition {
        get { isMinimal ? .minimal : isLite ? .lite : .full }
        set {
            lite = newValue == .full ? nil : true
            minimal = newValue == .minimal ? true : nil
        }
    }
    var isLandscape: Bool { width > height }

    var imageDirRelative: String {
        imagePath.split(separator: ";").joined(separator: "/") + "/"
    }

    var imageTag: String { imagePath.split(separator: ";").dropFirst(2).first.map(String.init) ?? "" }
    var platform: String { imagePath.split(separator: ";").dropFirst().first.map(String.init) ?? "" }
    /// 33 for "android-33", 36 for "android-36.1".
    var apiLevel: Int { Int(platform.dropFirst("android-".count).prefix { $0.isNumber }) ?? 0 }
    /// The mode the emulator really runs: Vulkan needs an image new enough for it (GPUMode.minGuestAngleAPI).
    var effectiveGPUMode: GPUMode {
        gpuMode == .angleVulkan && apiLevel < GPUMode.minGuestAngleAPI ? .host : gpuMode
    }

    var avdDir: URL { AppPaths.avdHome.appendingPathComponent("\(id).avd", isDirectory: true) }
    /// Which profile is currently written into the instance's build.prop files.
    var profileMarkerFile: URL { avdDir.appendingPathComponent("vex-profile.txt") }
    var appliedProfileMarker: String? { try? String(contentsOf: profileMarkerFile, encoding: .utf8) }
    /// System partitions must stay writable while a profile is (or was) written into them.
    var needsWritableSystem: Bool { deviceProfile != nil || appliedProfileMarker != nil }
    /// Android's Bluetooth has been switched off, so the instance starts without netsim (see InstanceSession.netsimFeatures).
    var bluetoothOffMarkerFile: URL { avdDir.appendingPathComponent("vex-bluetooth-off.txt") }
    var quickbootSnapshotDir: URL { avdDir.appendingPathComponent("snapshots/default_boot") }
    /// Which version of the Lite package list has been applied.
    var liteMarkerFile: URL { avdDir.appendingPathComponent("vex-lite.txt") }
    var avdIni: URL { AppPaths.avdHome.appendingPathComponent("\(id).ini") }
    var metadataFile: URL { avdDir.appendingPathComponent("vex.json") }

    static var hostCores: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var hostRAMMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
    /// Performance cores only: a vCPU landing on an efficiency core stalls the game thread on it.
    static var performanceCores: Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 else { return hostCores / 2 }
        return Int(n)
    }
    static var defaultCores: Int { max(2, min(8, performanceCores)) }
    static var defaultRAM: Int { hostRAMMB >= 32_768 ? 8192 : hostRAMMB >= 16_384 ? 4096 : 3072 }
    /// After a Quickboot restore the whole guest RAM is resident on the Mac, so Lite's smaller Android pays off here.
    static var defaultLiteRAM: Int { hostRAMMB >= 32_768 ? 6144 : hostRAMMB >= 16_384 ? 3072 : 2048 }
    /// Minimal Android (~1.1 GB) plus a game (~0.6-0.9 GB) fits in 2.5 GB; anything above fills with Linux page
    /// cache, and the guest never hands RAM back to the Mac (the emulator's balloon can't free it on macOS).
    static var defaultMinimalRAM: Int { hostRAMMB >= 32_768 ? 4096 : hostRAMMB >= 16_384 ? 2560 : 2048 }
    static func defaultRAM(for edition: ImageEdition) -> Int {
        switch edition {
        case .full: return defaultRAM
        case .lite: return defaultLiteRAM
        case .minimal: return defaultMinimalRAM
        }
    }
    /// "2.5" for 2560 MB and "3" for 3072 MB, in the user's number format.
    static func gigabytes(_ mb: Int) -> String {
        (Double(mb) / 1024).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// config.ini tuned for performance on Apple Silicon.
    func configIni() -> String {
        let playStore = imageTag == "google_apis_playstore"
        let tagDisplay = playStore ? "Google Play" : (imageTag == "google_apis" ? "Google APIs" : imageTag)
        let pairs: [(String, String)] = [
            ("AvdId", id),
            ("avd.ini.displayname", name),
            ("avd.ini.encoding", "UTF-8"),
            ("abi.type", "arm64-v8a"),
            ("hw.cpu.arch", "arm64"),
            ("image.sysdir.1", imageDirRelative),
            ("tag.id", imageTag),
            ("tag.display", tagDisplay),
            ("PlayStore.enabled", playStore ? "true" : "false"),
            ("hw.cpu.ncore", "\(cpuCores)"),
            ("hw.ramSize", "\(ramMB)"),
            ("vm.heapSize", "\(ramMB >= 4096 ? 512 : 256)"),
            ("hw.lcd.width", "\(width)"),
            ("hw.lcd.height", "\(height)"),
            ("hw.lcd.density", "\(dpi)"),
            ("hw.lcd.vsync", "\(refreshRate)"),
            ("hw.initialOrientation", isLandscape ? "landscape" : "portrait"),
            ("hw.gpu.enabled", "yes"),
            ("hw.gpu.mode", effectiveGPUMode.emulatorGPU),
            ("hw.keyboard", "yes"),
            ("hw.mainKeys", "no"),
            ("hw.dPad", "no"),
            ("hw.trackBall", "no"),
            ("hw.audioOutput", audioEnabled ? "yes" : "no"),
            ("hw.audioInput", microphoneEnabled ? "yes" : "no"),
            ("hw.accelerometer", "yes"),
            ("hw.gyroscope", "yes"),
            ("hw.sensors.orientation", "yes"),
            ("hw.sensors.proximity", "yes"),
            ("hw.gps", "yes"),
            ("hw.battery", "yes"),
            ("hw.camera.back", "none"),
            ("hw.camera.front", "none"),
            ("hw.arc", "false"),
            ("disk.dataPartition.size", "\(dataSizeGB)G"),
            ("fastboot.forceColdBoot", fastBoot ? "no" : "yes"),
            ("fastboot.forceFastBoot", fastBoot ? "yes" : "no"),
            ("showDeviceFrame", "no"),
            ("skin.dynamic", "yes"),
            ("skin.name", "\(width)x\(height)"),
            ("skin.path", "_no_skin"),
            ("runtime.network.latency", "none"),
            ("runtime.network.speed", "full"),
        ]
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }

    func avdIniContents() -> String {
        "avd.ini.encoding=UTF-8\npath=\(avdDir.path)\ntarget=\(platform)\n"
    }
}
