import AppKit
import Darwin
import EmulatorAPI
import Foundation
import Observation

/// Thread-safe hand-off point between the gRPC frame stream and whoever draws/records.
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _renderer: ScreenRenderer?
    private var _size: (Int, Int) = (0, 0)
    private var _seq: UInt32 = 0

    var renderer: ScreenRenderer? {
        get { lock.withLock { _renderer } }
        set { lock.withLock { _renderer = newValue } }
    }
    var size: (width: Int, height: Int) { lock.withLock { _size } }

    /// Returns true when the frame size changed.
    func frame(width: Int, height: Int, seq: UInt32) -> Bool {
        lock.withLock {
            _seq = seq
            let changed = _size != (width, height)
            _size = (width, height)
            return changed
        }
    }
}

@MainActor @Observable
final class InstanceSession: Identifiable {
    enum State: Equatable {
        case stopped, starting, booting, running, stopping
        case preparing(String)
        case failed(String)

        var isAlive: Bool {
            switch self { case .starting, .booting, .preparing, .running, .stopping: return true; default: return false }
        }
        var label: String {
            switch self {
            case .stopped: return "Остановлен"
            case .starting: return "Запуск…"
            case .booting: return "Загрузка Android…"
            case .running: return "Работает"
            case .stopping: return "Сохранение и остановка…"
            case .preparing(let what): return what
            case .failed(let e): return "Ошибка: \(e)"
            }
        }
    }

    var config: InstanceConfig
    nonisolated let id: String
    private(set) var state: State = .stopped
    private(set) var fps: Double = 0
    private(set) var bootSeconds: Double?
    private(set) var geometry: DisplayGeometry
    private(set) var foregroundPackage: String?
    private(set) var keymap = Keymap()
    /// All control schemes of the foreground game; `keymap` is the active one.
    private(set) var keymapProfile = KeymapProfile.starter()
    var keymapEnabled = true { didSet { input.keymapEnabled = keymapEnabled; if !keymapEnabled { input.releaseAll() } } }
    private(set) var textFieldFocused = false
    private(set) var aimLocked = false
    private(set) var consolePort = 0
    private(set) var grpcPort = 0
    private(set) var logLines: [String] = []
    private(set) var client: EmulatorClient?
    private(set) var isRecordingVideo = false
    /// VexIME is installed, selected and talking to us: typed text follows the Mac's input source.
    private(set) var imeConnected = false
    var toast: String?

    let frameSink = FrameSink()
    let recorder = OperationRecorder()
    let ime = ImeBridge()
    @ObservationIgnored private(set) var input: InputController!
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private(set) var frameBuffer: FrameBuffer?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var startTime = Date()
    @ObservationIgnored private var lastGuestClipboard = ""
    @ObservationIgnored private var hostClipboardChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var videoRecorder: ScreenRecorder?
    @ObservationIgnored private var logFile: FileHandle?
    /// Frames are only pulled while someone looks at them (or records): a hidden window costs no GPU readback.
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var displayVisible = true

    var serial: String { "emulator-\(consolePort)" }
    var adb: ADB { ADB(serial: serial) }
    var image: SDKPackage? { SDKManager.shared.image(forPath: config.imagePath) }

    init(config: InstanceConfig) {
        self.config = config
        self.id = config.id
        geometry = DisplayGeometry(fbWidth: config.width, fbHeight: config.height)
        keymapProfile = KeymapStore.loadProfile(for: nil)
        keymap = keymapProfile.active?.keymap ?? Keymap()
        input = InputController(session: self, keymap: keymap)
        input.engine.aspect = geometry.aspect
        input.engine.onAimLockChanged = { [weak self] locked in self?.aimLocked = locked }
    }

    // MARK: Lifecycle

    func start() {
        guard !state.isAlive else { return }
        guard AppPaths.emulatorBinary.fileExists else { return fail("Эмулятор не установлен") }
        guard AppPaths.sdk.appendingPathComponent(config.imageDirRelative).fileExists else {
            return fail("Образ Android не установлен")
        }
        // Regenerate config.ini every launch so tuning from newer app versions reaches old instances.
        try? config.configIni().write(to: config.avdDir.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        state = .starting
        logLines = []
        let logURL = AppPaths.logs.appendingPathComponent("\(config.id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: logURL)
        bootSeconds = nil
        startTime = Date()
        geometry = DisplayGeometry(fbWidth: config.width, fbHeight: config.height)
        input.engine.aspect = geometry.aspect

        do {
            consolePort = try PortAllocator.consolePort()
            grpcPort = try PortAllocator.grpcPort()
            let side = max(config.width, config.height)
            frameBuffer = try FrameBuffer(name: config.id, capacity: side * side * 4)
        } catch {
            return fail(error.localizedDescription)
        }
        // adb first: it creates ~/.android/adbkey, which the emulator hands to Android so adb is pre-authorized.
        tasks.append(Task {
            await ADB.startServer()
            guard state == .starting else { return }
            launchProcess()
        })
    }

    private func launchProcess() {
        let p = Process()
        p.executableURL = AppPaths.emulatorBinary
        p.arguments = launchArguments()
        p.environment = AppPaths.sdkEnvironment()
        p.qualityOfService = .userInteractive
        p.currentDirectoryURL = AppPaths.emulatorDir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.processExited(code) }
        }
        appendLog("$ emulator " + (p.arguments ?? []).joined(separator: " ") + "\n")
        do {
            try p.run()
        } catch {
            return fail("Не удалось запустить эмулятор: \(error.localizedDescription)")
        }
        process = p
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Android instance \(config.name)")
        tasks.append(Task { await self.connectAndBoot(pid: p.processIdentifier) })
    }

    private var launchSignatureFile: URL { config.avdDir.appendingPathComponent("vex-launch.txt") }
    private var launchSignature: String {
        "\(config.gpuMode.rawValue)|\(config.gpuMode.features.joined(separator: ","))|\(AppSettings.shared.hiddenQtWindow)"
    }

    private func launchArguments() -> [String] {
        let settings = AppSettings.shared
        var args = [
            "-avd", config.id,
            "-port", "\(consolePort)",
            "-grpc", "\(grpcPort)", "-grpc-use-token",
            "-gpu", config.gpuMode.emulatorGPU,
            "-no-boot-anim",
            "-no-metrics",
            "-netfast",
            "-camera-back", "none", "-camera-front", "none",
        ]
        args += settings.hiddenQtWindow ? ["-qt-hide-window"] : ["-no-window"]
        if !config.gpuMode.features.isEmpty { args += ["-feature", config.gpuMode.features.joined(separator: ",")] }
        if !config.audioEnabled { args.append("-no-audio") }
        if !config.fastBoot { args.append("-no-snapshot-save") }
        // A snapshot taken under other GPU features would restore a guest driver that no longer matches.
        if (try? String(contentsOf: launchSignatureFile, encoding: .utf8)) != launchSignature {
            args.append("-no-snapshot-load")
        }
        if config.needsWritableSystem { args.append("-writable-system") }
        args += settings.extraEmulatorArgs.split(separator: " ").map(String.init)
        return args
    }

    /// Graceful stop: SIGINT makes the emulator save its Quickboot snapshot, so the next start takes seconds.
    func stop() {
        if process == nil, state == .starting {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
            frameBuffer = nil
            state = .stopped
            return
        }
        guard let p = process, state.isAlive, state != .stopping else { return }
        state = .stopping
        input.releaseAll()
        stopVideoRecording()
        p.interrupt()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            if p.isRunning { p.terminate() }
            try? await Task.sleep(for: .seconds(5))
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = self
        }
    }

    func forceStop() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
    }

    func restart() {
        Task {
            stop()
            while state.isAlive { try? await Task.sleep(for: .milliseconds(200)) }
            start()
        }
    }

    private func processExited(_ code: Int32) {
        frameTask?.cancel()
        frameTask = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        client?.close()
        client = nil
        frameBuffer = nil
        process = nil
        stopVideoRecording()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        try? logFile?.close()
        ime.stop()
        imeConnected = false
        logFile = nil
        if state == .stopping || code == 0 {
            state = .stopped
        } else {
            let tail = logLines.suffix(6).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed("эмулятор завершился с кодом \(code). \(tail.suffix(300))")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        appendLog("ERROR: \(message)\n")
    }

    private func appendLog(_ text: String) {
        logFile?.write(Data(text.utf8))
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logLines.append(String(line) + "\n")
        }
        if logLines.count > 600 { logLines.removeFirst(logLines.count - 600) }
    }

    // MARK: Boot

    private func connectAndBoot(pid: Int32) async {
        guard let token = await discoverToken(pid: pid) else {
            if state.isAlive { fail("gRPC не поднялся (нет файла обнаружения)") }
            return
        }
        let client: EmulatorClient
        do {
            client = try EmulatorClient(port: grpcPort, token: token)
        } catch {
            return fail("gRPC: \(error.localizedDescription)")
        }
        self.client = client
        state = .booting

        updateFrameStreaming()
        tasks.append(Task { await self.runNotifications(client) })
        tasks.append(Task { await self.runClipboard(client) })

        // Wait for Android to report boot completion.
        while !Task.isCancelled && state.isAlive {
            if let status = try? await client.status(), status.booted { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !Task.isCancelled, state == .booting else { return }
        await applyDeviceProfileIfNeeded()
        guard !Task.isCancelled, state.isAlive, state != .stopping else { return }
        bootSeconds = Date().timeIntervalSince(startTime)
        state = .running
        try? launchSignature.write(to: launchSignatureFile, atomically: true, encoding: .utf8)
        appendLog("Boot completed in \(String(format: "%.1f", bootSeconds ?? 0)) s\n")

        if config.rootOnBoot, image?.supportsRoot ?? false {
            try? await adb.root()
        }
        tasks.append(Task { await self.pollDisplayState() })
        if AppSettings.shared.macInputMethod { tasks.append(Task { await self.setupIME() }) }
    }

    private func discoverToken(pid: Int32) async -> String? {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && state.isAlive && !Task.isCancelled {
            for dir in AppPaths.discoveryDirs {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                for f in files where f.hasPrefix("pid_") && f.hasSuffix(".ini") {
                    // Files of crashed emulators linger; only trust live processes.
                    guard let filePid = Int32(f.dropFirst(4).dropLast(4)), kill(filePid, 0) == 0 else { continue }
                    let props = SDKManager.readProperties(dir.appendingPathComponent(f))
                    if filePid == pid || props["grpc.port"] == "\(grpcPort)", props["grpc.port"] != nil {
                        return props["grpc.token"] ?? ""
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func runFrameStream(_ client: EmulatorClient) async {
        guard let buffer = frameBuffer else { return }
        let sink = frameSink
        while !Task.isCancelled && state.isAlive {
            do {
                try await client.streamFrames(mmapFile: buffer.url) { [weak self] image in
                    let w = Int(image.format.width), h = Int(image.format.height)
                    guard w > 0, h > 0, w * h * 4 <= buffer.capacity else { return }
                    if sink.frame(width: w, height: h, seq: image.seq) {
                        Task { @MainActor in self?.framebufferResized(w, h) }
                    }
                    sink.renderer?.submitFrame(buffer, width: w, height: h)
                }
            } catch {}
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func framebufferResized(_ w: Int, _ h: Int) {
        geometry.fbWidth = w
        geometry.fbHeight = h
        input.engine.aspect = geometry.aspect
    }

    func attachRenderer(_ renderer: ScreenRenderer?) {
        frameSink.renderer = renderer
        renderer?.rotation = geometry.rotation
        renderer?.onFPS = { [weak self] fps in Task { @MainActor in self?.fps = fps } }
        updateFrameStreaming()
    }

    /// Window miniaturized / fully covered / back on screen.
    func setDisplayVisible(_ visible: Bool) {
        guard visible != displayVisible else { return }
        displayVisible = visible
        updateFrameStreaming()
    }

    private func updateFrameStreaming() {
        let wanted = client != nil && state.isAlive && (isRecordingVideo || (frameSink.renderer != nil && displayVisible))
        if wanted, frameTask == nil, let client {
            frameTask = Task { await self.runFrameStream(client) }
        } else if !wanted, let task = frameTask {
            task.cancel()   // closes the gRPC stream; the emulator stops reading frames back
            frameTask = nil
            if frameSink.renderer == nil { fps = 0 }
        }
    }

    private func runNotifications(_ client: EmulatorClient) async {
        while !Task.isCancelled && state.isAlive {
            try? await client.streamNotifications { [weak self] n in
                if case .textViewFocus(let f)? = n.type {
                    Task { @MainActor in
                        guard self?.imeConnected == false else { return }
                        self?.setTextFocus(f.textViewHasFocus)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Device profile

    /// Writes (or removes) the phone identity in every build.prop, then reboots Android once.
    /// Needs a Google APIs (userdebug) image: root + `adb remount` on a `-writable-system` launch.
    private func applyDeviceProfileIfNeeded() async {
        let profile = DeviceProfile.find(config.deviceProfile)
        let wanted = profile?.marker
        guard wanted != config.appliedProfileMarker, image?.supportsRoot ?? false else { return }
        state = .preparing(profile.map { "Профиль устройства: \($0.title)…" } ?? "Снятие профиля устройства…")
        do {
            try await waitForADB()
            try await adb.run(["root"])
            try await waitForADB()
            var out = try await adb.run(["remount"])
            if out.lowercased().contains("reboot") {
                // First remount disables verity; it only takes effect after a reboot.
                try await adb.run(["reboot"])
                try await waitForAndroidBoot()
                try await adb.run(["root"])
                try await waitForADB()
                out = try await adb.run(["remount"])
            }
            appendLog("remount: \(out.trimmingCharacters(in: .whitespacesAndNewlines))\n")

            var block = ""
            if let profile {
                let release = try await adb.shell("getprop ro.build.version.release").trimmingCharacters(in: .whitespacesAndNewlines)
                let buildID = try await adb.shell("getprop ro.build.id").trimmingCharacters(in: .whitespacesAndNewlines)
                block = (["# VexPlayer device profile begin"] + profile.buildProps(release: release, buildID: buildID)
                         + ["# VexPlayer device profile end"]).joined(separator: "\n") + "\n"
            }
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("vex-profile-\(config.id).prop")
            try block.write(to: local, atomically: true, encoding: .utf8)
            try await adb.push(local, to: "/data/local/tmp/vex-profile.prop")
            try await adb.shell("""
                for f in /system/build.prop /system_ext/etc/build.prop /vendor/build.prop /odm/etc/build.prop /product/etc/build.prop; do \
                  [ -f "$f" ] || continue; \
                  sed -i '/# VexPlayer device profile begin/,/# VexPlayer device profile end/d' "$f"; \
                  cat /data/local/tmp/vex-profile.prop >> "$f"; \
                done; rm /data/local/tmp/vex-profile.prop
                """)
            try await adb.run(["reboot"])
            try await waitForAndroidBoot()

            let model = try await adb.shell("getprop ro.product.model").trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog("Device profile applied, ro.product.model=\(model)\n")
            if let profile, model != profile.model { throw NSError(domain: "VexPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: "модель осталась \(model)"]) }
            if let wanted {
                try wanted.write(to: config.profileMarkerFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: config.profileMarkerFile)
            }
        } catch {
            appendLog("Device profile failed: \(error.localizedDescription)\n")
            showToast("Не удалось применить профиль устройства: \(error.localizedDescription)")
        }
        if state.isAlive, state != .stopping { state = .booting }
    }

    private func waitForADB(timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || !state.isAlive { throw CancellationError() }
            if let s = try? await adb.run(["get-state"]), s.contains("device") { return }
            try? await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "VexPlayer", code: 4, userInfo: [NSLocalizedDescriptionKey: "adb не отвечает"])
    }

    private func waitForAndroidBoot(timeout: TimeInterval = 240) async throws {
        try? await Task.sleep(for: .seconds(3))   // let the old boot state go away after `adb reboot`
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || !state.isAlive { throw CancellationError() }
            if let v = try? await adb.shell("getprop sys.boot_completed"), v.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            try? await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "VexPlayer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Android не загрузился после перезагрузки"])
    }

    // MARK: Input method

    /// Installs VexIME if needed, makes it the active IME and connects to it.
    private func setupIME() async {
        guard let apk = ImeBridge.apkURL else { return appendLog("VexIME.apk not found\n") }
        // After a Quickboot restore Android reports "booted" while adbd is still reconnecting ("device offline").
        var online = false
        for _ in 0..<60 where !Task.isCancelled {
            if let s = try? await adb.run(["get-state"]), s.contains("device") { online = true; break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard online else { return appendLog("VexIME: adb never came online\n") }
        let info = (try? await adb.shell("dumpsys package \(ImeBridge.package) | grep -m1 versionCode")) ?? ""
        let installedVersion = info.range(of: #"versionCode=\d+"#, options: .regularExpression)
            .flatMap { Int(info[$0].dropFirst("versionCode=".count)) }
        if installedVersion != ImeBridge.version {
            do {
                try await adb.run(["install", "-r", apk.path])
            } catch where error.localizedDescription.contains("UPDATE_INCOMPATIBLE") {
                // Built by a fork with another signing key: replace it.
                _ = try? await adb.run(["uninstall", ImeBridge.package])
                guard (try? await adb.run(["install", apk.path])) != nil else {
                    return appendLog("VexIME reinstall failed\n")
                }
            } catch {
                return appendLog("VexIME install failed: \(error.localizedDescription)\n")
            }
        }
        _ = try? await adb.shell("ime enable \(ImeBridge.component); ime set \(ImeBridge.component)")
        guard let port = try? PortAllocator.freePort(in: 27183...27383) else { return }
        do {
            try await adb.run(["forward", "tcp:\(port)", "localabstract:\(ImeBridge.socketName)"])
        } catch {
            return appendLog("adb forward failed: \(error.localizedDescription)\n")
        }
        ime.onConnection = { [weak self] connected in
            Task { @MainActor in
                self?.imeConnected = connected
                self?.appendLog("VexIME \(connected ? "connected" : "disconnected")\n")
            }
        }
        ime.onFocus = { [weak self] focused in
            Task { @MainActor in
                self?.appendLog("VexIME text focus: \(focused)\n")
                self?.setTextFocus(focused)
            }
        }
        ime.start(port: port)
    }

    private func setTextFocus(_ focused: Bool) {
        textFieldFocused = focused
        input.textFieldFocused = focused
        if focused { input.engine.releaseAll() }
    }

    // MARK: Clipboard

    private func runClipboard(_ client: EmulatorClient) async {
        while !Task.isCancelled && state.isAlive {
            try? await client.streamClipboard { [weak self] text in
                Task { @MainActor in self?.guestClipboardChanged(text) }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func guestClipboardChanged(_ text: String) {
        guard AppSettings.shared.clipboardSync, !text.isEmpty, text != lastGuestClipboard else { return }
        lastGuestClipboard = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hostClipboardChangeCount = NSPasteboard.general.changeCount
    }

    /// Called when the player window becomes key: push a changed Mac clipboard into Android.
    func syncHostClipboard() {
        guard AppSettings.shared.clipboardSync, let client else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != hostClipboardChangeCount else { return }
        hostClipboardChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), text != lastGuestClipboard else { return }
        lastGuestClipboard = text
        Task { await client.setClipboard(text) }
    }

    // MARK: Rotation & foreground app

    private func pollDisplayState() async {
        while !Task.isCancelled && state == .running {
            let (rotation, package) = await adb.displayState()
            if let rotation {
                // Surface.ROTATION_90 means the UI is drawn turned clockwise inside the panel.
                let turns = (4 - rotation) % 4
                if turns != geometry.rotation {
                    geometry.rotation = turns
                    input.engine.aspect = geometry.aspect
                    input.releaseAll()
                    frameSink.renderer?.rotation = turns
                }
            }
            if let package, package != foregroundPackage {
                foregroundPackage = package
                loadKeymap()
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    // MARK: Keymap

    var keymapProfileName: String { foregroundPackage ?? KeymapStore.defaultProfile }

    var activeScheme: KeymapScheme? { keymapProfile.active }

    func loadKeymap() {
        keymapProfile = KeymapStore.loadProfile(for: foregroundPackage)
        applyActiveScheme()
    }

    /// Saves `map` into the active scheme of the foreground game.
    func saveKeymap(_ map: Keymap) {
        guard let id = activeScheme?.id, let i = keymapProfile.schemes.firstIndex(where: { $0.id == id }) else { return }
        keymapProfile.schemes[i].keymap = map
        persistProfile()
    }

    func selectScheme(_ id: UUID) {
        keymapProfile.activeID = id
        persistProfile()
        if let name = activeScheme?.name { showToast("Схема: \(name)") }
    }

    /// New scheme, empty or a copy of the active one; becomes active.
    @discardableResult
    func createScheme(copyingActive: Bool) -> KeymapScheme {
        var scheme = KeymapScheme(name: keymapProfile.nextName())
        if copyingActive, let active = activeScheme {
            scheme.keymap = active.keymap
            scheme.name = "\(active.name) (копия)"
        }
        keymapProfile.schemes.append(scheme)
        keymapProfile.activeID = scheme.id
        persistProfile()
        return scheme
    }

    func renameScheme(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = keymapProfile.schemes.firstIndex(where: { $0.id == id }) else { return }
        keymapProfile.schemes[i].name = trimmed
        persistProfile()
    }

    func deleteScheme(_ id: UUID) {
        guard keymapProfile.schemes.count > 1 else { return }
        keymapProfile.schemes.removeAll { $0.id == id }
        if keymapProfile.activeID == id { keymapProfile.activeID = keymapProfile.schemes.first?.id }
        persistProfile()
    }

    func addImportedScheme(_ scheme: KeymapScheme) {
        keymapProfile.schemes.append(scheme)
        keymapProfile.activeID = scheme.id
        persistProfile()
    }

    private func persistProfile() {
        KeymapStore.saveProfile(keymapProfile, for: foregroundPackage)
        applyActiveScheme()
    }

    private func applyActiveScheme() {
        keymap = keymapProfile.active?.keymap ?? Keymap()
        input.engine.map = keymap
    }

    // MARK: Device actions

    func back() { input.pressNamedKey("GoBack") }
    func home() { input.pressNamedKey("GoHome") }
    func recents() { input.pressNamedKey("AppSwitch") }
    func power() { input.pressNamedKey("Power") }
    func volumeUp() { input.pressNamedKey("AudioVolumeUp") }
    func volumeDown() { input.pressNamedKey("AudioVolumeDown") }
    func shake() { Task { await client?.shake() } }

    /// Turns the Android UI a quarter turn (auto-rotate off, user rotation set).
    func rotate() {
        let next = ((4 - geometry.rotation) % 4 + 1) % 4
        Task {
            try? await adb.shell("settings put system accelerometer_rotation 0; settings put system user_rotation \(next)")
        }
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        try await client?.setGPS(latitude: latitude, longitude: longitude)
    }

    func install(_ files: [URL]) {
        for file in files {
            showToast("Установка \(file.lastPathComponent)…")
            Task {
                do {
                    if ["apk", "apks", "xapk", "apkm"].contains(file.pathExtension.lowercased()) {
                        _ = try await adb.install(file)
                        showToast("Установлено: \(file.lastPathComponent)")
                    } else {
                        try await adb.sendFile(file)
                        showToast("Отправлено в Download: \(file.lastPathComponent)")
                    }
                } catch {
                    showToast("Ошибка: \(error.localizedDescription)")
                }
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }

    // MARK: Screenshot & recording

    func takeScreenshot() {
        guard let buffer = frameBuffer else { return }
        let (w, h) = frameSink.size
        guard w > 0 else { return }
        let rotation = geometry.rotation
        let name = "\(config.name) \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
        let url = AppPaths.screenshots.appendingPathComponent(name.replacingOccurrences(of: ":", with: "-"))
        let data = Data(bytes: buffer.pointer, count: w * h * 4)
        Task.detached {
            guard let image = makeCGImage(rgba: data, width: w, height: h, rotation: rotation) else { return }
            try? FileManager.default.createDirectory(at: AppPaths.screenshots, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            await MainActor.run {
                self.showToast("Скриншот сохранён в Изображения/VexPlayer")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
            }
        }
    }

    func toggleVideoRecording() {
        if isRecordingVideo { stopVideoRecording() } else { startVideoRecording() }
    }

    private func startVideoRecording() {
        let (w, h) = frameSink.size
        guard w > 0, let renderer = frameSink.renderer else { return }
        let name = "\(config.name) \(Int(Date().timeIntervalSince1970)).mp4"
        try? FileManager.default.createDirectory(at: AppPaths.recordings, withIntermediateDirectories: true)
        let url = AppPaths.recordings.appendingPathComponent(name)
        guard let rec = try? ScreenRecorder(url: url, width: w, height: h, rotation: geometry.rotation) else {
            showToast("Не удалось начать запись")
            return
        }
        videoRecorder = rec
        renderer.onFrameUploaded = { ptr, fw, fh in rec.append(ptr, width: fw, height: fh) }
        isRecordingVideo = true
        updateFrameStreaming()
        showToast("Запись экрана…")
    }

    func stopVideoRecording() {
        guard let rec = videoRecorder else { return }
        frameSink.renderer?.onFrameUploaded = nil
        videoRecorder = nil
        isRecordingVideo = false
        updateFrameStreaming()
        Task {
            await rec.finish()
            showToast("Видео сохранено в Фильмы/VexPlayer")
        }
    }
}

/// RGBA bytes → CGImage, turned upright.
func makeCGImage(rgba: Data, width: Int, height: Int, rotation: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: rgba as CFData),
          let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    guard rotation % 4 != 0 else { return img }
    let (ow, oh) = rotation % 2 == 0 ? (width, height) : (height, width)
    guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    // CoreGraphics is y-up: a clockwise turn on screen is a negative angle here.
    ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
    ctx.rotate(by: -CGFloat(rotation) * .pi / 2)
    ctx.draw(img, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
    return ctx.makeImage()
}

enum PortAllocator {
    /// Even console ports 5554…5682 (adb uses port+1), like the stock emulator.
    static func consolePort() throws -> Int {
        let busy = Set(InstanceStore.sharedPortsInUse())
        for port in stride(from: 5554, through: 5682, by: 2) where !busy.contains(port) {
            if isFree(port) && isFree(port + 1) { return port }
        }
        throw POSIXError(.EADDRINUSE)
    }

    static func grpcPort() throws -> Int {
        let busy = Set(InstanceStore.sharedGrpcPortsInUse())
        for port in 8554...8754 where !busy.contains(port) && isFree(port) { return port }
        throw POSIXError(.EADDRINUSE)
    }

    static func freePort(in range: ClosedRange<Int>) throws -> Int {
        for port in range where isFree(port) { return port }
        throw POSIXError(.EADDRINUSE)
    }

    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}

extension InstanceStore {
    nonisolated static func sharedPortsInUse() -> [Int] {
        MainActor.assumeIsolated { shared.sessions.values.filter { $0.state.isAlive }.map(\.consolePort) }
    }
    nonisolated static func sharedGrpcPortsInUse() -> [Int] {
        MainActor.assumeIsolated { shared.sessions.values.filter { $0.state.isAlive }.map(\.grpcPort) }
    }
}
