import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// The mockup's iPhone, shot, background and frame.
struct MockupInspector: View {
    @Bindable var document: StudioDocument
    @State private var thumbnails = ShotThumbnails()
    @State private var templates = MockupTemplate.saved()
    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var showsEffects = false

    private static let ownModel = "own"

    var body: some View {
        Form {
            Section("iPhone") { phone }
            Section("Shot") { shots }
            Section("Motion") { motion }
            Section("Light") { light }
            Section("Lens", isExpanded: $showsEffects) { lens }
            Section("Background") { background }
            Section("Video Size") {
                Picker("Frame", selection: $document.mockup.canvas) {
                    ForEach(MockupCanvas.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Templates") { templateControls }
        }
        .alert("Save as Template", isPresented: $savingTemplate) {
            TextField("Name", text: $templateName)
            Button("Save", action: saveTemplate)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps the iPhone, shot, motion, light, lens and background to start another mockup from.")
        }
        .formStyle(.grouped)
        .task(id: thumbnailKey) {
            await thumbnails.render(document.mockup, still: document.thumbnails.dropFirst(document.thumbnails.count / 3).first,
                              videoSize: document.videoSize)
        }
    }

    // MARK: - iPhone

    @ViewBuilder private var phone: some View {
        Picker("Model", selection: family) {
            ForEach(MockupLibrary.families, id: \.self) { Text($0).tag($0) }
            if !MockupLibrary.families.isEmpty { Divider() }
            Text("Your Own Model…").tag(Self.ownModel)
        }
        if let device = document.mockup.model?.device {
            LabeledContent(device.finish) {
                HStack(spacing: 4) {
                    ForEach(MockupLibrary.finishes(of: device.family)) { option in
                        FinishSwatch(device: option, isSelected: option == device) {
                            document.mockup.model = .device(option.id)
                        }
                    }
                }
            }
        } else if case .file(let path) = document.mockup.model {
            LabeledContent("File") {
                Text(URL(filePath: path).deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose Another Model…", action: chooseModel)
            if let scene = document.mockupScene, !scene.parts.isEmpty {
                Picker("Screen", selection: $document.mockup.screenPart) {
                    ForEach(scene.parts, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
        } else {
            Button("Choose a USDZ Model…", action: chooseModel)
            Text("Use an iPhone model you have the rights to, with its screen as a part of its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if document.mockup.shot.layout.phones.count > 1, let device = document.mockup.model?.device {
            Picker("Other iPhones", selection: $document.mockup.pairModel) {
                Text("Same Finish").tag(MockupModel?.none)
                Divider()
                ForEach(MockupLibrary.finishes(of: device.family).filter { $0 != device }) { option in
                    Text(option.finish).tag(Optional(MockupModel.device(option.id)))
                }
            }
        }
        if let error = document.mockupError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if document.mockupScene != nil {
            Picker("Turn Video", selection: $document.mockup.screenTurns) {
                Text("0°").tag(0)
                Text("90°").tag(1)
                Text("180°").tag(2)
                Text("270°").tag(3)
            }
            Toggle("Mirror Video", isOn: $document.mockup.screenFlipped)
        }
    }

    /// The model's family, or the person's own model.
    private var family: Binding<String> {
        Binding(
            get: {
                switch document.mockup.model {
                case .device(let id)?: MockupLibrary.device(id)?.family ?? Self.ownModel
                default: Self.ownModel
                }
            },
            set: { family in
                guard family != Self.ownModel else {
                    chooseModel()
                    return
                }
                // The same finish in the other size, where there is one.
                let finishes = MockupLibrary.finishes(of: family)
                let finish = document.mockup.model?.device?.finish
                if let device = finishes.first(where: { $0.finish == finish }) ?? finishes.first {
                    document.mockup.screenPart = nil
                    document.mockup.model = .device(device.id)
                }
            })
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.usdz, UTType.usd].compactMap { $0 }
        panel.message = "Choose a 3D iPhone model (.usdz)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.mockup.screenPart = nil
        document.mockup.model = .file(url.path)
    }

    // MARK: - Shot

    @ViewBuilder private var shots: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            ForEach(MockupShot.allCases) { shot in
                ShotTile(shot: shot, image: thumbnails.images[shot], aspectRatio: document.mockup.canvas.aspectRatio,
                         isSelected: document.mockup.shot == shot) {
                    document.mockup.shot = shot
                    document.mockup.yaw = 0
                    document.mockup.pitch = 0
                    document.mockup.zoom = 1
                }
            }
        }
        .padding(.vertical, 4)
        Slider(value: $document.mockup.yaw, in: -45...45) { Text("Turn") }
        Slider(value: $document.mockup.pitch, in: -30...30) { Text("Tilt") }
        Slider(value: $document.mockup.zoom, in: 0.6...1.6) { Text("Size") }
        if document.mockup.yaw != 0 || document.mockup.pitch != 0 || document.mockup.zoom != 1 {
            Button("Reset Angle and Size") {
                document.mockup.yaw = 0
                document.mockup.pitch = 0
                document.mockup.zoom = 1
            }
        }
    }

    // MARK: - Motion, light and lens

    @ViewBuilder private var motion: some View {
        Picker("Camera", selection: $document.mockup.motion) {
            ForEach(MockupMotion.allCases) { Text($0.title).tag($0) }
        }
        if document.mockup.motion != .still {
            Slider(value: $document.mockup.motionAmount, in: 0.2...2) { Text("Amount") }
            Text("The camera moves across the whole video. Play it to see.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var light: some View {
        Picker("Lighting", selection: $document.mockup.lighting) {
            ForEach(MockupLighting.allCases) { Text($0.title).tag($0) }
        }
        Slider(value: $document.mockup.lightAngle, in: -180...180) { Text("Angle") }
    }

    @ViewBuilder private var lens: some View {
        Slider(value: $document.mockup.depthOfField, in: 0...1) { Text("Depth of Field") }
        Slider(value: $document.mockup.bloom, in: 0...1) { Text("Glow") }
        Slider(value: $document.mockup.grain, in: 0...1) { Text("Grain") }
        Slider(value: $document.mockup.vignette, in: 0...1) { Text("Vignette") }
        Slider(value: $document.mockup.saturation, in: 0...2) { Text("Saturation") }
        Slider(value: $document.mockup.contrast, in: -0.5...0.5) { Text("Contrast") }
        if document.mockup.depthOfField != 0 || document.mockup.hasEffects {
            Button("Reset Lens") {
                document.mockup.depthOfField = 0
                document.mockup.bloom = 0
                document.mockup.grain = 0
                document.mockup.vignette = 0
                document.mockup.saturation = 1
                document.mockup.contrast = 0
            }
        }
    }

    // MARK: - Templates

    @ViewBuilder private var templateControls: some View {
        if templates.isEmpty {
            Text("Save a setup you like to start the next mockup from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(templates) { template in
                HStack {
                    Button(template.name) { apply(template) }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Delete", systemImage: "minus.circle") {
                        templates.removeAll { $0.id == template.id }
                        MockupTemplate.save(templates)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete \(template.name)")
                }
            }
        }
        Button("Save as Template…") {
            templateName = "\(document.mockup.shot.title) \(templates.count + 1)"
            savingTemplate = true
        }
    }

    private func saveTemplate() {
        let name = templateName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        templates.append(MockupTemplate(name: name, settings: document.mockup))
        MockupTemplate.save(templates)
    }

    private func apply(_ template: MockupTemplate) {
        var settings = template.settings
        settings.enabled = true
        settings.dropMissingModels()
        document.mockup = settings
    }

    // MARK: - Background

    @ViewBuilder private var background: some View {
        LabeledContent("Style") {
            HStack(spacing: 6) {
                ForEach(BackgroundPreset.allCases) { preset in
                    BackgroundSwatch(preset: preset, isSelected: document.mockup.background == preset.background) {
                        document.mockup.background = preset.background
                    }
                }
            }
        }
        Picker("Custom", selection: backgroundKind) {
            Text("Color").tag(0)
            Text("Gradient").tag(1)
            Text("Image").tag(2)
            Text("Clear").tag(3)
        }
        switch document.mockup.background {
        case .color(let color):
            ColorPicker("Color", selection: Binding(
                get: { color.color },
                set: { document.mockup.background = .color(RGBA($0)) }))
        case .gradient(let top, let bottom):
            ColorPicker("Top", selection: Binding(
                get: { top.color },
                set: { document.mockup.background = .gradient(RGBA($0), bottom) }))
            ColorPicker("Bottom", selection: Binding(
                get: { bottom.color },
                set: { document.mockup.background = .gradient(top, RGBA($0)) }))
        case .image(let path):
            LabeledContent("Image") {
                Text(URL(filePath: path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose Another Image…", action: chooseBackgroundImage)
        case .clear:
            Text("Exports keep only the phones: a PNG, or a video in HEVC with alpha or ProRes 4444, to lay over slides.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundKind: Binding<Int> {
        Binding(
            get: {
                switch document.mockup.background {
                case .color: 0
                case .gradient: 1
                case .image: 2
                case .clear: 3
                }
            },
            set: { kind in
                switch kind {
                case 0: document.mockup.background = .color(RGBA(0.9, 0.9, 0.9))
                case 1: document.mockup.background = .studio
                case 3: document.mockup.background = .clear
                default: chooseBackgroundImage()
                }
            })
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.mockup.background = .image(url.path)
    }

    // MARK: - Thumbnails

    /// What the shot thumbnails show: the iPhone, its screen and the frame.
    private var thumbnailKey: ShotThumbnails.Key {
        ShotThumbnails.Key(model: document.mockup.model, pairModel: document.mockup.pairModel,
                           screenPart: document.mockup.screenPart,
                           turns: document.mockup.screenTurns, flipped: document.mockup.screenFlipped,
                           lighting: document.mockup.lighting, lightAngle: document.mockup.lightAngle,
                           background: document.mockup.background, canvas: document.mockup.canvas,
                           stills: document.thumbnails.count)
    }
}

/// A dot of one finish's colour; the chosen one is ringed.
private struct FinishSwatch: View {
    let device: MockupDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(device.swatch.color)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(device.finish)
        .accessibilityLabel(device.finish)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One shot in the picker: a small render of it with the chosen iPhone.
private struct ShotTile: View {
    let shot: MockupShot
    let image: CGImage?
    let aspectRatio: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                }
                Text(shot.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shot.title) shot")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Ready-made backgrounds.
private enum BackgroundPreset: String, CaseIterable, Identifiable {
    case studio = "Studio"
    case night = "Night"
    case white = "White"
    case black = "Black"
    case clear = "Clear"

    var id: Self { self }

    var background: MockupBackground {
        switch self {
        case .studio: .studio
        case .night: .night
        case .white: .white
        case .black: .black
        case .clear: .clear
        }
    }
}

private struct BackgroundSwatch: View {
    let preset: BackgroundPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
                .overlay { if preset == .clear { Checkerboard().clipShape(.rect(cornerRadius: 5)) } }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                .frame(width: 26, height: 26)
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(preset.rawValue)
        .accessibilityLabel("\(preset.rawValue) background")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: AnyShapeStyle {
        switch preset.background {
        case .color(let color): AnyShapeStyle(color.color)
        case .gradient(let top, let bottom): AnyShapeStyle(LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom))
        case .image, .clear: AnyShapeStyle(Color.gray)
        }
    }
}

/// Small renders of every shot with the chosen iPhone and the recording on
/// its screen, made off the main thread.
@MainActor
@Observable
final class ShotThumbnails {
    struct Key: Equatable {
        var model: MockupModel?
        var pairModel: MockupModel?
        var screenPart: String?
        var turns: Int
        var flipped: Bool
        var lighting: MockupLighting
        var lightAngle: Double
        var background: MockupBackground
        var canvas: MockupCanvas
        var stills: Int
    }

    private(set) var images: [MockupShot: CGImage] = [:]

    /// Renders them again; a newer call cancels this one.
    func render(_ settings: MockupSettings, still: CGImage?, videoSize: CGSize) async {
        guard let url = settings.modelURL else {
            images = [:]
            return
        }
        let rendered = await Self.render(url: url, settings: settings, still: still, videoSize: videoSize)
        if !Task.isCancelled, !rendered.isEmpty { images = rendered }
    }

    @concurrent
    private static func render(url: URL, settings: MockupSettings, still: CGImage?, videoSize: CGSize) async -> [MockupShot: CGImage] {
        guard let mockup = try? MockupScene(modelURL: url, pairURL: settings.pairURL) else { return [:] }
        mockup.useScreen(settings.screenPart)
        if let still {
            mockup.show(still, size: videoSize, turns: settings.screenTurns, flipped: settings.screenFlipped)
        }
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = mockup.scene
        renderer.pointOfView = mockup.cameraNode
        let size = CGSize(width: 260, height: (260 / settings.canvas.aspectRatio).rounded())
        var images: [MockupShot: CGImage] = [:]
        for shot in MockupShot.allCases {
            guard !Task.isCancelled else { return [:] }
            var framing = settings
            framing.shot = shot
            framing.yaw = 0
            framing.pitch = 0
            framing.zoom = 1
            framing.motion = .still
            framing.depthOfField = 0
            mockup.apply(framing)
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            var rect = CGRect(origin: .zero, size: image.size)
            images[shot] = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return images
    }
}
