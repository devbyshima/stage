@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The Studio: a recording's editor. Trim, split and remove pieces, keep or
/// drop the sound, put it in a 3D mockup, and export.
struct StudioView: View {
    static let windowID = "studio"

    @Environment(StageModel.self) private var model
    @State private var document: StudioDocument
    @State private var showsExport = false

    init(url: URL) {
        _document = State(initialValue: StudioDocument(url: url))
    }

    var body: some View {
        Group {
            if let error = document.loadError {
                ContentUnavailableView("Can’t Open This Recording", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        preview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                        if document.mockup.enabled {
                            Divider()
                            MockupInspector(document: document)
                                .frame(width: 320)
                        }
                    }
                    Divider()
                    TransportBar(document: document)
                    EditTimeline(document: document)
                        .frame(height: 86)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .navigationTitle(document.name)
        .toolbar { toolbar }
        .task {
            await document.load()
            #if DEBUG
            await DebugLaunch.studioChecks(document: document, format: model.prefs.videoFormat)
            #endif
        }
        .sheet(isPresented: $showsExport) {
            ExportSheet(document: document, format: model.prefs.videoFormat, folder: model.prefs.saveFolder)
        }
        .onDisappear { document.player.pause() }
    }

    @ViewBuilder private var preview: some View {
        if document.mockup.enabled {
            if let scene = document.mockupScene {
                MockupPreview(mockup: scene, player: document.player, videoSize: document.videoSize,
                              progress: document.currentTime.seconds / max(document.editedDuration.seconds, 0.001),
                              settings: $document.mockup)
                    .background { if document.mockup.background == .clear { Checkerboard() } }
                    .aspectRatio(document.mockup.canvas.aspectRatio, contentMode: .fit)
                    .padding(20)
                    .help("Drag to turn the phones, scroll to size them, double-click to reset")
            } else {
                ContentUnavailableView {
                    Label("Choose a 3D iPhone", systemImage: "iphone")
                } description: {
                    Text("Pick a model on the right. Stage plays the video on its screen.")
                }
            }
        } else {
            PlayerPreview(player: document.player)
                .padding(20)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Undo", systemImage: "arrow.uturn.backward", action: document.undo)
                .keyboardShortcut("z")
                .disabled(!document.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward", action: document.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!document.canRedo)
        }
        ToolbarItemGroup {
            Button("Split at Playhead", systemImage: "scissors", action: document.split)
                .keyboardShortcut("b")
                .help("Split at the playhead (⌘B)")
            Button("Delete Piece", systemImage: "trash", action: document.deleteSelection)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(document.selection == nil || document.segments.count < 2)
                .help("Remove the selected piece (Delete)")
        }
        ToolbarItemGroup {
            Toggle(isOn: $document.includeAudio) {
                Label("Sound", systemImage: document.includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .disabled(!document.hasAudio)
            .help(document.includeAudio ? "Keep the sound" : "Leave the sound out")
            Toggle(isOn: $document.mockup.enabled) {
                Label("Mockup", systemImage: "iphone")
            }
            .help("Put the video on a 3D iPhone")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Export…") { showsExport = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e")
                .disabled(!document.isLoaded)
        }
    }
}

/// Grey and white squares, where a clear background lets them show.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(white: 0.92))
            for row in 0..<Int((size.height / side).rounded(.up)) {
                for column in 0..<Int((size.width / side).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)),
                                 with: .color(white: 0.78))
                }
            }
        }
    }
}

/// The edited video as it plays, without a mockup.
private struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct TransportBar: View {
    let document: StudioDocument

    var body: some View {
        HStack(spacing: 12) {
            Button(action: document.togglePlay) {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help(document.isPlaying ? "Pause (Space)" : "Play (Space)")
            Text("\(Clock.string(document.currentTime.seconds)) / \(Clock.string(document.editedDuration.seconds))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if document.segments.count > 1 {
                Text("\(document.segments.count) pieces")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The edited timeline: a ruler to scrub, the pieces as film strips (click
/// to select, drag the yellow handles to trim), and the playhead.
private struct EditTimeline: View {
    @Bindable var document: StudioDocument
    private let gap: CGFloat = 3
    private let rulerHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let layout = TimelineLayout(segments: document.segments, width: geometry.size.width, gap: gap)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 6) {
                    ruler(layout)
                        .frame(height: rulerHeight)
                    HStack(spacing: gap) {
                        ForEach(document.segments) { segment in
                            SegmentStrip(document: document, segment: segment,
                                         pointsPerSecond: layout.pointsPerSecond,
                                         isSelected: document.selection == segment.id)
                                .frame(width: layout.width(of: segment))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .leading)
                }
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: geometry.size.height)
                    .offset(x: layout.x(for: document.currentTime) - 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func ruler(_ layout: TimelineLayout) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.08))
            HStack {
                Text(Clock.string(0))
                Spacer()
                Text(Clock.string(document.editedDuration.seconds))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .clipShape(.rect(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            document.seek(to: layout.time(at: value.location.x))
        })
        .help("Drag to move through the video")
    }
}

/// Where each piece sits across the timeline's width.
private struct TimelineLayout {
    let segments: [Segment]
    let width: CGFloat
    let gap: CGFloat

    var pointsPerSecond: CGFloat {
        let total = segments.reduce(0) { $0 + $1.duration.seconds }
        let usable = width - gap * CGFloat(max(segments.count - 1, 0))
        return total > 0 ? usable / total : 0
    }

    func width(of segment: Segment) -> CGFloat {
        max(segment.duration.seconds * pointsPerSecond, 4)
    }

    /// The x of an edited-timeline time.
    func x(for time: CMTime) -> CGFloat {
        var x: CGFloat = 0
        var start = 0.0
        for segment in segments {
            let length = segment.duration.seconds
            if time.seconds <= start + length { return x + (time.seconds - start) * pointsPerSecond }
            x += width(of: segment) + gap
            start += length
        }
        return min(x, width)
    }

    /// The edited-timeline time at an x.
    func time(at x: CGFloat) -> CMTime {
        var left: CGFloat = 0
        var start = 0.0
        for segment in segments {
            let span = width(of: segment)
            if x <= left + span + gap / 2 {
                let into = min(max((x - left) / max(pointsPerSecond, 0.0001), 0), segment.duration.seconds)
                return CMTime(seconds: start + into, preferredTimescale: 600)
            }
            left += span + gap
            start += segment.duration.seconds
        }
        return CMTime(seconds: start, preferredTimescale: 600)
    }
}

/// One piece as a film strip of stills from its own part of the recording.
private struct SegmentStrip: View {
    let document: StudioDocument
    let segment: Segment
    let pointsPerSecond: CGFloat
    let isSelected: Bool
    @State private var dragOrigin: CMTime?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let aspect = document.videoSize.width / max(document.videoSize.height, 1)
            let tile = max(height * aspect, 12)
            let count = max(Int((geometry.size.width / tile).rounded(.up)), 1)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    let fraction = (CGFloat(index) + 0.5) * tile / max(geometry.size.width, 1)
                    let time = segment.range.start + CMTime(seconds: segment.duration.seconds * min(fraction, 1), preferredTimescale: 600)
                    Group {
                        if let image = document.thumbnail(at: time) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .frame(width: tile, height: height)
                    .clipped()
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .leading)
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.yellow, lineWidth: 3)
                }
            }
            .overlay(alignment: .leading) { if isSelected { handle(isStart: true) } }
            .overlay(alignment: .trailing) { if isSelected { handle(isStart: false) } }
            .contentShape(Rectangle())
            .onTapGesture { location in
                document.selection = segment.id
                let start = document.editedStart(of: segment.id)
                document.seek(to: start + CMTime(seconds: location.x / max(pointsPerSecond, 0.0001), preferredTimescale: 600))
            }
        }
    }

    /// A yellow grip on one end of the selected piece; drag it to trim.
    private func handle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 10)
            .overlay {
                Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragOrigin == nil {
                        document.beginTrim()
                        dragOrigin = isStart ? segment.range.start : segment.range.end
                    }
                    guard let origin = dragOrigin else { return }
                    let moved = origin + CMTime(seconds: value.translation.width / max(pointsPerSecond, 0.0001), preferredTimescale: 600)
                    if isStart {
                        document.trim(segment.id, start: moved)
                    } else {
                        document.trim(segment.id, end: moved)
                    }
                }
                .onEnded { _ in dragOrigin = nil })
            .help(isStart ? "Drag to trim the start" : "Drag to trim the end")
    }
}

/// What an export makes.
enum ExportKind: String, CaseIterable, Identifiable {
    case video = "Video"
    case still = "Still Image"

    var id: Self { self }
}

/// One export, from the save panel to a finished file.
@MainActor
@Observable
final class ExportJob {
    enum Phase: Equatable {
        case ready
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    var phase = Phase.ready
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(_ document: StudioDocument, kind: ExportKind, format: VideoFormat, to url: URL) {
        phase = .exporting(0)
        task = Task {
            do {
                switch kind {
                case .video: try await Self.export(document, format: format, to: url, job: self)
                case .still: try await Self.exportStill(document, to: url)
                }
                phase = .done(url)
            } catch is CancellationError {
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    fileprivate func report(_ fraction: Double) {
        if case .exporting = phase { phase = .exporting(fraction) }
    }

    static func export(_ document: StudioDocument, format: VideoFormat, to url: URL, job: ExportJob?) async throws {
        let composition = try document.makeComposition(includeAudio: document.includeAudio)
        let progress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in job?.report(fraction) }
        }
        if document.mockup.enabled, let modelURL = document.mockup.modelURL {
            // Its own scene, used by the export alone.
            let scene = try MockupScene(modelURL: modelURL, pairURL: document.mockup.pairURL)
            try await MockupExport.run(composition, mockup: scene, settings: document.mockup, format: format,
                                       to: url, progress: progress)
        } else {
            try await PlainExport.run(composition, format: format, to: url, progress: progress)
        }
    }

    /// The mockup at the playhead as a 5K PNG.
    static func exportStill(_ document: StudioDocument, to url: URL) async throws {
        guard let modelURL = document.mockup.modelURL else { throw StudioExportError.unsupported }
        let frame = try await document.frame(at: document.currentTime)
        let scene = try MockupScene(modelURL: modelURL, pairURL: document.mockup.pairURL)
        let progress = document.currentTime.seconds / max(document.editedDuration.seconds, 0.001)
        try await MockupStill.render(frame, mockup: scene, settings: document.mockup, progress: progress, to: url)
    }
}

private struct ExportSheet: View {
    let document: StudioDocument
    @State var format: VideoFormat
    let folder: URL
    @State private var kind = ExportKind.video
    @State private var job = ExportJob()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.title3.weight(.semibold))
            if document.mockup.enabled {
                Picker("Export", selection: $kind) {
                    ForEach(ExportKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(isExporting)
            }
            if kind == .video {
                Picker("Format", selection: $format) {
                    ForEach(VideoFormat.allCases) { Text($0.title).tag($0) }
                }
                .disabled(isExporting)
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            switch job.phase {
            case .ready:
                EmptyView()
            case .exporting(let fraction):
                if kind == .still { ProgressView() } else { ProgressView(value: fraction) }
            case .done(let url):
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let reason):
                Text(reason)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                switch job.phase {
                case .exporting:
                    Button("Stop") { job.cancel() }
                case .done(let url):
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                default:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export…", action: chooseDestination)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var isExporting: Bool {
        if case .exporting = job.phase { true } else { false }
    }

    private var summary: String {
        let mockup = document.mockup
        guard mockup.enabled else {
            let sound = document.includeAudio && document.hasAudio ? "with sound" : "without sound"
            return "\(Clock.string(document.editedDuration.seconds)) as recorded, "
                + "\(Int(document.videoSize.width)) × \(Int(document.videoSize.height)), \(sound)."
        }
        let phone = mockup.model?.device.map { "\($0.family) in \($0.finish)" } ?? "your 3D model"
        let clear = mockup.background == .clear
        switch kind {
        case .still:
            let size = MockupStill.size(for: mockup.canvas)
            return "The frame at \(Clock.string(document.currentTime.seconds)) on \(phone), \(mockup.shot.title) shot, "
                + "\(Int(size.width)) × \(Int(size.height)) PNG\(clear ? " with a clear background" : "")."
        case .video:
            let sound = document.includeAudio && document.hasAudio ? "with sound" : "without sound"
            let alpha = clear ? (format == .proRes ? ", clear background in ProRes 4444" : ", clear background in HEVC with alpha") : ""
            return "\(Clock.string(document.editedDuration.seconds)) on \(phone), \(mockup.shot.title) shot, "
                + "\(mockup.canvas.title.lowercased())\(alpha), \(sound)."
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        let still = document.mockup.enabled && kind == .still
        panel.nameFieldStringValue = "\(document.name) \(document.mockup.enabled ? "mockup" : "edited").\(still ? "png" : "mov")"
        panel.directoryURL = folder
        panel.allowedContentTypes = [still ? .png : .quickTimeMovie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        job.start(document, kind: still ? .still : .video, format: format, to: url)
    }
}
