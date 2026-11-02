import Foundation

/// One installable package from Google's Android SDK repository.
struct SDKPackage: Identifiable, Hashable, Codable, Sendable {
    var id: String { path }
    let path: String              // "emulator" | "platform-tools" | "system-images;android-36;google_apis_playstore;arm64-v8a"
    let displayName: String
    let revision: String
    let licenseID: String
    let archiveURL: URL
    let size: Int64
    let sha1: String

    // System image details
    let apiString: String?        // "36", "36.1", "37.0"
    let tagID: String?            // "google_apis_playstore" | "google_apis"
    let tagDisplay: String?

    var isSystemImage: Bool { path.hasPrefix("system-images;") }

    /// Directory inside the SDK root, e.g. system-images/android-36/google_apis_playstore/arm64-v8a
    var installDir: URL {
        path.split(separator: ";").reduce(AppPaths.sdk) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    var isInstalled: Bool {
        installDir.appendingPathComponent("source.properties").fileExists
            || installDir.appendingPathComponent("package.xml").fileExists
    }

    var hasPlayStore: Bool { tagID == "google_apis_playstore" }
    /// Google APIs images are userdebug builds: `adb root` works there.
    var supportsRoot: Bool { tagID == "google_apis" || tagID == "default" }

    var apiMajor: Int { Int(apiString?.split(separator: ".").first ?? "") ?? 0 }

    var androidVersionName: String {
        guard let api = apiString else { return displayName }
        let names: [Int: String] = [
            28: "9", 29: "10", 30: "11", 31: "12", 32: "12L", 33: "13",
            34: "14", 35: "15", 36: "16", 37: "17", 38: "18",
        ]
        var name = "Android " + (names[apiMajor] ?? "API \(api)")
        if let minor = api.split(separator: ".").dropFirst().first, minor != "0" { name += " (API \(api))" }
        return name
    }

    var title: String {
        guard isSystemImage else { return displayName }
        return "\(androidVersionName) · \(tagDisplay ?? "")"
    }
}

struct SDKLicense: Hashable, Sendable {
    let id: String
    let text: String
}

struct SDKCatalog: Sendable {
    var emulator: SDKPackage?
    var platformTools: SDKPackage?
    var systemImages: [SDKPackage]
    var licenses: [String: SDKLicense]

    /// The image we suggest on first run: newest stable Android with Google Play.
    var recommendedImage: SDKPackage? {
        systemImages.first { $0.hasPlayStore && $0.apiString == "36" }
            ?? systemImages.first { $0.hasPlayStore }
    }
}

enum SDKRepositoryError: LocalizedError {
    case badManifest(String)
    var errorDescription: String? {
        switch self {
        case .badManifest(let s): return String(localized: "Couldn't parse the SDK manifest: \(s)")
        }
    }
}

/// Reads Google's repository manifests (the same ones sdkmanager uses).
enum SDKRepository {
    static let base = URL(string: "https://dl.google.com/android/repository/")!
    static let imageTags = ["google_apis_playstore", "google_apis"]

    static func fetchCatalog() async throws -> SDKCatalog {
        async let toolsDoc = loadManifest(base, names: ["repository2-3.xml", "repository2-1.xml"])
        var imageDocs: [(XMLDocument, URL)] = []
        for tag in imageTags {
            let dir = base.appendingPathComponent("sys-img/\(tag)/", isDirectory: true)
            if let doc = try? await loadManifest(dir, names: ["sys-img2-3.xml", "sys-img2-1.xml"]) {
                imageDocs.append((doc, dir))
            }
        }
        let tools = try await toolsDoc

        var licenses: [String: SDKLicense] = [:]
        for doc in [tools] + imageDocs.map(\.0) {
            for node in (try? doc.nodes(forXPath: "//license")) ?? [] {
                guard let el = node as? XMLElement, let id = el.attribute(forName: "id")?.stringValue else { continue }
                licenses[id] = SDKLicense(id: id, text: el.stringValue ?? "")
            }
        }

        let toolPackages = parsePackages(tools, baseURL: base)
        let emulator = newest(toolPackages.filter { $0.path == "emulator" })
        let platformTools = newest(toolPackages.filter { $0.path == "platform-tools" })

        var images: [SDKPackage] = []
        for (doc, dir) in imageDocs {
            images += parsePackages(doc, baseURL: dir).filter(isUsefulImage)
        }
        // Keep one (newest) revision per path, newest Android first, Play Store before plain.
        var byPath: [String: SDKPackage] = [:]
        for img in images {
            if let old = byPath[img.path], compareRevision(old.revision, img.revision) >= 0 { continue }
            byPath[img.path] = img
        }
        let sorted = byPath.values.sorted {
            let a = Double($0.apiString ?? "0") ?? 0, b = Double($1.apiString ?? "0") ?? 0
            if a != b { return a > b }
            return ($0.hasPlayStore ? 0 : 1) < ($1.hasPlayStore ? 0 : 1)
        }
        return SDKCatalog(emulator: emulator, platformTools: platformTools, systemImages: sorted, licenses: licenses)
    }

    private static func loadManifest(_ dir: URL, names: [String]) async throws -> XMLDocument {
        var lastError: Error = SDKRepositoryError.badManifest(dir.absoluteString)
        for name in names {
            do {
                let (data, response) = try await URLSession.shared.data(from: dir.appendingPathComponent(name))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                return try XMLDocument(data: data)
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Stable arm64 images from Android 11 up; skips betas, canaries, SDK-extension and 16k-page variants.
    private static func isUsefulImage(_ p: SDKPackage) -> Bool {
        let parts = p.path.split(separator: ";").map(String.init)
        guard parts.count == 4, parts[3] == "arm64-v8a", imageTags.contains(parts[2]) else { return false }
        let version = parts[1].replacingOccurrences(of: "android-", with: "")
        guard version.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return p.apiMajor >= 30
    }

    private static func newest(_ list: [SDKPackage]) -> SDKPackage? {
        list.max { compareRevision($0.revision, $1.revision) < 0 }
    }

    static func compareRevision(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func parsePackages(_ doc: XMLDocument, baseURL: URL) -> [SDKPackage] {
        guard let nodes = try? doc.nodes(forXPath: "//remotePackage") else { return [] }
        var out: [SDKPackage] = []
        for case let el as XMLElement in nodes {
            guard let path = el.attribute(forName: "path")?.stringValue else { continue }
            // Only the stable channel.
            let channel = text(el, "channelRef/@ref") ?? "channel-0"
            guard channel == "channel-0" else { continue }

            let revision = ["major", "minor", "micro"].compactMap { text(el, "revision/\($0)") }.joined(separator: ".")
            guard let archive = pickArchive(el) else { continue }

            var api: String?
            if path.hasPrefix("system-images;") {
                let v = path.split(separator: ";")[1].replacingOccurrences(of: "android-", with: "")
                api = v
            }
            out.append(SDKPackage(
                path: path,
                displayName: text(el, "display-name") ?? path,
                revision: revision,
                licenseID: text(el, "uses-license/@ref") ?? "android-sdk-license",
                archiveURL: URL(string: archive.url, relativeTo: baseURL)!.absoluteURL,
                size: archive.size,
                sha1: archive.sha1,
                apiString: api,
                tagID: text(el, "type-details/tag/id"),
                tagDisplay: text(el, "type-details/tag/display")
            ))
        }
        return out
    }

    private static func pickArchive(_ el: XMLElement) -> (url: String, size: Int64, sha1: String)? {
        guard let archives = try? el.nodes(forXPath: "archives/archive") else { return nil }
        for case let a as XMLElement in archives {
            let os = text(a, "host-os")
            let arch = text(a, "host-arch")
            if let os, os != "macosx" { continue }
            if let arch, arch != "aarch64" { continue }
            guard let url = text(a, "complete/url"),
                  let size = Int64(text(a, "complete/size") ?? ""),
                  let sha1 = text(a, "complete/checksum") else { continue }
            return (url, size, sha1)
        }
        return nil
    }

    private static func text(_ el: XMLElement, _ xpath: String) -> String? {
        (try? el.nodes(forXPath: xpath))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
