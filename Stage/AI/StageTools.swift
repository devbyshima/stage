import AppKit
@preconcurrency import AVFoundation

/// What an AI tool connected through `Stage --mcp` can see and do: open a
/// recording in the Studio, cut it, set up its mockup, look at the result
/// and export it. Speaks MCP's JSON-RPC, one message a line.
@MainActor
final class StageTools {
    static let shared = StageTools()

    weak var model: StageModel?

    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private static let instructions = """
        Stage records an iPhone's screen. Its Studio edits a recording, puts it on a 3D iPhone (the mockup) \
        and exports it. Start with get_studio to see what's open and every choice the other tools take. \
        If nothing is open, use list_recordings and open_recording. Shape the mockup with update_mockup \
        and set_focus_areas, look at it with render_preview, and export when it's right.
        """

    /// The reply to one message, or nil for a notification.
    func handle(_ line: String) async -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "That isn't JSON."]])
        }
        guard let method = message["method"] as? String else { return nil }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "stage", "title": "Stage",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.reply(id, [:])
        case "tools/list":
            return Self.reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return Self.reply(id, ["content": try await call(name, Arguments(arguments)), "isError": false])
            } catch {
                return Self.reply(id, ["content": [Self.text(error.localizedDescription)], "isError": true])
            }
        default:
            guard let id else { return nil }
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Stage has no method \(method)."]])
        }
    }

    // MARK: - Tools

    private func call(_ name: String, _ arguments: Arguments) async throws -> [[String: Any]] {
        switch name {
        case "get_studio":
            guard let document = try? await studio() else {
                return [Self.json([
                    "open": false,
                    "recent_recordings": RecordingLibrary.recent().map(\.path),
                    "hint": "No recording is open in the Studio. Call open_recording.",
                    "choices": Self.choices,
                ])]
            }
            var studio = state(of: document)
            studio["choices"] = Self.choices
            return [Self.json(studio)]
        case "list_recordings":
            let limit = Int(try arguments.number("limit", in: 1...50) ?? 10)
            return [Self.json(["recordings": RecordingLibrary.recent(limit: limit).map(Self.describeRecording)])]
        case "open_recording":
            return [Self.json(state(of: try await open(arguments.string("path"))))]
        case "update_mockup":
            let document = try await studio()
            try update(&document.mockup, with: arguments)
            return [Self.json(["mockup": Self.describe(document.mockup)])]
        case "set_focus_areas":
            let document = try await studio()
            try setFocus(&document.mockup, arguments)
            return [Self.json(["mockup": Self.describe(document.mockup)])]
        case "reset_pose":
            let document = try await studio()
            document.mockup.yaw = 0
            document.mockup.pitch = 0
            document.mockup.zoom = 1
            return [Self.json(["mockup": Self.describe(document.mockup)])]
        case "edit_recording":
            let document = try await studio()
            try edit(document, arguments)
            return [Self.json(state(of: document))]
        case "render_preview":
            let document = try await studio()
            let width = try arguments.number("width", in: 320...2048) ?? 1280
            return [["type": "image", "data": try await preview(document, width: width).base64EncodedString(), "mimeType": "image/png"]]
        case "save_template":
            let document = try await studio()
            guard let name = try arguments.string("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ToolError("Give the template a name.")
            }
            MockupTemplates.shared.save(name, settings: document.mockup)
            return [Self.text("Saved the mockup as the template \u{201C}\(name)\u{201D}.")]
        case "apply_template":
            let document = try await studio()
            guard let name = try arguments.string("name"), let template = MockupTemplates.shared.named(name) else {
                let names = MockupTemplates.shared.items.map(\.name)
                throw ToolError("There's no template by that name. Saved templates: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
            }
            var settings = template.settings
            settings.enabled = true
            settings.dropMissingModels()
            document.mockup = settings
            return [Self.json(["mockup": Self.describe(document.mockup)])]
        case "export":
            return [Self.text(try await export(studio(), arguments))]
        default:
            throw ToolError("Stage has no tool named \(name).")
        }
    }

    /// The Studio the tools work on: the one used last, once it has loaded.
    private func studio() async throws -> StudioDocument {
        guard let document = StudioRegistry.shared.active else {
            throw ToolError("No recording is open in the Studio. Call list_recordings, then open_recording.")
        }
        for _ in 0..<50 where !document.isLoaded && document.loadError == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        if let error = document.loadError { throw ToolError(error) }
        return document
    }

    private func open(_ path: String?) async throws -> StudioDocument {
        guard let model else { throw ToolError("Stage isn't ready yet. Try again in a moment.") }
        let url: URL
        if let path {
            url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("There's no file at \(path).") }
        } else if let latest = model.lastRecording ?? RecordingLibrary.recent(limit: 1).first {
            url = latest
        } else {
            throw ToolError("There are no recordings yet. Record the iPhone in Stage first.")
        }
        if let document = StudioRegistry.shared.document(for: url) {
            StudioRegistry.shared.activate(document)
            return try await studio()
        }
        model.openStudio(url)
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if StudioRegistry.shared.document(for: url) != nil { return try await studio() }
        }
        throw ToolError("Stage couldn't open the Studio for \(url.lastPathComponent).")
    }

    private func update(_ mockup: inout MockupSettings, with arguments: Arguments) throws {
        var settings = mockup
        settings.enabled = try arguments.bool("enabled") ?? true
        if let path = try arguments.string("model_file") {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("There's no model file at \(path).") }
            settings.model = .file(url.path)
            settings.screenPart = nil
        }
        let family = try arguments.string("iphone")
        let finish = try arguments.string("finish")
        if family != nil || finish != nil {
            let current = settings.model?.device
            guard let familyName = Self.match(family ?? current?.family ?? "", MockupLibrary.families) else {
                throw ToolError("Stage has no iPhone called \(family ?? "that"). It has: \(MockupLibrary.families.joined(separator: ", ")).")
            }
            let finishes = MockupLibrary.finishes(of: familyName)
            let wanted = finish ?? current?.finish ?? ""
            let device = finishes.first { Self.same($0.finish, wanted) } ?? (finish == nil ? finishes.first : nil)
            guard let device else {
                throw ToolError("\(familyName) comes in \(finishes.map(\.finish).joined(separator: ", ")).")
            }
            settings.model = .device(device.id)
            settings.screenPart = nil
        }
        if let other = try arguments.string("other_finish") {
            if Self.same(other, "same") {
                settings.pairModel = nil
            } else if let family = settings.model?.device?.family,
                      let device = MockupLibrary.finishes(of: family).first(where: { Self.same($0.finish, other) }) {
                settings.pairModel = .device(device.id)
            } else {
                throw ToolError("other_finish must be \"same\" or one of the current iPhone's finishes.")
            }
        }
        if let shot = try arguments.choice("shot", MockupShot.allCases, names: { [$0.rawValue, $0.title] }) { settings.shot = shot }
        if let value = try arguments.number("turn", in: -45...45) { settings.yaw = value }
        if let value = try arguments.number("tilt", in: -30...30) { settings.pitch = value }
        if let value = try arguments.number("zoom", in: 0.6...1.6) { settings.zoom = value }
        if let motion = try arguments.choice("motion", MockupMotion.allCases, names: { [$0.rawValue, $0.title] }) {
            if motion == .focus, settings.focusAreas.isEmpty { settings.focusAreas = [.top, .bottom] }
            settings.motion = motion
        }
        if let value = try arguments.number("motion_amount", in: 0.2...2) { settings.motionAmount = value }
        if let lighting = try arguments.choice("lighting", MockupLighting.allCases, names: { [$0.rawValue, $0.title] }) {
            settings.lighting = lighting
        }
        if let value = try arguments.number("light_angle", in: -180...180) { settings.lightAngle = value }
        if let value = try arguments.number("depth_of_field", in: 0...1) { settings.depthOfField = value }
        if let value = try arguments.number("glow", in: 0...1) { settings.bloom = value }
        if let value = try arguments.number("grain", in: 0...1) { settings.grain = value }
        if let value = try arguments.number("vignette", in: 0...1) { settings.vignette = value }
        if let value = try arguments.number("saturation", in: 0...2) { settings.saturation = value }
        if let value = try arguments.number("contrast", in: -0.5...0.5) { settings.contrast = value }
        if let value = try arguments.string("background") { settings.background = try Self.background(value) }
        if let frame = try arguments.choice("frame", MockupCanvas.allCases, names: { [$0.rawValue, Self.frameName($0)] }) {
            settings.canvas = frame
        }
        if let degrees = try arguments.number("turn_video", in: 0...270) {
            guard degrees.truncatingRemainder(dividingBy: 90) == 0 else { throw ToolError("turn_video must be 0, 90, 180 or 270.") }
            settings.screenTurns = Int(degrees / 90)
        }
        if let mirror = try arguments.bool("mirror_video") { settings.screenFlipped = mirror }
        mockup = settings
    }

    private func setFocus(_ mockup: inout MockupSettings, _ arguments: Arguments) throws {
        guard let list = arguments.values["areas"] as? [Any] else { throw ToolError("Give areas: a list, empty to stop.") }
        let areas = try list.map { item -> MockupFocus in
            if let name = item as? String {
                guard let area = [MockupFocus.top, .middle, .bottom, .whole].first(where: { Self.same($0.title, name) }) else {
                    throw ToolError("Named areas are top, middle, bottom and whole_screen.")
                }
                return area
            }
            let corners = Arguments(item as? [String: Any] ?? [:])
            guard let x0 = try corners.number("x0", in: 0...1), let y0 = try corners.number("y0", in: 0...1),
                  let x1 = try corners.number("x1", in: 0...1), let y1 = try corners.number("y1", in: 0...1) else {
                throw ToolError("Each area needs x0, y0, x1 and y1, from 0 to 1.")
            }
            return MockupFocus(x0: x0, y0: y0, x1: x1, y1: y1).tidy
        }
        mockup.enabled = true
        mockup.focusAreas = areas
        if !areas.isEmpty {
            mockup.motion = .focus
        } else if mockup.motion == .focus {
            mockup.motion = .still
        }
    }

    private func edit(_ document: StudioDocument, _ arguments: Arguments) throws {
        let action = try arguments.string("action") ?? ""
        let seconds = try arguments.number("seconds", in: 0...86_400)
        func piece() throws -> Segment {
            guard let number = try arguments.number("piece", in: 1...1_000), document.segments.indices.contains(Int(number) - 1) else {
                throw ToolError("Give piece, from 1 to \(document.segments.count).")
            }
            return document.segments[Int(number) - 1]
        }
        func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
        switch action {
        case "seek":
            guard let seconds else { throw ToolError("Give seconds to move the playhead to.") }
            document.seek(to: time(seconds))
        case "split":
            if let seconds { document.seek(to: time(seconds)) }
            let count = document.segments.count
            document.split()
            if document.segments.count == count { throw ToolError("A piece can't be split that close to its end.") }
        case "delete_piece":
            guard document.segments.count > 1 else { throw ToolError("The last piece can't be deleted.") }
            document.selection = try piece().id
            document.deleteSelection()
        case "trim_piece":
            let segment = try piece()
            let start = try arguments.number("start", in: 0...86_400)
            let end = try arguments.number("end", in: 0...86_400)
            guard start != nil || end != nil else { throw ToolError("Give start or end, in the recording's own seconds.") }
            document.beginTrim()
            document.trim(segment.id, start: start.map(time), end: end.map(time))
        case "undo": document.undo()
        case "redo": document.redo()
        case "sound_on", "sound_off":
            guard document.hasAudio else { throw ToolError("This recording has no sound.") }
            document.includeAudio = action == "sound_on"
        case "play": if !document.isPlaying { document.togglePlay() }
        case "pause": if document.isPlaying { document.togglePlay() }
        default:
            throw ToolError("action must be seek, split, delete_piece, trim_piece, undo, redo, sound_on, sound_off, play or pause.")
        }
    }

    /// The Studio at the playhead: the mockup if it's on, else the video.
    private func preview(_ document: StudioDocument, width: Double) async throws -> Data {
        let frame = try await document.frame(at: document.currentTime)
        let mockup = document.mockup
        if mockup.enabled, let url = mockup.modelURL {
            let scene = try MockupScene(modelURL: url, pairURL: mockup.pairURL)
            let progress = document.currentTime.seconds / max(document.editedDuration.seconds, 0.001)
            let size = CGSize(width: width.rounded(), height: (width / mockup.canvas.aspectRatio).rounded())
            return try await MockupStill.png(frame, mockup: scene, settings: mockup, progress: progress, size: size)
        }
        let height = width * Double(frame.height) / Double(max(frame.width, 1))
        let image = NSImage(cgImage: frame, size: NSSize(width: width, height: height))
        guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw ToolError("Stage couldn't make the preview.")
        }
        return data
    }

    private func export(_ document: StudioDocument, _ arguments: Arguments) async throws -> String {
        guard let model else { throw ToolError("Stage isn't ready yet.") }
        let still = try arguments.choice("kind", ["video", "still"], names: { [$0] }) == "still"
        if still, !document.mockup.enabled { throw ToolError("A still is of the mockup. Turn the mockup on first.") }
        let format = try arguments.choice("format", VideoFormat.allCases, names: { [$0.rawValue, $0.title] }) ?? model.prefs.videoFormat
        let url: URL
        if let path = try arguments.string("path") {
            url = URL(filePath: (path as NSString).expandingTildeInPath)
        } else {
            let name = "\(document.name) \(document.mockup.enabled ? "mockup" : "edited").\(still ? "png" : "mov")"
            url = RecordingName.unique(name, in: model.prefs.saveFolder)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if still {
            try await ExportJob.exportStill(document, to: url)
        } else {
            try await ExportJob.export(document, format: format, to: url, job: nil)
        }
        return "Exported \(url.path)"
    }

    // MARK: - Describing

    private func state(of document: StudioDocument) -> [String: Any] {
        [
            "recording": document.name,
            "path": document.url.path,
            "length_seconds": Self.round(document.editedDuration.seconds),
            "recording_seconds": Self.round(document.duration.seconds),
            "playhead_seconds": Self.round(document.currentTime.seconds),
            "playing": document.isPlaying,
            "has_sound": document.hasAudio,
            "sound": document.includeAudio && document.hasAudio,
            "video_size": [Int(document.videoSize.width), Int(document.videoSize.height)],
            "pieces": document.segments.enumerated().map { index, segment in
                [
                    "piece": index + 1,
                    "from_seconds": Self.round(segment.range.start.seconds),
                    "to_seconds": Self.round(segment.range.end.seconds),
                    "length_seconds": Self.round(segment.duration.seconds),
                ]
            },
            "mockup": Self.describe(document.mockup),
            "templates": MockupTemplates.shared.items.map(\.name),
        ]
    }

    static func describe(_ mockup: MockupSettings) -> [String: Any] {
        var description: [String: Any] = [
            "enabled": mockup.enabled,
            "shot": name(mockup.shot.title),
            "turn": round(mockup.yaw), "tilt": round(mockup.pitch), "zoom": round(mockup.zoom),
            "motion": name(mockup.motion.title), "motion_amount": round(mockup.motionAmount),
            "focus_areas": mockup.focusAreas.map { ["x0": round($0.x0), "y0": round($0.y0), "x1": round($0.x1), "y1": round($0.y1)] },
            "lighting": name(mockup.lighting.title), "light_angle": round(mockup.lightAngle),
            "depth_of_field": round(mockup.depthOfField), "glow": round(mockup.bloom), "grain": round(mockup.grain),
            "vignette": round(mockup.vignette), "saturation": round(mockup.saturation), "contrast": round(mockup.contrast),
            "background": describe(mockup.background),
            "frame": frameName(mockup.canvas),
            "turn_video": mockup.screenTurns * 90, "mirror_video": mockup.screenFlipped,
        ]
        switch mockup.model {
        case .device(let id)?:
            let device = MockupLibrary.device(id)
            description["iphone"] = device?.family ?? id
            description["finish"] = device?.finish
            description["other_finish"] = mockup.pairModel?.device?.finish ?? "same"
        case .file(let path)?:
            description["model_file"] = path
        case nil:
            description["iphone"] = "none"
        }
        return description
    }

    private static func describeRecording(_ url: URL) -> [String: Any] {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return ["name": url.deletingPathExtension().lastPathComponent, "path": url.path,
                "recorded": created.formatted(.iso8601)]
    }

    private static func describe(_ background: MockupBackground) -> String {
        switch background {
        case .studio: "studio"
        case .night: "night"
        case .white: "white"
        case .black: "black"
        case .clear: "clear"
        case .color(let color): hex(color)
        case .gradient(let top, let bottom): "\(hex(top)),\(hex(bottom))"
        case .image(let path): path
        }
    }

    private static var choices: [String: Any] {
        [
            "iphones": Dictionary(uniqueKeysWithValues: MockupLibrary.families.map { family in
                (family, MockupLibrary.finishes(of: family).map(\.finish))
            }),
            "shots": MockupShot.allCases.map { name($0.title) },
            "motions": MockupMotion.allCases.map { name($0.title) },
            "lightings": MockupLighting.allCases.map { name($0.title) },
            "frames": MockupCanvas.allCases.map(frameName),
            "backgrounds": ["studio", "night", "white", "black", "clear", "#RRGGBB (a colour)",
                            "#RRGGBB,#RRGGBB (a gradient, top then bottom)", "a path to an image"],
            "focus_areas": "fractions of the video as it shows, from its top left: x0, y0, x1, y1",
        ]
    }

    // MARK: - Tool list

    private static var tools: [[String: Any]] {
        let none: [String: Any] = ["type": "object", "properties": [String: Any]()]
        func number(_ description: String, _ range: ClosedRange<Double>) -> [String: Any] {
            ["type": "number", "minimum": range.lowerBound, "maximum": range.upperBound, "description": description]
        }
        func choice(_ description: String, _ values: [String]) -> [String: Any] {
            ["type": "string", "enum": values, "description": description]
        }
        let area: [String: Any] = [
            "type": "object",
            "properties": ["x0": number("Left", 0...1), "y0": number("Top", 0...1), "x1": number("Right", 0...1), "y1": number("Bottom", 0...1)],
            "required": ["x0", "y0", "x1", "y1"],
        ]
        return [
            ["name": "get_studio", "title": "Get the Studio",
             "description": "What's open in Stage's Studio: the recording, its length and pieces, the playhead, the sound and the mockup, with every choice the other tools take.",
             "inputSchema": none, "annotations": ["readOnlyHint": true]],
            ["name": "list_recordings", "title": "List recordings",
             "description": "Stage's recordings of the iPhone, newest first.",
             "inputSchema": ["type": "object", "properties": ["limit": number("How many, 10 by default", 1...50)]],
             "annotations": ["readOnlyHint": true]],
            ["name": "open_recording", "title": "Open a recording",
             "description": "Opens a recording (or any movie) in the Studio, and makes it the one these tools work on. With no path, the latest recording.",
             "inputSchema": ["type": "object", "properties": ["path": ["type": "string", "description": "The movie file"]]]],
            ["name": "update_mockup", "title": "Update the mockup",
             "description": "Changes the mockup: the 3D iPhone, the shot, its angle and size, the camera motion, the light, the lens and the background. Only what's given changes. Changing anything turns the mockup on unless enabled is false.",
             "inputSchema": ["type": "object", "properties": [
                "enabled": ["type": "boolean", "description": "Show the video on the 3D iPhone (true) or as recorded (false)"],
                "iphone": choice("Which iPhone", MockupLibrary.families),
                "finish": ["type": "string", "description": "The iPhone's finish, as get_studio lists"],
                "other_finish": ["type": "string", "description": "The finish of the other phones in a shot of two or three, or \"same\""],
                "model_file": ["type": "string", "description": "A USDZ model of one's own instead"],
                "shot": choice("The framing", MockupShot.allCases.map { name($0.title) }),
                "turn": number("Degrees the phones turn left or right, on top of the shot", -45...45),
                "tilt": number("Degrees the phones tip toward or away, on top of the shot", -30...30),
                "zoom": number("How large the phones are; 1 is the shot's own", 0.6...1.6),
                "motion": choice("How the camera moves over the video", MockupMotion.allCases.map { name($0.title) }),
                "motion_amount": number("How strong the motion is; 1 is normal", 0.2...2),
                "lighting": choice("The studio light", MockupLighting.allCases.map { name($0.title) }),
                "light_angle": number("Degrees the light comes round the phones", -180...180),
                "depth_of_field": number("0 for everything sharp, up to 1 for a shallow focus", 0...1),
                "glow": number("Bloom round the brightest parts of the screen", 0...1),
                "grain": number("Film grain", 0...1),
                "vignette": number("Darkened corners", 0...1),
                "saturation": number("Colour; 1 is unchanged", 0...2),
                "contrast": number("0 is unchanged", -0.5...0.5),
                "background": ["type": "string", "description": "studio, night, white, black, clear, #RRGGBB, #RRGGBB,#RRGGBB (a gradient, top then bottom), or a path to an image"],
                "frame": choice("The exported video's size", MockupCanvas.allCases.map(frameName)),
                "turn_video": ["type": "integer", "enum": [0, 90, 180, 270], "description": "Degrees to turn the video on the screen"],
                "mirror_video": ["type": "boolean", "description": "Mirror the video on the screen"],
             ]]],
            ["name": "set_focus_areas", "title": "Set focus areas",
             "description": "Makes the camera close in on parts of the screen in turn across the video, resting on each and gliding between them, like a guided tour. One area holds on it throughout. An empty list goes back to the whole shot.",
             "inputSchema": ["type": "object", "properties": [
                "areas": ["type": "array", "description": "In order. Each is top, middle, bottom, whole_screen, or corners as fractions of the video as it shows, from its top left.",
                          "items": ["anyOf": [["type": "string", "enum": ["top", "middle", "bottom", "whole_screen"]], area]]],
             ], "required": ["areas"]]],
            ["name": "reset_pose", "title": "Reset the pose",
             "description": "Puts the phones back at the shot's own angle and size.", "inputSchema": none],
            ["name": "edit_recording", "title": "Edit the recording",
             "description": "Cuts the video in the Studio. The recording itself never changes; export makes a new file.",
             "inputSchema": ["type": "object", "properties": [
                "action": choice("seek moves the playhead; split cuts the piece under it in two; delete_piece takes a piece out; trim_piece moves a piece's ends",
                                 ["seek", "split", "delete_piece", "trim_piece", "undo", "redo", "sound_on", "sound_off", "play", "pause"]),
                "seconds": number("For seek and split: a time in the edited video", 0...86_400),
                "piece": number("For delete_piece and trim_piece: its number, from 1", 1...1_000),
                "start": number("For trim_piece: the new start, in the recording's own seconds", 0...86_400),
                "end": number("For trim_piece: the new end, in the recording's own seconds", 0...86_400),
             ], "required": ["action"]]],
            ["name": "render_preview", "title": "Render a preview",
             "description": "A picture of the Studio at the playhead: the mockup as it will export (with its motion at that moment), or the video if the mockup is off. Use it to check changes.",
             "inputSchema": ["type": "object", "properties": ["width": number("Pixels across, 1280 by default", 320...2048)]],
             "annotations": ["readOnlyHint": true]],
            ["name": "save_template", "title": "Save a template",
             "description": "Saves the mockup's setup under a name, to start other mockups from.",
             "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]],
            ["name": "apply_template", "title": "Apply a template",
             "description": "Sets the mockup up from a saved template; get_studio lists them.",
             "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]],
            ["name": "export", "title": "Export",
             "description": "Exports the edited video (with its mockup, if on) or, as a still, the mockup at the playhead as a 5K PNG. Waits until it's written and gives the path.",
             "inputSchema": ["type": "object", "properties": [
                "kind": choice("video by default", ["video", "still"]),
                "format": choice("For video; the Settings choice by default", VideoFormat.allCases.map(\.rawValue)),
                "path": ["type": "string", "description": "Where to write it; Stage's export folder by default"],
             ]]],
        ]
    }

    // MARK: - Helpers

    private static func name(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private static func frameName(_ canvas: MockupCanvas) -> String {
        canvas.rawValue.replacingOccurrences(of: "4K", with: "_4k")
    }

    /// Letters and digits alone, lower case, so "Push In", "push_in" and
    /// "pushIn" are the same.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        func plain(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        return plain(a) == plain(b)
    }

    private static func match(_ value: String, _ options: [String]) -> String? {
        options.first { same($0, value) }
    }

    static func background(_ value: String) throws -> MockupBackground {
        let presets: [String: MockupBackground] = ["studio": .studio, "night": .night, "white": .white, "black": .black,
                                                   "clear": .clear, "transparent": .clear]
        if let preset = presets.first(where: { same($0.key, value) })?.value { return preset }
        let colours = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if colours.allSatisfy({ $0.hasPrefix("#") }) {
            let parsed = colours.compactMap(color)
            if parsed.count == 1, colours.count == 1 { return .color(parsed[0]) }
            if parsed.count == 2, colours.count == 2 { return .gradient(parsed[0], parsed[1]) }
            throw ToolError("Colours are #RRGGBB; a gradient is two, top then bottom.")
        }
        let path = (value as NSString).expandingTildeInPath
        guard NSImage(contentsOfFile: path) != nil else {
            throw ToolError("The background must be studio, night, white, black, clear, a colour, a gradient, or an image file.")
        }
        return .image(path)
    }

    private static func color(_ hex: String) -> RGBA? {
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return RGBA(Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }

    private static func hex(_ color: RGBA) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    /// Three decimal places, written as such (a plain Double prints 0.6 as
    /// 0.59999999999999998).
    private static func round(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", value), locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    private static func json(_ value: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return text(String(decoding: data, as: UTF8.self))
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) -> String? {
        guard let id else { return nil }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ message: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A tool's arguments, read with checks.
struct Arguments {
    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ToolError("\(key) must be text.") }
        return text
    }

    func number(_ key: String, in range: ClosedRange<Double>) throws -> Double? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        let number: Double? = switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
        guard let number, number.isFinite else { throw ToolError("\(key) must be a number.") }
        guard range.contains(number) else {
            throw ToolError("\(key) must be from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
        }
        return number
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        guard let flag = value as? Bool else { throw ToolError("\(key) must be true or false.") }
        return flag
    }

    func choice<Option>(_ key: String, _ options: [Option], names: (Option) -> [String]) throws -> Option? {
        guard let text = try string(key) else { return nil }
        if let option = options.first(where: { names($0).contains { StageTools.same($0, text) } }) { return option }
        throw ToolError("\(key) must be one of: \(options.compactMap { names($0).last }.joined(separator: ", ")).")
    }
}

struct ToolError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
