import EmulatorAPI
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

typealias EmuAPI = Android_Emulation_Control_EmulatorController
typealias EmuInputEvent = Android_Emulation_Control_InputEvent
typealias EmuTouch = Android_Emulation_Control_Touch
typealias EmuImage = Android_Emulation_Control_Image
typealias EmuNotification = Android_Emulation_Control_Notification

/// Thin wrapper over the emulator's gRPC control API.
///
/// Input goes through one long-lived client stream (`streamInputEvent`), so a touch costs
/// one HTTP/2 DATA frame instead of a full unary round trip.
final class EmulatorClient: @unchecked Sendable {
    private let grpc: GRPCClient<HTTP2ClientTransport.Posix>
    let api: EmuAPI.Client<HTTP2ClientTransport.Posix>
    let metadata: Metadata

    private var connectionTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private let lock = NSLock()
    private var inputSink: AsyncStream<EmuInputEvent>.Continuation?

    init(port: Int, token: String?) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: port),
            transportSecurity: .plaintext
        )
        grpc = GRPCClient(transport: transport)
        api = EmuAPI.Client(wrapping: grpc)
        var md = Metadata()
        if let token { md.addString("Bearer \(token)", forKey: "authorization") }
        metadata = md

        let grpc = self.grpc
        connectionTask = Task.detached(priority: .userInitiated) {
            try? await grpc.runConnections()
        }
        startInputPump()
    }

    deinit { close() }

    func close() {
        lock.withLock {
            inputSink?.finish()
            inputSink = nil
        }
        inputTask?.cancel()
        grpc.beginGracefulShutdown()
        connectionTask?.cancel()
    }

    // MARK: Input

    private func startInputPump() {
        let api = api, md = metadata
        inputTask = Task.detached(priority: .high) { [weak self] in
            while !Task.isCancelled {
                let (stream, sink) = AsyncStream<EmuInputEvent>.makeStream(bufferingPolicy: .unbounded)
                self?.lock.withLock { self?.inputSink = sink }
                do {
                    _ = try await api.streamInputEvent(metadata: md) { writer in
                        for await event in stream { try await writer.write(event) }
                    }
                } catch {}
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func send(_ event: EmuInputEvent) {
        lock.withLock { _ = inputSink?.yield(event) }
    }

    /// Touches in framebuffer pixels. pressure 0 releases the contact.
    func sendTouches(_ touches: [(id: Int, x: Int, y: Int, down: Bool)]) {
        var ev = Android_Emulation_Control_TouchEvent()
        ev.touches = touches.map { t in
            var touch = EmuTouch()
            touch.identifier = Int32(t.id)
            touch.x = Int32(t.x)
            touch.y = Int32(t.y)
            touch.pressure = t.down ? 1024 : 0
            touch.touchMajor = t.down ? 8 : 0
            touch.expiration = .neverExpire
            return touch
        }
        var input = EmuInputEvent()
        input.touchEvent = ev
        send(input)
    }

    /// Physical key by macOS virtual key code, sent as a Linux evdev code.
    func sendMacKey(_ keyCode: UInt16, down: Bool) {
        var key = Android_Emulation_Control_KeyboardEvent()
        if let evdev = EvdevKeys.code(forMac: keyCode) {
            key.codeType = .evdev
            key.keyCode = evdev
        } else {
            guard keyCode != 0 else { return }
            key.codeType = .mac
            key.keyCode = Int32(keyCode)
        }
        key.eventType = down ? .keydown : .keyup
        var input = EmuInputEvent()
        input.keyEvent = key
        send(input)
    }

    /// Named key ("GoBack", "GoHome", "AppSwitch", "Power", "AudioVolumeUp", …), pressed and released.
    func pressKey(_ name: String) {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.eventType = .keypress
        key.key = name
        var input = EmuInputEvent()
        input.keyEvent = key
        send(input)
    }

    func keyEvent(_ name: String, down: Bool) {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.eventType = down ? .keydown : .keyup
        key.key = name
        var input = EmuInputEvent()
        input.keyEvent = key
        send(input)
    }

    func sendText(_ text: String) {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.text = text
        var input = EmuInputEvent()
        input.keyEvent = key
        send(input)
    }

    func sendWheel(dx: Int, dy: Int) {
        var wheel = Android_Emulation_Control_WheelEvent()
        wheel.dx = Int32(dx)
        wheel.dy = Int32(dy)
        var input = EmuInputEvent()
        input.wheelEvent = wheel
        send(input)
    }

    // MARK: Queries & controls

    func status() async throws -> Android_Emulation_Control_EmulatorStatus {
        try await api.getStatus(Google_Protobuf_Empty(), metadata: metadata)
    }

    func setClipboard(_ text: String) async {
        var clip = Android_Emulation_Control_ClipData()
        clip.text = text
        _ = try? await api.setClipboard(clip, metadata: metadata)
    }

    func setGPS(latitude: Double, longitude: Double, altitude: Double = 120) async throws {
        var gps = Android_Emulation_Control_GpsState()
        gps.passiveUpdate = false
        gps.latitude = latitude
        gps.longitude = longitude
        gps.altitude = altitude
        gps.satellites = 12
        _ = try await api.setGps(gps, metadata: metadata)
    }

    func setVMState(_ state: Android_Emulation_Control_VmRunState.RunState) async throws {
        var s = Android_Emulation_Control_VmRunState()
        s.state = state
        _ = try await api.setVmState(s, metadata: metadata)
    }

    /// Jerks the virtual device back and forth so the accelerometer reports a shake.
    func shake() async {
        func setPosition(_ x: Float) async {
            var v = Android_Emulation_Control_PhysicalModelValue()
            v.target = .position
            v.interpolation = .step
            v.value.data = [x, 0, 0]
            _ = try? await api.setPhysicalModel(v, metadata: metadata)
        }
        for i in 0..<12 {
            await setPosition(i.isMultiple(of: 2) ? 0.08 : -0.08)
            try? await Task.sleep(for: .milliseconds(35))
        }
        await setPosition(0)
    }

    // MARK: Streams

    /// Frames are written by the emulator straight into `mmapFile`; each message only announces one.
    func streamFrames(mmapFile: URL, onFrame: @escaping @Sendable (EmuImage) -> Void) async throws {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.transport.channel = .mmap
        format.transport.handle = mmapFile.absoluteString   // file:///…
        try await api.streamScreenshot(format, metadata: metadata) { response in
            for try await image in response.messages { onFrame(image) }
        }
    }

    func streamNotifications(_ handler: @escaping @Sendable (EmuNotification) -> Void) async throws {
        try await api.streamNotification(Google_Protobuf_Empty(), metadata: metadata) { response in
            for try await n in response.messages { handler(n) }
        }
    }

    func streamClipboard(_ handler: @escaping @Sendable (String) -> Void) async throws {
        try await api.streamClipboard(Google_Protobuf_Empty(), metadata: metadata) { response in
            for try await clip in response.messages { handler(clip.text) }
        }
    }
}
