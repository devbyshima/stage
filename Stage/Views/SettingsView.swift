import SwiftUI

struct SettingsView: View {
    @Environment(StageModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Recordings") {
                LabeledContent("Save in") {
                    HStack {
                        Text(prefs.saveFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("When a recording stops", selection: $prefs.askWhereToSave) {
                    Text("Save it in this folder").tag(false)
                    Text("Ask where to save it").tag(true)
                }
                Picker("Video format", selection: $prefs.videoFormat) {
                    ForEach(VideoFormat.allCases) { Text($0.title).tag($0) }
                }
                Text(prefs.videoFormat.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Presenting") {
                Toggle("Float on top of other windows", isOn: $prefs.floatsOnTop)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.prefs.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.prefs.saveFolder = url
        }
    }
}
