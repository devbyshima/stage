import AppKit
import Observation
import SwiftUI

/// A colour that can be saved: its sRGB components.
struct RGBA: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// What sits behind the mockup.
enum MockupBackground: Codable, Equatable, Sendable {
    case color(RGBA)
    case gradient(RGBA, RGBA)
    case image(String)
    /// Nothing: the export keeps the phones alone, for laying over slides.
    case clear

    /// A photographer's light grey sweep, a shade darker at the top.
    static let studio = MockupBackground.gradient(RGBA(0.84, 0.84, 0.84), RGBA(0.906, 0.906, 0.906))
    /// The same sweep in the dark.
    static let night = MockupBackground.gradient(RGBA(0.16, 0.16, 0.17), RGBA(0.06, 0.06, 0.07))
    static let white = MockupBackground.color(RGBA(1, 1, 1))
    static let black = MockupBackground.color(RGBA(0, 0, 0))
}

/// The exported video's frame.
enum MockupCanvas: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape
    case portrait
    case square
    case landscape4K
    case portrait4K

    var id: Self { self }

    var size: CGSize {
        switch self {
        case .landscape: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        case .landscape4K: CGSize(width: 3840, height: 2160)
        case .portrait4K: CGSize(width: 2160, height: 3840)
        }
    }

    var title: String {
        switch self {
        case .landscape: "Landscape, 1920 × 1080"
        case .portrait: "Portrait, 1080 × 1920"
        case .square: "Square, 1080 × 1080"
        case .landscape4K: "Landscape 4K, 3840 × 2160"
        case .portrait4K: "Portrait 4K, 2160 × 3840"
        }
    }

    var aspectRatio: CGFloat { size.width / size.height }
}

/// Which 3D iPhone a mockup uses.
enum MockupModel: Codable, Hashable, Sendable {
    /// One that comes with Stage, by its `MockupDevice` id.
    case device(String)
    /// The person's own USDZ file.
    case file(String)

    var url: URL? {
        switch self {
        case .device(let id): MockupLibrary.device(id)?.url
        case .file(let path): URL(filePath: path)
        }
    }

    var device: MockupDevice? {
        if case .device(let id) = self { MockupLibrary.device(id) } else { nil }
    }
}

/// How the camera moves while the video plays.
enum MockupMotion: String, Codable, CaseIterable, Identifiable, Sendable {
    case still
    case pushIn
    case pullBack
    case orbit
    case drift
    case rise
    case scroll
    case focus

    var id: Self { self }

    var title: String {
        switch self {
        case .still: "Still"
        case .pushIn: "Push In"
        case .pullBack: "Pull Back"
        case .orbit: "Orbit"
        case .drift: "Drift"
        case .rise: "Rise"
        case .scroll: "Top to Bottom"
        case .focus: "Focus Areas"
        }
    }

    /// What the motion adds at `progress` (0 to 1) through the video, at
    /// `amount` strength: degrees of turn and tilt, a zoom factor, and how
    /// far the camera's aim moves up, in phone heights.
    func offsets(at progress: Double, amount: Double) -> (yaw: Double, pitch: Double, zoom: Double, lift: Double) {
        let t = min(max(progress, 0), 1)
        let eased = t * t * (3 - 2 * t)
        switch self {
        case .still, .focus:
            // Focus areas move the camera from the scene, which knows where
            // the screen is.
            return (0, 0, 1, 0)
        case .pushIn:
            return (0, 0, 1 + 0.3 * amount * eased, 0)
        case .pullBack:
            return (0, 0, 1 + 0.3 * amount * (1 - eased), 0)
        case .orbit:
            return (amount * (40 * eased - 20), 0, 1, 0)
        case .drift:
            let wave = sin(2 * .pi * t)
            return (6 * amount * wave, 3 * amount * cos(2 * .pi * t), 1, 0.015 * amount * sin(4 * .pi * t))
        case .rise:
            return (0, amount * (12 - 16 * eased), 1 + 0.08 * amount * eased, 0)
        case .scroll:
            // Close on the top of the screen, then down to the bottom.
            return (0, 0, 1 + 0.9 * amount, 0.3 * amount * (1 - 2 * eased))
        }
    }
}

/// A part of the screen for the camera to close in on: fractions of the
/// video's width and height as it shows on the screen, from its top left.
struct MockupFocus: Codable, Equatable, Sendable {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double

    static let top = MockupFocus(x0: 0, y0: 0, x1: 1, y1: 0.38)
    static let middle = MockupFocus(x0: 0, y0: 0.31, x1: 1, y1: 0.69)
    static let bottom = MockupFocus(x0: 0, y0: 0.62, x1: 1, y1: 1)
    static let whole = MockupFocus(x0: 0, y0: 0, x1: 1, y1: 1)

    /// Inside the screen, corners in order, and no thinner than a tenth.
    var tidy: MockupFocus {
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        var area = MockupFocus(x0: clamp(min(x0, x1)), y0: clamp(min(y0, y1)), x1: clamp(max(x0, x1)), y1: clamp(max(y0, y1)))
        if area.x1 - area.x0 < 0.1 { area.x0 = min(area.x0, 0.9); area.x1 = area.x0 + 0.1 }
        if area.y1 - area.y0 < 0.1 { area.y0 = min(area.y0, 0.9); area.y1 = area.y0 + 0.1 }
        return area
    }

    var title: String {
        switch self {
        case .top: "Top"
        case .middle: "Middle"
        case .bottom: "Bottom"
        case .whole: "Whole Screen"
        default: String(format: "%.0f%% to %.0f%% down, %.0f%% to %.0f%% across", y0 * 100, y1 * 100, x0 * 100, x1 * 100)
        }
    }

    /// Where the camera is at `progress` (0 to 1) through a tour of
    /// `areas`: it rests on each in turn and glides between them.
    static func path(_ areas: [MockupFocus], at progress: Double) -> MockupFocus? {
        guard let first = areas.first else { return nil }
        guard areas.count > 1 else { return first }
        let position = min(max(progress, 0), 1) * Double(areas.count - 1)
        let index = min(Int(position), areas.count - 2)
        let travel = min(max((position - Double(index) - 0.3) / 0.4, 0), 1)
        let eased = travel * travel * (3 - 2 * travel)
        let from = areas[index]
        let to = areas[index + 1]
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * eased }
        return MockupFocus(x0: mix(from.x0, to.x0), y0: mix(from.y0, to.y0), x1: mix(from.x1, to.x1), y1: mix(from.y1, to.y1))
    }
}

/// The studio's light.
enum MockupLighting: String, Codable, CaseIterable, Identifiable, Sendable {
    case studio
    case soft
    case dramatic
    case bright

    var id: Self { self }

    var title: String {
        switch self {
        case .studio: "Studio"
        case .soft: "Soft"
        case .dramatic: "Dramatic"
        case .bright: "Bright"
        }
    }
}

/// How the video goes into the 3D iPhone, and what's around it.
struct MockupSettings: Codable, Equatable, Sendable {
    var enabled = false
    var model = MockupLibrary.standard.map { MockupModel.device($0.id) }
    /// The other phones in a shot of two or three; nil for the same as `model`.
    var pairModel: MockupModel?
    /// The model's material the video plays on. Stage finds it in its own
    /// iPhones; a person's own model may need it chosen.
    var screenPart: String?
    /// Quarter turns, and a mirror, to line the video up with the screen.
    var screenTurns = 0
    var screenFlipped = false
    var shot = MockupShot.front
    /// Degrees, on top of the shot's own angles.
    var yaw = 0.0
    var pitch = 0.0
    var zoom = 1.0
    var motion = MockupMotion.still
    var motionAmount = 1.0
    /// The parts of the screen the Focus Areas motion visits, in order.
    var focusAreas: [MockupFocus] = []
    var lighting = MockupLighting.studio
    /// Degrees the light comes round the phones.
    var lightAngle = 0.0
    /// 0 for everything sharp, up to 1 for a shallow focus on the screen.
    var depthOfField = 0.0
    var bloom = 0.0
    var grain = 0.0
    var vignette = 0.0
    var saturation = 1.0
    var contrast = 0.0
    var background = MockupBackground.studio
    var canvas = MockupCanvas.landscape

    var modelURL: URL? { model?.url }
    /// The other phones' model, when it differs from the main one.
    var pairURL: URL? { pairModel.flatMap { $0 == model ? nil : $0.url } }
    var hasEffects: Bool { bloom > 0 || grain > 0 || vignette > 0 || saturation != 1 || contrast != 0 }

    private static let storageKey = "mockup"

    /// The last mockup used, so the next video starts from it (switched off).
    static func last() -> MockupSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(MockupSettings.self, from: data) else { return MockupSettings() }
        settings.enabled = false
        settings.dropMissingModels()
        return settings
    }

    func remember() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Back to Stage's own iPhone where a model file has gone.
    mutating func dropMissingModels() {
        if modelURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            model = MockupSettings().model
        }
        if let url = pairModel?.url, !FileManager.default.fileExists(atPath: url.path) {
            pairModel = nil
        }
    }
}

extension MockupSettings {
    /// Reads what's there and keeps the defaults for the rest, so settings
    /// saved by an older Stage still open.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func read<Value: Decodable>(_ key: CodingKeys, into value: inout Value) {
            if let decoded = try? values.decodeIfPresent(Value.self, forKey: key) { value = decoded }
        }
        read(.enabled, into: &enabled)
        read(.model, into: &model)
        read(.pairModel, into: &pairModel)
        read(.screenPart, into: &screenPart)
        read(.screenTurns, into: &screenTurns)
        read(.screenFlipped, into: &screenFlipped)
        read(.shot, into: &shot)
        read(.yaw, into: &yaw)
        read(.pitch, into: &pitch)
        read(.zoom, into: &zoom)
        read(.motion, into: &motion)
        read(.motionAmount, into: &motionAmount)
        read(.focusAreas, into: &focusAreas)
        read(.lighting, into: &lighting)
        read(.lightAngle, into: &lightAngle)
        read(.depthOfField, into: &depthOfField)
        read(.bloom, into: &bloom)
        read(.grain, into: &grain)
        read(.vignette, into: &vignette)
        read(.saturation, into: &saturation)
        read(.contrast, into: &contrast)
        read(.background, into: &background)
        read(.canvas, into: &canvas)
    }
}

/// A mockup setup saved under a name, to start the next one from.
struct MockupTemplate: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var settings: MockupSettings

    private static let storageKey = "mockupTemplates"

    static func saved() -> [MockupTemplate] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([MockupTemplate].self, from: data)) ?? []
    }

    static func save(_ templates: [MockupTemplate]) {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

/// The saved templates, shared by the inspector and AI control.
@MainActor
@Observable
final class MockupTemplates {
    static let shared = MockupTemplates()

    private(set) var items = MockupTemplate.saved()

    /// Saves `settings` as `name`, replacing a template of that name.
    func save(_ name: String, settings: MockupSettings) {
        items.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        items.append(MockupTemplate(name: name, settings: settings))
        MockupTemplate.save(items)
    }

    func remove(_ template: MockupTemplate) {
        items.removeAll { $0.id == template.id }
        MockupTemplate.save(items)
    }

    func named(_ name: String) -> MockupTemplate? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
