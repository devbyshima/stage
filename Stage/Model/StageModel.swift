import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// The app's state: which devices are connected, which one is on stage, and
/// whether it is being recorded.
@MainActor
@Observable
final class StageModel {
    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping

        var isActive: Bool { self != .idle }
    }

    let prefs = Preferences()
    private(set) var sources: [CaptureSource] = []
    private(set) var microphones: [Microphone] = []
    private(set) var selectedSourceID: String?
    /// The live picture's size in pixels; nil until the first frame arrives.
    private(set) var videoSize: CGSize?
    private(set) var isRunning = false
    private(set) var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var recording = RecordingState.idle
    /// The recording just finished, offered in the controls strip until they
    /// hide, and by File › Edit Last Recording after.
    var lastRecording: URL?
    /// A recording to open in the Studio; the window that can open it does.
    var studioRequest: URL?
    var alertMessage: String?
    private(set) var isDemo = false

    @ObservationIgnored let engine = CaptureEngine()
    @ObservationIgnored let previewLayer: AVCaptureVideoPreviewLayer
    @ObservationIgnored private let statusItem = RecordingStatusItem()
    @ObservationIgnored private var deviceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var configureTask: Task<Void, Never>?
    @ObservationIgnored private var appliedAudio: AudioChoice?
    @ObservationIgnored private var displayActivity: (any NSObjectProtocol)?
    @ObservationIgnored private var quitHandler: (() -> Void)?

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: engine.session)
        previewLayer.videoGravity = .resizeAspectFill
        statusItem.onClick = { [weak self] in self?.stopRecording() }
    }

    var selectedSource: CaptureSource? { sources.first { $0.id == selectedSourceID } }
    var isLive: Bool { layout != nil }
    var canRecord: Bool { isLive && isRunning && recording == .idle }

    var layout: StageLayout? {
        guard let videoSize, selectedSource != nil else { return nil }
        return StageLayout(videoSize: videoSize)
    }

    /// The audio actually recorded: the chosen one, or the phone's own sound
    /// if the chosen microphone is gone.
    var effectiveAudio: AudioChoice {
        if case .microphone(let id) = prefs.audioChoice, !microphones.contains(where: { $0.id == id }) {
            return .source
        }
        return prefs.audioChoice
    }

    // MARK: - Devices

    func start() {
        CaptureEngine.allowScreenCaptureDevices()
        engine.setMonitorVolume(Float(prefs.monitorVolume))
        Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events { self?.handle(event) }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        refreshDevices()
        // Phones appear a moment after screen capture is allowed.
        Task { [weak self] in
            for delay in [1.0, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                self?.refreshDevices()
            }
        }
    }

    func refreshDevices() {
        guard !isDemo else { return }
        sources = CaptureSource.available()
        microphones = Microphone.available()
        if let id = selectedSourceID, sources.contains(where: { $0.id == id }) {
            if appliedAudio != nil, effectiveAudio != appliedAudio, !recording.isActive { applyConfiguration() }
            return
        }
        // The shown device went away (or nothing was shown): pick the next best.
        let preferred = sources.first { $0.id == prefs.preferredSourceID }
        setSource(preferred?.id ?? sources.first?.id)
    }

    /// Shows a source the person picked.
    func choose(sourceID: String) {
        guard sourceID != selectedSourceID, !recording.isActive else { return }
        prefs.preferredSourceID = sourceID
        setSource(sourceID)
    }

    func chooseAudio(_ choice: AudioChoice) {
        guard !recording.isActive else { return }
        prefs.audioChoice = choice
        applyConfiguration()
    }

    func setMonitorVolume(_ volume: Double) {
        prefs.monitorVolume = volume
        engine.setMonitorVolume(Float(volume))
    }

    private func setSource(_ id: String?) {
        guard id != selectedSourceID else { return }
        selectedSourceID = id
        videoSize = nil
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard !isDemo else { return }
        configureTask?.cancel()
        let sourceID = selectedSourceID
        configureTask = Task { [weak self] in
            guard let self else { return }
            let audio = effectiveAudio
            if sourceID != nil {
                // macOS counts a plugged-in iPhone screen as a camera.
                guard await requestAccess(for: .video) else {
                    engine.configure(sourceID: nil, audio: .off)
                    return
                }
                if audio != .off { _ = await requestAccess(for: .audio) }
            }
            guard !Task.isCancelled else { return }
            appliedAudio = audio
            engine.configure(sourceID: sourceID, audio: audio)
        }
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: mediaType) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: mediaType)
        }
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        if mediaType == .video { cameraAccess = status }
        return status == .authorized
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .running(let running):
            isRunning = running
            updateDisplayActivity()
        case .videoSize(let size):
            if selectedSourceID != nil { videoSize = size }
        case .recordingStarted:
            let start = Date.now
            recording = .recording(since: start)
            statusItem.show(since: start)
            if quitHandler != nil { stopRecording() }
        case .recordingFinished(let url, let error):
            recording = .idle
            statusItem.hide()
            finishRecording(at: url, error: error)
        case .failed(let message):
            alertMessage = message
        }
    }

    /// Keeps the Mac's display awake while a device is on stage.
    private func updateDisplayActivity() {
        if isRunning, displayActivity == nil {
            displayActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Showing a live device screen")
        } else if !isRunning, let activity = displayActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displayActivity = nil
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        switch recording {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .starting, .stopping: break
        }
    }

    func startRecording() {
        guard canRecord, let source = selectedSource else { return }
        // Recordings wait in Stage's own folder for the Studio.
        let folder = RecordingLibrary.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            alertMessage = "Stage can’t keep recordings in “\(folder.path)”. \(error.localizedDescription)"
            return
        }
        lastRecording = nil
        recording = .starting
        let url = RecordingName.unique(RecordingName.make(for: source.name, at: .now), in: folder)
        engine.startRecording(to: url, codec: prefs.videoFormat.codec)
    }

    func stopRecording() {
        guard case .recording = recording else { return }
        recording = .stopping
        engine.stopRecording()
    }

    /// Stops a recording in progress so the file is complete before quitting.
    func finishRecordingForQuit(then done: @escaping () -> Void) {
        quitHandler = done
        stopRecording()
    }

    private func finishRecording(at url: URL, error: (any Error)?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "The recording couldn’t be saved. \(error?.localizedDescription ?? "")"
            quitHandler?()
            return
        }
        if let quitHandler {
            quitHandler()
        } else {
            lastRecording = url
        }
    }

    /// Asks the window to open `url` in the Studio.
    func openStudio(_ url: URL) {
        studioRequest = url
    }

    /// Any movie on the Mac, to trim or put in a mockup.
    func chooseMovieForStudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = RecordingLibrary.folder
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url { self?.openStudio(url) }
            }
        }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: prefs.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(prefs.saveFolder)
    }

    // MARK: - Demo

    #if DEBUG
    /// A fake phone on stage, for checking the design without a device.
    func startDemo(_ state: String) {
        isDemo = true
        let phone = CaptureSource(id: "demo", name: "Serein")
        sources = state == "empty" ? [] : [phone]
        microphones = [Microphone(id: "mic", name: "MacBook Pro Microphone")]
        guard state != "empty" else { return }
        // Chosen, with no picture yet: the connecting screen.
        guard state != "connecting" else {
            selectedSourceID = phone.id
            return
        }
        selectedSourceID = phone.id
        videoSize = state == "landscape" ? CGSize(width: 2622, height: 1206) : CGSize(width: 1206, height: 2622)
        isRunning = true
        switch state {
        case "recording": recording = .recording(since: .now.addingTimeInterval(-83))
        case "saved": lastRecording = RecordingLibrary.folder.appending(path: RecordingName.make(for: phone.name, at: .now))
        default: break
        }
    }
    #endif
}
