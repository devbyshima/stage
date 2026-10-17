@preconcurrency import AVFoundation
import CoreMediaIO

/// Owns the capture session: the live source, the optional microphone, and the
/// movie file being written. Everything that touches the session runs on
/// `queue`; results come back through `events`.
final class CaptureEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let events: AsyncStream<CaptureEvent>
    /// The phone's picture for Stage Camera, when an app is watching it.
    let virtualCamera = VirtualCameraFeed()

    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let queue = DispatchQueue(label: "com.fulltimestudio.stage.capture")
    private let frameQueue = DispatchQueue(label: "com.fulltimestudio.stage.frames")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioMonitor = AVCaptureAudioPreviewOutput()
    // Only read for frame sizes, so the window can follow the phone when it rotates.
    private let frameOutput = AVCaptureVideoDataOutput()

    // Touched on `queue` only.
    private var sourceInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var microphoneConnection: AVCaptureConnection?
    // Touched on `frameQueue` only.
    private var lastFrameSize = CGSize.zero

    override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        events = stream
        self.continuation = continuation
        super.init()

        audioMonitor.volume = 0
        frameOutput.videoSettings = [:]  // the device's own format, no conversion
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(self, queue: frameQueue)

        queue.async { [self] in
            session.beginConfiguration()
            for output in [movieOutput, audioMonitor, frameOutput] as [AVCaptureOutput] where session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionFailed(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    /// Lets iPhone and iPad screens appear as capture devices, the same switch
    /// QuickTime Player flips. They show up a moment later, over USB.
    static func allowScreenCaptureDevices() {
        for selector in [kCMIOHardwarePropertyAllowScreenCaptureDevices, kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices] {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(selector),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var allow: UInt32 = 1
            CMIOObjectSetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &allow)
        }
    }

    // MARK: - Configuration

    /// Shows `sourceID` (nil stops the session) and records `audio` with it.
    func configure(sourceID: String?, audio: AudioChoice) {
        queue.async { [self] in
            session.beginConfiguration()
            if sourceInput?.device.uniqueID != sourceID {
                if let old = sourceInput {
                    session.removeInput(old)
                    sourceInput = nil
                }
                frameQueue.async { [self] in lastFrameSize = .zero }
                if let sourceID { addSource(sourceID) }
            }
            routeAudio(audio)
            session.commitConfiguration()

            if sourceInput == nil {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
            continuation.yield(.running(session.isRunning))
        }
    }

    func setMonitorVolume(_ volume: Float) {
        queue.async { [self] in audioMonitor.volume = volume }
    }

    private func addSource(_ id: String) {
        guard let device = AVCaptureDevice(uniqueID: id) else {
            continuation.yield(.failed("That device is no longer connected."))
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                continuation.yield(.failed("Stage can’t show \(device.localizedName) right now. Another app may be using it."))
                return
            }
            // Connects itself to the preview, the movie file and the speaker monitor.
            session.addInput(input)
            sourceInput = input
        } catch {
            continuation.yield(.failed("Stage can’t open \(device.localizedName). \(error.localizedDescription)"))
        }
    }

    private func routeAudio(_ audio: AudioChoice) {
        let microphoneID = audio.microphoneID
        if let input = microphoneInput, input.device.uniqueID != microphoneID {
            if let connection = microphoneConnection { session.removeConnection(connection) }
            session.removeInput(input)
            microphoneInput = nil
            microphoneConnection = nil
        }
        if let microphoneID, microphoneInput == nil,
           let device = AVCaptureDevice(uniqueID: microphoneID),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            // Wired to the movie file only, so the speaker monitor never plays it back.
            session.addInputWithNoConnections(input)
            microphoneInput = input
            if let port = input.ports.first(where: { $0.mediaType == .audio }) {
                let connection = AVCaptureConnection(inputPorts: [port], output: movieOutput)
                if session.canAddConnection(connection) {
                    session.addConnection(connection)
                    microphoneConnection = connection
                }
            }
        }
        // The source's own sound goes into the file only when it is the chosen audio.
        for connection in movieOutput.connections where connection !== microphoneConnection {
            if connection.inputPorts.contains(where: { $0.mediaType == .audio }) {
                connection.isEnabled = audio == .source
            }
        }
    }

    @objc private func sessionFailed(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        queue.async { [self] in continuation.yield(.running(session.isRunning)) }
        // A device being unplugged also lands here; the device list handles that.
        guard error?.code != .deviceWasDisconnected else { return }
        continuation.yield(.failed("The live picture stopped. \(error?.localizedDescription ?? "")"))
    }

    // MARK: - Recording

    func startRecording(to url: URL, codec: AVVideoCodecType) {
        queue.async { [self] in
            guard sourceInput != nil, !movieOutput.isRecording else { return }
            // Left alone, macOS writes raw frames: gigabytes a minute.
            if let video = movieOutput.connection(with: .video) {
                movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: video)
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
    }
}

extension CaptureEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        continuation.yield(.recordingStarted)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        // A recording cut short (say, the cable came out) still reports an
        // error, but flags that the file is complete and playable.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        continuation.yield(.recordingFinished(outputFileURL, finished ? nil : error))
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { virtualCamera.send(pixels) }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        guard size != lastFrameSize, size.width > 0, size.height > 0 else { return }
        lastFrameSize = size
        continuation.yield(.videoSize(size))
    }
}
