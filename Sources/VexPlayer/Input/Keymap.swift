import Foundation

/// Key codes: macOS virtual key codes, plus synthetic codes for mouse and gamepad buttons.
enum KeyCode {
    static let mouseLeft = 1001
    static let mouseRight = 1002
    static let mouseMiddle = 1003
    static let gamepadBase = 2000   // + GamepadButton.rawValue

    static let w = 0x0D, a = 0x00, s = 0x01, d = 0x02
    static let space = 0x31, grave = 0x32, escape = 0x35, tab = 0x30
    static let leftShift = 0x38, leftControl = 0x3B, leftOption = 0x3A, command = 0x37, rightCommand = 0x36
    static let returnKey = 0x24

    static func name(_ code: Int) -> String {
        if code >= gamepadBase, let b = GamepadButton(rawValue: code - gamepadBase) { return b.label }
        return names[code] ?? "#\(code)"
    }

    private static let names: [Int: String] = {
        var n: [Int: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
            0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
            0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
            0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "Tab",
            0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "Esc", 0x37: "⌘", 0x38: "⇧", 0x39: "Caps",
            0x3A: "⌥", 0x3B: "⌃", 0x3C: "R⇧", 0x3D: "R⌥", 0x3E: "R⌃", 0x36: "R⌘",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "Home", 0x77: "End", 0x74: "PgUp", 0x79: "PgDn",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
            0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x52: "Num0", 0x53: "Num1", 0x54: "Num2", 0x55: "Num3", 0x56: "Num4", 0x57: "Num5",
            0x58: "Num6", 0x59: "Num7", 0x5B: "Num8", 0x5C: "Num9",
        ]
        n[mouseLeft] = String(localized: "LMB")
        n[mouseRight] = String(localized: "RMB")
        n[mouseMiddle] = String(localized: "MMB")
        return n
    }()
}

enum GamepadButton: Int, CaseIterable, Sendable {
    case a, b, x, y, leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight, menu, options, leftThumb, rightThumb
    var label: String {
        ["Ⓐ", "Ⓑ", "Ⓧ", "Ⓨ", "LB", "RB", "LT", "RT", "D↑", "D↓", "D←", "D→", "☰", "⧉", "L3", "R3"][rawValue]
    }
}

enum KeyControlKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case tap        // hold key = hold finger
    case repeatTap  // rapid taps while held
    case joystick   // WASD → virtual stick
    case aim        // locks the cursor; mouse moves a finger (camera / look)
    case fire       // left click while aiming
    case swipe      // key → swipe from point to point
    case skill      // MOBA smart-cast: drag the skill towards the cursor, release on key up

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tap: return String(localized: "Tap")
        case .repeatTap: return String(localized: "Auto-tap")
        case .joystick: return String(localized: "Joystick")
        case .aim: return String(localized: "Mouse look")
        case .fire: return String(localized: "Fire")
        case .swipe: return String(localized: "Swipe")
        case .skill: return String(localized: "Skill")
        }
    }
    var symbol: String {
        switch self {
        case .tap: return "hand.tap"
        case .repeatTap: return "repeat"
        case .joystick: return "dpad"
        case .aim: return "scope"
        case .fire: return "flame"
        case .swipe: return "hand.draw"
        case .skill: return "sparkles"
        }
    }
}

/// One on-screen control. Positions are normalized (0…1) in the upright picture.
struct KeyControl: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: KeyControlKind
    var x: Double
    var y: Double
    var key: Int?
    /// Joystick: up, left, down, right.
    var keys: [Int] = []
    /// Fraction of the picture width (joystick throw, skill drag, aim recenter radius).
    var radius: Double = 0.07
    var x2: Double = 0.5
    var y2: Double = 0.5
    var sensitivity: Double = 1.0
    var intervalMS: Int = 60

    static func make(_ kind: KeyControlKind, at x: Double, _ y: Double) -> KeyControl {
        var c = KeyControl(kind: kind, x: x, y: y)
        switch kind {
        case .joystick:
            c.keys = [KeyCode.w, KeyCode.a, KeyCode.s, KeyCode.d]
            c.radius = 0.06
        case .aim:
            c.key = KeyCode.grave
            c.radius = 0.12
        case .fire:
            c.key = KeyCode.mouseLeft
        case .swipe:
            c.x2 = min(1, x + 0.15)
            c.y2 = y
        case .skill:
            c.radius = 0.08
        default: break
        }
        return c
    }

    var allKeys: [Int] { (key.map { [$0] } ?? []) + keys }

    var label: String {
        switch kind {
        case .joystick: return keys.map(KeyCode.name).joined()
        default: return key.map(KeyCode.name) ?? "?"
        }
    }
}

struct Keymap: Codable, Hashable, Sendable {
    var controls: [KeyControl] = []
    var showHints = true
    var hintOpacity = 0.55

    var aim: KeyControl? { controls.first { $0.kind == .aim } }
    var fire: KeyControl? { controls.first { $0.kind == .fire } }

    init(controls: [KeyControl] = [], showHints: Bool = true, hintOpacity: Double = 0.55) {
        self.controls = controls
        self.showHints = showHints
        self.hintOpacity = hintOpacity
    }

    // Tolerant decoding: files written by older versions keep loading when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controls = try c.decodeIfPresent([KeyControl].self, forKey: .controls) ?? []
        showHints = try c.decodeIfPresent(Bool.self, forKey: .showHints) ?? true
        hintOpacity = try c.decodeIfPresent(Double.self, forKey: .hintOpacity) ?? 0.55
    }
}

/// One named control layout. A game can have several (driving, shooting, menus…), one active.
struct KeymapScheme: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var keymap = Keymap()

    init(id: UUID = UUID(), name: String, keymap: Keymap = Keymap()) {
        self.id = id
        self.name = name
        self.keymap = keymap
    }

    // Hand-written or shared schemes may omit the id.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "Scheme")
        keymap = try c.decode(Keymap.self, forKey: .keymap)
    }
}

struct KeymapProfile: Codable, Hashable, Sendable {
    var activeID: UUID?
    var schemes: [KeymapScheme] = []

    var active: KeymapScheme? { schemes.first { $0.id == activeID } ?? schemes.first }

    static func starter() -> KeymapProfile {
        let scheme = KeymapScheme(name: String(localized: "Scheme 1"))
        return KeymapProfile(activeID: scheme.id, schemes: [scheme])
    }

    /// A free name like "Scheme 3".
    func nextName(_ base: String = String(localized: "Scheme")) -> String {
        let used = Set(schemes.map(\.name))
        var n = schemes.count + 1
        while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// Control schemes are stored per Android package, so each game keeps its own layouts.
enum KeymapStore {
    static let defaultProfile = "_default"

    static func url(for package: String) -> URL {
        let safe = package.replacingOccurrences(of: "/", with: "_")
        return AppPaths.keymaps.appendingPathComponent("\(safe).json")
    }

    /// Falls back to the shared profile for games that have none yet.
    static func loadProfile(for package: String?) -> KeymapProfile {
        for name in [package, defaultProfile].compactMap({ $0 }) {
            if let profile = read(url(for: name)) { return profile }
        }
        return .starter()
    }

    static func read(_ url: URL) -> KeymapProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let profile = try? JSONDecoder().decode(KeymapProfile.self, from: data), !profile.schemes.isEmpty {
            return profile
        }
        // Files from 0.1 held a single bare keymap.
        if let map = try? JSONDecoder().decode(Keymap.self, from: data) {
            let scheme = KeymapScheme(name: String(localized: "Scheme 1"), keymap: map)
            return KeymapProfile(activeID: scheme.id, schemes: [scheme])
        }
        return nil
    }

    static func saveProfile(_ profile: KeymapProfile, for package: String?) {
        AppPaths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(profile).write(to: url(for: package ?? defaultProfile), options: .atomic)
    }

    static func export(_ scheme: KeymapScheme, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(scheme).write(to: url, options: .atomic)
    }

    static func importScheme(from url: URL) throws -> KeymapScheme {
        let data = try Data(contentsOf: url)
        if var scheme = try? JSONDecoder().decode(KeymapScheme.self, from: data) {
            scheme.id = UUID()
            return scheme
        }
        let map = try JSONDecoder().decode(Keymap.self, from: data)
        return KeymapScheme(name: url.deletingPathExtension().lastPathComponent, keymap: map)
    }
}

extension KeyControl {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(KeyControlKind.self, forKey: .kind)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        key = try c.decodeIfPresent(Int.self, forKey: .key)
        keys = try c.decodeIfPresent([Int].self, forKey: .keys) ?? []
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.07
        x2 = try c.decodeIfPresent(Double.self, forKey: .x2) ?? 0.5
        y2 = try c.decodeIfPresent(Double.self, forKey: .y2) ?? 0.5
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 1.0
        intervalMS = try c.decodeIfPresent(Int.self, forKey: .intervalMS) ?? 60
    }
}
