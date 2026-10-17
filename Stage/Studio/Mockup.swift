import AppKit
@preconcurrency import AVFoundation
import SceneKit
import SwiftUI

/// The 3D scene: the shot's phones, lit like a studio shoot, with the
/// video on their screens. The preview uses one on the main thread; an
/// export builds its own and uses it on its own task alone.
final class MockupScene: @unchecked Sendable {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// The model's materials by name, to choose the screen from.
    let parts: [String]
    private(set) var screenPart: String?

    /// One phone, a phone-height tall, centred, its screen facing +z.
    private let phone: SCNNode
    /// The other phones of a shot of two or three, when they're another
    /// model or finish.
    private let pair: SCNNode?
    /// Turn and Tilt, round the shot's focus.
    private let turn = SCNNode()
    /// The shot's phones: copies of `phone` (and `pair`) sharing their
    /// materials, so the video plays on every screen.
    private let group = SCNNode()
    private let key = SCNNode()
    private let fill = SCNNode()
    private var arranged: MockupShot?
    private var lit: (MockupLighting, Double)?
    private var backdrop: (MockupBackground, CGSize)?
    private let materials: [SCNMaterial]
    private let pairScreens: [SCNMaterial]
    private var screenMaterials: [SCNMaterial] = []
    private var originals: [ObjectIdentifier: (diffuse: Any?, emission: Any?, lighting: SCNMaterial.LightingModel)] = [:]
    /// The screen's width over its height, as the model was made.
    private var screenAspect: CGFloat = 0.46
    private var shownContents: AnyObject?

    init(modelURL: URL, pairURL: URL? = nil) throws {
        (phone, materials) = try Self.load(modelURL)
        if let pairURL, let (node, pairMaterials) = try? Self.load(pairURL) {
            pair = node
            pairScreens = pairMaterials.filter { Self.looksLikeScreen($0.name ?? "") }
        } else {
            pair = nil
            pairScreens = []
        }
        parts = materials.compactMap(\.name).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        turn.addChildNode(group)
        scene.rootNode.addChildNode(turn)

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 60
        camera.wantsExposureAdaptation = false
        camera.focalBlurSampleCount = 24
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        key.light = keyLight
        scene.rootNode.addChildNode(key)
        let fillLight = SCNLight()
        fillLight.type = .ambient
        fill.light = fillLight
        scene.rootNode.addChildNode(fill)
    }

    /// A model, scaled to a phone-height tall and centred, and its materials.
    private static func load(_ url: URL) throws -> (SCNNode, [SCNMaterial]) {
        let source = try SCNScene(url: url, options: [.convertToYUp: true])
        let content = SCNNode()
        for child in source.rootNode.childNodes {
            child.removeFromParentNode()
            content.addChildNode(child)
        }
        // Models that move, like a fold opening, hold still at rest.
        content.enumerateHierarchy { node, _ in node.removeAllAnimations() }

        let (low, high) = bounds(of: content, in: content)
        let size = SCNVector3(high.x - low.x, high.y - low.y, high.z - low.z)
        let scale = 1 / max(size.x, size.y, size.z, 0.0001)
        content.scale = SCNVector3(scale, scale, scale)
        content.position = SCNVector3(-(low.x + high.x) / 2 * scale, -(low.y + high.y) / 2 * scale, -(low.z + high.z) / 2 * scale)
        let node = SCNNode()
        node.addChildNode(content)

        var found: [SCNMaterial] = []
        content.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] where !found.contains(where: { $0 === material }) {
                found.append(material)
            }
        }
        for (index, material) in found.enumerated() where (material.name ?? "").isEmpty {
            material.name = "Part \(index + 1)"
        }
        return (node, found)
    }

    /// A part named like a screen; for a fold, the big one inside.
    private static func looksLikeScreen(_ name: String) -> Bool {
        if name.localizedCaseInsensitiveContains("screen_outer") { return false }
        return name.localizedCaseInsensitiveContains("screen") || name.localizedCaseInsensitiveContains("display")
    }

    // MARK: - Screen

    /// Makes `name` the screen, or, with no name, the part named like one.
    @discardableResult
    func useScreen(_ name: String?) -> String? {
        let chosen = name.flatMap { parts.contains($0) ? $0 : nil } ?? parts.first { Self.looksLikeScreen($0) }
        guard chosen != screenPart || screenMaterials.isEmpty else { return chosen }
        for material in screenMaterials {
            if let original = originals[ObjectIdentifier(material)] {
                material.diffuse.contents = original.diffuse
                material.emission.contents = original.emission
                material.lightingModel = original.lighting
                material.emission.contentsTransform = SCNMatrix4Identity
            }
        }
        screenMaterials = materials.filter { $0.name == chosen } + pairScreens
        for material in screenMaterials {
            originals[ObjectIdentifier(material)] = (material.diffuse.contents, material.emission.contents, material.lightingModel)
            // The video lights the screen itself, in its own colours: no
            // studio light falls on it to grey its blacks.
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.black
            material.emission.intensity = 1
            material.emission.wrapS = .clampToBorder
            material.emission.wrapT = .clampToBorder
        }
        screenAspect = measureScreen() ?? screenAspect
        screenPart = chosen
        shownContents = nil
        return chosen
    }

    /// The screen's width over its height, from the meshes it covers.
    private func measureScreen() -> CGFloat? {
        var low = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, 0)
        var high = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0)
        phone.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  geometry.materials.contains(where: { material in screenMaterials.contains { $0 === material } }) else { return }
            let (a, b) = Self.bounds(of: node, in: phone)
            low = SCNVector3(min(low.x, a.x), min(low.y, a.y), 0)
            high = SCNVector3(max(high.x, b.x), max(high.y, b.y), 0)
        }
        guard high.x > low.x, high.y > low.y else { return nil }
        return (high.x - low.x) / (high.y - low.y)
    }

    /// Puts `contents` (an AVPlayer for the preview, a frame for export),
    /// a video of `size`, on the screen, turned and mirrored to fit.
    func show(_ contents: AnyObject, size: CGSize, turns: Int, flipped: Bool) {
        // A landscape recording on a portrait screen (or the other way) turns
        // a quarter to fill it, upright as the Landscape shot holds the phone.
        let crosswise = (size.width > size.height) != (screenAspect > 1)
        let turns = turns + (crosswise ? Self.quarterTurn : 0)
        let transform = Self.screenTransform(video: size, screen: screenAspect, turns: turns, flipped: flipped)
        for material in screenMaterials {
            if shownContents !== contents { material.emission.contents = contents }
            material.emission.contentsTransform = transform
        }
        shownContents = contents
    }

    // MARK: - Shot

    /// The shot, its angle, motion, light and look, and the background, for
    /// a frame of `settings.canvas` at `progress` (0 to 1) through the video.
    func apply(_ settings: MockupSettings, progress: Double = 0) {
        if arranged != settings.shot { arrange(settings.shot) }
        let layout = settings.shot.layout
        let move = settings.motion.offsets(at: progress, amount: settings.motionAmount)
        let focus = SCNVector3(layout.focus)
        let aim = SCNVector3(focus.x, focus.y + move.lift, focus.z)
        turn.position = focus
        group.position = SCNVector3(-focus.x, -focus.y, -focus.z)
        turn.eulerAngles = SCNVector3((settings.pitch + move.pitch) * .pi / 180, (settings.yaw + move.yaw) * .pi / 180, 0)

        let lens = Double(layout.lens)
        let visible = max(Double(layout.visible.y), Double(layout.visible.x) / Double(settings.canvas.aspectRatio))
        let distance = visible / 2 / tan(lens * .pi / 360) / max(settings.zoom * move.zoom, 0.2)
        let azimuth = Double(layout.azimuth) * .pi / 180
        let elevation = Double(layout.elevation) * .pi / 180
        cameraNode.position = SCNVector3(
            aim.x + distance * sin(azimuth) * cos(elevation),
            aim.y + distance * sin(elevation),
            aim.z + distance * cos(azimuth) * cos(elevation))
        cameraNode.look(at: aim, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        if let camera = cameraNode.camera {
            camera.fieldOfView = lens
            look(camera, settings, distance: distance)
        }

        if lit.map({ $0 != settings.lighting || $1 != settings.lightAngle }) ?? true {
            light(settings.lighting, angle: settings.lightAngle)
        }
        if backdrop.map({ $0 != settings.background || $1 != settings.canvas.size }) ?? true {
            setBackground(settings.background, canvas: settings.canvas.size)
        }
    }

    private func arrange(_ shot: MockupShot) {
        for node in group.childNodes { node.removeFromParentNode() }
        for (index, placement) in shot.layout.phones.enumerated() {
            let copy = (index > 0 ? pair ?? phone : phone).clone()
            copy.position = SCNVector3(placement.position)
            // Spun in its own plane, then turned, then tipped.
            let degrees = Float.pi / 180
            copy.simdOrientation = simd_quatf(angle: placement.pitch * degrees, axis: [1, 0, 0])
                * simd_quatf(angle: placement.yaw * degrees, axis: [0, 1, 0])
                * simd_quatf(angle: placement.roll * degrees, axis: [0, 0, 1])
            group.addChildNode(copy)
        }
        arranged = shot
    }

    /// Focus and the lens's finishing: bloom, grain, vignette and colour.
    private func look(_ camera: SCNCamera, _ settings: MockupSettings, distance: Double) {
        camera.wantsDepthOfField = settings.depthOfField > 0
        if settings.depthOfField > 0 {
            camera.focusDistance = distance
            // Stage's scenes are a phone-height a unit, far larger than life,
            // so the aperture opens past any real lens's for a real blur.
            camera.fStop = 0.05 / pow(settings.depthOfField, 1.5)
        }
        camera.wantsHDR = settings.hasEffects
        guard settings.hasEffects else { return }
        // HDR rendering lifts everything a touch; this keeps the backdrop's
        // colour the one chosen.
        camera.exposureOffset = -0.13
        // Only near-white glows: the screen's highlights, not a pale backdrop.
        camera.bloomIntensity = settings.bloom * 1.6
        camera.bloomThreshold = 0.92
        camera.bloomBlurRadius = 12
        camera.grainIntensity = settings.grain * 0.4
        camera.grainScale = 1
        camera.grainIsColored = false
        camera.vignettingIntensity = settings.vignette * 0.9
        camera.vignettingPower = 1.4
        camera.saturation = settings.saturation
        camera.contrast = settings.contrast
    }

    private func light(_ lighting: MockupLighting, angle: Double) {
        let (environment, keyIntensity, fillIntensity): (Double, Double, Double) = switch lighting {
        case .studio: (1.7, 650, 120)
        case .soft: (1.5, 320, 260)
        case .dramatic: (2.0, 1100, 25)
        case .bright: (1.6, 520, 320)
        }
        scene.lightingEnvironment.contents = Self.environment(lighting, angle: angle)
        scene.lightingEnvironment.intensity = environment
        key.light?.intensity = keyIntensity
        fill.light?.intensity = fillIntensity
        let side = lighting == .dramatic ? -1.1 : -0.5
        key.eulerAngles = SCNVector3(-0.6, side + angle * .pi / 180, 0)
        lit = (lighting, angle)
    }

    private func setBackground(_ background: MockupBackground, canvas: CGSize) {
        switch background {
        case .color(let color):
            scene.background.contents = color.nsColor
        case .gradient(let top, let bottom):
            scene.background.contents = NSImage(size: NSSize(width: 64, height: 256), flipped: false) { rect in
                NSGradient(starting: bottom.nsColor, ending: top.nsColor)?.draw(in: rect, angle: 90)
                return true
            }
        case .image(let path):
            // Filled to the frame's shape, so it isn't stretched.
            guard let image = NSImage(contentsOfFile: path) else {
                scene.background.contents = NSColor.black
                break
            }
            let size = NSSize(width: 1024, height: 1024 / max(canvas.width / canvas.height, 0.01))
            scene.background.contents = NSImage(size: size, flipped: false) { rect in
                let scale = max(rect.width / image.size.width, rect.height / image.size.height)
                let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
                return true
            }
        case .clear:
            scene.background.contents = nil
        }
        backdrop = (background, canvas)
    }

    // MARK: - Helpers

    /// The box round every mesh under `root`, in `space`'s coordinates.
    private static func bounds(of root: SCNNode, in space: SCNNode) -> (SCNVector3, SCNVector3) {
        var low = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var high = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] {
                for y in [a.y, b.y] {
                    for z in [a.z, b.z] {
                        let corner = node.convertPosition(SCNVector3(x, y, z), to: space)
                        low = SCNVector3(min(low.x, corner.x), min(low.y, corner.y), min(low.z, corner.z))
                        high = SCNVector3(max(high.x, corner.x), max(high.y, corner.y), max(high.z, corner.z))
                    }
                }
            }
        }
        guard low.x <= high.x else { return (SCNVector3(-0.5, -0.5, -0.5), SCNVector3(0.5, 0.5, 0.5)) }
        return (low, high)
    }

    private static let quarterTurn = 3

    /// Maps the screen onto the video. A video nearly the screen's shape
    /// fills it, trimming a sliver; any other shape fits whole, on black.
    static func screenTransform(video: CGSize, screen: CGFloat, turns: Int, flipped: Bool) -> SCNMatrix4 {
        let quarter = turns % 2 == 1
        let shown = quarter ? video.height / max(video.width, 1) : video.width / max(video.height, 1)
        let ratio = shown / max(screen, 0.01)
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        if abs(ratio - 1) < 0.12 {
            if ratio < 1 { scaleY = ratio } else { scaleX = 1 / ratio }
        } else {
            if ratio < 1 { scaleX = 1 / ratio } else { scaleY = ratio }
        }
        var transform = SCNMatrix4MakeTranslation(-0.5, -0.5, 0)
        transform = SCNMatrix4Mult(transform, SCNMatrix4MakeScale(scaleX, scaleY, 1))
        if flipped { transform = SCNMatrix4Mult(transform, SCNMatrix4MakeScale(-1, 1, 1)) }
        transform = SCNMatrix4Mult(transform, SCNMatrix4MakeRotation(CGFloat(turns % 4) * .pi / 2, 0, 0, 1))
        return SCNMatrix4Mult(transform, SCNMatrix4MakeTranslation(0.5, 0.5, 0))
    }

    /// The studio as seen from the phones: a room dim enough for black glass
    /// to stay black, with soft boxes for the edges to catch, brought round
    /// by `angle` degrees.
    static func environment(_ lighting: MockupLighting, angle: Double = 0) -> NSImage {
        let (low, high, boxes): (CGFloat, CGFloat, [NSRect]) = switch lighting {
        case .studio:
            (0.1, 0.32, [NSRect(x: 90, y: 250, width: 200, height: 170), NSRect(x: 700, y: 240, width: 220, height: 180),
                         NSRect(x: 330, y: 430, width: 360, height: 70)])
        case .soft:
            (0.22, 0.45, [NSRect(x: 40, y: 200, width: 320, height: 260), NSRect(x: 640, y: 200, width: 340, height: 260),
                          NSRect(x: 300, y: 410, width: 420, height: 100)])
        case .dramatic:
            (0.02, 0.06, [NSRect(x: 60, y: 260, width: 120, height: 200)])
        case .bright:
            (0.42, 0.7, [NSRect(x: 60, y: 220, width: 280, height: 240), NSRect(x: 660, y: 220, width: 300, height: 240),
                         NSRect(x: 280, y: 420, width: 460, height: 92)])
        }
        let shift = CGFloat(angle / 360) * 1024
        return NSImage(size: NSSize(width: 1024, height: 512), flipped: false) { rect in
            NSGradient(starting: NSColor(white: low, alpha: 1), ending: NSColor(white: high, alpha: 1))?.draw(in: rect, angle: 90)
            for box in boxes {
                // Round the wrap, so a box carried off one side comes back in.
                for wrap: CGFloat in [-1024, 0, 1024] {
                    let placed = box.offsetBy(dx: shift + wrap, dy: 0)
                    guard placed.intersects(rect) else { continue }
                    NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.85, alpha: 0.8))?
                        .draw(in: NSBezierPath(roundedRect: placed, xRadius: 30, yRadius: 30), angle: 90)
                }
            }
            return true
        }
    }
}

/// The live mockup in the Studio: the shot playing the video on its
/// screens. Drag to turn and tilt it, scroll or pinch to size it, and
/// double-click to put the angle back.
struct MockupPreview: NSViewRepresentable {
    let mockup: MockupScene
    let player: AVPlayer
    let videoSize: CGSize
    /// How far through the video the playhead is, 0 to 1, for the motion.
    let progress: Double
    @Binding var settings: MockupSettings

    func makeCoordinator() -> Coordinator { Coordinator(settings: $settings) }

    func makeNSView(context: Context) -> SCNView {
        let view = SceneView()
        view.scene = mockup.scene
        view.pointOfView = mockup.cameraNode
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.backgroundColor = .clear
        view.onScroll = { [coordinator = context.coordinator] delta in coordinator.zoom(by: delta) }
        view.addGestureRecognizer(NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        let reset = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset(_:)))
        reset.numberOfClicksRequired = 2
        view.addGestureRecognizer(reset)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.settings = $settings
        if view.scene !== mockup.scene {
            view.scene = mockup.scene
            view.pointOfView = mockup.cameraNode
        }
        mockup.useScreen(settings.screenPart)
        mockup.show(player, size: videoSize, turns: settings.screenTurns, flipped: settings.screenFlipped)
        mockup.apply(settings, progress: progress)
    }

    @MainActor
    final class Coordinator: NSObject {
        var settings: Binding<MockupSettings>
        private var start: (yaw: Double, pitch: Double, zoom: Double) = (0, 0, 1)

        init(settings: Binding<MockupSettings>) {
            self.settings = settings
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            if gesture.state == .began { remember() }
            let moved = gesture.translation(in: gesture.view)
            settings.wrappedValue.yaw = min(max(start.yaw + moved.x * 0.3, -45), 45)
            settings.wrappedValue.pitch = min(max(start.pitch - moved.y * 0.3, -30), 30)
        }

        @objc func pinch(_ gesture: NSMagnificationGestureRecognizer) {
            if gesture.state == .began { remember() }
            settings.wrappedValue.zoom = min(max(start.zoom * (1 + gesture.magnification), 0.6), 1.6)
        }

        func zoom(by delta: CGFloat) {
            settings.wrappedValue.zoom = min(max(settings.wrappedValue.zoom * (1 + delta * 0.01), 0.6), 1.6)
        }

        @objc func reset(_ gesture: NSClickGestureRecognizer) {
            settings.wrappedValue.yaw = 0
            settings.wrappedValue.pitch = 0
            settings.wrappedValue.zoom = 1
        }

        private func remember() {
            start = (settings.wrappedValue.yaw, settings.wrappedValue.pitch, settings.wrappedValue.zoom)
        }
    }

    /// An SCNView that hands its scroll wheel to the mockup's size.
    final class SceneView: SCNView {
        var onScroll: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
        }
    }
}
