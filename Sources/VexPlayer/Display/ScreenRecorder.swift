import Accelerate
import AVFoundation
import CoreVideo
import QuartzCore

/// Hardware HEVC screen recording straight from the shared frame buffer.
final class ScreenRecorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var startTime: CFTimeInterval = 0
    private var lastPTS = CMTime.invalid

    init(url: URL, width: Int, height: Int, rotation: Int) throws {
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 6,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        // Rotation is metadata only: players turn the picture, we never touch pixels.
        input.transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 2)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func append(_ source: UnsafeRawPointer, width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, width == self.width, height == self.height else { return }
        let now = CACurrentMediaTime()
        if !started {
            writer.startSession(atSourceTime: .zero)
            startTime = now
            started = true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let pb = out else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width * 4)
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let rgbaToBGRA: [UInt8] = [2, 1, 0, 3]
        vImagePermuteChannels_ARGB8888(&src, &dst, rgbaToBGRA, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pb, [])

        let pts = CMTime(seconds: now - startTime, preferredTimescale: 6000)
        if lastPTS.isValid && pts <= lastPTS { return }
        if adaptor.append(pb, withPresentationTime: pts) { lastPTS = pts }
    }

    func finish() async {
        let shouldFinish: Bool = lock.withLock {
            defer { finished = true }
            return !finished && started
        }
        guard shouldFinish else {
            writer.cancelWriting()
            return
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
