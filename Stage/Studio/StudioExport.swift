@preconcurrency import AVFoundation
import AppKit
import CoreImage
import SceneKit

enum StudioExportError: LocalizedError {
    case unsupported
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This format can't be written on this Mac."
        case .failed(let reason): reason
        }
    }
}

/// Writes the edited video as it is: the kept pieces, re-encoded once.
enum PlainExport {
    static func run(_ composition: AVComposition, format: VideoFormat, to url: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let preset = switch format {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .proRes: AVAssetExportPresetAppleProRes422LPCM
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw StudioExportError.unsupported
        }
        // The session reports its own progress to any task while it exports.
        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.2) {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mov)
    }
}

/// Renders the edited video inside the person's 3D model, frame by frame,
/// and writes it with its sound. Cancel the calling task to stop it.
enum MockupExport {
    /// `mockup` must be this export's own scene, not the preview's.
    @concurrent
    static func run(_ composition: AVComposition, mockup: MockupScene, settings: MockupSettings, format: VideoFormat,
                    to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw StudioExportError.failed("There's no video to export.")
        }
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let size = settings.canvas.size
        try? FileManager.default.removeItem(at: url)

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        // Sound comes out as plain stereo, whatever was recorded, for AAC.
        let audioOutput: AVAssetReaderAudioMixOutput? = audioTracks.isEmpty ? nil : AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        let frames = reader.outputProvider(for: videoOutput)
        var sounds: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?
        if let audioOutput { sounds = reader.outputProvider(for: audioOutput) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec(for: format, transparent: settings.background == .clear),
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let pictureAttributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: Int(size.width), height: Int(size.height)))
        let pictures = writer.inputPixelBufferReceiver(for: videoInput, pixelBufferAttributes: pictureAttributes)
        let audioInput: AVAssetWriterInput? = audioOutput == nil ? nil : AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        var soundTrack: AVAssetWriterInput.SampleBufferReceiver?
        if let audioInput { soundTrack = writer.inputReceiver(for: audioInput) }

        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = mockup.scene
        renderer.pointOfView = mockup.cameraNode
        mockup.useScreen(settings.screenPart)
        let images = CIContext()
        let total = max(composition.duration.seconds, 0.001)
        // Frames up to 1080p render at twice the size and scale down, for
        // edges as clean as a still render's.
        let supersample: CGFloat = max(size.width, size.height) <= 1920 ? 2 : 1
        let renderSize = CGSize(width: size.width * supersample, height: size.height * supersample)

        do {
            // Sound copies alongside the picture, so the writer can
            // interleave the two however it needs.
            async let soundCopied: Void = copy(sounds, into: soundTrack)
            while let next = try await frames.next() {
                try Task.checkCancellation()
                let time = next.presentationTimeStamp
                if case .pixelBuffer(let pixels) = next.content,
                   let still = pixels.withUnsafeBuffer({ images.createCGImage(CIImage(cvPixelBuffer: $0), from: CIImage(cvPixelBuffer: $0).extent) }) {
                    mockup.show(still, size: CGSize(width: still.width, height: still.height),
                                turns: settings.screenTurns, flipped: settings.screenFlipped)
                    mockup.apply(settings, progress: time.seconds / total)
                    let shot = renderer.snapshot(atTime: time.seconds, with: renderSize, antialiasingMode: .multisampling4X)
                    try await pictures.append(try picture(of: shot, size: size, pool: pictures.pixelBufferPool,
                                                          attributes: pictureAttributes, images: images), with: time)
                }
                progress(min(time.seconds / total, 1))
            }
            pictures.finish()
            try await soundCopied
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw StudioExportError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "The export didn't finish.")
        }
    }

    /// A transparent background needs a codec that keeps alpha: ProRes 4444,
    /// or HEVC with alpha, which Keynote and Safari play.
    static func codec(for format: VideoFormat, transparent: Bool) -> AVVideoCodecType {
        guard transparent else { return format.codec }
        return format == .proRes ? .proRes4444 : .hevcWithAlpha
    }

    @concurrent
    private static func copy(_ sounds: sending AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?,
                             into track: sending AVAssetWriterInput.SampleBufferReceiver?) async throws {
        guard let sounds, let track else { return }
        while let sample = try await sounds.next() {
            try Task.checkCancellation()
            try await track.append(sample)
        }
        track.finish()
    }

    /// The rendered frame, scaled to the canvas, filling a buffer for the writer.
    private static func picture(of shot: NSImage, size: CGSize, pool: CVMutablePixelBuffer.Pool?,
                                attributes: CVPixelBufferCreationAttributes, images: CIContext) throws -> CVReadOnlyPixelBuffer {
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let rendered = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw StudioExportError.failed("Stage couldn't render the mockup.")
        }
        let image = CIImage(cgImage: rendered)
        let scale = size.height / image.extent.height
        let fitted = image
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: size.width / image.extent.width / scale,
            ])
            .cropped(to: CGRect(origin: .zero, size: size))
        let buffer = try pool?.makeMutablePixelBuffer() ?? CVMutablePixelBuffer(attributes)
        buffer.withUnsafeBuffer { images.render(fitted, to: $0) }
        return CVReadOnlyPixelBuffer(buffer)
    }
}

/// One frame of the mockup as a PNG, up to 5K on its long side.
enum MockupStill {
    static let longSide: CGFloat = 5120

    /// The size a still of `canvas` comes out at.
    static func size(for canvas: MockupCanvas) -> CGSize {
        let scale = longSide / max(canvas.size.width, canvas.size.height)
        return CGSize(width: (canvas.size.width * scale).rounded(), height: (canvas.size.height * scale).rounded())
    }

    /// `frame` on the mockup's screens, `progress` through the video's motion.
    @concurrent
    static func render(_ frame: CGImage, mockup: MockupScene, settings: MockupSettings, progress: Double,
                       to url: URL) async throws {
        let size = size(for: settings.canvas)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = mockup.scene
        renderer.pointOfView = mockup.cameraNode
        mockup.useScreen(settings.screenPart)
        mockup.show(frame, size: CGSize(width: frame.width, height: frame.height),
                    turns: settings.screenTurns, flipped: settings.screenFlipped)
        mockup.apply(settings, progress: progress)
        let shot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let image = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw StudioExportError.failed("Stage couldn't render the mockup.")
        }
        try data.write(to: url)
    }
}
