import SwiftUI

/// Stage starts as the app or, run as `Stage --mcp` by an AI tool, as the
/// relay between that tool and the app.
@main
enum StageMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == MCPServer.argument {
            MCPBridge.run()
        }
        StageApp.main()
    }
}
