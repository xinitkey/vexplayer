import Foundation

/// A touch in upright normalized coordinates (0…1, y down).
struct NormTouch: Sendable, Codable, Hashable {
    var id: Int
    var u: Double
    var v: Double
    var down: Bool
}

/// Turns key/mouse/gamepad state into virtual fingers according to a Keymap.
@MainActor
final class KeymapEngine {
    var map: Keymap {
        didSet { if oldValue != map { releaseAll() } }
    }
    /// Shown width / height, so joystick throws are circular on screen.
    var aspect: Double = 16.0 / 9.0
    var emit: ([NormTouch]) -> Void = { _ in }
    var onAimLockChanged: (Bool) -> Void = { _ in }

    private(set) var aimLocked = false
    private var held = Set<Int>()
    private var down: [Int: (u: Double, v: Double)] = [:]
    private var repeatTasks: [Int: Task<Void, Never>] = [:]
    private var aimFinger: (u: Double, v: Double)?
    private var mouse: (u: Double, v: Double) = (0.5, 0.5)
    private var analog: (x: Double, y: Double) = (0, 0)

    /// The touch id of each control's current finger. Every new press takes the other of two ids: a lift and a
    /// landing on the same id within one frame read to a game as one finger sliding over, so a re-pressed
    /// joystick started from where the last direction left it.
    private var fingerIDs: [Int: Int] = [:]
    private var presses: [Int: Int] = [:]
    private var liftTimes: [Int: TimeInterval] = [:]
    /// Timed landings (joystick) and re-plantings (mouse look) in progress, per control.
    private var landings: [Int: Task<Void, Never>] = [:]
    private var stickTargets: [Int: (u: Double, v: Double)] = [:]
    /// Mouse-look motion that arrived while its finger was being lifted and put back.
    private var aimSettling = false
    private var aimPending: (du: Double, dv: Double) = (0, 0)

    /// Long enough for a game to read one frame of input in between (a 30 fps game reads every 33 ms).
    nonisolated static let frameGap: TimeInterval = 0.035

    init(map: Keymap) { self.map = map }

    var isEmpty: Bool { map.controls.isEmpty }

    private func touchID(_ index: Int) -> Int { 10 + index }
    private func fingerID(_ index: Int) -> Int { fingerIDs[index] ?? touchID(index) }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Puts down a new finger for control `index`.
    @discardableResult
    private func land(_ index: Int, _ u: Double, _ v: Double) -> Int {
        let n = (presses[index] ?? 0) + 1
        presses[index] = n
        let id = n % 2 == 1 ? touchID(index) : touchID(index) + 100
        fingerIDs[index] = id
        press(id, u, v)
        return id
    }

    private func lift(_ index: Int) {
        guard down[fingerID(index)] != nil else { return }
        release(fingerID(index))
        liftTimes[index] = now
    }

    // MARK: Keys

    /// Returns true when the key belongs to the keymap (and must not reach Android).
    func keyDown(_ code: Int) -> Bool {
        let bound = map.controls.enumerated().filter { $0.element.allKeys.contains(code) }
        guard !bound.isEmpty else { return false }
        if held.contains(code) { return true }   // auto-repeat
        held.insert(code)
        for (i, c) in bound {
            switch c.kind {
            case .tap:
                land(i, c.x, c.y)
            case .repeatTap:
                startRepeat(i, c)
            case .joystick:
                updateJoystick(i, c)
            case .aim:
                if code == c.key { setAim(!aimLocked) }
            case .fire:
                if code != KeyCode.mouseLeft || aimLocked { land(i, c.x, c.y) }
            case .swipe:
                swipe(i, c)
            case .skill:
                land(i, c.x, c.y)
                updateSkill(i, c)
            }
        }
        return true
    }

    func keyUp(_ code: Int) -> Bool {
        let bound = map.controls.enumerated().filter { $0.element.allKeys.contains(code) }
        guard !bound.isEmpty else { return false }
        held.remove(code)
        for (i, c) in bound {
            switch c.kind {
            case .tap, .fire, .skill:
                lift(i)
            case .repeatTap:
                repeatTasks.removeValue(forKey: i)?.cancel()
                lift(i)
            case .joystick:
                updateJoystick(i, c)
            case .aim, .swipe:
                break
            }
        }
        return true
    }

    /// Mouse buttons are keys too (1001…). While aiming, the left button always belongs to us.
    func mouseButton(_ code: Int, down isDown: Bool) -> Bool {
        if aimLocked && code == KeyCode.mouseLeft {
            if map.fire != nil { _ = isDown ? keyDown(code) : keyUp(code) }
            return true
        }
        let boundNonFire = map.controls.contains { $0.kind != .fire && $0.allKeys.contains(code) }
        guard boundNonFire else { return false }
        return isDown ? keyDown(code) : keyUp(code)
    }

    // MARK: Mouse

    func mouseMoved(u: Double, v: Double) {
        mouse = (u, v)
        for (i, c) in map.controls.enumerated() where c.kind == .skill && down[fingerID(i)] != nil {
            updateSkill(i, c)
        }
    }

    /// Relative motion while the cursor is captured. `scale` converts points to picture-width units.
    func aimDelta(dx: Double, dy: Double, scale: Double) {
        guard aimLocked, let idx = map.controls.firstIndex(where: { $0.kind == .aim }) else { return }
        let c = map.controls[idx]
        aimMove(idx, c, du: dx * scale * c.sensitivity, dv: dy * scale * c.sensitivity * aspect)
    }

    /// Moves the look finger by (du, dv) in picture units.
    private func aimMove(_ idx: Int, _ c: KeyControl, du: Double, dv: Double) {
        if aimSettling {
            aimPending.du += du
            aimPending.dv += dv
            return
        }
        guard let start = aimFinger else { return }
        let f = (u: start.u + du, v: start.v + dv)
        let dist = hypot(f.u - c.x, (f.v - c.y) / aspect)
        if dist > c.radius || f.u < 0.01 || f.u > 0.99 || f.v < 0.01 || f.v > 0.99 {
            // Out of the look area: lift, and a frame later put a new finger in its middle. Lifting and landing
            // at once read to games as the finger sliding back, which swung the camera back each time.
            // This motion is applied from the middle once the new finger is down, capped so it fits the area.
            let len = hypot(du, dv / aspect)
            let k = len > c.radius * 0.9 ? c.radius * 0.9 / len : 1
            aimPending = (du * k, dv * k)
            aimSettling = true
            lift(idx)
            aimFinger = nil
            landings[idx]?.cancel()
            landings[idx] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.frameGap))
                guard let self, !Task.isCancelled, self.aimLocked else { return }
                self.plantAim(idx, c)
            }
        } else {
            move(fingerID(idx), f.u, f.v)
            aimFinger = f
        }
    }

    /// Lands the look finger in the middle of its area and holds it still for a frame, so the game sees the
    /// touch begin there; motion that arrives meanwhile is applied afterwards.
    private func plantAim(_ idx: Int, _ c: KeyControl) {
        aimSettling = true
        land(idx, c.x, c.y)
        aimFinger = (c.x, c.y)
        landings[idx]?.cancel()
        landings[idx] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.frameGap))
            guard let self, !Task.isCancelled, self.aimLocked else { return }
            self.landings[idx] = nil
            self.aimSettling = false
            let p = self.aimPending
            self.aimPending = (0, 0)
            if p.du != 0 || p.dv != 0 { self.aimMove(idx, c, du: p.du, dv: p.dv) }
        }
    }

    func setAim(_ locked: Bool) {
        guard let idx = map.controls.firstIndex(where: { $0.kind == .aim }) else {
            if aimLocked { aimLocked = false; onAimLockChanged(false) }
            return
        }
        guard locked != aimLocked else { return }
        aimLocked = locked
        let c = map.controls[idx]
        if locked {
            aimPending = (0, 0)
            plantAim(idx, c)
        } else {
            landings.removeValue(forKey: idx)?.cancel()
            aimSettling = false
            aimPending = (0, 0)
            lift(idx)
            aimFinger = nil
            if let f = map.controls.firstIndex(where: { $0.kind == .fire }) { lift(f) }
        }
        onAimLockChanged(locked)
    }

    // MARK: Gamepad analog

    /// Left stick drives the first joystick control directly (analog, -1…1).
    func setAnalogStick(x: Double, y: Double) {
        analog = (x, y)
        guard let i = map.controls.firstIndex(where: { $0.kind == .joystick }) else { return }
        updateJoystick(i, map.controls[i])
    }

    /// Right stick acts like the mouse in aim mode.
    func setLookStick(x: Double, y: Double) {
        guard abs(x) > 0.08 || abs(y) > 0.08 else { return }
        if !aimLocked { setAim(true) }
        aimDelta(dx: x * 14, dy: y * 14, scale: 1.0 / 1000.0)
    }

    // MARK: Control behaviours

    private func updateJoystick(_ i: Int, _ c: KeyControl) {
        guard c.keys.count == 4 else { return }
        var dx = 0.0, dy = 0.0
        if held.contains(c.keys[0]) { dy -= 1 }
        if held.contains(c.keys[1]) { dx -= 1 }
        if held.contains(c.keys[2]) { dy += 1 }
        if held.contains(c.keys[3]) { dx += 1 }
        var magnitude = 1.0
        if dx == 0 && dy == 0 && hypot(analog.x, analog.y) > 0.15 {
            dx = analog.x
            dy = analog.y
            magnitude = min(1, hypot(dx, dy))
        }
        guard dx != 0 || dy != 0 else {
            stickTargets[i] = nil
            landings.removeValue(forKey: i)?.cancel()
            lift(i)
            return
        }
        let len = hypot(dx, dy)
        let target = (u: c.x + dx / len * c.radius * magnitude, v: c.y + dy / len * c.radius * magnitude * aspect)
        stickTargets[i] = target
        if landings[i] != nil { return }   // the landing under way picks up the newest direction
        if down[fingerID(i)] != nil {
            move(fingerID(i), target.u, target.v)
            return
        }
        // A new touch must reach the game at the stick's centre, as a touch of its own and with the finger
        // still for a frame, or a quick re-press starts the stick from the previous direction. Then push out
        // in two steps: many games only start the stick once the finger has moved a bit from where it landed.
        let wait = (liftTimes[i].map { Self.frameGap - (now - $0) } ?? 0)
        landings[i] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            let id = self.land(i, c.x, c.y)
            try? await Task.sleep(for: .seconds(Self.frameGap))
            guard !Task.isCancelled, let t = self.stickTargets[i] else { return }
            self.move(id, c.x + (t.u - c.x) * 0.3, c.y + (t.v - c.y) * 0.3)
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let t = self.stickTargets[i] else { return }
            self.move(id, t.u, t.v)
            self.landings[i] = nil
        }
    }

    private func updateSkill(_ i: Int, _ c: KeyControl) {
        let dx = mouse.u - 0.5, dy = (mouse.v - 0.5) / aspect
        let len = hypot(dx, dy)
        guard len > 0.02 else { return }
        let k = min(1, len / 0.35)
        move(fingerID(i), c.x + dx / len * c.radius * k, c.y + dy / len * c.radius * k * aspect)
    }

    private func startRepeat(_ i: Int, _ c: KeyControl) {
        repeatTasks[i]?.cancel()
        let half = max(15, c.intervalMS / 2)
        repeatTasks[i] = Task { [weak self] in
            while !Task.isCancelled {
                self?.land(i, c.x, c.y)
                try? await Task.sleep(for: .milliseconds(half))
                self?.lift(i)
                try? await Task.sleep(for: .milliseconds(half))
            }
        }
    }

    private func swipe(_ i: Int, _ c: KeyControl) {
        Task { [weak self] in
            guard let id = self?.land(i, c.x, c.y) else { return }
            for step in 1...8 {
                try? await Task.sleep(for: .milliseconds(14))
                let t = Double(step) / 8
                self?.move(id, c.x + (c.x2 - c.x) * t, c.y + (c.y2 - c.y) * t)
            }
            try? await Task.sleep(for: .milliseconds(20))
            self?.release(id)
        }
    }

    // MARK: Fingers

    private func press(_ id: Int, _ u: Double, _ v: Double) {
        down[id] = (u, v)
        emit([NormTouch(id: id, u: u, v: v, down: true)])
    }

    private func move(_ id: Int, _ u: Double, _ v: Double) {
        guard down[id] != nil else { return }
        down[id] = (u, v)
        emit([NormTouch(id: id, u: u, v: v, down: true)])
    }

    private func release(_ id: Int) {
        guard let p = down.removeValue(forKey: id) else { return }
        emit([NormTouch(id: id, u: p.u, v: p.v, down: false)])
    }

    func releaseAll() {
        repeatTasks.values.forEach { $0.cancel() }
        repeatTasks.removeAll()
        landings.values.forEach { $0.cancel() }
        landings.removeAll()
        stickTargets.removeAll()
        aimSettling = false
        aimPending = (0, 0)
        held.removeAll()
        analog = (0, 0)
        let ups = down.map { NormTouch(id: $0.key, u: $0.value.u, v: $0.value.v, down: false) }
        down.removeAll()
        aimFinger = nil
        if !ups.isEmpty { emit(ups) }
        if aimLocked {
            aimLocked = false
            onAimLockChanged(false)
        }
    }
}
