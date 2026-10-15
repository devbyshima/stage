import SwiftUI

/// QuickTime-style controls: speaker on the left, record in the middle,
/// time and options on the right.
struct ControlBar: View {
    @Environment(StageModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VolumeControl(volume: Binding(
                get: { model.prefs.monitorVolume },
                set: { model.setMonitorVolume($0) }))
                .disabled(model.selectedSource == nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            RecordButton(state: model.recording, action: model.toggleRecording)
                .disabled(!model.canRecord && !model.recording.isActive)

            HStack(spacing: 12) {
                RecordingClock(state: model.recording)
                OptionsMenu()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.8), in: .capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
        .environment(\.colorScheme, .dark)
    }
}

struct RecordButton: View {
    let state: StageModel.RecordingState
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    private var isRecording: Bool {
        if case .recording = state { true } else { state == .stopping }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
                RoundedRectangle(cornerRadius: isRecording ? 4 : 14, style: .continuous)
                    .fill(Color(red: 1, green: 0.23, blue: 0.19))
                    .frame(width: isRecording ? 16 : 28, height: isRecording ? 16 : 28)
            }
            .frame(width: 40, height: 40)
            .contentShape(.circle)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: isRecording)
        .help(isRecording ? "Stop recording (Space)" : "Start recording (Space)")
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
    }
}

struct RecordingClock: View {
    let state: StageModel.RecordingState

    var body: some View {
        Group {
            if case .recording(let since) = state {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Clock.string(context.date.timeIntervalSince(since)))
                        .foregroundStyle(.white)
                }
            } else {
                Text("0:00")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .frame(minWidth: 40, alignment: .trailing)
        .accessibilityLabel("Recording time")
    }
}

struct VolumeControl: View {
    @Binding var volume: Double
    @State private var volumeBeforeMute = 0.8

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if volume > 0 {
                    volumeBeforeMute = volume
                    volume = 0
                } else {
                    volume = volumeBeforeMute
                }
            } label: {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: volume)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(volume == 0 ? "Play the device’s sound on this Mac" : "Mute on this Mac")

            Slider(value: $volume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 64)
                .accessibilityLabel("Volume on this Mac")
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// Source, audio and look, in one menu.
struct OptionsMenu: View {
    @Environment(StageModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Menu {
            Section("Show") {
                Picker("Show", selection: sourceSelection) {
                    ForEach(model.sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.recording.isActive)
            }

            Section("Record Sound From") {
                Picker("Record Sound From", selection: audioSelection) {
                    if let source = model.selectedSource {
                        Text(source.name).tag(AudioChoice.source)
                    }
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(AudioChoice.microphone(microphone.id))
                    }
                    Text("No Sound").tag(AudioChoice.off)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.recording.isActive)
            }

            Divider()
            Toggle("Float on Top", isOn: $prefs.floatsOnTop)

            Divider()
            Button("Open Recordings Folder") { model.openRecordingsFolder() }
            SettingsLink { Text("Settings…") }
        } label: {
            Image(systemName: "chevron.down.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Device, sound and look")
        .accessibilityLabel("Options")
    }

    private var sourceSelection: Binding<String> {
        Binding(
            get: { model.selectedSourceID ?? "" },
            set: { model.choose(sourceID: $0) })
    }

    private var audioSelection: Binding<AudioChoice> {
        Binding(
            get: { model.effectiveAudio },
            set: { model.chooseAudio($0) })
    }
}

struct SavedToast: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording saved")
                    .font(.callout.weight(.semibold))
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .help("Show in Finder")
            Button("Play") { NSWorkspace.shared.open(url) }
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Back to the controls")
            .accessibilityLabel("Dismiss")
        }
        .controlSize(.small)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 58)
        .background(.black.opacity(0.8), in: .capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
        .environment(\.colorScheme, .dark)
    }
}
