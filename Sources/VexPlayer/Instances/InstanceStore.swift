import Darwin
import Foundation
import Observation

enum InstanceError: LocalizedError {
    case running, imageMissing(String)
    var errorDescription: String? {
        switch self {
        case .running: return "Сначала остановите инстанс"
        case .imageMissing(let p): return "Образ не установлен: \(p)"
        }
    }
}

/// Owns the list of instances (AVDs) and their live sessions.
@MainActor @Observable
final class InstanceStore {
    static let shared = InstanceStore()

    private(set) var instances: [InstanceConfig] = []
    private(set) var sessions: [String: InstanceSession] = [:]

    init() { reload() }

    func reload() {
        AppPaths.ensure()
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.avdHome, includingPropertiesForKeys: nil)) ?? []
        instances = dirs
            .filter { $0.pathExtension == "avd" }
            .compactMap { try? JSONDecoder().decode(InstanceConfig.self, from: Data(contentsOf: $0.appendingPathComponent("vex.json"))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func session(for config: InstanceConfig) -> InstanceSession {
        if let s = sessions[config.id] { return s }
        let s = InstanceSession(config: config)
        sessions[config.id] = s
        return s
    }

    func isRunning(_ id: String) -> Bool { sessions[id]?.state.isAlive ?? false }

    // MARK: CRUD

    func nextID() -> String {
        let used = Set(instances.map(\.id))
        var n = 0
        while used.contains("vex_\(n)") { n += 1 }
        return "vex_\(n)"
    }

    func nextName() -> String {
        let used = Set(instances.map(\.name))
        var n = instances.count
        while used.contains(n == 0 ? "VexPlayer" : "VexPlayer-\(n)") { n += 1 }
        return n == 0 ? "VexPlayer" : "VexPlayer-\(n)"
    }

    @discardableResult
    func create(_ config: InstanceConfig) throws -> InstanceConfig {
        let image = AppPaths.sdk.appendingPathComponent(config.imageDirRelative)
        guard image.fileExists else { throw InstanceError.imageMissing(config.imagePath) }
        try FileManager.default.createDirectory(at: config.avdDir, withIntermediateDirectories: true)
        try write(config)
        reload()
        return config
    }

    func update(_ config: InstanceConfig) throws {
        guard !isRunning(config.id) else { throw InstanceError.running }
        try write(config)
        sessions[config.id]?.config = config
        reload()
    }

    func delete(_ id: String) throws {
        guard !isRunning(id) else { throw InstanceError.running }
        guard let config = instances.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: config.avdIni)
        try FileManager.default.removeItem(at: config.avdDir)
        sessions[id] = nil
        reload()
    }

    /// Wipe user data: next boot is a factory-fresh device.
    func wipeData(_ id: String) throws {
        guard !isRunning(id), let config = instances.first(where: { $0.id == id }) else { throw InstanceError.running }
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: config.avdDir.path)) ?? [] where item != "vex.json" && item != "config.ini" {
            try? fm.removeItem(at: config.avdDir.appendingPathComponent(item))
        }
    }

    /// APFS copy-on-write clone: a 10 GB instance clones instantly and takes no extra space until it diverges.
    func clone(_ id: String, name: String) throws -> InstanceConfig {
        guard !isRunning(id) else { throw InstanceError.running }
        guard let source = instances.first(where: { $0.id == id }) else { throw InstanceError.imageMissing(id) }
        var copy = source
        copy.id = nextID()
        copy.name = name
        copy.createdAt = Date()

        let fm = FileManager.default
        if clonefile(source.avdDir.path, copy.avdDir.path, 0) != 0 {
            try fm.copyItem(at: source.avdDir, to: copy.avdDir)
        }
        // Per-run state that must not leak into the clone.
        for item in (try? fm.contentsOfDirectory(atPath: copy.avdDir.path)) ?? []
        where item.hasSuffix(".lock") || item == "hardware-qemu.ini" || item == "emu-launch-params.txt" {
            try? fm.removeItem(at: copy.avdDir.appendingPathComponent(item))
        }
        try rebaseOverlays(in: copy.avdDir, from: source.avdDir)
        try write(copy)
        reload()
        return copy
    }

    /// qcow2 overlays store absolute backing-file paths; point the clone's overlays at its own base images.
    private func rebaseOverlays(in dir: URL, from oldDir: URL) throws {
        guard AppPaths.qemuImg.fileExists else { return }
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where item.hasSuffix(".qcow2") {
            let file = dir.appendingPathComponent(item)
            guard let json = try? runTool(AppPaths.qemuImg.path, ["info", "--output=json", file.path]),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let backing = obj["backing-filename"] as? String,
                  backing.hasPrefix(oldDir.path) else { continue }
            let newBacking = dir.path + backing.dropFirst(oldDir.path.count)
            try runTool(AppPaths.qemuImg.path, ["rebase", "-u", "-f", "qcow2", "-b", newBacking, "-F", "raw", file.path])
        }
    }

    private func write(_ config: InstanceConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: config.metadataFile, options: .atomic)
        try config.configIni().write(to: config.avdDir.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        try config.avdIniContents().write(to: config.avdIni, atomically: true, encoding: .utf8)
    }
}
