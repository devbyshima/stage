import SwiftUI

/// The main window: the live device on black, with controls
/// that fade away when the pointer rests, so the window can be shared as is.
struct StageView: View {
    /// The strip under the device that holds the controls.
    static let controlsHeight: CGFloat = 80

    @Environment(StageModel.self) private var model
    @State private var window: NSWindow?
    @State private var controlsVisible = true
    @State private var lastActivity = Date.now
    @State private var pointerOverControls = false

    var body: some View {
        ZStack {
            Color.black
            stage
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            if model.selectedSource != nil {
                controls
            }
        }
        .frame(minWidth: 280, minHeight: 300)
        .onContinuousHover { _ in noteActivity() }
        .background(WindowReader { window = $0 })
        .onChange(of: window) { configureWindow() }
        .onChange(of: model.layout) {
            if let window { WindowFitter.fit(window, layout: model.layout, bottomInset: Self.controlsHeight) }
        }
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
                DeviceStage(layout: layout, bottomInset: Self.controlsHeight)
            } else {
                ConnectingView(source: source)
            }
        } else {
            ConnectView()
        }
    }

    /// The bar, or right after a recording the saved notice in its place, so
    /// neither ever covers the device.
    private var controls: some View {
        ZStack {
            if let saved = model.lastSaved, !model.recording.isActive {
                SavedToast(url: saved) { model.lastSaved = nil }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                ControlBar()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: 380)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .onHover { pointerOverControls = $0 }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeOut(duration: 0.25), value: controlsVisible)
        .animation(.snappy, value: model.lastSaved)
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })
    }

    private func noteActivity() {
        lastActivity = .now
        if !controlsVisible { setControls(visible: true) }
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
                || pointerOverControls
                || model.recording == .starting
                || Date.now.timeIntervalSince(lastActivity) < delay
            guard visible != controlsVisible else { continue }
            setControls(visible: visible)
            if !visible {
                model.lastSaved = nil
                if let window, window.isKeyWindow, window.frame.contains(NSEvent.mouseLocation) {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }

    private func setControls(visible: Bool) {
        controlsVisible = visible
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
        WindowFitter.fit(window, layout: model.layout, bottomInset: Self.controlsHeight)
    }

    private func updateWindowLevel() {
        window?.level = model.prefs.floatsOnTop ? .floating : .normal
    }
}

/// The live picture, edge to edge.
struct DeviceStage: View {
    @Environment(StageModel.self) private var model
    let layout: StageLayout
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let rect = layout.pictureRect(in: geometry.size, bottomInset: bottomInset)
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
