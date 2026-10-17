import SwiftUI

struct SettingsView: View {
    @Environment(StageModel.self) private var model
    @State private var camera = VirtualCameraInstaller()

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Exports") {
                LabeledContent("Export to") {
                    HStack {
                        Text(prefs.saveFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Video format", selection: $prefs.videoFormat) {
                    ForEach(VideoFormat.allCases) { Text($0.title).tag($0) }
                }
                Text(prefs.videoFormat.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Virtual Camera") {
                LabeledContent("Stage Camera") {
                    cameraControl
                }
                Text("Choose Stage Camera in Keynote (Insert › Live Video), Zoom, Meet or FaceTime to show the phone there. Stage must be in Applications, built by a team in the Apple Developer Program.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Control") {
                Toggle("Let AI tools work in the Studio", isOn: $prefs.allowsAIControl)
                if prefs.allowsAIControl {
                    LabeledContent("Command") {
                        Text("\(MCPServer.command) \(MCPServer.argument)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Button("Copy for Claude Code") { copy(claudeCodeCommand) }
                        Button("Copy MCP Config") { copy(mcpConfig) }
                    }
                }
                Text("Add Stage as an MCP server in Claude, Claude Code, Cursor or another AI tool. It can then open recordings, cut them, set up the mockup, look at it and export, while Stage is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Presenting") {
                Toggle("Float on top of other windows", isOn: $prefs.floatsOnTop)
                Text("Browsers such as Chrome and Arc can't share a floating window. Turn this off to present Stage in Google Meet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: prefs.allowsAIControl) { _, allowed in
            MCPServer.shared.setEnabled(allowed)
        }
    }

    private var claudeCodeCommand: String {
        "claude mcp add stage -- \"\(MCPServer.command)\" \(MCPServer.argument)"
    }

    /// The `mcpServers` entry most AI tools take in their settings file.
    private var mcpConfig: String {
        let config = ["mcpServers": ["stage": ["command": MCPServer.command, "args": [MCPServer.argument]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder private var cameraControl: some View {
        switch camera.state {
        case .notInThisBuild:
            Text("Not in this build")
                .foregroundStyle(.secondary)
        case .notInstalled:
            Button("Install…", action: camera.install)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .needsApproval:
            HStack {
                Text("Allow it in System Settings")
                    .foregroundStyle(.secondary)
                Button("Open") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .installed:
            HStack {
                Text("Installed")
                    .foregroundStyle(.secondary)
                Button("Remove", action: camera.remove)
            }
        case .failed(let reason):
            HStack {
                Text(reason)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Try Again", action: camera.install)
            }
        }
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
