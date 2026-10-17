import Darwin
import Foundation

/// Where Stage listens for AI tools: a Unix socket in Stage's own support
/// folder that only this Mac's user can open. Messages go both ways as
/// JSON-RPC, one a line, as MCP sends them over standard input and output.
enum MCPSocket {
    static var url: URL {
        #if DEBUG
        // A Debug build listens apart, so trying one never takes over the
        // socket of the Stage in use.
        let name = "mcp-debug.sock"
        #else
        let name = "mcp.sock"
        #endif
        return URL.applicationSupportDirectory.appending(path: "Stage/\(name)")
    }

    /// Runs `body` with the address of the socket at `path`.
    static func withAddress<Result>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A connection to the running Stage, or nil when it isn't listening.
    static func connect() -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        noSignalOnClose(descriptor)
        guard withAddress(url.path, { Darwin.connect(descriptor, $0, $1) }) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Writing to a socket the other end closed fails instead of ending
    /// the process.
    static func noSignalOnClose(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`; false if the other end has gone.
    @discardableResult
    static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
