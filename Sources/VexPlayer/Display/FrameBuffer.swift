import Darwin
import Foundation

/// A file-backed shared mapping. The emulator mmaps the same file and writes RGBA frames
/// into it; we read them without any copy over the socket.
final class FrameBuffer: @unchecked Sendable {
    let url: URL
    let capacity: Int
    let pointer: UnsafeMutableRawPointer
    private let fd: Int32

    init(name: String, capacity requested: Int) throws {
        AppPaths.ensure()
        let page = Int(getpagesize())
        capacity = (requested + page - 1) / page * page
        url = AppPaths.frames.appendingPathComponent("\(name)-\(getpid()).rgba")
        fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard ftruncate(fd, off_t(capacity)) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let p = mmap(nil, capacity, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p, p != MAP_FAILED else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .ENOMEM)
        }
        pointer = p
    }

    deinit {
        munmap(pointer, capacity)
        close(fd)
        unlink(url.path)
    }
}

/// Maps between the emulator framebuffer (fixed, natural orientation) and what we show,
/// which is rotated upright when the guest rotates its UI (games forcing landscape, etc.).
struct DisplayGeometry: Equatable, Sendable {
    var fbWidth: Int
    var fbHeight: Int
    /// Clockwise quarter turns applied to the framebuffer to get an upright picture.
    var rotation: Int = 0

    var shownWidth: Int { rotation % 2 == 0 ? fbWidth : fbHeight }
    var shownHeight: Int { rotation % 2 == 0 ? fbHeight : fbWidth }
    var aspect: CGFloat { CGFloat(shownWidth) / CGFloat(max(1, shownHeight)) }
    var isLandscape: Bool { shownWidth > shownHeight }

    /// Aspect-fit rectangle of the picture inside a container.
    func fitRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(shownWidth), size.height / CGFloat(shownHeight))
        let w = CGFloat(shownWidth) * scale, h = CGFloat(shownHeight) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Upright normalized (0…1, y down) → framebuffer pixels.
    func framebufferPoint(u: Double, v: Double) -> (x: Int, y: Int) {
        let u = min(max(u, 0), 1), v = min(max(v, 0), 1)
        let (fx, fy): (Double, Double)
        switch rotation {
        case 1: (fx, fy) = (v, 1 - u)
        case 2: (fx, fy) = (1 - u, 1 - v)
        case 3: (fx, fy) = (1 - v, u)
        default: (fx, fy) = (u, v)
        }
        return (Int((fx * Double(fbWidth - 1)).rounded()), Int((fy * Double(fbHeight - 1)).rounded()))
    }

    /// Point in a (flipped, y-down) container → upright normalized coords, nil if outside the picture.
    func normalized(_ p: CGPoint, in size: CGSize, clamp: Bool = false) -> (u: Double, v: Double)? {
        let r = fitRect(in: size)
        guard r.width > 0 else { return nil }
        let u = (p.x - r.minX) / r.width, v = (p.y - r.minY) / r.height
        if !clamp && (u < 0 || u > 1 || v < 0 || v > 1) { return nil }
        return (Double(min(max(u, 0), 1)), Double(min(max(v, 0), 1)))
    }
}
