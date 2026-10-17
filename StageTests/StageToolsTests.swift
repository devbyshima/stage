import Foundation
import Testing
@testable import Stage

@MainActor
struct StageToolsTests {
    private func send(_ message: [String: Any]) async throws -> [String: Any]? {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        guard let reply = await StageTools.shared.handle(line) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
    }

    @Test func initializeAnswersWithTheClientsVersion() async throws {
        let reply = try #require(try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": ["protocolVersion": "2025-06-18"]]))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "stage")
    }

    @Test func listsEveryTool() async throws {
        let reply = try #require(try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["get_studio", "list_recordings", "open_recording", "update_mockup", "set_focus_areas", "reset_pose",
                          "edit_recording", "render_preview", "save_template", "apply_template", "export"])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
    }

    @Test func notificationsGetNoReply() async throws {
        #expect(try await send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func unknownMethodsAreErrors() async throws {
        let reply = try #require(try await send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"]))
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func unknownToolsAreToolErrors() async throws {
        let reply = try #require(try await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "fly"]]))
        #expect((reply["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func backgroundsReadEveryWay() throws {
        #expect(try StageTools.background("studio") == .studio)
        #expect(try StageTools.background("Clear") == .clear)
        #expect(try StageTools.background("#FFFFFF") == .color(RGBA(1, 1, 1)))
        #expect(try StageTools.background("#000, #fff") == .gradient(RGBA(0, 0, 0), RGBA(1, 1, 1)))
        #expect(throws: ToolError.self) { try StageTools.background("plaid") }
    }

    @Test func namesMatchHoweverWritten() {
        #expect(StageTools.same("push_in", "Push In"))
        #expect(StageTools.same("pushIn", "push in"))
        #expect(!StageTools.same("orbit", "drift"))
    }

    @Test func argumentsAreChecked() throws {
        let arguments = Arguments(["turn": 20, "zoom": 9, "shot": "Pair", "enabled": "yes"])
        #expect(try arguments.number("turn", in: -45...45) == 20)
        #expect(throws: ToolError.self) { try arguments.number("zoom", in: 0.6...1.6) }
        #expect(try arguments.choice("shot", MockupShot.allCases, names: { [$0.rawValue, $0.title] }) == .pair)
        #expect(throws: ToolError.self) { try arguments.bool("enabled") }
        #expect(try arguments.number("tilt", in: -30...30) == nil)
    }
}

struct MockupFocusTests {
    @Test func aTourRestsOnEachAreaAtItsTime() {
        let tour = [MockupFocus.top, .bottom]
        #expect(MockupFocus.path(tour, at: 0) == .top)
        #expect(MockupFocus.path(tour, at: 0.2) == .top)
        #expect(MockupFocus.path(tour, at: 1) == .bottom)
        let halfway = MockupFocus.path(tour, at: 0.5)
        #expect(halfway.map { $0.y0 > MockupFocus.top.y0 && $0.y0 < MockupFocus.bottom.y0 } == true)
    }

    @Test func oneAreaHolds() {
        #expect(MockupFocus.path([.middle], at: 0.7) == .middle)
        #expect(MockupFocus.path([], at: 0.7) == nil)
    }

    @Test func areasAreTidied() {
        let area = MockupFocus(x0: 1.2, y0: 0.5, x1: -0.1, y1: 0.52).tidy
        #expect(area.x0 == 0 && area.x1 == 1)
        #expect(abs((area.y1 - area.y0) - 0.1) < 0.0001)
    }
}
