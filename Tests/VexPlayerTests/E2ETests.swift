import AppKit
import Foundation
import QuartzCore
import Testing
@testable import VexPlayer

/// End-to-end checks against a real emulator. Opt-in: `VEX_E2E=1 swift test --filter E2E`.
/// Downloads ~2.3 GB on first run and boots Android, so it takes minutes.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VEX_E2E"] != nil))
struct E2ETests {
    static let imagePath = "system-images;android-36;google_apis_playstore;arm64-v8a"

    @Test func installSDK() async throws {
        let sdk = SDKManager.shared
        await sdk.refreshCatalog()
        let catalog = try #require(sdk.catalog)
        let image = try #require(catalog.systemImages.first { $0.path == Self.imagePath })
        let packages = [catalog.emulator, catalog.platformTools, image].compactMap { $0 }
        sdk.acceptLicenses(Set(packages.map(\.licenseID)))
        try await sdk.install(packages)
        #expect(sdk.emulatorInstalled)
        #expect(sdk.adbInstalled)
        #expect(sdk.installedImages.contains { $0.path == Self.imagePath })
    }

    @Test func bootTouchRotateQuickboot() async throws {
        let store = InstanceStore.shared
        let config = try store.instances.first { $0.name == "E2E" }
            ?? store.create(InstanceConfig(id: store.nextID(), name: "E2E", imagePath: Self.imagePath))
        let session = store.session(for: config)
        defer { dumpLog(session) }
        // Frames only stream to an attached renderer: use an offscreen layer (exercises the zero-copy path).
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 1280, height: 720)
        let renderer = try #require(ScreenRenderer(layer: layer))
        session.attachRenderer(renderer)

        // 1. Boot
        var t0 = Date()
        session.start()
        let booted = await waitUntil(420) { session.state == .running || !session.state.isAlive }
        try #require(booted && session.state == .running, "state: \(session.state.label)")
        log("boot #1: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

        // 2. Frames arrive in shared memory
        try #require(await waitUntil(30) { session.frameSink.size.width > 0 }, "no frames")
        let (fw, fh) = session.frameSink.size
        log("framebuffer \(fw)x\(fh)")
        #expect(fw == config.width && fh == config.height)

        // Hidden window: the stream pauses; shown again: frames come back.
        session.setDisplayVisible(false)
        try await Task.sleep(for: .seconds(2))
        session.setDisplayVisible(true)
        try await session.adb.shell("input keyevent HOME")
        #expect(await waitUntil(10) { session.fps > 0 }, "frames did not resume after the window was shown again")
        log("displayed fps after resume: \(String(format: "%.1f", session.fps))")

        // Let the launcher settle, then compare our frame with Android's own screenshot.
        _ = await waitUntil(60) { session.foregroundPackage?.contains("launcher") == true }
        try await Task.sleep(for: .seconds(4))
        // The launcher may still be animating; give it a few chances to hold still.
        var match0 = try await compareWithScreencap(session)
        for _ in 0..<4 where match0.error >= 20 {
            try await Task.sleep(for: .seconds(3))
            match0 = try await compareWithScreencap(session)
        }
        log("orientation match at rotation 0: \(match0)")
        let gles = try await session.adb.shell("getprop ro.opengles.version").trimmingCharacters(in: .whitespacesAndNewlines)
        let egl = try await session.adb.shell("getprop ro.hardware.egl").trimmingCharacters(in: .whitespacesAndNewlines)
        log("gpu mode \(config.gpuMode.rawValue): ro.opengles.version=\(gles) egl=\(egl)")
        if config.gpuMode == .angleVulkan { #expect(gles == "196609" && egl == "angle") }
        #expect(match0.rotation == 0 && !match0.flipped && match0.error < 20)

        // 3. A real tap through our input path opens an app.
        if let (cx, cy, label) = try await findIcon(session, names: ["Chrome", "Play Store", "Google Play Store", "Play Маркет"]) {
            let g = session.geometry
            let u = cx / Double(g.shownWidth), v = cy / Double(g.shownHeight)
            log("tapping \(label) at \(cx),\(cy)")
            session.input.sendTouches([NormTouch(id: 0, u: u, v: v, down: true)])
            try await Task.sleep(for: .milliseconds(80))
            session.input.sendTouches([NormTouch(id: 0, u: u, v: v, down: false)])
            let opened = await waitUntil(15) {
                guard let p = session.foregroundPackage else { return false }
                return p.contains("chrome") || p.contains("vending")
            }
            log("foreground after tap: \(session.foregroundPackage ?? "?")")
            #expect(opened)
            session.home()
            _ = await waitUntil(10) { session.foregroundPackage?.contains("launcher") == true }
        } else {
            Issue.record("no launcher icon found to tap")
        }

        // 3b. Keyboard: the A key (macOS key code 0) and Russian text through VexIME land in an Android field.
        let imeReady = await waitUntil(60) { session.imeConnected }
        log("VexIME connected: \(imeReady)")
        #expect(imeReady)
        // Open all apps (its search box takes typed text); retry while the launcher is still animating back.
        for _ in 0..<4 {
            try await session.adb.shell("input swipe 960 1000 960 300 250")
            try await Task.sleep(for: .milliseconds(1500))
            let dump = try await session.adb.shell("uiautomator dump /sdcard/vex-ui.xml >/dev/null && cat /sdcard/vex-ui.xml")
            if dump.contains(":id/input\"") { break }
            session.home()
            try await Task.sleep(for: .seconds(1))
        }
        session.input.keyDown(0x00)   // A
        session.input.keyUp(0x00)
        let focused = await waitUntil(8) { session.textFieldFocused }
        log("text field focus from IME: \(focused)")
        #expect(focused)
        session.ime.commit("привет")
        try await Task.sleep(for: .seconds(2))
        let ui = try await session.adb.shell("uiautomator dump /sdcard/vex-ui.xml >/dev/null && cat /sdcard/vex-ui.xml")
        let field = ui.range(of: #"text="[^"]*" resource-id="[^"]*:id/input""#, options: .regularExpression).map { String(ui[$0]) } ?? "?"
        log("search field: \(field)")
        #expect(field.contains("text=\"aпривет\""))
        session.home()
        _ = await waitUntil(10) { session.foregroundPackage?.contains("launcher") == true }

        // 4. Rotation: turn the UI and check our geometry matches Android's screenshot.
        try await session.adb.shell("settings put system accelerometer_rotation 0; settings put system user_rotation 1")
        let rotated = await waitUntil(10) { session.geometry.rotation != 0 }
        log("geometry rotation after user_rotation=1: \(session.geometry.rotation)")
        #expect(rotated)
        try await Task.sleep(for: .seconds(3))
        var match1 = try await compareWithScreencap(session)
        for _ in 0..<4 where match1.error >= 20 {
            try await Task.sleep(for: .seconds(3))
            match1 = try await compareWithScreencap(session)
        }
        log("orientation match after rotation: \(match1)")
        #expect(match1.rotation == session.geometry.rotation && !match1.flipped && match1.error < 20)
        try await session.adb.shell("settings put system user_rotation 0")
        _ = await waitUntil(10) { session.geometry.rotation == 0 }

        // 5. Graceful stop saves Quickboot; the second start should be much faster.
        t0 = Date()
        session.stop()
        try #require(await waitUntil(120) { !session.state.isAlive }, "stop hung")
        log("stop + snapshot save: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, state \(session.state.label)")
        #expect(session.state == .stopped)

        t0 = Date()
        session.start()
        try #require(await waitUntil(300) { session.state == .running || !session.state.isAlive })
        let quick = Date().timeIntervalSince(t0)
        log("boot #2 (quickboot): \(String(format: "%.1f", quick)) s")
        #expect(session.state == .running)
        if config.fastBoot { #expect(quick < 10) }

        session.stop()
        _ = await waitUntil(120) { !session.state.isAlive }
        withExtendedLifetime(renderer) {}
    }

    /// Google APIs image + device profile: Android must report the phone, not "sdk_gphone64_arm64".
    @Test func deviceProfile() async throws {
        let path = "system-images;android-36;google_apis;arm64-v8a"
        try #require(SDKManager.shared.installedImages.contains { $0.path == path }, "Google APIs image not installed")
        let store = InstanceStore.shared
        var config = try store.instances.first { $0.name == "E2E-Profile" }
            ?? store.create(InstanceConfig(id: store.nextID(), name: "E2E-Profile", imagePath: path))
        config.deviceProfile = "galaxy_s24_ultra"
        try store.update(config)
        let session = store.session(for: config)
        session.config = config
        defer { dumpLog(session) }

        let t0 = Date()
        session.start()
        try #require(await waitUntil(900) { session.state == .running || !session.state.isAlive }, "never booted")
        log("profile boot (incl. apply + reboots): \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, state \(session.state.label)")
        let props = try await session.adb.shell("getprop ro.product.model; getprop ro.product.manufacturer; getprop ro.build.fingerprint")
        log("props: \(props.replacingOccurrences(of: "\n", with: " | "))")
        #expect(props.contains("SM-S928B"))
        #expect(props.contains("samsung/e3qxeea/e3q:16/"))
        #expect(config.appliedProfileMarker == "galaxy_s24_ultra@\(DeviceProfile.schemaVersion)")

        session.stop()
        _ = await waitUntil(120) { !session.state.isAlive }
    }

    /// A new Lite instance boots with the Lite package list disabled; the instance is deleted afterwards.
    @Test func liteEdition() async throws {
        let path = "system-images;android-36;google_apis_playstore;arm64-v8a"
        try #require(SDKManager.shared.installedImages.contains { $0.path == path }, "Google Play image not installed")
        let store = InstanceStore.shared
        var config = InstanceConfig(id: store.nextID(), name: "E2E-Lite", imagePath: path)
        config.lite = true
        config.ramMB = InstanceConfig.defaultLiteRAM
        config = try store.create(config)
        let session = store.session(for: config)
        // A running instance can't be deleted: stop it first, whatever the checks did.
        var failure: Error?
        do {
            try await checkLite(session, config)
        } catch {
            failure = error
        }
        dumpLog(session)
        session.forceStop()
        _ = await waitUntil(60) { !session.state.isAlive }
        try store.delete(config.id)
        if let failure { throw failure }
    }

    private func checkLite(_ session: InstanceSession, _ config: InstanceConfig) async throws {
        let t0 = Date()
        session.start()
        try #require(await waitUntil(600) { session.state == .running || !session.state.isAlive }, "never booted")
        log("lite first boot: \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let marker = "lite@\(LiteEdition.version)"
        try #require(await waitUntil(180) { (try? String(contentsOf: config.liteMarkerFile, encoding: .utf8)) == marker },
                     "Lite package list never applied")

        let disabled = Set(try await session.adb.shell("pm list packages -d").split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "package:", with: "") })
        let installed = Set(try await session.adb.shell("pm list packages").split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "package:", with: "") })
        let expected = Set(LiteEdition.disabledPackages).intersection(installed)
        log("lite: \(expected.count) of \(LiteEdition.disabledPackages.count) listed packages present, \(expected.subtracting(disabled).count) still enabled")
        #expect(expected.isSubset(of: disabled))
        #expect(!disabled.contains("com.android.vending"))
        #expect(!disabled.contains("com.google.android.gms"))

        try? await Task.sleep(for: .seconds(30))
        let mem = (try? await session.adb.shell("dumpsys meminfo | grep -E 'Used RAM|Free RAM'; true")) ?? ""
        log("lite meminfo: \(mem.replacingOccurrences(of: "\n", with: " | "))")
        let cached = try await session.adb.shell("device_config get activity_manager max_cached_processes")
        #expect(cached.trimmingCharacters(in: .whitespacesAndNewlines) == "\(LiteEdition.maxCachedProcesses)")
    }

    // MARK: Helpers

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }

    private func log(_ s: String) { print("E2E: \(s)") }

    private func dumpLog(_ session: InstanceSession) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vex-e2e-emulator.log")
        try? session.logLines.joined().write(to: url, atomically: true, encoding: .utf8)
        print("E2E: emulator log at \(url.path)")
    }

    private func screencap(_ session: InstanceSession) async throws -> NSBitmapImageRep {
        let local = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vex-e2e-screencap.png")
        try await session.adb.shell("screencap -p /sdcard/vex-e2e.png")
        try await session.adb.run(["pull", "/sdcard/vex-e2e.png", local.path])
        return try #require(NSBitmapImageRep(data: Data(contentsOf: local)))
    }

    /// Finds which rotation/flip of our raw framebuffer reproduces Android's upright screenshot.
    private func compareWithScreencap(_ session: InstanceSession) async throws
        -> (rotation: Int, flipped: Bool, error: Double) {
        let shot = try await screencap(session)
        let buffer = try #require(session.frameBuffer)
        let (w, h) = session.frameSink.size
        let raw = buffer.pointer.assumingMemoryBound(to: UInt8.self)
        let shotBytes = try #require(shot.bitmapData)
        let spp = shot.samplesPerPixel, rowBytes = shot.bytesPerRow
        try #require(shot.bitsPerSample == 8 && spp >= 3)
        var best = (rotation: -1, flipped: false, error: Double.infinity)
        for rotation in 0..<4 {
            let g = DisplayGeometry(fbWidth: w, fbHeight: h, rotation: rotation)
            guard (g.shownWidth > g.shownHeight) == (shot.pixelsWide > shot.pixelsHigh) else { continue }
            for flipped in [false, true] {
                var total = 0.0, n = 0
                for iy in 1..<24 {
                    for ix in 1..<24 {
                        let u = Double(ix) / 24, v = Double(iy) / 24
                        var p = g.framebufferPoint(u: u, v: v)
                        if flipped { p.y = h - 1 - p.y }
                        let o = (p.y * w + p.x) * 4
                        let sx = Int(u * Double(shot.pixelsWide - 1)), sy = Int(v * Double(shot.pixelsHigh - 1))
                        let so = sy * rowBytes + sx * spp
                        for ch in 0..<3 { total += abs(Double(raw[o + ch]) - Double(shotBytes[so + ch])) }
                        n += 3
                    }
                }
                let err = total / Double(max(n, 1))
                if err < best.error { best = (rotation, flipped, err) }
            }
        }
        return best
    }

    /// Launcher icon centre (upright display coordinates) from a uiautomator dump.
    private func findIcon(_ session: InstanceSession, names: [String]) async throws -> (Double, Double, String)? {
        let xml = try await session.adb.shell("uiautomator dump /sdcard/vex-ui.xml >/dev/null && cat /sdcard/vex-ui.xml")
        for name in names {
            let pattern = #"(text|content-desc)="\#(NSRegularExpression.escapedPattern(for: name))"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]""#
            let re = try NSRegularExpression(pattern: pattern)
            if let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                let n = (2...5).map { Double(xml[Range(m.range(at: $0), in: xml)!])! }
                return ((n[0] + n[2]) / 2, (n[1] + n[3]) / 2, name)
            }
        }
        print("E2E: ui dump had no match; first 600 chars: \(xml.prefix(600))")
        return nil
    }
}
