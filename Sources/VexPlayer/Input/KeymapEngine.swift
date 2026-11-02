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

    init(map: Keymap) { self.map = map }

    var isEmpty: Bool { map.controls.isEmpty }

    private func touchID(_ index: Int) -> Int { 10 + index }

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
                press(touchID(i), c.x, c.y)
            case .repeatTap:
                startRepeat(i, c)
            case .joystick:
                updateJoystick(i, c)
            case .aim:
                if code == c.key { setAim(!aimLocked) }
            case .fire:
                if code != KeyCode.mouseLeft || aimLocked { press(touchID(i), c.x, c.y) }
            case .swipe:
                swipe(i, c)
            case .skill:
                press(touchID(i), c.x, c.y)
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
                release(touchID(i))
            case .repeatTap:
                repeatTasks.removeValue(forKey: i)?.cancel()
                release(touchID(i))
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
        for (i, c) in map.controls.enumerated() where c.kind == .skill && down[touchID(i)] != nil {
            updateSkill(i, c)
        }
    }

    /// Relative motion while the cursor is captured. `scale` converts points to picture-width units.
    func aimDelta(dx: Double, dy: Double, scale: Double) {
        guard aimLocked, let idx = map.controls.firstIndex(where: { $0.kind == .aim }) else { return }
        let c = map.controls[idx]
        var f = aimFinger ?? (c.x, c.y)
        f.u += dx * scale * c.sensitivity
        f.v += dy * scale * c.sensitivity * aspect
        let dist = hypot(f.u - c.x, (f.v - c.y) / aspect)
        if dist > c.radius || f.u < 0.01 || f.u > 0.99 || f.v < 0.01 || f.v > 0.99 {
            // Out of throw: lift and put the finger back in the middle of the look area.
            release(touchID(idx))
            press(touchID(idx), c.x, c.y)
            f = (c.x, c.y)
        } else {
            move(touchID(idx), f.u, f.v)
        }
        aimFinger = f
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
            press(touchID(idx), c.x, c.y)
            aimFinger = (c.x, c.y)
        } else {
            release(touchID(idx))
            aimFinger = nil
            if let f = map.controls.firstIndex(where: { $0.kind == .fire }) { release(touchID(f)) }
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
        let id = touchID(i)
        guard dx != 0 || dy != 0 else {
            release(id)
            return
        }
        let len = hypot(dx, dy)
        let tx = c.x + dx / len * c.radius * magnitude
        let ty = c.y + dy / len * c.radius * magnitude * aspect
        if down[id] == nil {
            press(id, c.x, c.y)
            // Many games only start the stick once the finger has moved a bit from where it landed.
            move(id, c.x + (tx - c.x) * 0.3, c.y + (ty - c.y) * 0.3)
        }
        move(id, tx, ty)
    }

    private func updateSkill(_ i: Int, _ c: KeyControl) {
        let dx = mouse.u - 0.5, dy = (mouse.v - 0.5) / aspect
        let len = hypot(dx, dy)
        guard len > 0.02 else { return }
        let k = min(1, len / 0.35)
        move(touchID(i), c.x + dx / len * c.radius * k, c.y + dy / len * c.radius * k * aspect)
    }

    private func startRepeat(_ i: Int, _ c: KeyControl) {
        repeatTasks[i]?.cancel()
        let id = touchID(i)
        let half = max(15, c.intervalMS / 2)
        repeatTasks[i] = Task { [weak self] in
            while !Task.isCancelled {
                self?.press(id, c.x, c.y)
                try? await Task.sleep(for: .milliseconds(half))
                self?.release(id)
                try? await Task.sleep(for: .milliseconds(half))
            }
        }
    }

    private func swipe(_ i: Int, _ c: KeyControl) {
        let id = touchID(i)
        Task { [weak self] in
            self?.press(id, c.x, c.y)
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
