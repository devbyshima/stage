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

/// A device is chosen but no picture has arrived yet.
struct ConnectingView: View {
    let source: CaptureSource

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("Connecting to \(source.name)…")
                .font(.headline)
            Text("Keep it unlocked.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
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
