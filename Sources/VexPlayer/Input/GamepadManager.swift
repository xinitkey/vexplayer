import Foundation
import GameController

/// Game controllers drive the keymap of the focused player window:
/// buttons act as keys (Ⓐ, LB, …), the left stick moves the joystick control, the right stick looks around.
@MainActor
final class GamepadManager {
    static let shared = GamepadManager()
    private var lookTimer: Timer?
    private var look: (x: Float, y: Float) = (0, 0)

    func start() {
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            guard let c = note.object as? GCController else { return }
            MainActor.assumeIsolated { self.attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery()
    }

    private var engine: KeymapEngine? {
        guard let s = PlayerWindows.shared.activeSession, s.state == .running, s.keymapEnabled else { return nil }
        return s.input.engine
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let buttons: [(GCControllerButtonInput?, GamepadButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftTrigger, .leftTrigger), (pad.rightTrigger, .rightTrigger),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown), (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options),
            (pad.leftThumbstickButton, .leftThumb), (pad.rightThumbstickButton, .rightThumb),
        ]
        for (input, button) in buttons {
            input?.pressedChangedHandler = { _, _, pressed in
                MainActor.assumeIsolated {
                    let code = KeyCode.gamepadBase + button.rawValue
                    let handled = pressed ? self.engine?.keyDown(code) : self.engine?.keyUp(code)
                    if handled != true, pressed, button == .b {
                        PlayerWindows.shared.activeSession?.back()
                    }
                }
            }
        }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated { self.engine?.setAnalogStick(x: Double(x), y: Double(-y)) }
        }
        pad.rightThumbstick.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated { self.setLook(x, -y) }
        }
    }

    /// The right stick is a rate control, so it needs a steady tick while deflected.
    private func setLook(_ x: Float, _ y: Float) {
        look = (x, y)
        let active = abs(x) > 0.08 || abs(y) > 0.08
        if active && lookTimer == nil {
            lookTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    self.engine?.setLookStick(x: Double(self.look.x), y: Double(self.look.y))
                }
            }
        } else if !active {
            lookTimer?.invalidate()
            lookTimer = nil
        }
    }
}
