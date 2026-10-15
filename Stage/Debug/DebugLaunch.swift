#if DEBUG
import SwiftUI

/// Launch arguments for checking the app without an iPhone attached. Each
/// takes a value: a lone word is read as a file to open, and then macOS
/// skips opening the window.
///
///   -demo <state>             a drawn phone screen instead of live capture;
///                             idle, recording, saved, landscape or empty
///   -snapshot <file.png>      save the window as a PNG after a moment, then quit
///   -autoRecord <seconds>     record the live source that long, then quit
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
        if let path = value(after: "-snapshot") {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                snapshotWindow(to: URL(filePath: path))
                NSApp.terminate(nil)
            }
        }
        if let seconds = value(after: "-autoRecord").flatMap(Double.init) {
            Task { await autoRecord(model, seconds: seconds) }
        }
    }

    private static func snapshotWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("snapshot: no window among", NSApp.windows.map { "\($0) visible=\($0.isVisible)" })
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            print("snapshot:", error)
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
        print("autoRecord: done, saved \(model.lastSaved?.path ?? "nothing"), alert \(model.alertMessage ?? "none")")
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
