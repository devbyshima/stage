import SwiftUI

/// Whether the controls show, shared by the window and the strip under it.
@MainActor
@Observable
final class ControlsState {
    var visible = true
    var pointerOver = false
}

/// The bar, or right after a recording the saved notice in its place.
struct ControlsLane: View {
    @Environment(StageModel.self) private var model
    let state: ControlsState

    var body: some View {
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
        // It floats over whatever is under the window, so it lifts off it.
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onHover { state.pointerOver = $0 }
        .padding(.horizontal, 12)
        .padding(.top, ControlsPanel.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.snappy, value: model.lastSaved)
    }
}

/// The controls in a borderless strip of their own, attached under the Stage
/// window: the window holds only the picture, with no band for them, and a
/// meeting sharing the window never shows them.
@MainActor
final class ControlsPanel {
    /// The space between the window's bottom edge and the bar, and the room
    /// under the bar for its shadow.
    static let gap: CGFloat = 10
    static let height: CGFloat = gap + 58 + 14
    static let width: CGFloat = 404

    private let panel: NSPanel
    private weak var parent: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    init(content: some View) {
        panel = StripPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Clicks work without taking the keyboard from the window, where
        // Space starts and stops recording.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        panel.contentView = NSHostingView(rootView: content)
    }

    func attach(to window: NSWindow) {
        guard parent !== window else { return }
        parent = window
        window.addChildWindow(panel, ordered: .above)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.close() }
        })
        reposition()
    }

    /// Centred under the window; inside its bottom edge instead when there's
    /// no room below it, or in full screen.
    func reposition() {
        guard let parent else { return }
        let width = min(parent.frame.width, Self.width)
        var frame = NSRect(x: parent.frame.midX - width / 2, y: parent.frame.minY - Self.height,
                           width: width, height: Self.height)
        let floor = parent.screen?.visibleFrame.minY ?? 0
        if parent.styleMask.contains(.fullScreen) || frame.minY < floor {
            frame.origin.y = parent.frame.minY + 14
        }
        panel.setFrame(frame, display: true)
    }

    func setVisible(_ visible: Bool) {
        panel.ignoresMouseEvents = !visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// Borderless panels can't become key by default, which would leave the
/// menu and slider half working.
private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
