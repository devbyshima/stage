@preconcurrency import AVFoundation
import CoreImage
@preconcurrency import CoreMediaIO
import Observation
import SystemExtensions

/// Sends the phone's picture to Stage Camera, the virtual camera Keynote's
/// Live Video, Zoom and Meet can choose, while one of them is watching.
/// Frames are fitted into its 1920 × 1080 on black.
final class VirtualCameraFeed: @unchecked Sendable {
    static let deviceName = "Stage Camera"
    static let size = CGSize(width: 1920, height: 1080)

    private let queue = DispatchQueue(label: "com.fulltimestudio.stage.virtual-camera")
    private let images = CIContext(options: [.cacheIntermediates: false])
    // Touched on `queue` only.
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var pool: CVPixelBufferPool?
    private var format: CMFormatDescription?
    private var lastCheck = Date.distantPast

    /// One frame of the phone, in whatever format it came.
    func send(_ pixelBuffer: CVPixelBuffer) {
        nonisolated(unsafe) let frame = pixelBuffer
        queue.async { [self] in
            checkWatchers()
            guard let bufferQueue, CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue),
                  let sample = compose(frame) else { return }
            CMSimpleQueueEnqueue(bufferQueue, element: Unmanaged.passRetained(sample).toOpaque())
        }
    }

    /// Every couple of seconds: is Stage Camera there, and is anyone using it?
    /// The stream into it only runs while someone is.
    private func checkWatchers() {
        guard Date().timeIntervalSince(lastCheck) > 2 else { return }
        lastCheck = Date()
        if deviceID == 0 || !Self.exists(deviceID) { (deviceID, sinkStreamID) = Self.findCamera() }
        guard deviceID != 0 else {
            stopSink()
            return
        }
        let watched: UInt32 = Self.property(deviceID, kCMIODevicePropertyDeviceIsRunningSomewhere) ?? 0
        if watched != 0, bufferQueue == nil {
            startSink()
        } else if watched == 0, bufferQueue != nil {
            stopSink()
        }
    }

    private func startSink() {
        var queue: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sinkStreamID, { _, _, _ in }, nil, &queue) == noErr, let queue else { return }
        bufferQueue = queue.takeRetainedValue()
        CMIODeviceStartStream(deviceID, sinkStreamID)
    }

    private func stopSink() {
        guard bufferQueue != nil else { return }
        CMIODeviceStopStream(deviceID, sinkStreamID)
        bufferQueue = nil
    }

    /// The phone fitted into 1920 × 1080, centred on black, stamped now.
    private func compose(_ frame: CVPixelBuffer) -> CMSampleBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(Self.size.width),
                kCVPixelBufferHeightKey as String: Int(Self.size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        var made: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess,
              let output = made else { return nil }

        let phone = CIImage(cvPixelBuffer: frame)
        let scale = min(Self.size.width / phone.extent.width, Self.size.height / phone.extent.height)
        let fitted = phone.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = fitted.transformed(by: CGAffineTransform(
            translationX: (Self.size.width - fitted.extent.width) / 2 - fitted.extent.minX,
            y: (Self.size.height - fitted.extent.height) / 2 - fitted.extent.minY))
        let canvas = CGRect(origin: .zero, size: Self.size)
        images.render(placed.composited(over: CIImage(color: .black).cropped(to: canvas)), to: output)

        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: output, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    // MARK: - Core Media IO lookups

    /// Stage Camera's device and the stream Stage writes into.
    static func findCamera() -> (CMIOObjectID, CMIOStreamID) {
        for device in objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) {
            guard name(of: device) == deviceName else { continue }
            let streams = objects(device, kCMIODevicePropertyStreams)
            // The sink stream: data flowing into the device, direction 0.
            let sink = streams.first { (property($0, kCMIOStreamPropertyDirection) as UInt32?) == 0 } ?? streams.last
            if let sink { return (device, sink) }
        }
        return (0, 0)
    }

    static var isInstalled: Bool { findCamera().0 != 0 }

    private static func exists(_ device: CMIOObjectID) -> Bool {
        objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).contains(device)
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func property<Value: FixedWidthInteger>(_ object: CMIOObjectID, _ selector: Int) -> Value? {
        var address = address(selector)
        var value: Value = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &used, &value) == noErr else { return nil }
        return value
    }

    private static func name(of object: CMIOObjectID) -> String? {
        var address = address(kCMIOObjectPropertyName)
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// Installs and removes Stage Camera, the system extension inside Stage.
@MainActor
@Observable
final class VirtualCameraInstaller: NSObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        /// Stage was built without it; see project-camera.yml.
        case notInThisBuild
        case notInstalled
        case working
        case needsApproval
        case installed
        case failed(String)
    }

    static let extensionID = "com.fulltimestudio.stage.camera"

    private(set) var state: State = VirtualCameraFeed.isInstalled ? .installed : isEmbedded ? .notInstalled : .notInThisBuild

    /// Whether Stage Camera is inside this copy of Stage.
    static var isEmbedded: Bool {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(extensionID).systemextension")
        return FileManager.default.fileExists(atPath: url.path)
    }

    func install() {
        submit(.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main))
    }

    func remove() {
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        state = .working
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            state = VirtualCameraFeed.isInstalled || result == .willCompleteAfterReboot ? .installed : .notInstalled
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { state = .failed(message) }
    }
}
