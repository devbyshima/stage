import SwiftUI

@main
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

        Button("Open Recordings Folder") {
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
