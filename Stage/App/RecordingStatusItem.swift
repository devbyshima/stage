import AppKit

/// A red "● 1:23" in the menu bar while recording, kept out of screen
/// sharing (even of the whole screen). Clicking it stops the recording.
@MainActor
final class RecordingStatusItem: NSObject {
    var onClick: (() -> Void)?

    private var item: NSStatusItem?
    private var timer: Timer?
    private var start = Date.now

    func show(since start: Date) {
        self.start = start
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
                    .withSymbolConfiguration(.init(hierarchicalColor: .systemRed))
                image?.isTemplate = false
                button.image = image
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                button.toolTip = "Stage is recording. Click to stop."
                button.target = self
                button.action = #selector(clicked)
            }
            item.button?.window?.sharingType = .none
            self.item = item
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func tick() {
        item?.button?.title = " " + Clock.string(Date.now.timeIntervalSince(start))
    }

    @objc private func clicked() {
        onClick?()
    }
}
