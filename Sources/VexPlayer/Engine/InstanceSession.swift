import AppKit
import Darwin
import EmulatorAPI
import Foundation
import Observation
import os

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
            case .stopped: return String(localized: "Stopped")
            case .starting: return String(localized: "Starting…")
            case .booting: return String(localized: "Booting Android…")
            case .running: return String(localized: "Running")
            case .stopping: return String(localized: "Saving and stopping…")
            case .preparing(let what): return what
            case .failed(let e): return String(localized: "Error: \(e)")
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
    private(set) var keyboardRequested = false
    /// Mac keys type into Android instead of driving the key mapping. In an app without a scheme any focused
    /// field takes them; a game only gets text once it asks for a keyboard (its chat), because games often
    /// keep a hidden field focused while you play.
    var typing: Bool { textFieldFocused && (keyboardRequested || !keymapEnabled || keymap.controls.isEmpty) }
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
    @ObservationIgnored private var sensorResetTask: Task<Void, Never>?
    @ObservationIgnored private var runsInBackground = false
    /// Boot finished and Android had half a minute to settle; only then may a hidden instance go to the background.
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var vmPaused = false
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var policyObserver: NSObjectProtocol?
    @ObservationIgnored private var keymapObserver: NSObjectProtocol?

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
        policyObserver = NotificationCenter.default.addObserver(
            forName: .vexBackgroundPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProcessPriority() }
        }
        // Two windows of the same game share its schemes: without this, each kept its own copy and the
        // next save from either one overwrote what the other had changed.
        keymapObserver = NotificationCenter.default.addObserver(
            forName: .vexKeymapProfileSaved, object: nil, queue: .main) { [weak self] note in
            let profile = note.userInfo?["profile"] as? String
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self), profile == self.keymapProfileName else { return }
                self.loadKeymap()
            }
        }
    }

    // MARK: Lifecycle

    /// `continuingLog` appends to the current log (a restart VexPlayer does by itself) instead of starting a new one;
    /// `discardingSnapshot` drops the Quickboot snapshot first, giving the reason in the log.
    func start(continuingLog: Bool = false, discardingSnapshot reason: String? = nil) {
        guard !state.isAlive else { return }
        guard AppPaths.emulatorBinary.fileExists else { return fail(String(localized: "The emulator isn't installed")) }
        guard AppPaths.sdk.appendingPathComponent(config.imageDirRelative).fileExists else {
            return fail(String(localized: "The Android image isn't installed"))
        }
        // Regenerate config.ini every launch so tuning from newer app versions reaches old instances.
        try? config.configIni().write(to: config.avdDir.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        state = .starting
        logLines = []
        restoredSnapshot = false
        coldRestartPending = false
        let logURL = AppPaths.logs.appendingPathComponent("\(config.id).log")
        if continuingLog, let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            logFile = handle
        } else {
            // Keep the last run's log: after a crash the user usually starts again before anyone looks at it.
            let previousLog = AppPaths.logs.appendingPathComponent("\(config.id).prev.log")
            try? FileManager.default.removeItem(at: previousLog)
            try? FileManager.default.moveItem(at: logURL, to: previousLog)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logFile = try? FileHandle(forWritingTo: logURL)
        }
        if let reason { discardSnapshot(reason) }
        discardBrokenSnapshot()
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
            return fail(String(localized: "Couldn't start the emulator: \(error.localizedDescription)"))
        }
        process = p
        runsInBackground = false
        settled = false
        updateProcessPriority()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Android instance \(config.name)")
        tasks.append(Task { await self.connectAndBoot(pid: p.processIdentifier) })
    }

    /// Bluetooth and UWB emulation and Wi-Fi packet streaming all go through netsimd, one daemon shared by every
    /// running emulator. When its stream drops, the emulator's Bluetooth/UWB transport aborts while reconnecting
    /// (std::bad_function_call under PacketStreamerTransport::OnDone), killing an instance mid-game. Without them
    /// Wi-Fi runs on the emulator's own network stack and instances no longer share anything. Android's Bluetooth
    /// must be off first: with no controller it crashes six times and leaves an error dialog on screen.
    static let netsimFeatures = ["-BluetoothEmulation", "-Uwb", "-WiFiPacketStream"]
    private var runsWithoutNetsim: Bool { config.bluetoothOffMarkerFile.fileExists }
    private var features: [String] { config.effectiveGPUMode.features + (runsWithoutNetsim ? Self.netsimFeatures : []) }

    private var launchSignatureFile: URL { config.avdDir.appendingPathComponent("vex-launch.txt") }
    private var launchSignature: String {
        "\(config.effectiveGPUMode.rawValue)|\(features.joined(separator: ","))|\(AppSettings.shared.hiddenQtWindow)"
    }

    private func launchArguments() -> [String] {
        let settings = AppSettings.shared
        var args = [
            "-avd", config.id,
            "-port", "\(consolePort)",
            "-grpc", "\(grpcPort)", "-grpc-use-token",
            "-gpu", config.effectiveGPUMode.emulatorGPU,
            "-no-boot-anim",
            "-no-metrics",
            "-netfast",
            "-camera-back", "none", "-camera-front", "none",
        ]
        args += settings.hiddenQtWindow ? ["-qt-hide-window"] : ["-no-window"]
        if !features.isEmpty { args += ["-feature", features.joined(separator: ",")] }
        if !config.audioEnabled { args.append("-no-audio") }
        if !config.quickboot { args.append("-no-snapshot-save") }
        // A snapshot taken under other GPU features would restore a guest driver that no longer matches.
        if !config.effectiveGPUMode.supportsQuickboot
            || (try? String(contentsOf: launchSignatureFile, encoding: .utf8)) != launchSignature {
            args.append("-no-snapshot-load")
        }
        if config.needsWritableSystem { args.append("-writable-system") }
        args += settings.extraEmulatorArgs.split(separator: " ").map(String.init)
        return args
    }

    /// Graceful stop: SIGINT makes the emulator save its Quickboot snapshot, so the next start takes seconds.
    /// `closeApps: false` leaves Android's apps alone (used when their GPU state is already broken).
    func stop(closeApps: Bool = true) {
        if process == nil, state == .starting {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
            frameBuffer = nil
            state = .stopped
            return
        }
        guard let p = process, state.isAlive, state != .stopping else { return }
        let wasRunning = state == .running
        state = .stopping
        input.releaseAll()
        stopVideoRecording()
        pauseTask?.cancel()
        let resume = vmPaused ? client : nil
        vmPaused = false
        stopSavesSnapshot = wasRunning && config.quickboot
        snapshotSaved = false
        let closesApps = closeApps && stopSavesSnapshot
        Task {
            // Quickboot saves a running VM, and a paused one can't sync: wake it first.
            if let resume { try? await resume.setVMState(.running) }
            if closesApps { await closeAppsForSnapshot() }
            if wasRunning { await syncGuestDisks() }
            p.interrupt()
        }
        Task {
            // The launcher kills qemu by itself emulatorStopTimeout after the interrupt (see sdkEnvironment);
            // this only covers a launcher that hangs.
            let deadline = Date().addingTimeInterval(AppPaths.emulatorStopTimeout + 30)
            while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
            if p.isRunning { p.terminate() }
            try? await Task.sleep(for: .seconds(5))
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// Set by stop() when the emulator is expected to save Quickboot on exit, and by the log line that says it did.
    private var stopSavesSnapshot = false
    private var snapshotSaved = false
    /// This run came from a Quickboot snapshot / a cold restart after a broken restore is under way.
    private var restoredSnapshot = false
    private var coldRestartPending = false

    /// A Quickboot save cut off by a kill leaves an empty or partial RAM image next to disk snapshots. The emulator
    /// may still try to restore it, so drop it and let the next start boot cold from the disks.
    private func discardSnapshot(_ reason: String) {
        let dir = config.quickbootSnapshotDir
        guard dir.fileExists else { return }
        try? FileManager.default.removeItem(at: dir)
        appendLog("Quickboot snapshot discarded (\(reason)); the next start boots cold\n")
    }

    private func discardBrokenSnapshot() {
        // A Vulkan instance never loads one (see GPUMode.supportsQuickboot); it only takes disk space.
        if !config.effectiveGPUMode.supportsQuickboot { return discardSnapshot("Quickboot is off with Vulkan graphics") }
        let ram = config.quickbootSnapshotDir.appendingPathComponent("ram.bin")
        let size = (try? FileManager.default.attributesOfItem(atPath: ram.path)[.size] as? Int) ?? nil
        if size == 0 { discardSnapshot("empty RAM image") }
    }

    /// Android keeps its latest writes in its page cache, and neither a Quickboot save nor the emulator's exit
    /// flushes them: the next cold boot (Quickboot off, a snapshot that fails to load, new launch flags) came up
    /// without the last seconds of changes, a just-installed app included. Waits at most 10 s, so a hung
    /// Android can't hold up the stop.
    private func syncGuestDisks() async {
        await shellBounded("sync", seconds: 10)
    }

    /// Quickboot can't bring back the GPU state of a running 3D app: a game restored mid-session got VK_NOT_READY on
    /// every frame (a frozen picture), and freeing its dead Vulkan objects later crashed the emulator in MoltenVK.
    /// So the apps are closed before a save: HOME first, so they save their state the usual way, then every
    /// third-party app and whatever else is in front. The snapshot keeps only the system UI; an online game has to
    /// reconnect after a restore anyway.
    private func closeAppsForSnapshot() async {
        let script = "input keyevent HOME; sleep 1; "
            + "fg=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed -E 's#.* ([^ /]+)/.*#\\1#'); "
            + "for p in $(pm list packages -3 | cut -d: -f2) $fg; do case $p in "
            + "\(ImeBridge.package)|*launcher*|com.android.systemui) ;; "
            + "*) pidof $p >/dev/null && am force-stop $p && echo $p ;; esac; done"
        let closed = await shellBounded(script, seconds: 10)
        if !closed.isEmpty {
            appendLog("Closed before the Quickboot save: \(closed.split(separator: "\n").joined(separator: ", "))\n")
            // Give the renderer a moment to free their GPU objects before the RAM is saved.
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Runs a guest shell command but waits at most `seconds`, so a hung Android can't hold up a stop.
    @discardableResult
    private func shellBounded(_ command: String, seconds: Double) async -> String {
        let adb = adb
        let result = OSAllocatedUnfairLock<String?>(initialState: nil)
        Task.detached {
            let out = (try? await adb.shell(command)) ?? ""
            result.withLock { $0 = out }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let out = result.withLock({ $0 }) { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ""
    }

    /// A Quickboot restore whose GPU state didn't come back (VK_NOT_READY from the renderer) leaves a frozen
    /// picture and crashes the emulator once the affected app exits. Stop without touching the apps, drop the
    /// snapshot and boot cold: about a minute instead of a dead window.
    private func restartColdAfterBrokenRestore() {
        appendLog("Quickboot restore lost the GPU state of running apps; restarting with a cold boot\n")
        Task {
            stop(closeApps: false)
            while state.isAlive { try? await Task.sleep(for: .milliseconds(200)) }
            start(continuingLog: true, discardingSnapshot: "its GPU state can't be restored")
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
        sensorResetTask?.cancel()
        sensorResetTask = nil
        pauseTask?.cancel()
        pauseTask = nil
        vmPaused = false
        client?.close()
        client = nil
        frameBuffer = nil
        process = nil
        stopVideoRecording()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if state == .stopping && stopSavesSnapshot && !snapshotSaved { discardSnapshot("the save didn't finish") }
        stopSavesSnapshot = false
        try? logFile?.close()
        ime.stop()
        imeConnected = false
        logFile = nil
        if state == .stopping || code == 0 {
            state = .stopped
        } else {
            let tail = logLines.suffix(6).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            state = .failed(String(localized: "the emulator exited with code \(code). \(tail.suffix(300))"))
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        appendLog("ERROR: \(message)\n")
    }

    private func appendLog(_ text: String) {
        logFile?.write(Data(text.utf8))
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if stopSavesSnapshot && line.contains("Saving snapshot") && line.contains(" took ") { snapshotSaved = true }
            if line.contains("Successfully loaded snapshot") { restoredSnapshot = true }
            if restoredSnapshot && !coldRestartPending && state.isAlive && state != .stopping
                && line.contains("VK_NOT_READY") {
                coldRestartPending = true
                restartColdAfterBrokenRestore()
            }
            logLines.append(String(line) + "\n")
        }
        if logLines.count > 600 { logLines.removeFirst(logLines.count - 600) }
    }

    // MARK: Boot

    private func connectAndBoot(pid: Int32) async {
        guard let token = await discoverToken(pid: pid) else {
            if state.isAlive { fail(String(localized: "gRPC didn't come up (no discovery file)")) }
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
        tasks.append(Task { await self.watchDisplayState() })
        tasks.append(Task { await self.setupAgent() })
        tasks.append(Task {
            // Android keeps starting services for a while after boot_completed.
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self.settled = true
            self.updateProcessPriority()
        })
        tasks.append(Task {
            // One dumpsys every 15 s, only while someone looks at the screen (see refreshForeground).
            while !Task.isCancelled && self.state.isAlive {
                try? await Task.sleep(for: .seconds(15))
                if self.isWatched && !self.keymapEditing { await self.refreshForeground() }
            }
        })
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

    /// Someone sees the screen or records it.
    private var isWatched: Bool { isRecordingVideo || (frameSink.renderer != nil && displayVisible) }

    private func updateFrameStreaming() {
        let wanted = client != nil && state.isAlive && isWatched
        if wanted, frameTask == nil, let client {
            frameTask = Task { await self.runFrameStream(client) }
        } else if !wanted, let task = frameTask {
            task.cancel()   // closes the gRPC stream; the emulator stops reading frames back
            frameTask = nil
            if frameSink.renderer == nil { fps = 0 }
        }
        updateProcessPriority()
    }

    /// With "pause minimized instances" on, minimizing the window freezes the VM (0 % CPU); restoring resumes it.
    func setMinimized(_ minimized: Bool) {
        pauseTask?.cancel()
        pauseTask = Task {
            if minimized {
                // A quick minimize-and-restore shouldn't stall the game.
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, AppSettings.shared.pauseWhenMinimized, state == .running,
                      !isRecordingVideo, !recorder.isPlaying, !vmPaused, let client else { return }
                vmPaused = true
                try? await client.setVMState(.paused)
                appendLog("VM paused (window minimized)\n")
            } else if vmPaused, let client {
                vmPaused = false
                try? await client.setVMState(.running)
                appendLog("VM resumed\n")
            }
        }
    }

    /// An instance nobody looks at keeps running, but at background priority: macOS moves it to the
    /// efficiency cores and gives the user's own apps the performance cores first. Not while Android boots:
    /// two hidden instances booting at once on efficiency cores took a minute and left ANR dialogs behind
    /// (System UI, the phone service), and a game started then failed to load.
    private func updateProcessPriority() {
        guard let p = process, p.isRunning else { return }
        let background = AppSettings.shared.backgroundWhenHidden && !isWatched && settled
        guard background != runsInBackground else { return }
        runsInBackground = background
        setpriority(PRIO_DARWIN_PROCESS, id_t(p.processIdentifier), background ? PRIO_DARWIN_BG : 0)
        appendLog("Priority: \(background ? "background" : "normal")\n")
    }

    private func runNotifications(_ client: EmulatorClient) async {
        while !Task.isCancelled && state.isAlive {
            try? await client.streamNotifications { [weak self] n in
                if case .textViewFocus(let f)? = n.type {
                    Task { @MainActor in
                        guard self?.imeConnected == false else { return }
                        // Without VexIME nothing says whether a keyboard was asked for: any focus counts.
                        self?.setTextFocus(ImeBridge.Focus(field: f.textViewHasFocus, keyboard: f.textViewHasFocus))
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
        state = .preparing(profile.map { String(localized: "Device profile: \($0.title)…") } ?? String(localized: "Removing the device profile…"))
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
            if let profile, model != profile.model { throw NSError(domain: "VexPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "the model is still \(model)")]) }
            if let wanted {
                try wanted.write(to: config.profileMarkerFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: config.profileMarkerFile)
            }
        } catch {
            appendLog("Device profile failed: \(error.localizedDescription)\n")
            showToast(String(localized: "Couldn't apply the device profile: \(error.localizedDescription)"))
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
        throw NSError(domain: "VexPlayer", code: 4, userInfo: [NSLocalizedDescriptionKey: String(localized: "adb isn't responding")])
    }

    private func waitForAndroidBoot(timeout: TimeInterval = 240) async throws {
        try? await Task.sleep(for: .seconds(3))   // let the old boot state go away after `adb reboot`
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || !state.isAlive { throw CancellationError() }
            if let v = try? await adb.shell("getprop sys.boot_completed"), v.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            try? await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "VexPlayer", code: 5, userInfo: [NSLocalizedDescriptionKey: String(localized: "Android didn't boot after the restart")])
    }

    // MARK: Android agent (VexIME)

    /// Quiets the idle sensors, installs VexIME if needed and, with Mac text input on, makes it the active IME.
    private func setupAgent() async {
        guard let apk = ImeBridge.apkURL else { return appendLog("VexIME.apk not found\n") }
        // After a Quickboot restore Android reports "booted" while adbd is still reconnecting ("device offline").
        var online = false
        for _ in 0..<60 where !Task.isCancelled {
            if let s = try? await adb.run(["get-state"]), s.contains("device") { online = true; break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard online else { return appendLog("VexIME: adb never came online\n") }
        await adb.quietSensors()
        if config.isLite { await applyLiteEdition() }
        await installAgent(apk)
        if AppSettings.shared.macInputMethod {
            await connectIME()
        } else if config.isMinimal {
            // Minimal has no Gboard: VexIME becomes the keyboard, passing the Mac's keys straight through,
            // unless the user has picked another one since.
            await selectIME(onlyIfNone: true)
        }
        await adb.resetSensorRate()
        if !runsWithoutNetsim { await turnBluetoothOff() }

        // Without the IME nothing inside Android resets the sensor rate on its own (VexIME does every minute).
        while !Task.isCancelled && state == .running {
            try? await Task.sleep(for: .seconds(120))
            if !imeConnected && state == .running { await adb.resetSensorRate() }
        }
    }

    /// Disables the Lite (or Minimal) package list once per list version; the cached-process limit is DeviceConfig
    /// and lasts until reboot, so it is set on every boot (after quietSensors paused DeviceConfig sync).
    private func applyLiteEdition() async {
        _ = try? await adb.shell("device_config put activity_manager max_cached_processes \(LiteEdition.maxCachedProcesses)")
        let minimal = config.isMinimal
        let marker = minimal ? "minimal@\(LiteEdition.version).\(LiteEdition.minimalVersion)" : "lite@\(LiteEdition.version)"
        guard (try? String(contentsOf: config.liteMarkerFile, encoding: .utf8)) != marker else { return }
        // `cmd package` talks to the package service directly: no Java start-up per package as with `pm`.
        let list = minimal ? LiteEdition.minimalPackages : LiteEdition.disabledPackages
        let settings = minimal ? LiteEdition.minimalSettings.map { "\($0) >/dev/null 2>&1; " }.joined() : ""
        guard (try? await adb.shell("for p in \(list.joined(separator: " ")); do cmd package disable-user --user 0 $p >/dev/null 2>&1; done; \(settings)true")) != nil else {
            return appendLog("\(minimal ? "Minimal" : "Lite") edition not applied: adb failed, retrying next boot\n")
        }
        try? marker.write(to: config.liteMarkerFile, atomically: true, encoding: .utf8)
        appendLog("\(minimal ? "Minimal" : "Lite") edition applied (\(list.count) packages disabled)\n")
    }

    /// Once per instance, while the emulated controller is still there: switch Android's Bluetooth off so the next
    /// start can drop netsim (see netsimFeatures). The process takes ~8 s to exit, and a Quickboot snapshot taken
    /// before that brings it back half-stopped and it crashes on restore, so the marker waits for it.
    private func turnBluetoothOff() async {
        _ = try? await adb.shell("cmd bluetooth_manager disable >/dev/null 2>&1; true")
        for _ in 0..<30 where !Task.isCancelled && state == .running {
            if let out = try? await adb.shell("settings get global bluetooth_on; pidof com.google.android.bluetooth; true"),
               out.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) == ["0"] {
                try? "off".write(to: config.bluetoothOffMarkerFile, atomically: true, encoding: .utf8)
                return appendLog("Bluetooth is off: the next start runs without netsim\n")
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func installAgent(_ apk: URL) async {
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
    }

    /// Makes VexIME the keyboard. Right after its first install Android doesn't list it yet, so `ime set`
    /// fails quietly for a moment: retry until Android reports it as the current input method.
    /// With `onlyIfNone`, leaves a keyboard the user picked alone and only fills an empty choice.
    private func selectIME(onlyIfNone: Bool = false) async {
        let current = "settings get secure default_input_method"
        if onlyIfNone, let ime = try? await adb.shell(current).trimmingCharacters(in: .whitespacesAndNewlines),
           !ime.isEmpty, ime != "null" { return }
        let command = "ime enable \(ImeBridge.component) >/dev/null 2>&1; ime set \(ImeBridge.component) >/dev/null 2>&1; \(current)"
        for _ in 0..<30 where !Task.isCancelled {
            if (try? await adb.shell(command))?.trimmingCharacters(in: .whitespacesAndNewlines) == ImeBridge.component { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !Task.isCancelled { appendLog("VexIME couldn't be made the keyboard\n") }
    }

    private func connectIME() async {
        await selectIME()
        guard !Task.isCancelled else { return }
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
        ime.onFocus = { [weak self] focus in
            Task { @MainActor in
                guard let self, focus != ImeBridge.Focus(field: self.textFieldFocused, keyboard: self.keyboardRequested) else { return }
                self.appendLog("VexIME text focus: \(focus.field), keyboard requested: \(focus.keyboard)\n")
                self.setTextFocus(focus)
            }
        }
        ime.start(port: port)
    }

    private func setTextFocus(_ focus: ImeBridge.Focus) {
        textFieldFocused = focus.field
        keyboardRequested = focus.keyboard
        input.textFieldFocused = focus.field
        input.keyboardRequested = focus.keyboard
        if typing { input.engine.releaseAll() }
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

    /// Rotation and the foreground app come from Android's event log as they change. A waiting `logcat`
    /// costs nothing; polling `dumpsys` kept system_server and adb busy around the clock.
    private func watchDisplayState() async {
        while !Task.isCancelled && state == .running {
            let (rotation, package) = await adb.displayState()
            if let rotation { applyRotation(rotation) }
            if let package { foregroundChanged(package) }
            for await line in adb.shellLines(ADB.displayEventsCommand) {
                if line.contains("configuration_changed") {
                    // The display reports its new orientation up to ~0.3 s after the event (longer on a busy Mac),
                    // and no further event follows: re-read a couple of times before settling.
                    let before = geometry.rotation
                    for delay in [0, 300, 1000] {
                        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                        if let rotation = await adb.rotation() { applyRotation(rotation) }
                        if geometry.rotation != before { break }
                    }
                } else if let package = ADB.resumedPackage(in: line) {
                    foregroundChanged(package)
                }
            }
            // adb dropped (Android reboot, Quickboot restore): reconnect and resync.
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func applyRotation(_ rotation: Int) {
        // Surface.ROTATION_90 means the UI is drawn turned clockwise inside the panel.
        let turns = (4 - rotation) % 4
        guard turns != geometry.rotation else { return }
        geometry.rotation = turns
        input.engine.aspect = geometry.aspect
        input.releaseAll()
        frameSink.renderer?.rotation = turns
    }

    /// Schemes are stored per foreground app, so a missed switch loads, edits and imports the wrong app's schemes
    /// (a game's schemes ended up under the launcher). The event stream can miss one, so ask Android directly
    /// when it matters: before the editor opens, when a window comes to the front, and every 15 s on screen.
    func refreshForeground() async {
        guard state == .running, let package = await adb.foregroundPackage() else { return }
        foregroundChanged(package)
    }

    /// While the key mapping editor is open the scheme it edits stays loaded; a switch is applied on close.
    var keymapEditing = false {
        didSet {
            guard !keymapEditing, let package = deferredForeground else { return }
            deferredForeground = nil
            foregroundChanged(package)
        }
    }
    @ObservationIgnored private var deferredForeground: String?

    private func foregroundChanged(_ package: String) {
        if keymapEditing {
            deferredForeground = package
            return
        }
        guard package != foregroundPackage else { return }
        foregroundPackage = package
        appendLog("Foreground: \(package)\n")
        loadKeymap()
        // A game that read sensors at 50+ Hz leaves the emulator streaming them after it closes.
        // Give the old app a moment to unregister its listeners first.
        sensorResetTask?.cancel()
        sensorResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, state == .running else { return }
            if imeConnected { ime.resetSensorRate() } else { await adb.resetSensorRate() }
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
        if let name = activeScheme?.name { showToast(String(localized: "Scheme: \(name)")) }
    }

    /// New scheme, empty or a copy of the active one; becomes active.
    @discardableResult
    func createScheme(copyingActive: Bool) -> KeymapScheme {
        var scheme = KeymapScheme(name: keymapProfile.nextName())
        if copyingActive, let active = activeScheme {
            scheme.keymap = active.keymap
            scheme.name = String(localized: "\(active.name) (copy)")
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
        var scheme = scheme
        scheme.name = keymapProfile.uniqueName(scheme.name)
        keymapProfile.schemes.append(scheme)
        keymapProfile.activeID = scheme.id
        persistProfile()
    }

    private func persistProfile() {
        KeymapStore.saveProfile(keymapProfile, for: foregroundPackage)
        applyActiveScheme()
        NotificationCenter.default.post(name: .vexKeymapProfileSaved, object: self, userInfo: ["profile": keymapProfileName])
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
            showToast(String(localized: "Installing \(file.lastPathComponent)…"))
            Task {
                do {
                    if ["apk", "apks", "xapk", "apkm"].contains(file.pathExtension.lowercased()) {
                        _ = try await adb.install(file)
                        showToast(String(localized: "Installed: \(file.lastPathComponent)"))
                    } else {
                        try await adb.sendFile(file)
                        showToast(String(localized: "Sent to Download: \(file.lastPathComponent)"))
                    }
                } catch {
                    showToast(String(localized: "Error: \(error.localizedDescription)"))
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
                self.showToast(String(localized: "Screenshot saved to Pictures/VexPlayer"))
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
            showToast(String(localized: "Couldn't start recording"))
            return
        }
        videoRecorder = rec
        renderer.onFrameUploaded = { ptr, fw, fh in rec.append(ptr, width: fw, height: fh) }
        isRecordingVideo = true
        updateFrameStreaming()
        showToast(String(localized: "Recording the screen…"))
    }

    func stopVideoRecording() {
        guard let rec = videoRecorder else { return }
        frameSink.renderer?.onFrameUploaded = nil
        videoRecorder = nil
        isRecordingVideo = false
        updateFrameStreaming()
        Task {
            await rec.finish()
            showToast(String(localized: "Video saved to Movies/VexPlayer"))
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
