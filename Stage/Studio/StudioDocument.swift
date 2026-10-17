@preconcurrency import AVFoundation
import AppKit
import Observation

/// One kept piece of the recording, by its own time in the file.
struct Segment: Identifiable, Equatable, Sendable {
    var id = UUID()
    var range: CMTimeRange
    var duration: CMTime { range.duration }
}

/// A recording open in the Studio: the pieces kept, in order, which play
/// back to back. Edits never touch the file; export writes a new one.
@MainActor
@Observable
final class StudioDocument {
    /// The shortest piece a trim or split leaves.
    static let minimumLength = CMTime(value: 1, timescale: 10)

    let url: URL
    let name: String
    let player = AVPlayer()

    private(set) var duration = CMTime.zero
    /// The picture's size as it shows, turned upright.
    private(set) var videoSize = CGSize(width: 1206, height: 2622)
    private(set) var hasAudio = false
    private(set) var loadError: String?
    private(set) var isLoaded = false
    private(set) var segments: [Segment] = []
    /// Where playback is, in the edited timeline's time.
    private(set) var currentTime = CMTime.zero
    private(set) var isPlaying = false
    /// About 60 stills spread across the recording, for the timeline.
    private(set) var thumbnails: [CGImage] = []

    var selection: Segment.ID?
    var includeAudio = true {
        didSet { rebuildPlayer() }
    }
    var mockup = MockupSettings.last() {
        didSet {
            if mockup.model != oldValue.model || mockup.pairURL != oldValue.pairURL { loadModel() }
            // A landscape recording starts on a phone lying on its side.
            if mockup.enabled, !oldValue.enabled, videoSize.width > videoSize.height, mockup.shot == .front {
                mockup.shot = .landscape
            }
            mockup.remember()
        }
    }
    private(set) var mockupScene: MockupScene?
    private(set) var mockupError: String?

    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private var videoTrack: AVAssetTrack?
    @ObservationIgnored private var audioTracks: [AVAssetTrack] = []
    @ObservationIgnored private var sourceTransform = CGAffineTransform.identity
    @ObservationIgnored private var history: [[Segment]] = []
    @ObservationIgnored private var future: [[Segment]] = []
    @ObservationIgnored private var timeObserver: Any?

    init(url: URL) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    var editedDuration: CMTime { segments.reduce(.zero) { $0 + $1.duration } }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func load() async {
        guard !isLoaded else { return }
        do {
            let (length, tracks) = try await asset.load(.duration, .tracks)
            duration = length
            videoTrack = tracks.first { $0.mediaType == .video }
            audioTracks = tracks.filter { $0.mediaType == .audio }
            hasAudio = !audioTracks.isEmpty
            guard let videoTrack else {
                loadError = "This file has no video."
                return
            }
            let (natural, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
            sourceTransform = transform
            let turned = natural.applying(transform)
            videoSize = CGSize(width: abs(turned.width), height: abs(turned.height))
            segments = [Segment(range: CMTimeRange(start: .zero, duration: duration))]
            isLoaded = true
            rebuildPlayer()
            observeTime()
            loadModel()
            await makeThumbnails()
        } catch {
            loadError = "Stage can’t open this recording. \(error.localizedDescription)"
        }
    }

    // MARK: - Edits

    /// Cuts the piece under the playhead in two there.
    func split() {
        guard let (index, offset) = locate(currentTime),
              offset > Self.minimumLength, segments[index].duration - offset > Self.minimumLength else { return }
        record()
        let piece = segments[index]
        let cut = piece.range.start + offset
        segments.replaceSubrange(index...index, with: [
            Segment(range: CMTimeRange(start: piece.range.start, end: cut)),
            Segment(range: CMTimeRange(start: cut, end: piece.range.end)),
        ])
        selection = segments[index + 1].id
        rebuildPlayer()
    }

    /// Takes the selected piece out; the rest closes up.
    func deleteSelection() {
        guard segments.count > 1, let selection, let index = segments.firstIndex(where: { $0.id == selection }) else { return }
        record()
        segments.remove(at: index)
        self.selection = nil
        rebuildPlayer()
    }

    /// Call once as a trim starts, so undo takes the whole drag back.
    func beginTrim() {
        record()
    }

    /// Moves one end of a piece, in the recording's own time.
    func trim(_ id: Segment.ID, start: CMTime? = nil, end: CMTime? = nil) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        var range = segments[index].range
        if let start {
            range = CMTimeRange(start: CMTimeClampToRange(start, range: CMTimeRange(start: .zero, end: range.end - Self.minimumLength)),
                                end: range.end)
        }
        if let end {
            range = CMTimeRange(start: range.start,
                                end: CMTimeClampToRange(end, range: CMTimeRange(start: range.start + Self.minimumLength, end: duration)))
        }
        segments[index].range = range
        rebuildPlayer()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        future.append(segments)
        segments = last
        rebuildPlayer()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(segments)
        segments = next
        rebuildPlayer()
    }

    private func record() {
        history.append(segments)
        future.removeAll()
    }

    // MARK: - Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= editedDuration - CMTime(value: 1, timescale: 30) { seek(to: .zero) }
            player.play()
        }
    }

    func seek(to time: CMTime) {
        let clamped = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: editedDuration))
        currentTime = clamped
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The piece at `time` in the edited timeline, and how far into it.
    func locate(_ time: CMTime) -> (index: Int, offset: CMTime)? {
        var start = CMTime.zero
        for (index, segment) in segments.enumerated() {
            if time < start + segment.duration || index == segments.count - 1 {
                return (index, CMTimeMaximum(.zero, time - start))
            }
            start = start + segment.duration
        }
        return nil
    }

    /// Where a piece starts in the edited timeline.
    func editedStart(of id: Segment.ID) -> CMTime {
        var start = CMTime.zero
        for segment in segments {
            if segment.id == id { return start }
            start = start + segment.duration
        }
        return start
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    private func rebuildPlayer() {
        guard isLoaded, let composition = try? makeComposition(includeAudio: includeAudio) else { return }
        let time = CMTimeMinimum(currentTime, composition.duration)
        let wasPlaying = isPlaying
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    /// The kept pieces back to back, picture and (if wanted) sound.
    func makeComposition(includeAudio: Bool) throws -> AVComposition {
        let composition = AVMutableComposition()
        guard let videoTrack,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return composition
        }
        let audio = includeAudio ? audioTracks.compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        } : []
        var cursor = CMTime.zero
        for segment in segments {
            try video.insertTimeRange(segment.range, of: videoTrack, at: cursor)
            for (source, target) in zip(audioTracks, audio) {
                try target.insertTimeRange(segment.range, of: source, at: cursor)
            }
            cursor = cursor + segment.duration
        }
        video.preferredTransform = sourceTransform
        return composition
    }

    // MARK: - Timeline stills

    /// The still nearest `time` in the recording's own time.
    func thumbnail(at time: CMTime) -> CGImage? {
        guard !thumbnails.isEmpty, duration.seconds > 0 else { return nil }
        let index = Int((time.seconds / duration.seconds * Double(thumbnails.count)).rounded(.down))
        return thumbnails[min(max(index, 0), thumbnails.count - 1)]
    }

    /// The edited video's frame at `time` in the edited timeline, as a
    /// still for a mockup image.
    func frame(at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: try makeComposition(includeAudio: false))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time).image
    }

    private func makeThumbnails() async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let count = 60
        let times = (0..<count).map { CMTime(seconds: duration.seconds * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { images.append(image) }
        }
        thumbnails = images
    }

    // MARK: - Mockup

    private func loadModel() {
        mockupError = nil
        guard let url = mockup.modelURL else {
            mockupScene = nil
            return
        }
        do {
            let scene = try MockupScene(modelURL: url, pairURL: mockup.pairURL)
            let screen = scene.useScreen(mockup.screenPart)
            if mockup.screenPart != screen { mockup.screenPart = screen }
            if scene.screenPart == nil {
                mockupError = "Choose which part of the model is the screen."
            }
            mockupScene = scene
        } catch {
            mockupScene = nil
            mockupError = "Stage can’t open this model. \(error.localizedDescription)"
        }
    }
}
