import SwiftUI

/// Shown until a phone is plugged in.
struct ConnectView: View {
    var body: some View {
        EmptyStateView(doodle: "EmptyCable", title: "Plug in your iPhone")
    }
}

/// Stage's empty screen in StarHash's look: a green doodle with a title
/// under it, centred, and no line explaining it. The title is Gochi Hand, a
/// marker hand as heavy as the doodle's brush pen.
struct EmptyStateView: View {
    let doodle: String
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            Image(doodle)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            Text(title)
                .font(.custom("Gochi Hand", size: 26))
                .foregroundStyle(Color(white: 244 / 255))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .contain)
    }
}

/// A device is chosen but no picture has arrived yet: the empty screen's
/// look, with a handwritten loader above the title.
struct ConnectingView: View {
    let source: CaptureSource

    var body: some View {
        VStack(spacing: 0) {
            HandwrittenLoader()
                .frame(width: 64, height: 64)
                .padding(.bottom, 24)
            Text("Connecting to \(source.name)")
                .font(.custom("Gochi Hand", size: 26))
                .foregroundStyle(Color(white: 244 / 255))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Keep it unlocked")
                .font(.custom("Gochi Hand", size: 19))
                .foregroundStyle(Color(white: 0.6))
                .padding(.top, 4)
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .combine)
    }
}

/// A loader written by hand: a marker stroke draws a loop the way a quick
/// pen circle goes, wobbly and running past its start, then lifts off from
/// where it began, and writes it again a little further round. In the
/// doodles' mint, the colour of their lines.
struct HandwrittenLoader: View {
    /// One loop written and lifted.
    private static let cycle: TimeInterval = 1.5

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let progress = time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
            // The pen writes for the first 60%, and the stroke lifts away
            // from its start over the last 60%, so the two overlap.
            let head = Self.ease(min(1, progress / 0.6))
            let tail = Self.ease(max(0, (progress - 0.4) / 0.6))
            HandDrawnLoop()
                .trim(from: tail, to: head)
                .stroke(Color(red: 0x5C / 255, green: 0xF0 / 255, blue: 0x8F / 255),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                // Each loop starts a little further round than the last.
                .rotationEffect(.degrees(time / Self.cycle * 75))
        }
        .accessibilityHidden(true)
    }

    private static func ease(_ x: Double) -> Double {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

/// A circle as a hand draws it: never quite round, and the end overshooting
/// the start a little on the outside.
struct HandDrawnLoop: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.82
        let sweep = 2 * Double.pi + 0.55
        let steps = 90
        var path = Path()
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let angle = -Double.pi / 2 + sweep * t
            // A slight lumpiness, and a drift outward towards the end.
            let wobble = 1 + 0.045 * sin(3 * angle + 0.9) + 0.025 * sin(5 * angle + 2.1)
            let r = radius * (wobble + 0.07 * t)
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Camera access was turned off, which also hides iPhone screens.
struct AccessNeededView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Allow Stage to use the camera")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("macOS treats a connected iPhone screen as a camera. Turn on Stage in Privacy & Security › Camera, then reopen Stage.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 360)
    }
}
