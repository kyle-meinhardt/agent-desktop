import Darwin
import Foundation

@main
struct AgentDesktop {
    @MainActor
    static func main() async {
        do {
            try await CLI().run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            stderr("agent-desktop: \(error.localizedDescription)")
            exit(1)
        }
    }
}

let appVersion = "0.1.0"

var launcherPath: String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
}

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printJSON(_ value: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
