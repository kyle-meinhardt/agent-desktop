import Foundation
import XCTest
@testable import AgentDesktop

final class DesktopWatchServerTests: XCTestCase {
    @MainActor
    func testViewerServesOnlyAuthorizedReadOnlyRequests() async throws {
        let server = try DesktopWatchServer()
        defer { server.stop() }
        let frame = Data([0xff, 0xd8, 0xff, 0xd9])
        server.frame = (1, frame)
        let url = try await server.start()
        XCTAssertEqual(url.host, "127.0.0.1")

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: path.isEmpty ? url : try XCTUnwrap(URL(string: path, relativeTo: url)), timeoutInterval: 3)
            request.httpMethod = method
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let (page, html) = try await fetch("")
        XCTAssertEqual(html.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Agent Desktop"))
        XCTAssertEqual(html.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(html.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
        XCTAssertEqual(html.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy"), "same-origin")

        let (image, first) = try await fetch("frame?since=0")
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(first.mimeType, "image/jpeg")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Frame-Sequence"), "1")
        XCTAssertEqual(image, frame)

        let (empty, unchanged) = try await fetch("frame?since=1")
        XCTAssertEqual(unchanged.statusCode, 204)
        XCTAssertTrue(empty.isEmpty)

        server.frame = (2, frame + Data([1]))
        let (updated, next) = try await fetch("frame?since=1")
        XCTAssertEqual(next.statusCode, 200)
        XCTAssertEqual(next.value(forHTTPHeaderField: "X-Frame-Sequence"), "2")
        XCTAssertNotEqual(updated, image)

        let (_, missingToken) = try await fetch("/frame?since=0")
        let (_, wrongToken) = try await fetch("/another/frame?since=0")
        let (_, post) = try await fetch("frame?since=0", method: "POST")
        let (_, input) = try await fetch("click?x=0&y=0")
        for rejected in [missingToken, wrongToken, post, input] {
            XCTAssertEqual(rejected.statusCode, 404)
        }
    }
}
