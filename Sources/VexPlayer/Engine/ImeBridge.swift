import Darwin
import Foundation

/// Talks to VexIME inside Android (android/vexime) through `adb forward tcp:N localabstract:vexplayer_ime`.
/// Frames both ways: [type u8][length u32 big-endian][UTF-8 payload].
final class ImeBridge: @unchecked Sendable {
    static let package = "app.vexplayer.ime"
    static let component = "app.vexplayer.ime/.VexIME"
    static let socketName = "vexplayer_ime"
    /// Must match android:versionCode in android/vexime/AndroidManifest.xml.
    static let version = 1

    var onFocus: (@Sendable (Bool) -> Void)?
    var onConnection: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private let writeQueue = DispatchQueue(label: "vex.ime.write", qos: .userInteractive)

    static var apkURL: URL? {
        if let url = Bundle.main.url(forResource: "VexIME", withExtension: "apk") { return url }
        // Development builds and tests run outside the .app: use the copy in the source tree.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/VexIME.apk")
        return source.fileExists ? source : nil
    }

    func start(port: Int) {
        lock.withLock { running = true }
        let thread = Thread { [weak self] in self?.run(port: port) }
        thread.name = "vex.ime.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.withLock {
            running = false
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }

    func commit(_ text: String) { send(UInt8(ascii: "C"), text) }
    func compose(_ text: String) { send(UInt8(ascii: "M"), text) }

    private var isRunning: Bool { lock.withLock { running } }

    private func run(port: Int) {
        while isRunning {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { Thread.sleep(forTimeInterval: 1); continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
            if !ok {
                close(s)
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            lock.withLock { fd = s }
            // adb accepts the TCP side even when nothing listens in Android; only a hello proves the IME is there.
            var greeted = false
            while isRunning, let (type, payload) = readFrame(s) {
                switch type {
                case UInt8(ascii: "H"):
                    greeted = true
                    onConnection?(true)
                case UInt8(ascii: "F"):
                    onFocus?(payload.hasPrefix("1"))
                default:
                    break
                }
            }
            lock.withLock { fd = -1 }
            close(s)
            if greeted { onConnection?(false) }
            if isRunning { Thread.sleep(forTimeInterval: 1) }
        }
    }

    private func readFrame(_ s: Int32) -> (UInt8, String)? {
        guard let header = readExactly(s, 5) else { return nil }
        let length = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
        guard length >= 0, length <= 1 << 20 else { return nil }
        guard let body = length == 0 ? [] : readExactly(s, length) else { return nil }
        return (header[0], String(decoding: body, as: UTF8.self))
    }

    private func readExactly(_ s: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { read(s, $0.baseAddress! + done, count - done) }
            if n <= 0 { return nil }
            done += n
        }
        return buffer
    }

    private func send(_ type: UInt8, _ text: String) {
        let payload = Array(text.utf8)
        var frame: [UInt8] = [type]
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: payload)
        writeQueue.async { [weak self] in
            guard let self else { return }
            let s = self.lock.withLock { self.fd }
            guard s >= 0 else { return }
            var sent = 0
            while sent < frame.count {
                let n = frame.withUnsafeBytes { write(s, $0.baseAddress! + sent, frame.count - sent) }
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
