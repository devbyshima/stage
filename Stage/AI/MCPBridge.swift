import AppKit
import Darwin

/// `Stage --mcp`, what an AI tool runs to use Stage: it opens Stage if it
/// isn't running, then relays the tool's MCP messages between its standard
/// input and output and the app.
enum MCPBridge {
    @MainActor
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let socket = connectOpeningStage() else {
            FileHandle.standardError.write(Data("Stage isn't reachable. Open Stage, and turn on AI Control in its Settings.\n".utf8))
            exit(1)
        }
        let replies = Thread {
            relay(from: socket, to: STDOUT_FILENO)
            exit(0)
        }
        replies.start()
        relay(from: STDIN_FILENO, to: socket)
        exit(0)
    }

    @MainActor
    private static func connectOpeningStage() -> Int32? {
        if let socket = MCPSocket.connect() { return socket }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        // Stage opens its socket once it has launched.
        for _ in 0..<80 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            if let socket = MCPSocket.connect() { return socket }
        }
        return nil
    }

    private static func relay(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(source, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, MCPSocket.write(Data(chunk[0..<count]), to: destination) else { return }
        }
    }
}
