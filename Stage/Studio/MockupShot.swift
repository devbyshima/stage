import simd

/// A framing from a product shoot: where each phone floats and how the
/// camera sees them. Lengths are in phone heights.
enum MockupShot: String, Codable, CaseIterable, Identifiable, Sendable {
    case front
    case turn
    case lean
    case hero
    case lying
    case corner
    case landscape
    case pair
    case stack
    case mirror
    case trio
    case float

    var id: Self { self }

    var title: String {
        switch self {
        case .front: "Front"
        case .turn: "Turn"
        case .lean: "Lean"
        case .hero: "Hero"
        case .lying: "Lying"
        case .corner: "Corner"
        case .landscape: "Landscape"
        case .pair: "Pair"
        case .stack: "Stack"
        case .mirror: "Mirror"
        case .trio: "Trio"
        case .float: "Float"
        }
    }

    /// One phone of the shot. Angles are degrees: the phone is first spun
    /// in its own plane (roll), then turned (yaw), then tipped (pitch).
    /// At zero it stands upright with its screen to the camera.
    struct Phone: Sendable {
        var position = SIMD3<Float>.zero
        var pitch: Float = 0
        var yaw: Float = 0
        var roll: Float = 0
    }

    struct Layout: Sendable {
        /// The first is the one showing its screen best; a second finish
        /// goes on the rest.
        var phones: [Phone]
        /// The camera's vertical field of view in degrees: small for a flat,
        /// long-lens look, wide for a close, dramatic one.
        var lens: Float
        /// Where the camera looks from, in degrees round the focus:
        /// left or right, then up or down.
        var azimuth: Float = 0
        var elevation: Float = 0
        /// The point the camera centres on.
        var focus = SIMD3<Float>.zero
        /// How much must stay in the frame round the focus, width and height.
        var visible: SIMD2<Float>
    }

    var layout: Layout {
        switch self {
        case .front:
            Layout(phones: [Phone()], lens: 12, visible: [0.62, 1.32])
        case .turn:
            Layout(phones: [Phone(pitch: 6, yaw: -34, roll: -14)], lens: 18, visible: [0.8, 1.36])
        case .lean:
            Layout(phones: [Phone(pitch: 56)], lens: 58, focus: [0, 0.1, 0.22], visible: [0.75, 0.8])
        case .hero:
            Layout(phones: [Phone(pitch: 26)], lens: 34, focus: [0, 0.27, 0.12], visible: [1.1, 0.62])
        case .lying:
            Layout(phones: [Phone(pitch: -76, roll: 16)], lens: 40, elevation: 4, focus: [-0.04, 0.0, -0.06], visible: [1.55, 0.87])
        case .corner:
            Layout(phones: [Phone(yaw: 38, roll: 22)], lens: 24, focus: [-0.2, 0.36, 0.1], visible: [0.42, 0.24])
        case .landscape:
            Layout(phones: [
                Phone(position: [0, 0.27, 0], pitch: -6, roll: 90),
                Phone(position: [0, 0, 0], pitch: 90, roll: 90),
            ], lens: 18, elevation: 6, focus: [0, 0.18, 0], visible: [1.3, 0.73])
        case .pair:
            Layout(phones: [
                Phone(position: [0, 0.24, 0], pitch: 66),
                Phone(position: [0, -0.27, 0], pitch: -82, yaw: 180),
            ], lens: 50, focus: [0, 0.03, 0], visible: [1.1, 1.42])
        case .stack:
            Layout(phones: [
                Phone(position: [0, 0.25, 0], pitch: 80),
                Phone(position: [0, -0.27, 0], pitch: -82, yaw: 180),
            ], lens: 50, visible: [1.1, 1.3])
        case .mirror:
            Layout(phones: [
                Phone(position: [0, -0.25, 0], pitch: -82),
                Phone(position: [0, 0.25, 0], pitch: -98),
            ], lens: 50, visible: [1.1, 1.3])
        case .trio:
            Layout(phones: [
                Phone(position: [0, 0.17, 0.05], pitch: 66),
                Phone(position: [0, 0.46, -0.32], pitch: -98),
                Phone(position: [0, -0.35, 0], pitch: -82),
            ], lens: 50, focus: [0, 0.04, 0], visible: [1.1, 1.42])
        case .float:
            Layout(phones: [
                Phone(position: [0.02, -0.04, 0.06], pitch: 45, roll: 20),
                Phone(position: [-0.17, 0.12, -0.22], pitch: 45, yaw: 180, roll: -20),
            ], lens: 30, focus: [-0.03, 0.02, 0], visible: [1.05, 1.3])
        }
    }
}
