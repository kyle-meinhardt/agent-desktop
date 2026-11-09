import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exposes the separate desktop over MCP stdio.
@MainActor
final class AgentServer {
    let backend: VNCDesktopBackend
    let name: String

    init(backend: VNCDesktopBackend, name: String) {
        self.backend = backend
        self.name = name
    }

    let serverInstructions = """
    Controls a separate macOS user session through Screen Sharing.
    Confirm the virtual session and account with status. Verify the separate desktop with
    screenshot before sending input. Coordinates are screenshot pixels from the top left.
    Take screenshots after actions to verify results. Leave login and permission prompts
    to the user. Input requires approval through agent-desktop approve.
    """

    var toolDefinitions: [[String: Any]] { Self.tools }

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let point: [String: Any] = ["type": "integer", "minimum": 0]
    private static let after: [String: Any] = ["type": "boolean", "description": "Also return a screenshot taken shortly after the action."]
    static let tools: [[String: Any]] = [
        ["name": "screenshot", "description": "Capture the separate macOS user desktop. Other tools use pixels in this image.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]],
        ["name": "click", "description": "Click at a point. clicks: 2 double-clicks, 3 triple-clicks.",
         "inputSchema": schema(["x": point, "y": point, "button": ["type": "string", "enum": ["left", "right"]],
                                "clicks": ["type": "integer", "minimum": 1, "maximum": 3], "screenshot": after], required: ["x", "y"])],
        ["name": "move", "description": "Move the pointer, for example to reveal a hover menu or tooltip.",
         "inputSchema": schema(["x": point, "y": point, "screenshot": after], required: ["x", "y"])],
        ["name": "drag", "description": "Press the left button at (x, y), drag to (toX, toY) and release. Selects text, moves windows and items.",
         "inputSchema": schema(["x": point, "y": point, "toX": point, "toY": point, "screenshot": after], required: ["x", "y", "toX", "toY"])],
        ["name": "scroll", "description": "Scroll vertically at a point. Negative dy scrolls down the page. Pixels, -1000…1000. For horizontal movement, drag a horizontal scrollbar.",
         "inputSchema": schema(["x": point, "y": point, "dy": ["type": "integer"], "screenshot": after], required: ["x", "y", "dy"])],
        ["name": "type", "description": "Type literal text into the focused field. Supports BMP characters, including accented letters. Use key for return, tab and shortcuts.",
         "inputSchema": schema(["text": ["type": "string"], "screenshot": after], required: ["text"])],
        ["name": "key", "description": "Press a key or chord: return, tab, escape, backspace, up, cmd+space, cmd+tab, cmd+c, cmd+shift+... Modifiers: cmd, ctrl, alt, shift.",
         "inputSchema": schema(["key": ["type": "string"], "screenshot": after], required: ["key"])],
        ["name": "status", "description": "Report the Screen Sharing connection and whether session input is approved.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]]
    ]

    func run() async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            // Notifications have no id and get no reply.
            guard let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "agent-desktop", "version": appVersion],
                    "instructions": serverInstructions]])
            case "ping": send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list": send(["jsonrpc": "2.0", "id": id, "result": ["tools": toolDefinitions]])
            case "tools/call":
                let tool = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do { send(["jsonrpc": "2.0", "id": id, "result": ["content": try await call(tool, arguments)]]) }
                catch { send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]]) }
            default: send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    func call(_ tool: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        func int(_ key: String) throws -> String {
            guard let number = a[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = number as? Int else {
                throw Failure("Expected an integer in range for '\(key)'")
            }
            return String(value)
        }
        func string(_ key: String) throws -> String {
            guard let value = a[key] as? String, !value.isEmpty else { throw Failure("Missing '\(key)'") }
            return value
        }
        var requests: [Request] = []
        switch tool {
        case "screenshot": return try await screenshot()
        case "status":
            let reply = try await backend.call(Request(action: "status", timeout: 5))
            let summary = reply.values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return [["type": "text", "text": "Session '\(name)' is connected.\n" + summary]]
        case "click":
            var base = ["x": try int("x"), "y": try int("y")]
            if a["button"] as? String == "right" { base["button"] = "right" }
            let clicks = max(1, min(3, a["clicks"] as? Int ?? 1))
            // Each extra click continues the sequence, which macOS reads as a double or triple click.
            for count in 1...clicks { requests.append(Request(action: "click", arguments: count == 1 ? base : base.merging(["count": String(count)]) { $1 }, timeout: 10)) }
        case "move": requests = [Request(action: "move", arguments: ["x": try int("x"), "y": try int("y")], timeout: 10)]
        case "drag": requests = [Request(action: "drag", arguments: ["x": try int("x"), "y": try int("y"), "x2": try int("toX"), "y2": try int("toY")], timeout: 15)]
        case "scroll":
            var arguments = ["x": try int("x"), "y": try int("y"), "dy": try int("dy")]
            if a["dx"] != nil { arguments["dx"] = try int("dx") }
            requests = [Request(action: "scroll", arguments: arguments, timeout: 10)]
        case "type": requests = [Request(action: "type", arguments: ["text": try string("text")], timeout: 30)]
        case "key": requests = [Request(action: "key", arguments: ["key": try string("key")], timeout: 10)]
        default: throw Failure("Unknown tool: \(tool)")
        }
        for request in requests { _ = try await backend.call(request) }
        var content: [[String: Any]] = [["type": "text", "text": "Done: \(tool)."]]
        if a["screenshot"] as? Bool == true {
            // Give animations and redraws a moment before looking.
            try await Task.sleep(nanoseconds: 400_000_000)
            content += try await screenshot()
        }
        return content
    }

    /// A point-sized screenshot, so image pixels are the coordinates the other tools take.
    /// JPEG keeps the message small; the model sees the same detail at this size.
    private func screenshot() async throws -> [[String: Any]] {
        let request = Request(action: "screenshot", timeout: 15)
        let imageName = "image-\(request.id.uuidString).png"
        defer { backend.remove(imageName) }
        let reply = try await backend.call(request)
        guard reply.values["image"] == imageName, let png = try backend.read(imageName, limit: 64 * 1024 * 1024),
              let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("The desktop backend returned an invalid screenshot")
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure("Cannot encode screenshot") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode screenshot") }
        return [["type": "image", "data": (jpeg as Data).base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": "Screen: \(image.width)×\(image.height). Use these pixel coordinates."]]
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
