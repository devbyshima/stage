@preconcurrency import CoreMediaIO
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import IOKit.audio

/// What Stage Camera sends: 1920 × 1080 at 30 frames a second, the phone
/// fitted in the middle on black. Stage composes the frames to this.
enum CameraFormat {
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let frameDuration = CMTime(value: 1, timescale: 30)
}

/// The provider Core Media IO talks to: one device, Stage Camera.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: "Stage Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Stage Camera couldn't add its device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { providerProperties.manufacturer = "Stage" }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// The camera. Its sink stream takes Stage's frames in; its source stream
/// hands them to whoever is watching (Keynote, Zoom, Meet), and keeps a
/// steady dark frame coming when Stage isn't sending.
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CameraStreamSource!
    private var sinkStream: CameraSinkSource!
    private var format: CMFormatDescription!
    private var pool: CVPixelBufferPool!

    private let queue = DispatchQueue(label: "com.fulltimestudio.stage.camera.frames")
    // Touched on `queue` only.
    private var timer: DispatchSourceTimer?
    private var isSending = false
    private var lastFrameFromStage: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: UUID(uuidString: "4F1D6B2A-7C3E-4A59-9E21-5B8D0C7A3F64")!,
            legacyDeviceID: nil, source: self)
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: CameraFormat.width, height: CameraFormat.height, extensions: nil, formatDescriptionOut: &format)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(CameraFormat.width),
            kCVPixelBufferHeightKey as String: Int(CameraFormat.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format, maxFrameDuration: CameraFormat.frameDuration,
            minFrameDuration: CameraFormat.frameDuration, validFrameDurations: nil)
        sourceStream = CameraStreamSource(
            localizedName: "Stage Camera", streamID: UUID(uuidString: "A3C2E7F1-1B9D-4E6A-8C25-0D4F7B9E2A13")!,
            format: streamFormat, device: device)
        sinkStream = CameraSinkSource(
            localizedName: "Stage Camera Input", streamID: UUID(uuidString: "C8E1B4D2-6F3A-4B7C-9D05-2E8A1F6C4B97")!,
            format: streamFormat, device: device)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Stage Camera couldn't add its streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { deviceProperties.model = "Stage Camera" }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Sending

    func startSending() {
        queue.async { [self] in
            guard !isSending else { return }
            isSending = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: CameraFormat.frameDuration.seconds)
            timer.setEventHandler { [weak self] in self?.sendPlaceholderIfQuiet() }
            timer.resume()
            self.timer = timer
        }
    }

    func stopSending() {
        queue.async { [self] in
            isSending = false
            timer?.cancel()
            timer = nil
        }
    }

    /// A frame from Stage, straight to the watchers.
    func forward(_ sampleBuffer: CMSampleBuffer) {
        // Handed over once and not touched here again.
        nonisolated(unsafe) let frame = sampleBuffer
        queue.async { [self] in
            let now = Self.hostTimeNanoseconds()
            lastFrameFromStage = now
            guard isSending else { return }
            sourceStream.stream.send(frame, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    /// With nothing from Stage for half a second, a dark frame, so the
    /// picture in Keynote doesn't freeze on the last thing it showed.
    private func sendPlaceholderIfQuiet() {
        let now = Self.hostTimeNanoseconds()
        guard isSending, now - lastFrameFromStage > 500_000_000 else { return }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess, let buffer = made else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x10, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var timing = CMSampleTimingInfo(
            duration: CameraFormat.frameDuration,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
    }

    static func hostTimeNanoseconds() -> UInt64 {
        UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
    }
}

/// What watchers read.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let format: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.format = format
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { streamProperties.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { streamProperties.frameDuration = CameraFormat.frameDuration }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? CameraDeviceSource)?.startSending()
    }

    func stopStream() throws {
        (device.source as? CameraDeviceSource)?.stopSending()
    }
}

/// What Stage writes into.
final class CameraSinkSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let format: CMIOExtensionStreamFormat
    private let lock = NSLock()
    private var client: CMIOExtensionClient?
    private var isRunning = false

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.format = format
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { streamProperties.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { streamProperties.frameDuration = CameraFormat.frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { streamProperties.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { streamProperties.sinkBuffersRequiredForStartup = 1 }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        lock.withLock { self.client = client }
        return true
    }

    func startStream() throws {
        let client = lock.withLock { () -> CMIOExtensionClient? in
            isRunning = true
            return self.client
        }
        if let client { consume(from: client) }
    }

    func stopStream() throws {
        lock.withLock { isRunning = false }
    }

    /// Takes Stage's frames one after another while the stream runs.
    private func consume(from client: CMIOExtensionClient) {
        guard lock.withLock({ isRunning }) else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequence, _, _, _ in
            guard let self else { return }
            if let sampleBuffer {
                (device.source as? CameraDeviceSource)?.forward(sampleBuffer)
                stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(
                    sequenceNumber: sequence, hostTimeInNanoseconds: CameraDeviceSource.hostTimeNanoseconds()))
            }
            consume(from: client)
        }
    }
}
