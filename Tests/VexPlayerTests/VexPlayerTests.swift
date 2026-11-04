import Foundation
import Testing
@testable import VexPlayer

@Suite struct GeometryTests {
    let portrait = DisplayGeometry(fbWidth: 1080, fbHeight: 1920)

    @Test func identityMapping() {
        #expect(portrait.framebufferPoint(u: 0, v: 0) == (0, 0))
        #expect(portrait.framebufferPoint(u: 1, v: 1) == (1079, 1919))
        #expect(portrait.shownWidth == 1080 && portrait.shownHeight == 1920)
    }

    @Test func rotatedQuarterTurnSwapsShownSize() {
        var g = portrait
        g.rotation = 1
        #expect(g.shownWidth == 1920 && g.shownHeight == 1080)
        #expect(g.isLandscape)
        // Top-left of the upright picture is the framebuffer's bottom-left corner after a clockwise turn.
        #expect(g.framebufferPoint(u: 0, v: 0) == (0, 1919))
        #expect(g.framebufferPoint(u: 1, v: 0) == (0, 0))
        #expect(g.framebufferPoint(u: 1, v: 1) == (1079, 0))
    }

    @Test func everyRotationIsABijectionOfCorners() {
        for r in 0..<4 {
            var g = portrait
            g.rotation = r
            let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { g.framebufferPoint(u: $0.0, v: $0.1) }
            let unique = Set(corners.map { "\($0.x),\($0.y)" })
            #expect(unique.count == 4, "rotation \(r)")
        }
    }

    /// The shader samples texture coords t(d) for shown coords d; touches must hit the same framebuffer pixel.
    @Test func touchMappingMatchesShader() {
        func shader(_ r: Int, _ d: (Double, Double)) -> (Double, Double) {
            switch r {
            case 1: return (d.1, 1 - d.0)
            case 2: return (1 - d.0, 1 - d.1)
            case 3: return (1 - d.1, d.0)
            default: return d
            }
        }
        for r in 0..<4 {
            var g = DisplayGeometry(fbWidth: 1001, fbHeight: 2001)
            g.rotation = r
            for d in [(0.25, 0.1), (0.9, 0.6), (0.5, 0.5)] {
                let t = shader(r, d)
                let p = g.framebufferPoint(u: d.0, v: d.1)
                #expect(abs(Double(p.x) - t.0 * 1000) <= 1 && abs(Double(p.y) - t.1 * 2000) <= 1, "rotation \(r)")
            }
        }
    }

    @Test func fitRectLetterboxes() {
        let g = DisplayGeometry(fbWidth: 1920, fbHeight: 1080)
        let r = g.fitRect(in: CGSize(width: 1000, height: 1000))
        #expect(abs(r.width - 1000) < 0.01)
        #expect(abs(r.height - 562.5) < 0.01)
        #expect(abs(r.minY - 218.75) < 0.01)
        #expect(g.normalized(CGPoint(x: 500, y: 100), in: CGSize(width: 1000, height: 1000)) == nil)
        let n = g.normalized(CGPoint(x: 500, y: 500), in: CGSize(width: 1000, height: 1000))!
        #expect(abs(n.u - 0.5) < 1e-9 && abs(n.v - 0.5) < 1e-9)
    }
}

@MainActor @Suite struct KeymapEngineTests {
    final class Sink { var events: [NormTouch] = [] }

    func engine(_ controls: [KeyControl]) -> (KeymapEngine, Sink) {
        let sink = Sink()
        let e = KeymapEngine(map: Keymap(controls: controls))
        e.aspect = 1
        e.emit = { sink.events += $0 }
        return (e, sink)
    }

    @Test func tapHoldsWhileKeyIsDown() {
        var tap = KeyControl.make(.tap, at: 0.3, 0.4)
        tap.key = KeyCode.space
        let (e, sink) = engine([tap])
        #expect(e.keyDown(KeyCode.space))
        #expect(e.keyDown(KeyCode.space)) // auto-repeat is swallowed
        #expect(sink.events.count == 1 && sink.events[0].down)
        #expect(e.keyUp(KeyCode.space))
        #expect(sink.events.last?.down == false)
        #expect(!e.keyDown(KeyCode.w), "unbound keys pass through to Android")
    }

    @Test func joystickPressesCenterThenThrows() {
        let stick = KeyControl.make(.joystick, at: 0.2, 0.7)
        let (e, sink) = engine([stick])
        _ = e.keyDown(KeyCode.d)
        #expect(sink.events.first.map { $0.u == 0.2 && $0.v == 0.7 && $0.down } == true)
        let last = sink.events.last!
        #expect(abs(last.u - (0.2 + stick.radius)) < 1e-9 && abs(last.v - 0.7) < 1e-9)
        _ = e.keyDown(KeyCode.w)  // diagonal
        let diag = sink.events.last!
        #expect(diag.u > 0.2 && diag.v < 0.7)
        _ = e.keyUp(KeyCode.d)
        _ = e.keyUp(KeyCode.w)
        #expect(sink.events.last?.down == false)
    }

    @Test func aimRecentersWhenLeavingItsArea() {
        let aim = KeyControl.make(.aim, at: 0.6, 0.5)
        let fire = KeyControl.make(.fire, at: 0.9, 0.7)
        let (e, sink) = engine([aim, fire])
        _ = e.keyDown(KeyCode.grave)
        #expect(e.aimLocked)
        e.aimDelta(dx: 10, dy: 0, scale: 0.001)
        #expect(sink.events.last.map { abs($0.u - 0.61) < 1e-9 } == true)
        e.aimDelta(dx: 1000, dy: 0, scale: 0.001)  // far beyond the radius → lift and re-press at centre
        let tail = sink.events.suffix(2)
        #expect(tail.first?.down == false && tail.last?.down == true && tail.last?.u == 0.6)
        #expect(e.mouseButton(KeyCode.mouseLeft, down: true))
        #expect(sink.events.last.map { $0.u == 0.9 && $0.down } == true)
        e.releaseAll()
        #expect(!e.aimLocked)
    }

    @Test func leftClickIsNormalTouchWhenNotAiming() {
        let (e, _) = engine([KeyControl.make(.aim, at: 0.5, 0.5), KeyControl.make(.fire, at: 0.9, 0.7)])
        #expect(!e.mouseButton(KeyCode.mouseLeft, down: true))
    }
}

@Suite struct KeymapSchemeTests {
    func temp(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vex-keymap-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func legacySingleKeymapBecomesFirstScheme() throws {
        // Shape written by 0.1: a bare Keymap, controls without some later fields.
        let url = try temp(#"{"controls":[{"kind":"joystick","x":0.2,"y":0.7,"keys":[13,0,1,2]}],"showHints":true,"hintOpacity":0.5}"#)
        let profile = try #require(KeymapStore.read(url))
        #expect(profile.schemes.count == 1)
        #expect(profile.active?.name == "Scheme 1")
        let stick = try #require(profile.active?.keymap.controls.first)
        #expect(stick.kind == .joystick && stick.keys == [13, 0, 1, 2] && stick.radius == 0.07)
    }

    @Test func handWrittenSchemeImports() throws {
        let url = try temp(#"{"name":"Driving","keymap":{"controls":[{"kind":"joystick","x":0.16,"y":0.72,"keys":[13,0,1,2],"radius":0.065},{"kind":"tap","x":0.88,"y":0.8,"key":49}]}}"#)
        let scheme = try KeymapStore.importScheme(from: url)
        #expect(scheme.name == "Driving")
        #expect(scheme.keymap.controls.map(\.kind) == [.joystick, .tap])
    }

    @Test func profileRoundTripKeepsActiveScheme() throws {
        var profile = KeymapProfile.starter()
        var driving = KeymapScheme(name: "Driving")
        driving.keymap.controls = [KeyControl.make(.joystick, at: 0.15, 0.75)]
        profile.schemes.append(driving)
        profile.activeID = driving.id
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vex-profile-\(UUID().uuidString).json")
        try JSONEncoder().encode(profile).write(to: url)
        let back = try #require(KeymapStore.read(url))
        #expect(back.active?.name == "Driving")
        #expect(back.active?.keymap.controls.count == 1)
        #expect(back.nextName() == "Scheme 3")
    }
}

@Suite struct ImeFocusTests {
    @Test func focusReportsSayWhetherAKeyboardWasRequested() {
        #expect(ImeBridge.parseFocus("0") == ImeBridge.Focus())
        // A game's hidden field: focused, no keyboard asked for, so the key mapping stays on.
        #expect(ImeBridge.parseFocus("1|1|0") == ImeBridge.Focus(field: true, keyboard: false))
        // Chat opened: the game asked for a keyboard.
        #expect(ImeBridge.parseFocus("1|524289|1") == ImeBridge.Focus(field: true, keyboard: true))
        // VexIME 2 sent no keyboard flag.
        #expect(ImeBridge.parseFocus("1|1") == ImeBridge.Focus(field: true, keyboard: false))
    }
}

@Suite struct DisplayEventTests {
    @Test func resumedActivityGivesThePackage() {
        let full = "I/wm_set_resumed_activity(  639): [0,com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity,realStartActivityLocked - onActivityStateChanged]"
        #expect(ADB.resumedPackage(in: full) == "com.android.chrome")
        let short = "I/wm_set_resumed_activity(  639): [0,com.google.android.apps.nexuslauncher/.NexusLauncherActivity,resumeTopActivity]"
        #expect(ADB.resumedPackage(in: short) == "com.google.android.apps.nexuslauncher")
        // Android 10 named the event am_set_resumed_activity.
        #expect(ADB.resumedPackage(in: "I/am_set_resumed_activity( 512): [0,com.example.game/.Main,resume]") == "com.example.game")
    }

    @Test func otherEventsAreIgnored() {
        #expect(ADB.resumedPackage(in: "I/configuration_changed(  639): 536872064") == nil)
        #expect(ADB.resumedPackage(in: "--------- beginning of events") == nil)
    }
}

@Suite struct EvdevTests {
    @Test func everyLetterAndTheZeroCodeKeyMap() {
        #expect(EvdevKeys.code(forMac: 0x00) == 30)   // A: key code 0 used to be dropped as "unset"
        #expect(EvdevKeys.code(forMac: 0x31) == 57)   // Space
        #expect(EvdevKeys.code(forMac: 0x24) == 28)   // Return
        #expect(EvdevKeys.code(forMac: 0x33) == 14)   // Backspace
        // All 26 ANSI letters map to distinct evdev codes.
        let letters: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        let codes = Set(letters.compactMap(EvdevKeys.code(forMac:)))
        #expect(codes.count == 26)
    }
}

@Suite struct ConfigTests {
    @Test func instancesSavedBeforeLiteStillLoad() throws {
        var c = InstanceConfig(id: "vex_0", name: "Old", imagePath: "system-images;android-36;google_apis_playstore;arm64-v8a")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        json.removeValue(forKey: "lite")
        let old = try JSONDecoder().decode(InstanceConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.isLite)

        c.lite = true
        let lite = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(c))
        #expect(lite.isLite)
        #expect(InstanceConfig.defaultLiteRAM < InstanceConfig.defaultRAM)
    }

    @Test func minimalEditionIsLiteToo() throws {
        var c = InstanceConfig(id: "vex_0", name: "Game", imagePath: "system-images;android-36;google_apis;arm64-v8a")
        #expect(c.edition == .full)
        c.edition = .minimal
        let minimal = try JSONDecoder().decode(InstanceConfig.self, from: JSONEncoder().encode(c))
        #expect(minimal.edition == .minimal && minimal.isLite)
        // A build without Minimal reads only `lite`, so it still applies the Lite list.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        #expect(json["lite"] as? Bool == true)
        c.edition = .lite
        #expect(c.edition == .lite && c.minimal == nil)
        c.edition = .full
        #expect(c.lite == nil && c.minimal == nil)

        #expect(InstanceConfig.defaultMinimalRAM <= InstanceConfig.defaultLiteRAM)
        #expect(InstanceConfig.defaultRAM(for: .minimal) == InstanceConfig.defaultMinimalRAM)
        #expect(InstanceConfig.gigabytes(3072) == "3")
        #expect(["2.5", "2,5"].contains(InstanceConfig.gigabytes(2560)))

        let minimalList = Set(LiteEdition.minimalPackages)
        #expect(minimalList.isSuperset(of: LiteEdition.disabledPackages))
        #expect(minimalList.count == LiteEdition.minimalPackages.count, "duplicate package")
        // What a game and a browser need stays.
        for kept in ["com.android.chrome", "com.google.android.webview", "com.google.android.packageinstaller",
                     "com.google.android.documentsui", "com.android.providers.downloads", ImeBridge.package] {
            #expect(!minimalList.contains(kept), "\(kept)")
        }
    }

    @Test func configIniHasPerformanceKeys() {
        let c = InstanceConfig(id: "vex_0", name: "Test", imagePath: "system-images;android-36;google_apis_playstore;arm64-v8a",
                               cpuCores: 4, ramMB: 4096, width: 1920, height: 1080, dpi: 280)
        let ini = c.configIni()
        for line in ["image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/", "hw.cpu.ncore=4",
                     "hw.ramSize=4096", "hw.gpu.mode=host", "PlayStore.enabled=true", "hw.initialOrientation=landscape",
                     "hw.lcd.width=1920", "hw.lcd.height=1080", "hw.keyboard=yes",
                     "fastboot.forceFastBoot=yes"] {
            #expect(ini.contains(line + "\n"), "\(line)")
        }
        #expect(c.platform == "android-36")
        #expect(c.gpuMode == .angleVulkan)
        #expect(c.gpuMode.features == ["GuestAngle", "VulkanSnapshots", "-HostComposition", "-VulkanQueueSubmitWithCommands"])
        #expect(c.avdIniContents().contains("target=android-36"))
        #expect(c.apiLevel == 36 && c.effectiveGPUMode == .angleVulkan)
    }

    @Test func oldImagesFallBackToOpenGL() {
        func config(_ platform: String, _ mode: GPUMode = .angleVulkan) -> InstanceConfig {
            var c = InstanceConfig(id: "vex_0", name: "Test", imagePath: "system-images;\(platform);google_apis;arm64-v8a")
            c.gpuMode = mode
            return c
        }
        #expect(config("android-33").apiLevel == 33)
        #expect(config("android-36.1").apiLevel == 36)
        #expect(config("android-33").effectiveGPUMode == .host)
        #expect(config("android-30").effectiveGPUMode == .host)
        #expect(config("android-34").effectiveGPUMode == .host)
        #expect(config("android-33", .swiftshader).effectiveGPUMode == .swiftshader)
        #expect(config("android-\(GPUMode.minGuestAngleAPI)").effectiveGPUMode == .angleVulkan)
        #expect(config("android-37").effectiveGPUMode == .angleVulkan)
    }

    @Test func revisionsCompareNumerically() {
        #expect(SDKRepository.compareRevision("37.2.13", "37.2.9") == 1)
        #expect(SDKRepository.compareRevision("9", "10") == -1)
        #expect(SDKRepository.compareRevision("36.1", "36.1.0") == 0)
    }

    @Test func androidVersionNames() {
        func pkg(_ api: String, _ tag: String) -> SDKPackage {
            SDKPackage(path: "system-images;android-\(api);\(tag);arm64-v8a", displayName: "", revision: "1", licenseID: "",
                       archiveURL: URL(string: "https://x")!, size: 0, sha1: "", apiString: api, tagID: tag, tagDisplay: "Google Play")
        }
        #expect(pkg("36", "google_apis_playstore").androidVersionName == "Android 16")
        #expect(pkg("36.1", "google_apis").androidVersionName == "Android 16 (API 36.1)")
        #expect(pkg("37.0", "google_apis").androidVersionName == "Android 17")
        #expect(pkg("35", "google_apis").supportsRoot)
        #expect(!pkg("35", "google_apis_playstore").supportsRoot)
    }
}

/// Hits dl.google.com; skipped when offline.
@Suite struct CatalogTests {
    @Test func liveCatalogHasArm64ImagesAndEmulator() async throws {
        guard let catalog = try? await SDKRepository.fetchCatalog() else { return }
        let emu = try #require(catalog.emulator)
        #expect(emu.archiveURL.lastPathComponent.contains("darwin_aarch64"))
        #expect(catalog.platformTools?.archiveURL.lastPathComponent.contains("darwin") == true)
        #expect(catalog.systemImages.allSatisfy { $0.path.hasSuffix(";arm64-v8a") && $0.apiMajor >= 30 })
        #expect(catalog.systemImages.contains { $0.hasPlayStore && $0.apiMajor >= 36 })
        #expect(catalog.recommendedImage?.apiString == "36")
        #expect(catalog.licenses[emu.licenseID] != nil)
    }
}
