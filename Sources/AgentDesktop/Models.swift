import Foundation

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    init(_ input: [String], flags allowedFlags: Set<String> = [], options allowedOptions: Set<String> = []) throws {
        var i = 0
        while i < input.count {
            let item = input[i]
            if item == "--" { positionals += input.dropFirst(i + 1); break }
            if item.hasPrefix("--") {
                let name = String(item.dropFirst(2))
                guard !flags.contains(name), options[name] == nil else { throw Failure("Duplicate option: \(item)") }
                if allowedFlags.contains(name) { flags.insert(name) }
                else if allowedOptions.contains(name) {
                    i += 1
                    guard i < input.count, !input[i].hasPrefix("--") else { throw Failure("Missing value for \(item)") }
                    options[name] = input[i]
                } else { throw Failure("Unknown option: \(item)") }
            } else { positionals.append(item) }
            i += 1
        }
    }
    func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = options[key] else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw Failure("--\(key) must be in \(range)") }
        return value
    }
}

func validateName(_ name: String) throws {
    guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$", options: .regularExpression) != nil else {
        throw Failure("Session names must be 1–48 letters, numbers, underscores or hyphens, starting with a letter or number")
    }
}

struct Request: Codable {
    let id: UUID
    let action: String
    let arguments: [String: String]
    let deadline: Date
    init(action: String, arguments: [String: String] = [:], timeout: TimeInterval = 15) {
        id = UUID(); self.action = action; self.arguments = arguments; deadline = Date().addingTimeInterval(timeout)
    }
}

struct Reply: Codable {
    let id: UUID
    let ok: Bool
    let values: [String: String]
    let error: String?
    init(id: UUID, values: [String: String] = [:], error: String? = nil) {
        self.id = id; ok = error == nil; self.values = values; self.error = error
    }
}

struct Store {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["AGENT_DESKTOP_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/agent-desktop")
    }
}
