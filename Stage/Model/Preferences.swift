@preconcurrency import AVFoundation
import Foundation
import Observation

/// Settings that survive relaunches.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    // The observation macro can route an assignment in init through the setter,
    // which would save launch arguments for good. Saving waits until loaded.
    @ObservationIgnored private var isLoaded = false

    var floatsOnTop: Bool {
        didSet { save(floatsOnTop, Key.floatsOnTop) }
    }
    /// How loud the phone plays through this Mac while showing. Off by default,
    /// so a meeting mic never picks up a second copy of the sound.
    var monitorVolume: Double {
        didSet { save(monitorVolume, Key.monitorVolume) }
    }
    var audioChoice: AudioChoice {
        didSet { save(audioChoice.storedValue, Key.audioChoice) }
    }
    var saveFolder: URL {
        didSet { save(saveFolder.path, Key.saveFolderPath) }
    }
    var askWhereToSave: Bool {
        didSet { save(askWhereToSave, Key.askWhereToSave) }
    }
    var videoFormat: VideoFormat {
        didSet { save(videoFormat.rawValue, Key.videoFormat) }
    }
    /// The source last picked by hand, shown again whenever it is connected.
    var preferredSourceID: String? {
        didSet { save(preferredSourceID, Key.preferredSourceID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        floatsOnTop = defaults.bool(forKey: Key.floatsOnTop)
        monitorVolume = defaults.double(forKey: Key.monitorVolume)
        audioChoice = AudioChoice(storedValue: defaults.string(forKey: Key.audioChoice))
        saveFolder = defaults.string(forKey: Key.saveFolderPath).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? Self.defaultSaveFolder
        askWhereToSave = defaults.bool(forKey: Key.askWhereToSave)
        videoFormat = defaults.string(forKey: Key.videoFormat).flatMap(VideoFormat.init(rawValue:)) ?? .h264
        preferredSourceID = defaults.string(forKey: Key.preferredSourceID)
        isLoaded = true
    }

    private func save(_ value: Any?, _ key: String) {
        guard isLoaded else { return }
        defaults.set(value, forKey: key)
    }

    static let defaultSaveFolder = URL.moviesDirectory.appending(path: "Stage", directoryHint: .isDirectory)

    private enum Key {
        static let floatsOnTop = "floatsOnTop"
        static let monitorVolume = "monitorVolume"
        static let audioChoice = "audioChoice"
        static let saveFolderPath = "saveFolderPath"
        static let askWhereToSave = "askWhereToSave"
        static let videoFormat = "videoFormat"
        static let preferredSourceID = "preferredSourceID"
    }
}

enum VideoFormat: String, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc
    case proRes

    var id: Self { self }

    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes: "ProRes 422 HQ"
        }
    }

    var detail: String {
        switch self {
        case .h264: "Plays everywhere, including Windows and web uploads."
        case .hevc: "About half the file size. Best for Apple devices."
        case .proRes: "Near-lossless, for editing in Final Cut or Premiere. Files are many times larger."
        }
    }

    var codec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes: .proRes422HQ
        }
    }
}
