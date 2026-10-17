import AVFoundation
import Foundation
import SceneKit
import Testing
@testable import Stage

struct MockupMotionTests {
    @Test func stillNeverMoves() {
        for progress in [0.0, 0.5, 1] {
            let move = MockupMotion.still.offsets(at: progress, amount: 1)
            #expect(move.yaw == 0 && move.pitch == 0 && move.zoom == 1 && move.lift == 0)
        }
    }

    @Test func pushInEndsCloser() {
        #expect(MockupMotion.pushIn.offsets(at: 0, amount: 1).zoom == 1)
        #expect(abs(MockupMotion.pushIn.offsets(at: 1, amount: 1).zoom - 1.3) < 0.0001)
        #expect(abs(MockupMotion.pullBack.offsets(at: 1, amount: 1).zoom - 1) < 0.0001)
    }

    @Test func topToBottomRunsDownTheScreen() {
        let start = MockupMotion.scroll.offsets(at: 0, amount: 1)
        let end = MockupMotion.scroll.offsets(at: 1, amount: 1)
        #expect(start.lift > 0 && end.lift < 0)
        #expect(start.zoom > 1.5)
    }

    @Test func orbitSweepsEvenly() {
        let start = MockupMotion.orbit.offsets(at: 0, amount: 1).yaw
        let end = MockupMotion.orbit.offsets(at: 1, amount: 1).yaw
        #expect(abs(start + end) < 0.0001 && end > 0)
    }
}

struct MockupScreenTests {
    /// Where the screen's corner (u = 1, v = 1) lands in the video.
    private func corner(_ transform: SCNMatrix4) -> CGPoint {
        CGPoint(x: transform.m11 + transform.m21 + transform.m41, y: transform.m12 + transform.m22 + transform.m42)
    }

    @Test func nearlyTheScreensShapeFills() {
        // An iPhone 17 Pro recording on an iPhone 18 Pro screen: trimmed, no bars.
        let transform = MockupScene.screenTransform(video: CGSize(width: 1206, height: 2622), screen: 0.458, turns: 0, flipped: false)
        let point = corner(transform)
        #expect(point.x <= 1.0001 && point.y <= 1.0001)
    }

    @Test func anotherShapeFitsWhole() {
        // A portrait recording on an open fold's wide screen: bars at the sides.
        let transform = MockupScene.screenTransform(video: CGSize(width: 1206, height: 2622), screen: 1.42, turns: 0, flipped: false)
        #expect(corner(transform).x > 1.5)
    }
}

struct MockupSettingsTests {
    @Test func olderSettingsStillOpen() throws {
        let json = #"{"enabled": true, "shot": "pair", "yaw": 12}"#
        let settings = try JSONDecoder().decode(MockupSettings.self, from: Data(json.utf8))
        #expect(settings.enabled && settings.shot == .pair && settings.yaw == 12)
        #expect(settings.motion == .still && settings.lighting == .studio && settings.background == .studio)
    }

    @Test func unknownValuesKeepTheirDefaults() throws {
        let json = #"{"shot": "spiral", "canvas": "portrait"}"#
        let settings = try JSONDecoder().decode(MockupSettings.self, from: Data(json.utf8))
        #expect(settings.shot == .front && settings.canvas == .portrait)
    }

    @Test func settingsSurviveStorage() throws {
        var settings = MockupSettings()
        settings.shot = .trio
        settings.motion = .orbit
        settings.background = .clear
        settings.pairModel = .device("iPhone 18 Pro - Silver")
        let decoded = try JSONDecoder().decode(MockupSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func clearBackgroundsKeepAlpha() {
        #expect(MockupExport.codec(for: .h264, transparent: false) == .h264)
        #expect(MockupExport.codec(for: .h264, transparent: true) == .hevcWithAlpha)
        #expect(MockupExport.codec(for: .proRes, transparent: true) == .proRes4444)
    }

    @Test(arguments: MockupCanvas.allCases)
    func stillsAre5K(canvas: MockupCanvas) {
        let size = MockupStill.size(for: canvas)
        #expect(max(size.width, size.height) == 5120)
        #expect(abs(size.width / size.height - canvas.aspectRatio) < 0.01)
    }
}

struct MockupShotTests {
    @Test(arguments: MockupShot.allCases)
    func everyShotFrames(shot: MockupShot) {
        let layout = shot.layout
        #expect(!layout.phones.isEmpty)
        #expect(layout.lens > 0 && layout.lens < 90)
        #expect(layout.visible.x > 0 && layout.visible.y > 0)
    }

    @Test func builtInIPhonesAreNamedByFamilyAndFinish() {
        for device in MockupLibrary.devices {
            #expect(device.id == "\(device.family) - \(device.finish)")
            #expect(MockupLibrary.swatches[device.finish] != nil)
        }
    }
}
