import AppKit
import Foundation
import Observation

/// Routes Mac input for one instance: keymap first, everything else straight to Android.
@MainActor
final class InputController {
    unowned let session: InstanceSession
    let engine: KeymapEngine

    var keymapEnabled = true
    var textFieldFocused = false
    /// True while the keymap editor is open: input must not reach Android.
    var suspended = false
    /// Mouse wheel direction: Android scrolls content up for positive dy.
    var invertWheel = false

    private var pointerDown = false
    private var pointerPos: (u: Double, v: Double) = (0.5, 0.5)
    private var scrollFinger: (u: Double, v: Double)?
    private var heldAndroidKeys = Set<UInt16>()

    init(session: InstanceSession, keymap: Keymap) {
        self.session = session
        engine = KeymapEngine(map: keymap)
        engine.emit = { [weak self] touches in self?.sendTouches(touches) }
    }

    var keymapActive: Bool { keymapEnabled && !textFieldFocused && !engine.isEmpty }

    // MARK: Output

    func sendTouches(_ touches: [NormTouch], broadcast: Bool = true) {
        guard let client = session.client else { return }
        let g = session.geometry
        client.sendTouches(touches.map { t in
            let p = g.framebufferPoint(u: t.u, v: t.v)
            return (t.id, p.x, p.y, t.down)
        })
        session.recorder.record(.touches(touches))
        if broadcast { SyncController.shared.broadcast(from: session) { $0.input.sendTouches(touches, broadcast: false) } }
    }

    func sendKey(_ code: UInt16, down: Bool, broadcast: Bool = true) {
        if down { heldAndroidKeys.insert(code) } else { heldAndroidKeys.remove(code) }
        session.client?.sendMacKey(code, down: down)
        session.recorder.record(.key(code, down))
        if broadcast { SyncController.shared.broadcast(from: session) { $0.input.sendKey(code, down: down, broadcast: false) } }
    }

    func tapKey(_ code: UInt16) {
        sendKey(code, down: true)
        sendKey(code, down: false)
    }

    func pressNamedKey(_ name: String) {
        session.client?.pressKey(name)
        SyncController.shared.broadcast(from: session) { $0.client?.pressKey(name) }
    }

    // MARK: Mouse

    func mouseDown(button: Int, at p: (u: Double, v: Double)?) {
        let code = [KeyCode.mouseLeft, KeyCode.mouseRight, KeyCode.mouseMiddle][min(button, 2)]
        if keymapActive, engine.mouseButton(code, down: true) { return }
        guard let p else { return }
        switch button {
        case 0:
            pointerDown = true
            pointerPos = p
            sendTouches([NormTouch(id: 0, u: p.u, v: p.v, down: true)])
        case 1:
            pressNamedKey("GoBack")
        default:
            break
        }
    }

    func mouseDragged(at p: (u: Double, v: Double)) {
        guard pointerDown else { return }
        pointerPos = p
        sendTouches([NormTouch(id: 0, u: p.u, v: p.v, down: true)])
    }

    func mouseUp(button: Int, at p: (u: Double, v: Double)?) {
        let code = [KeyCode.mouseLeft, KeyCode.mouseRight, KeyCode.mouseMiddle][min(button, 2)]
        if keymapActive, engine.mouseButton(code, down: false) { return }
        guard button == 0, pointerDown else { return }
        pointerDown = false
        let q = p ?? pointerPos
        sendTouches([NormTouch(id: 0, u: q.u, v: q.v, down: false)])
    }

    /// `scale` converts points of relative motion into picture-width units.
    func mouseMoved(at p: (u: Double, v: Double)?, dx: Double, dy: Double, scale: Double) {
        if engine.aimLocked {
            engine.aimDelta(dx: dx, dy: dy, scale: scale)
        } else if let p {
            engine.mouseMoved(u: p.u, v: p.v)
        }
    }

    /// Trackpad: a two-finger scroll becomes a one-finger drag (with Android's own fling).
    /// Mouse wheel: real wheel events.
    func scroll(precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                dx: Double, dy: Double, at p: (u: Double, v: Double)?, pictureSize: CGSize) {
        if precise {
            if !momentum.isEmpty { return }
            if phase.contains(.began), let p {
                scrollFinger = p
                sendTouches([NormTouch(id: 1, u: p.u, v: p.v, down: true)])
            } else if phase.contains(.changed), var f = scrollFinger, pictureSize.width > 0 {
                f.u = min(max(f.u + dx / pictureSize.width, 0), 1)
                f.v = min(max(f.v + dy / pictureSize.height, 0), 1)
                scrollFinger = f
                sendTouches([NormTouch(id: 1, u: f.u, v: f.v, down: true)])
            } else if phase.contains(.ended) || phase.contains(.cancelled), let f = scrollFinger {
                scrollFinger = nil
                sendTouches([NormTouch(id: 1, u: f.u, v: f.v, down: false)])
            }
        } else {
            let sign = invertWheel ? -1.0 : 1.0
            session.client?.sendWheel(dx: Int(dx * 120 * sign), dy: Int(dy * 120 * sign))
        }
    }

    // MARK: Keyboard

    func keyDown(_ code: UInt16) {
        if Int(code) == KeyCode.escape, engine.aimLocked {
            engine.setAim(false)
            return
        }
        if keymapActive, engine.keyDown(Int(code)) { return }
        sendKey(code, down: true)
    }

    func keyUp(_ code: UInt16) {
        if keymapActive, engine.keyUp(Int(code)) { return }
        guard heldAndroidKeys.contains(code) else { return }
        sendKey(code, down: false)
    }

    func modifierChanged(_ code: UInt16, down: Bool) {
        guard Int(code) != KeyCode.command, Int(code) != KeyCode.rightCommand else { return }
        if down { keyDown(code) } else { keyUp(code) }
    }

    /// ⌘C/⌘X/⌘A/⌘Z map to Ctrl+… on Android; ⌘V first pushes the Mac clipboard into the guest.
    func commandShortcut(_ chars: String, keyCode: UInt16) -> Bool {
        switch chars.lowercased() {
        case "v":
            let text = NSPasteboard.general.string(forType: .string)
            Task { [weak self] in
                if let text { await self?.session.client?.setClipboard(text) }
                self?.sendControlChord(keyCode)
            }
            return true
        case "c", "x", "a", "z":
            sendControlChord(keyCode)
            return true
        default:
            return false
        }
    }

    private func sendControlChord(_ code: UInt16) {
        let ctrl = UInt16(KeyCode.leftControl)
        sendKey(ctrl, down: true)
        sendKey(code, down: true)
        sendKey(code, down: false)
        sendKey(ctrl, down: false)
    }

    /// Window lost focus: lift every finger and key so nothing stays stuck.
    func releaseAll() {
        engine.releaseAll()
        if pointerDown {
            pointerDown = false
            sendTouches([NormTouch(id: 0, u: pointerPos.u, v: pointerPos.v, down: false)])
        }
        if let f = scrollFinger {
            scrollFinger = nil
            sendTouches([NormTouch(id: 1, u: f.u, v: f.v, down: false)])
        }
        for code in heldAndroidKeys { sendKey(code, down: false) }
    }
}

/// "Synchronizer": mirror the leader instance's input to every other running instance.
@MainActor @Observable
final class SyncController {
    static let shared = SyncController()
    var enabled = false
    var leaderID: String?

    func broadcast(from session: InstanceSession, _ action: (InstanceSession) -> Void) {
        guard enabled, session.id == leaderID else { return }
        for s in InstanceStore.shared.sessions.values where s.id != session.id && s.state == .running {
            action(s)
        }
    }
}

/// Operation recorder: records input with timing and replays it (optionally in a loop).
@MainActor @Observable
final class OperationRecorder {
    enum Event: Codable, Sendable {
        case touches([NormTouch])
        case key(UInt16, Bool)
    }
    struct Step: Codable, Sendable {
        var t: Double
        var event: Event
    }

    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var steps: [Step] = []
    var loop = false
    private var startTime: CFTimeInterval = 0
    private var playTask: Task<Void, Never>?

    var duration: Double { steps.last?.t ?? 0 }

    func record(_ e: Event) {
        guard isRecording else { return }
        steps.append(Step(t: CACurrentMediaTime() - startTime, event: e))
    }

    func startRecording() {
        stop()
        steps = []
        startTime = CACurrentMediaTime()
        isRecording = true
    }

    func stopRecording() { isRecording = false }

    func play(on input: InputController) {
        guard !steps.isEmpty, !isRecording else { return }
        stop()
        isPlaying = true
        let steps = steps
        playTask = Task { [weak self] in
            repeat {
                let t0 = CACurrentMediaTime()
                for step in steps {
                    let wait = step.t - (CACurrentMediaTime() - t0)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { break }
                    switch step.event {
                    case .touches(let t): input.sendTouches(t)
                    case .key(let code, let down): input.sendKey(code, down: down)
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            } while !Task.isCancelled && (self?.loop ?? false)
            input.releaseAll()
            self?.isPlaying = false
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(steps).write(to: url, options: .atomic)
    }

    func load(from url: URL) throws {
        steps = try JSONDecoder().decode([Step].self, from: Data(contentsOf: url))
    }
}
