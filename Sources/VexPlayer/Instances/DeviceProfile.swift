import Foundation

/// A phone identity for the "Device model" setting (like MuMu's phone model picker).
/// It rewrites the build properties apps read through android.os.Build (MODEL, BRAND, FINGERPRINT…).
struct DeviceProfile: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let manufacturer: String
    let brand: String
    let model: String
    let device: String
    let name: String
    let board: String
    let incremental: String

    static let all: [DeviceProfile] = [
        .init(id: "galaxy_s24_ultra", title: "Samsung Galaxy S24 Ultra", manufacturer: "samsung", brand: "samsung",
              model: "SM-S928B", device: "e3q", name: "e3qxeea", board: "pineapple", incremental: "S928BXXS4AYB1"),
        .init(id: "galaxy_a55", title: "Samsung Galaxy A55", manufacturer: "samsung", brand: "samsung",
              model: "SM-A556B", device: "a55x", name: "a55xnsxx", board: "s5e8845", incremental: "A556BXXS3AYB2"),
        .init(id: "xiaomi_14", title: "Xiaomi 14", manufacturer: "Xiaomi", brand: "Xiaomi",
              model: "23127PN0CG", device: "houji", name: "houji_global", board: "houji", incremental: "OS2.0.6.0.VNCMIXM"),
        .init(id: "redmi_note_13_pro", title: "Redmi Note 13 Pro", manufacturer: "Xiaomi", brand: "Redmi",
              model: "23117RA68G", device: "garnet", name: "garnet_global", board: "garnet", incremental: "OS2.0.3.0.VNRMIXM"),
        .init(id: "oneplus_12", title: "OnePlus 12", manufacturer: "OnePlus", brand: "OnePlus",
              model: "CPH2581", device: "OP595DL1", name: "CPH2581EEA", board: "pineapple", incremental: "V.1e64d55-1b2f5c"),
        .init(id: "rog_phone_8", title: "ASUS ROG Phone 8", manufacturer: "asus", brand: "asus",
              model: "ASUS_AI2401_A", device: "ASUS_AI2401", name: "WW_AI2401", board: "pineapple", incremental: "35.1810.1810.231"),
        .init(id: "pixel_8_pro", title: "Google Pixel 8 Pro", manufacturer: "Google", brand: "google",
              model: "Pixel 8 Pro", device: "husky", name: "husky", board: "husky", incremental: "13557381"),
    ]

    static func find(_ id: String?) -> DeviceProfile? { all.first { $0.id == id } }

    /// Bump when the property set below changes, so existing instances get re-applied.
    static let schemaVersion = 1

    func fingerprint(release: String, buildID: String) -> String {
        "\(brand)/\(name)/\(device):\(release)/\(buildID)/\(incremental):user/release-keys"
    }

    /// Lines appended to every build.prop. Later partitions override earlier ones, and
    /// ro.product.<partition>.* feed the derived ro.product.*, so every variant is set.
    func buildProps(release: String, buildID: String) -> [String] {
        let fp = fingerprint(release: release, buildID: buildID)
        var lines = [
            "ro.product.model=\(model)",
            "ro.product.brand=\(brand)",
            "ro.product.manufacturer=\(manufacturer)",
            "ro.product.device=\(device)",
            "ro.product.name=\(name)",
            "ro.product.board=\(board)",
            "ro.build.product=\(device)",
            "ro.build.fingerprint=\(fp)",
            "ro.build.description=\(name)-user \(release) \(buildID) \(incremental) release-keys",
        ]
        for part in ["system", "system_ext", "vendor", "product", "odm", "vendor_dlkm", "odm_dlkm", "bootimage"] {
            lines += [
                "ro.product.\(part).model=\(model)",
                "ro.product.\(part).brand=\(brand)",
                "ro.product.\(part).manufacturer=\(manufacturer)",
                "ro.product.\(part).device=\(device)",
                "ro.product.\(part).name=\(name)",
                "ro.\(part).build.fingerprint=\(fp)",
            ]
        }
        return lines
    }

    var marker: String { "\(id)@\(Self.schemaVersion)" }
}
