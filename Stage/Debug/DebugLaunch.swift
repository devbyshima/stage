#if DEBUG
@preconcurrency import AVFoundation
import SceneKit
import SwiftUI

/// Launch arguments for checking the app without an iPhone attached. Each
/// takes a value: a lone word is read as a file to open, and then macOS
/// skips opening the window.
///
///   -demo <state>             a drawn phone screen instead of live capture;
///                             idle, recording, saved, landscape, connecting
///                             or empty
///   -snapshot <file.png>      save the window (the Studio's, with -studio) as
///                             a PNG after a moment, then quit
///   -snapshotDelay <seconds>  how long that moment is; 2.5 by default
///   -snapshotHeight <points>  make the window this tall first, to see more
///   -snapshotInspector <png>  with -studioMockup: the whole mockup inspector
///   -snapshotSettings <png>   the Settings window's contents
///   -autoRecord <seconds>     record the live source that long, then quit
///   -capturableControls YES   leave the controls strip in screenshots, which
///                             screen sharing otherwise leaves out
///   -look light|dark          the app in that appearance, whatever the Mac's
///   -studio <movie>           open the movie in the Studio
///   -studioMockup <model>     with -studio: the mockup on, with this iPhone
///                             ("iPhone 18 Pro - Silver") or USDZ file
///   -studioShot <shot>        with -studioMockup: this shot (front, pair, ...)
///   -studioMotion <motion>    with -studioMockup: this camera motion (orbit, ...)
///   -studioBackground clear   with -studioMockup: a clear background
///   -studioEdit pieces        with -studio: split in three, the middle selected
///   -studioExport <file.mov>  with -studio: export as set up, then quit
///   -studioStill <file.png>   with -studioMockup: export the first frame as a
///                             still, then quit
@MainActor
enum DebugLaunch {
    static let arguments = ProcessInfo.processInfo.arguments

    static var demoState: String? { value(after: "-demo") }
    static var isDemo: Bool { demoState != nil }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func scheduleChecks(model: StageModel) {
        switch value(after: "-look") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let path = value(after: "-studio") {
            model.openStudio(URL(filePath: path))
        }
        if let path = value(after: "-snapshot") {
            Task {
                if let height = value(after: "-snapshotHeight").flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(1.5))
                    for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                        var frame = window.frame
                        frame.size.height = height
                        window.setFrame(frame, display: true)
                    }
                }
                try? await Task.sleep(for: .seconds(value(after: "-snapshotDelay").flatMap(Double.init) ?? 2.5))
                snapshotWindow(to: URL(filePath: path))
                NSApp.terminate(nil)
            }
        }
        if let path = value(after: "-snapshotSettings") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                snapshot(SettingsView().environment(model), width: 480, height: 900, to: URL(filePath: path))
            }
        }
        if let seconds = value(after: "-autoRecord").flatMap(Double.init) {
            Task { await autoRecord(model, seconds: seconds) }
        }
    }

    /// Runs once a Studio has loaded its recording.
    static func studioChecks(document: StudioDocument, format: VideoFormat) async {
        if let name = value(after: "-studioMockup") {
            document.mockup.model = MockupLibrary.device(name) != nil ? .device(name) : .file(name)
            document.mockup.enabled = true
        }
        if let shot = value(after: "-studioShot").flatMap(MockupShot.init(rawValue:)) {
            document.mockup.shot = shot
        }
        if let motion = value(after: "-studioMotion").flatMap(MockupMotion.init(rawValue:)) {
            if motion == .focus, document.mockup.focusAreas.isEmpty { document.mockup.focusAreas = [.top, .bottom] }
            document.mockup.motion = motion
        }
        if value(after: "-studioBackground") == "clear" {
            document.mockup.background = .clear
        }
        if let path = value(after: "-snapshotInspector") {
            try? await Task.sleep(for: .seconds(4))
            snapshotInspector(document: document, to: URL(filePath: path))
        }
        if value(after: "-studioEdit") == "pieces" {
            let length = document.editedDuration.seconds
            document.seek(to: CMTime(seconds: length * 0.4, preferredTimescale: 600))
            document.split()
            document.seek(to: CMTime(seconds: length * 0.7, preferredTimescale: 600))
            document.split()
            document.selection = document.segments.dropFirst().first?.id
        }
        if let path = value(after: "-studioStill") {
            do {
                try await ExportJob.exportStill(document, to: URL(filePath: path))
                print("studioStill: done")
            } catch {
                print("studioStill: failed", error)
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
        if let path = value(after: "-studioExport") {
            do {
                try await ExportJob.export(document, format: format, to: URL(filePath: path), job: nil)
                print("studioExport: done")
            } catch {
                print("studioExport: failed", error)
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static func snapshotWindow(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        let studio = windows.first { $0.identifier?.rawValue.contains(StudioView.windowID) == true }
        guard let window = (value(after: "-studio") != nil ? studio : nil) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("snapshot: no window among", NSApp.windows.map { "\($0) visible=\($0.isVisible)" })
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // 3D views draw with Metal, which caching leaves blank: draw their
        // own snapshots over them.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for scene in sceneViews(in: view) {
            var frame = scene.convert(scene.bounds, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            scene.snapshot().draw(in: frame)
        }
        NSGraphicsContext.restoreGraphicsState()
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            print("snapshot:", error)
        }
    }

    /// The mockup inspector laid out at full height in a window of its own,
    /// which is never shown.
    private static func snapshotInspector(document: StudioDocument, to url: URL) {
        snapshot(MockupInspector(document: document), width: 320, height: 2600, to: url)
    }

    /// `view` laid out at that size in a window that's never shown.
    private static func snapshot(_ view: some View, width: CGFloat, height: CGFloat, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSApp.effectiveAppearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func sceneViews(in view: NSView) -> [SCNView] {
        view.subviews.flatMap { subview in
            (subview as? SCNView).map { [$0] } ?? sceneViews(in: subview)
        }
    }

    private static func autoRecord(_ model: StageModel, seconds: Double) async {
        var waited = 0
        while !model.canRecord, waited < 240 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
            print("autoRecord: waiting; camera access \(model.cameraAccess.rawValue), source \(model.selectedSource?.name ?? "none"),",
                  "running \(model.isRunning), size \(String(describing: model.videoSize)), sources \(model.sources.map(\.name))")
        }
        print("autoRecord: starting, can record \(model.canRecord)")
        model.startRecording()
        try? await Task.sleep(for: .seconds(seconds))
        model.stopRecording()
        waited = 0
        while model.recording.isActive, waited < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        print("autoRecord: done, recorded \(model.lastRecording?.path ?? "nothing"), alert \(model.alertMessage ?? "none")")
        NSApp.terminate(nil)
    }
}

/// A made-up home screen standing in for a live iPhone.
struct DemoScreen: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.2, green: 0.18, blue: 0.55), Color(red: 0.93, green: 0.47, blue: 0.4)],
                    startPoint: .top, endPoint: .bottom)
                VStack(spacing: width * 0.08) {
                    Text("9:41")
                        .font(.system(size: width * 0.045, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, width * 0.1)
                        .padding(.top, width * 0.05)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: width * 0.06), count: 4),
                              spacing: width * 0.08) {
                        ForEach(0..<20, id: \.self) { index in
                            RoundedRectangle(cornerRadius: width * 0.045, style: .continuous)
                                .fill(Color(hue: Double(index) / 20, saturation: 0.5, brightness: 0.97))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .padding(.horizontal, width * 0.07)
                }
            }
        }
    }
}
#endif
