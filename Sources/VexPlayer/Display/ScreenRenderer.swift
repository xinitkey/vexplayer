import Foundation
import Metal
import QuartzCore

/// Uploads emulator frames into a Metal texture and draws them aspect-fit and rotated.
/// All GPU work runs on one serial queue; bursts of frames coalesce to the newest one.
final class ScreenRenderer: @unchecked Sendable {
    let device: MTLDevice
    let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let renderQueue = DispatchQueue(label: "vex.render", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: 3)

    private let lock = NSLock()
    private var textures: [MTLTexture] = []
    private var textureIndex = 0
    private var current: MTLTexture?
    private var pendingFrame: (buffer: FrameBuffer, width: Int, height: Int)?
    /// Zero-copy: a Metal buffer over the very pages the emulator writes frames into.
    private var mapped: (frame: FrameBuffer, buffer: MTLBuffer)?
    private var mappedTexture: MTLTexture?
    private var scheduled = false
    private var _rotation = 0
    private var _flipY = false

    private var frameCount = 0
    private var lastFPSTime = CACurrentMediaTime()
    /// Called on the render queue roughly once a second with the displayed frame rate.
    var onFPS: (@Sendable (Double) -> Void)?
    /// Called on the render queue for every new frame (recording hook).
    var onFrameUploaded: (@Sendable (UnsafeRawPointer, Int, Int) -> Void)?

    var rotation: Int {
        get { lock.withLock { _rotation } }
        set { lock.withLock { _rotation = newValue }; redraw() }
    }
    var flipY: Bool {
        get { lock.withLock { _flipY } }
        set { lock.withLock { _flipY = newValue }; redraw() }
    }

    init?(layer: CAMetalLayer) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.layer = layer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("VexPlayer: shader compile failed: \(error)")
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!
    }

    /// Low-latency mode presents immediately instead of waiting for vsync.
    func setVSync(_ enabled: Bool) {
        layer.displaySyncEnabled = enabled
    }

    /// Called from the frame stream thread with the shared mapping the emulator just wrote.
    func submitFrame(_ frame: FrameBuffer, width: Int, height: Int) {
        let shouldSchedule: Bool = lock.withLock {
            pendingFrame = (frame, width, height)
            if scheduled { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { renderQueue.async { self.renderPending() } }
    }

    func redraw() {
        renderQueue.async { self.draw() }
    }

    private func renderPending() {
        let frame: (buffer: FrameBuffer, width: Int, height: Int)? = lock.withLock {
            scheduled = false
            defer { pendingFrame = nil }
            return pendingFrame
        }
        guard let frame else { return }
        if !bindZeroCopy(frame.buffer, width: frame.width, height: frame.height) {
            upload(UnsafeRawPointer(frame.buffer.pointer), width: frame.width, height: frame.height)
        }
        onFrameUploaded?(UnsafeRawPointer(frame.buffer.pointer), frame.width, frame.height)
        draw()

        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFPSTime >= 1 {
            onFPS?(Double(frameCount) / (now - lastFPSTime))
            frameCount = 0
            lastFPSTime = now
        }
    }

    /// Samples the frame where it lies instead of copying 8 MB per 1080p frame.
    /// The renderer keeps `frame` alive, so the pages stay mapped while the GPU may read them.
    private func bindZeroCopy(_ frame: FrameBuffer, width: Int, height: Int) -> Bool {
        let rowBytes = width * 4
        guard rowBytes % device.minimumLinearTextureAlignment(for: .rgba8Unorm) == 0,
              rowBytes * height <= frame.capacity else { return false }
        if mapped?.frame !== frame {
            mappedTexture = nil
            mapped = device.makeBuffer(bytesNoCopy: frame.pointer, length: frame.capacity,
                                       options: .storageModeShared, deallocator: nil).map { (frame, $0) }
        }
        guard let mapped else { return false }
        if mappedTexture.map({ $0.width != width || $0.height != height }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            mappedTexture = mapped.buffer.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes)
        }
        guard let mappedTexture else { return false }
        current = mappedTexture
        return true
    }

    private func upload(_ source: UnsafeRawPointer, width: Int, height: Int) {
        if textures.first.map({ $0.width != width || $0.height != height }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            textures = (0..<4).compactMap { _ in device.makeTexture(descriptor: d) }
            textureIndex = 0
        }
        guard !textures.isEmpty else { return }
        // Ring of textures so we never overwrite one the GPU is still sampling.
        textureIndex = (textureIndex + 1) % textures.count
        let tex = textures[textureIndex]
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: source, bytesPerRow: width * 4)
        current = tex
    }

    private func draw() {
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        inFlight.wait()
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            if let tex = current {
                let (rot, flip) = lock.withLock { (_rotation, _flipY) }
                let geo = DisplayGeometry(fbWidth: tex.width, fbHeight: tex.height, rotation: rot)
                let r = geo.fitRect(in: size)
                enc.setViewport(MTLViewport(originX: Double(r.minX), originY: Double(r.minY),
                                            width: Double(r.width), height: Double(r.height), znear: 0, zfar: 1))
                var params = SIMD2<Int32>(Int32(rot), flip ? 1 : 0)
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&params, length: MemoryLayout<SIMD2<Int32>>.size, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentSamplerState(sampler, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
        }
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]], constant int2 &p [[buffer(0)]]) {
        const float2 quad[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 shown[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        float2 d = shown[vid];
        float2 t;
        switch (p.x) {
            case 1: t = float2(d.y, 1.0 - d.x); break;
            case 2: t = float2(1.0 - d.x, 1.0 - d.y); break;
            case 3: t = float2(1.0 - d.y, d.x); break;
            default: t = d; break;
        }
        if (p.y != 0) { t.y = 1.0 - t.y; }
        VOut o;
        o.pos = float4(quad[vid], 0.0, 1.0);
        o.uv = t;
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(tex.sample(s, in.uv).rgb, 1.0);
    }
    """
}
