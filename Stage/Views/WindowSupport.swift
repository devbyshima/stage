@preconcurrency import AVFoundation
import SwiftUI

/// Hosts the capture preview layer.
struct VideoPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(previewLayer: previewLayer)
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }

        // Clicks and drags pass through, so the picture moves the window.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Hands the hosting NSWindow to SwiftUI.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                self?.onChange?(self?.window)
            }
        }
    }
}

@MainActor
enum WindowFitter {
    /// Gives the window the picture's shape, keeping its size along the long
    /// side, so a rotated phone gets a rotated window, and leaves `roomBelow`
    /// on screen for the controls under it. Nil frees the shape.
    static func fit(_ window: NSWindow, layout: StageLayout?, roomBelow: CGFloat) {
        guard let layout else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            return
        }
        let current = window.contentRect(forFrameRect: window.frame).size
        var size = layout.windowSize(longSide: max(current.width, current.height, 480), bottomInset: 0)
        window.contentAspectRatio = size
        guard !window.styleMask.contains(.fullScreen),
              var visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        visible.origin.y += roomBelow
        visible.size.height -= roomBelow

        let shrink = min(1, visible.width * 0.92 / size.width, visible.height * 0.92 / size.height)
        size = CGSize(width: (size.width * shrink).rounded(), height: (size.height * shrink).rounded())

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
