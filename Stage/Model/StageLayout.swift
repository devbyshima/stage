import CoreGraphics
import Foundation

/// Where the picture sits in the window: edge to edge, above the controls.
struct StageLayout: Equatable {
    var videoSize: CGSize

    /// Width over height of the picture.
    var aspectRatio: CGFloat { videoSize.width / videoSize.height }

    /// The window size that fits the picture plus the controls strip, keeping
    /// `longSide` points along the window's long side.
    func windowSize(longSide: CGFloat, bottomInset: CGFloat) -> CGSize {
        if aspectRatio >= 1 {
            return CGSize(width: longSide, height: longSide / aspectRatio + bottomInset)
        }
        return CGSize(width: (longSide - bottomInset) * aspectRatio, height: longSide)
    }

    /// The picture's rect above a strip of `bottomInset` points kept free for
    /// the controls. It fills the space, centered if the shapes differ (full screen).
    func pictureRect(in container: CGSize, bottomInset: CGFloat = 0) -> CGRect {
        let area = CGSize(width: container.width, height: max(container.height - bottomInset, 1))
        let scale = min(area.width / videoSize.width, area.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (area.width - size.width) / 2,
            y: (area.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

enum Clock {
    /// "0:42", "12:05", "1:02:03".
    static func string(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

enum RecordingName {
    /// "Serein 2026-10-15 at 15.03.12.mov"
    static func make(for deviceName: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = deviceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(name.isEmpty ? "Recording" : name) \(formatter.string(from: date)).mov"
    }

    /// `name` in `folder`, numbered if a file already has that name.
    static func unique(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
