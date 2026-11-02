import CryptoKit
import Foundation
import Observation

struct InstallProgress: Sendable {
    enum Phase: Sendable { case queued, downloading, verifying, extracting, done, failed(String) }
    var phase: Phase = .queued
    var received: Int64 = 0
    var total: Int64 = 0
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    var label: String {
        switch phase {
        case .queued: return String(localized: "Queued")
        case .downloading: return String(localized: "Downloading \(formatBytes(received)) of \(formatBytes(total))")
        case .verifying: return String(localized: "Verifying SHA-1…")
        case .extracting: return String(localized: "Unpacking…")
        case .done: return String(localized: "Installed")
        case .failed(let e): return String(localized: "Error: \(e)")
        }
    }
    var isActive: Bool {
        switch phase { case .queued, .downloading, .verifying, .extracting: return true; default: return false }
    }
}

enum SDKInstallError: LocalizedError {
    case checksum, emptyArchive, http(Int)
    var errorDescription: String? {
        switch self {
        case .checksum: return String(localized: "Checksum mismatch: the file is damaged")
        case .emptyArchive: return String(localized: "The archive is empty")
        case .http(let c): return "HTTP \(c)"
        }
    }
}

/// Downloads and installs SDK components (emulator, platform-tools, system images).
@MainActor @Observable
final class SDKManager {
    static let shared = SDKManager()

    var catalog: SDKCatalog?
    var isLoadingCatalog = false
    var catalogError: String?
    var progress: [String: InstallProgress] = [:]
    /// Bumped after every install/uninstall so views re-read disk state.
    var revision = 0

    private var downloaders: [String: FileDownloader] = [:]

    var emulatorInstalled: Bool { _ = revision; return AppPaths.emulatorBinary.fileExists }
    var adbInstalled: Bool { _ = revision; return AppPaths.adbBinary.fileExists }
    var isReady: Bool { emulatorInstalled && adbInstalled && !installedImages.isEmpty }

    var emulatorVersion: String? {
        _ = revision
        return Self.readProperties(AppPaths.emulatorDir.appendingPathComponent("source.properties"))["Pkg.Revision"]
    }

    func refreshCatalog() async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }
        do {
            catalog = try await SDKRepository.fetchCatalog()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    // MARK: Installed state

    /// Images present on disk (works offline).
    var installedImages: [SDKPackage] {
        _ = revision
        let root = AppPaths.sdk.appendingPathComponent("system-images")
        let fm = FileManager.default
        var out: [SDKPackage] = []
        for platform in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            for tag in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(platform).path)) ?? [] {
                let dir = root.appendingPathComponent(platform).appendingPathComponent(tag).appendingPathComponent("arm64-v8a")
                let props = Self.readProperties(dir.appendingPathComponent("source.properties"))
                guard !props.isEmpty else { continue }
                out.append(SDKPackage(
                    path: "system-images;\(platform);\(tag);arm64-v8a",
                    displayName: props["Pkg.Desc"] ?? platform,
                    revision: props["Pkg.Revision"] ?? "",
                    licenseID: "", archiveURL: dir, size: 0, sha1: "",
                    apiString: platform.replacingOccurrences(of: "android-", with: ""),
                    tagID: tag,
                    tagDisplay: props["SystemImage.TagDisplay"] ?? tag
                ))
            }
        }
        return out.sorted { (Double($0.apiString ?? "0") ?? 0) > (Double($1.apiString ?? "0") ?? 0) }
    }

    func image(forPath path: String) -> SDKPackage? {
        installedImages.first { $0.path == path } ?? catalog?.systemImages.first { $0.path == path }
    }

    // MARK: Licenses

    func isLicenseAccepted(_ id: String) -> Bool {
        AppPaths.sdk.appendingPathComponent("licenses/\(id)").fileExists
    }

    func acceptLicenses(_ ids: Set<String>) {
        let dir = AppPaths.sdk.appendingPathComponent("licenses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for id in ids {
            let text = catalog?.licenses[id]?.text ?? id
            let hash = Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            try? ("\n" + hash).write(to: dir.appendingPathComponent(id), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Install

    func install(_ packages: [SDKPackage]) async throws {
        for p in packages where !p.isInstalled { progress[p.path] = InstallProgress() }
        for p in packages where !p.isInstalled {
            do {
                try await install(p)
                progress[p.path]?.phase = .done
            } catch {
                progress[p.path]?.phase = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    func cancelAll() {
        downloaders.values.forEach { $0.cancel() }
        downloaders.removeAll()
    }

    private func install(_ p: SDKPackage) async throws {
        AppPaths.ensure()
        let zip = AppPaths.downloads.appendingPathComponent(p.archiveURL.lastPathComponent)

        if !(zip.fileExists && (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) == p.size }) == true) {
            progress[p.path]?.phase = .downloading
            progress[p.path]?.total = p.size
            let downloader = FileDownloader(url: p.archiveURL, destination: zip) { [weak self] received, total in
                Task { @MainActor in
                    self?.progress[p.path]?.received = received
                    if total > 0 { self?.progress[p.path]?.total = total }
                }
            }
            downloaders[p.path] = downloader
            defer { downloaders[p.path] = nil }
            try await downloader.start()
        }

        progress[p.path]?.phase = .verifying
        let ok = try await Task.detached(priority: .userInitiated) { try Self.sha1(of: zip) == p.sha1.lowercased() }.value
        guard ok else {
            try? FileManager.default.removeItem(at: zip)
            throw SDKInstallError.checksum
        }

        progress[p.path]?.phase = .extracting
        try await Task.detached(priority: .userInitiated) { try Self.extract(zip: zip, into: p.installDir) }.value
        try? FileManager.default.removeItem(at: zip)
        revision += 1
    }

    func uninstall(_ p: SDKPackage) throws {
        try FileManager.default.removeItem(at: p.installDir)
        revision += 1
    }

    // MARK: Helpers

    nonisolated static func sha1(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips into a temp dir and moves the archive's single top-level folder into place.
    nonisolated static func extract(zip: URL, into target: URL) throws {
        let fm = FileManager.default
        let tmp = AppPaths.downloads.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try runTool("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", tmp.path])

        let items = try fm.contentsOfDirectory(atPath: tmp.path).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard !items.isEmpty else { throw SDKInstallError.emptyArchive }
        let source = items.count == 1 ? tmp.appendingPathComponent(items[0]) : tmp

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: source, to: target)
    }

    nonisolated static func readProperties(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].hasPrefix("#") { out[parts[0]] = parts[1] }
        }
        return out
    }
}

/// Runs a command-line tool synchronously and throws on non-zero exit.
@discardableResult
func runTool(_ path: String, _ args: [String], env: [String: String]? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "VexPlayer", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent): \(out.suffix(400))"])
    }
    return out
}

/// URLSession download with progress callbacks, resumable after a network drop.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var resumeData: Data?
    private var retries = 0

    init(url: URL, destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.onProgress = onProgress
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                task = session.downloadTask(with: url)
                task?.resume()
            }
        } onCancel: { [weak self] in self?.cancel() }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = SDKInstallError.http(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code != .cancelled,
           let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, retries < 5 {
            retries += 1
            self.task = session.downloadTask(withResumeData: data)
            self.task?.resume()
            return
        }
        let result = error ?? moveError
        session.finishTasksAndInvalidate()
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
}
