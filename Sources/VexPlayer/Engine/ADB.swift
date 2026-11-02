import Foundation

/// adb from our own platform-tools, talking to our own adb server port.
struct ADB: Sendable {
    let serial: String

    @discardableResult
    func run(_ args: [String]) async throws -> String {
        let serial = serial
        return try await Task.detached(priority: .userInitiated) {
            try runTool(AppPaths.adbBinary.path, ["-s", serial] + args, env: AppPaths.sdkEnvironment())
        }.value
    }

    @discardableResult
    func shell(_ command: String) async throws -> String {
        try await run(["shell", command])
    }

    func waitForDevice() async throws {
        try await run(["wait-for-device"])
    }

    func root() async throws {
        try await run(["root"])
        try await run(["wait-for-device"])
    }

    func push(_ local: URL, to remote: String) async throws {
        try await run(["push", local.path, remote])
    }

    /// .apk, .apks / .xapk (split APK bundles, optional OBB data).
    func install(_ file: URL) async throws -> String {
        switch file.pathExtension.lowercased() {
        case "apk":
            return try await run(["install", "-r", "-g", "-t", file.path])
        case "apks", "xapk", "apkm":
            return try await installBundle(file)
        default:
            throw NSError(domain: "VexPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Неизвестный формат: \(file.lastPathComponent)"])
        }
    }

    private func installBundle(_ file: URL) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vex-xapk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try runTool("/usr/bin/unzip", ["-q", "-o", file.path, "-d", tmp.path])

        let apks = (FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "apk" }
        guard !apks.isEmpty else { throw NSError(domain: "VexPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "В архиве нет APK"]) }
        let out = try await run(["install-multiple", "-r", "-g", "-t"] + apks.map(\.path))

        // XAPK keeps game data in Android/obb/<package>/…
        let obb = tmp.appendingPathComponent("Android/obb", isDirectory: true)
        if obb.fileExists {
            for pkg in (try? FileManager.default.contentsOfDirectory(atPath: obb.path)) ?? [] {
                try await run(["push", obb.appendingPathComponent(pkg).path, "/sdcard/Android/obb/"])
            }
        }
        return out
    }

    /// Copies any file into Download and lets the media scanner index it.
    func sendFile(_ file: URL) async throws {
        let remote = "/sdcard/Download/\(file.lastPathComponent)"
        try await push(file, to: remote)
        _ = try? await shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(remote)'")
    }

    /// Display rotation (0…3, Surface.ROTATION_*) and the foreground package in one round trip.
    func displayState() async -> (rotation: Int?, package: String?) {
        // Not `dumpsys input`: it lists viewports in no fixed order, inactive ones (orientation=0) included.
        // `; true` keeps adb's exit status 0 when a grep finds nothing mid-transition.
        let cmd = "dumpsys display 2>/dev/null | grep -m1 -oE 'mCurrentOrientation=[0-9]'; " +
                  "dumpsys activity activities 2>/dev/null | grep -m1 -E 'topResumedActivity|mResumedActivity'; true"
        guard let out = try? await shell(cmd) else { return (nil, nil) }
        var rotation: Int?
        if let r = out.range(of: #"mCurrentOrientation=\d"#, options: .regularExpression) {
            rotation = Int(String(out[r].last!))
        }
        var package: String?
        if let r = out.range(of: #"u\d+ ([A-Za-z0-9_.]+)/"#, options: .regularExpression) {
            package = String(out[r]).split(separator: " ").last.map { String($0.dropLast()) }
        }
        return (rotation, package)
    }

    static func startServer() async {
        _ = try? await Task.detached {
            try runTool(AppPaths.adbBinary.path, ["start-server"], env: AppPaths.sdkEnvironment())
        }.value
    }

    static func killServer() {
        guard AppPaths.adbBinary.fileExists else { return }
        _ = try? runTool(AppPaths.adbBinary.path, ["kill-server"], env: AppPaths.sdkEnvironment())
    }
}
