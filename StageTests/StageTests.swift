import CoreGraphics
import Foundation
import Testing
@testable import Stage

struct StageLayoutTests {
    let phone = CGSize(width: 1206, height: 2622)

    @Test func pictureFillsTheWindowAboveTheControls() {
        let layout = StageLayout(videoSize: phone)
        let window = layout.windowSize(longSide: 820, bottomInset: 80)
        let rect = layout.pictureRect(in: window, bottomInset: 80)
        #expect(abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5)
        #expect(abs(rect.width - window.width) < 0.5)
        #expect(abs(rect.maxY - (window.height - 80)) < 0.5)
    }

    @Test func rotatedPhoneGivesAWideWindow() {
        let landscape = StageLayout(videoSize: CGSize(width: phone.height, height: phone.width))
        let window = landscape.windowSize(longSide: 820, bottomInset: 80)
        #expect(window.width == 820)
        #expect(abs(landscape.pictureRect(in: window, bottomInset: 80).height - (window.height - 80)) < 0.5)
    }

    @Test func otherShapesCenterThePictureAboveTheControls() {
        let layout = StageLayout(videoSize: phone)
        let rect = layout.pictureRect(in: CGSize(width: 1440, height: 900), bottomInset: 80)
        #expect(abs(rect.midX - 720) < 0.5)
        #expect(rect.maxY <= 820 + 0.01)
        #expect(abs(rect.height - 820) < 0.5)
    }
}

struct NamingTests {
    @Test func recordingNameUsesDeviceAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 3, second: 12)))
        #expect(RecordingName.make(for: "Serein", at: date) == "Serein 2026-10-15 at 15.03.12.mov")
        #expect(RecordingName.make(for: "A/B: C", at: date) == "A-B- C 2026-10-15 at 15.03.12.mov")
    }

    @Test func uniqueNameNumbersDuplicates() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(RecordingName.unique("Take.mov", in: folder).lastPathComponent == "Take.mov")
        FileManager.default.createFile(atPath: folder.appending(path: "Take.mov").path, contents: Data())
        #expect(RecordingName.unique("Take.mov", in: folder).lastPathComponent == "Take 2.mov")
    }

    @Test(arguments: [(0.0, "0:00"), (42.4, "0:42"), (725, "12:05"), (3723, "1:02:03")])
    func clockFormatsElapsedTime(seconds: Double, expected: String) {
        #expect(Clock.string(seconds) == expected)
    }

    @Test(arguments: [AudioChoice.source, .off, .microphone("BuiltInMicrophoneDevice")])
    func audioChoiceSurvivesStorage(choice: AudioChoice) {
        #expect(AudioChoice(storedValue: choice.storedValue) == choice)
    }
}
