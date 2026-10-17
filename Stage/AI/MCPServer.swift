import Darwin
import Foundation

/// Stage's end of AI control: listens on `MCPSocket` while it's allowed in
/// Settings, and hands each message to `StageTools`, writing back its reply.
final class MCPServer: @unchecked Sendable {
    static let shared = MCPServer()

    /// What an AI tool runs to reach Stage: this app's own executable.
    static var command: String { Bundle.main.executablePath ?? "/Applications/Stage.app/Contents/MacOS/Stage" }
    static let argument = "--mcp"

    private let queue = DispatchQueue(label: "com.fulltimestudio.stage.mcp")
    // Touched on `queue` only.
    private var listener: (any DispatchSourceRead)?
    private var connections: [Int32: MCPConnection] = [:]

    func setEnabled(_ enabled: Bool) {
        queue.async { enabled ? self.start() : self.stop() }
    }

    /// Stops listening before Stage quits, so no socket is left behind.
    func shutDown() {
        queue.sync { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        let path = MCPSocket.url.path
        try? FileManager.default.createDirectory(at: MCPSocket.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        guard MCPSocket.withAddress(path, { bind(descriptor, $0, $1) }) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return
        }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [unowned self] in accept(from: descriptor) }
        source.setCancelHandler {
            close(descriptor)
            unlink(path)
        }
        source.resume()
        listener = source
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func accept(from listener: Int32) {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        MCPSocket.noSignalOnClose(descriptor)
        let connection = MCPConnection(descriptor: descriptor, queue: queue) { [unowned self] in
            connections[descriptor] = nil
        }
        connections[descriptor] = connection
        connection.start()
    }
}

/// One AI tool's link to Stage.
private final class MCPConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let onClose: @Sendable () -> Void
    // Touched on `queue` only.
    private var source: (any DispatchSourceRead)?
    private var pending = Data()

    init(descriptor: Int32, queue: DispatchQueue, onClose: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [unowned self] in read() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &chunk, chunk.count)
        guard count > 0 else {
            close()
            onClose()
            return
        }
        pending.append(contentsOf: chunk[0..<count])
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            Task { @MainActor in
                guard let reply = await StageTools.shared.handle(line) else { return }
                self.send(reply)
            }
        }
    }

    private func send(_ reply: String) {
        queue.async { [self] in
            guard source != nil else { return }
            MCPSocket.write(Data((reply + "\n").utf8), to: descriptor)
        }
    }

    func close() {
        source?.cancel()
        source = nil
    }
}
