import SwiftUI

struct StageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Stage", id: "stage") {
            StageView()
                .environment(appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 420, height: 820)
        .commands { StageCommands(model: appDelegate.model) }

        WindowGroup("Studio", id: StudioView.windowID, for: URL.self) { $url in
            if let url {
                StudioView(url: url)
                    .environment(appDelegate.model)
            }
        }
        .defaultSize(width: 1120, height: 800)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = StageModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let state = DebugLaunch.demoState {
            model.startDemo(state)
        } else {
            model.start()
        }
        DebugLaunch.scheduleChecks(model: model)
        #else
        model.start()
        #endif
        StageTools.shared.model = model
        MCPServer.shared.setEnabled(model.prefs.allowsAIControl)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPServer.shared.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.recording.isActive, !model.isDemo else { return .terminateNow }
        // Let the movie file finish so it plays everywhere.
        model.finishRecordingForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct StageCommands: Commands {
    let model: StageModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            RecordingCommands(model: model)
        }
        CommandGroup(before: .toolbar) {
            LookCommands(prefs: model.prefs)
            Divider()
        }
    }
}

private struct RecordingCommands: View {
    let model: StageModel

    var body: some View {
        Button(model.recording.isActive ? "Stop Recording" : "Start Recording") {
            model.toggleRecording()
        }
        .keyboardShortcut("r")
        .disabled(!model.canRecord && !model.recording.isActive)

        Divider()

        Button("Edit Last Recording") {
            if let recording = model.lastRecording ?? RecordingLibrary.recent(limit: 1).first {
                model.openStudio(recording)
            }
        }
        .keyboardShortcut("l")

        Button("Open in Studio…") {
            model.chooseMovieForStudio()
        }
        .keyboardShortcut("o")

        Menu("Recent Recordings") {
            let recent = RecordingLibrary.recent()
            ForEach(recent, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { model.openStudio(url) }
            }
            if recent.isEmpty {
                Text("No Recordings Yet")
            }
        }

        Divider()

        Button("Show Exports Folder") {
            model.openRecordingsFolder()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

private struct LookCommands: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Toggle("Float on Top", isOn: $prefs.floatsOnTop)
            .keyboardShortcut("t", modifiers: [.command, .option])
    }
}
