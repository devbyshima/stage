@preconcurrency import AVFoundation

/// What the engines report back to the model.
enum CaptureEvent: Sendable {
    case running(Bool)
    case videoSize(CGSize)
    case recordingStarted
    case recordingFinished(URL, (any Error)?)
    case failed(String)
}

/// A connected iPhone or iPad screen.
struct CaptureSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    /// Phone and tablet screens arrive as one stream of picture and sound,
    /// which sets them apart from cameras.
    static func available() -> [CaptureSource] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        return discovery.devices
            .map { CaptureSource(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct Microphone: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static func available() -> [Microphone] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return discovery.devices
            .filter { !$0.hasMediaType(.muxed) }
            .map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Where a recording's sound comes from.
enum AudioChoice: Hashable, Sendable {
    /// The phone's own sound.
    case source
    case microphone(String)
    case off

    init(storedValue: String?) {
        switch storedValue {
        case "off": self = .off
        case let value? where value.hasPrefix("mic:"): self = .microphone(String(value.dropFirst(4)))
        default: self = .source
        }
    }

    var storedValue: String {
        switch self {
        case .source: "source"
        case .microphone(let id): "mic:\(id)"
        case .off: "off"
        }
    }

    var microphoneID: String? {
        if case .microphone(let id) = self { id } else { nil }
    }
}
