import Foundation
import XCTest
@testable import AgentDesktop

final class GuidedSetupTests: XCTestCase {
    @MainActor
    func testMCPRegistrationMatchesTheInstalledCommandAndProfile() throws {
        let command = "/usr/bin/true"
        func matches(path: String = "/usr/bin/true", args: [String] = ["mcp", "agent"],
                     enabled: Bool = true, dataRoot: String? = nil) throws -> Bool {
            let transport: [String: Any] = [
                "type": "stdio", "command": path, "args": args, "env": ["AGENT_DESKTOP_HOME": "/fixture"]
            ]
            let encoded = try JSONSerialization.data(withJSONObject: [
                "name": "agent-desktop", "enabled": enabled, "transport": transport
            ])
            return try JSONDecoder().decode(GuidedSetup.MCPRegistration.self, from: encoded)
                .matches(command: command, dataRoot: dataRoot)
        }

        XCTAssertTrue(try matches(dataRoot: "/fixture"))
        XCTAssertFalse(try matches(path: "/usr/bin/false", dataRoot: "/fixture"))
        XCTAssertFalse(try matches(args: ["mcp", "other"], dataRoot: "/fixture"))
        XCTAssertFalse(try matches(enabled: false, dataRoot: "/fixture"))
        XCTAssertFalse(try matches())
    }
}
