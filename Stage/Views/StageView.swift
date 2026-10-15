import SwiftUI

/// The main window: the live device edge to edge, nothing else. Its controls
/// float in a strip under it (`ControlsPanel`) and fade away when the pointer
/// rests, so the window can be shared as is.
struct StageView: View {
    @Environment(StageModel.self) private var model
    @State private var window: NSWindow?
    @State private var controls = ControlsState()
    @State private var panel: ControlsPanel?
    @State private var lastActivity = Date.now

    var body: some View {
        ZStack {
            Color.black
            stage
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 280, minHeight: 300)
        .onContinuousHover { _ in noteActivity() }
        .background(WindowReader { window = $0 })
        .onChange(of: window) { configureWindow() }
        .onChange(of: model.layout) {
            if let window { WindowFitter.fit(window, layout: model.layout, roomBelow: ControlsPanel.height) }
        }
        .onChange(of: controls.visible) { updatePanel() }
        .onChange(of: model.selectedSourceID) { updatePanel() }
        .onChange(of: model.isLive) { updateWindowButtons() }
        .background {
            // Space starts and stops recording even while the controls are hidden.
            Button("Start or Stop Recording", action: model.toggleRecording)
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: model.prefs.floatsOnTop) { updateWindowLevel() }
        .onChange(of: model.lastSaved) { _, saved in
            if saved != nil { noteActivity() }
        }
        .task { await hideControlsWhenIdle() }
        .alert("Stage", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder private var stage: some View {
        if model.cameraAccess == .denied || model.cameraAccess == .restricted {
            AccessNeededView()
        } else if let source = model.selectedSource {
            if let layout = model.layout {
                DeviceStage(layout: layout)
            } else {
                ConnectingView(source: source)
            }
        } else {
            ConnectView()
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })
    }

    private func noteActivity() {
        lastActivity = .now
        if !controls.visible { controls.visible = true }
    }

    /// Hides the controls and pointer once the pointer rests.
    private func hideControlsWhenIdle() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            #if DEBUG
            if DebugLaunch.isDemo { continue }
            #endif
            let delay: TimeInterval = model.lastSaved == nil ? 2.5 : 8
            let visible = !model.isLive
                || controls.pointerOver
                || model.recording == .starting
                || Date.now.timeIntervalSince(lastActivity) < delay
            guard visible != controls.visible else { continue }
            controls.visible = visible
            if !visible {
                model.lastSaved = nil
                if let window, window.isKeyWindow, window.frame.contains(NSEvent.mouseLocation) {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }

    /// The strip shows with a device chosen, while the controls are up.
    private func updatePanel() {
        panel?.setVisible(controls.visible && model.selectedSource != nil)
    }

    /// The close, minimize and zoom buttons would sit on the picture, so they
    /// stay hidden while a phone is showing. ⌘W, ⌘M and ⌃⌘F still work.
    private func updateWindowButtons() {
        guard let window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = model.isLive
        }
    }

    private func configureWindow() {
        guard let window else { return }
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        updateWindowLevel()
        updateWindowButtons()
        if panel == nil {
            panel = ControlsPanel(content: ControlsLane(state: controls).environment(model))
        }
        panel?.attach(to: window)
        updatePanel()
        WindowFitter.fit(window, layout: model.layout, roomBelow: ControlsPanel.height)
    }

    private func updateWindowLevel() {
        window?.level = model.prefs.floatsOnTop ? .floating : .normal
    }
}

/// The live picture, edge to edge.
struct DeviceStage: View {
    @Environment(StageModel.self) private var model
    let layout: StageLayout

    var body: some View {
        GeometryReader { geometry in
            let rect = layout.pictureRect(in: geometry.size)
            picture
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    @ViewBuilder private var picture: some View {
        #if DEBUG
        if model.isDemo {
            DemoScreen()
                .clipped()
        } else {
            VideoPreview(previewLayer: model.previewLayer)
        }
        #else
        VideoPreview(previewLayer: model.previewLayer)
        #endif
    }
}
