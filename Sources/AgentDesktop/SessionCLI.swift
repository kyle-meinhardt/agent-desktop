import Foundation
import Darwin

@MainActor
struct CLI {
    let store = Store()

    func run(_ input: [String]) async throws {
        let command = input.first ?? "help"
        let tail = Array(input.dropFirst())
        let profiles = SessionProfiles(store: store)
        switch command {
        case "help", "--help", "-h": print(Self.sessionHelp)
        case "--version", "version": print("agent-desktop \(appVersion)")
        case "doctor": try printJSON(["sessionLibraryAvailable": String(VNCConnection.available)])
        case "configure":
            let args = try Arguments(tail, options: ["host", "port", "user"])
            let name = try sessionName(args)
            let existing = try? profiles.load(name)
            let profile = SessionProfile(name: name, host: args.options["host"] ?? existing?.host ?? "127.0.0.1",
                                         port: try args.integer("port", default: existing?.port ?? 5900, range: 1...65535),
                                         username: args.options["user"] ?? existing?.username ?? "agent", inputApproved: false)
            try profile.validate()
            let password = try SessionProfiles.promptPassword()
            try profiles.savePassword(password, name: name)
            try profiles.save(profile)
            try printJSON(["session": name, "host": profile.host, "port": String(profile.port), "username": profile.username,
                           "inputApproved": "false", "credential": "Keychain"])
            stderr("Next: agent-desktop action \(name) screenshot. Confirm it shows the separate \(profile.username) desktop, then run agent-desktop approve \(name).")
        case "approve":
            let args = try Arguments(tail)
            let name = try sessionName(args)
            var profile = try profiles.load(name)
            guard isatty(STDIN_FILENO) == 1 else { throw Failure("Session approval requires an interactive terminal") }
            stderr("Approve input only after viewing this connection with `agent-desktop action \(name) screenshot`.")
            stderr("Confirm the desktop belongs to '\(profile.username)' and your physical desktop stays independent.")
            stderr("This is a user-account session on your Mac, not a VM. Type the account short username to approve input:")
            guard readLine() == profile.username else { throw Failure("Session input was not approved") }
            profile.inputApproved = true
            try profiles.save(profile)
            try printJSON(["session": name, "inputApproved": "true"])
        case "revoke":
            let args = try Arguments(tail)
            let name = try sessionName(args)
            var profile = try profiles.load(name)
            profile.inputApproved = false
            try profiles.save(profile)
            try printJSON(["session": name, "inputApproved": "false"])
        case "action": try await sessionAction(tail, profiles: profiles)
        case "watch":
            let args = try Arguments(tail, flags: ["terminal"])
            let name = try sessionName(args)
            let profile = try profiles.load(name)
            let connection = KeychainSessionConnection(profile: profile, profiles: profiles, readOnly: true)
            if args.flags.contains("terminal") {
                try await watchDesktopInTerminal(connection)
            } else {
                try await watchDesktop(connection)
            }
        case "mcp":
            let args = try Arguments(tail, flags: ["config"])
            let name = try sessionName(args)
            if args.flags.contains("config") {
                var server: [String: Any] = ["command": launcherPath, "args": ["mcp", name]]
                if ProcessInfo.processInfo.environment["AGENT_DESKTOP_HOME"] != nil {
                    server["env"] = ["AGENT_DESKTOP_HOME": store.root.path]
                }
                let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["agent-desktop": server]],
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: data, as: UTF8.self)); return
            }
            let profile = try profiles.load(name)
            let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: KeychainSessionConnection(profile: profile, profiles: profiles))
            try await AgentServer(backend: backend, name: name).run()
        default: throw Failure("Unknown session command: \(command). Run: agent-desktop help")
        }
    }

    private func sessionName(_ args: Arguments) throws -> String {
        guard args.positionals.count <= 1 else { throw Failure("Expected one session name") }
        let name = args.positionals.first ?? "agent"
        try validateName(name)
        return name
    }

    private func sessionAction(_ input: [String], profiles: SessionProfiles) async throws {
        let args = try Arguments(input, flags: ["double"], options: ["x", "y", "x2", "y2", "dx", "dy", "text", "key", "button", "count", "output", "timeout"])
        let actions: Set<String> = ["status", "screenshot", "snapshot", "click", "move", "drag", "scroll", "type", "key"]
        var positions = args.positionals
        let name: String
        if let first = positions.first, actions.contains(first) { name = "agent" }
        else {
            guard !positions.isEmpty else { throw Failure("Usage: agent-desktop action [NAME] status|screenshot|click|type|key|scroll") }
            name = positions.removeFirst()
        }
        let profile = try profiles.load(name)
        guard !positions.isEmpty, actions.contains(positions[0]) else { throw Failure("Unknown or missing session action") }
        let verb = positions.removeFirst()
        var parameters = args.options
        parameters.removeValue(forKey: "output"); parameters.removeValue(forKey: "timeout")
        if verb == "type", !positions.isEmpty { parameters["text"] = positions.joined(separator: " "); positions.removeAll() }
        if verb == "key", positions.count == 1 { parameters["key"] = positions.removeFirst() }
        if ["click", "move"].contains(verb), positions.count == 2 { parameters["x"] = positions.removeFirst(); parameters["y"] = positions.removeFirst() }
        if verb == "drag", positions.count == 4 {
            for key in ["x", "y", "x2", "y2"] { parameters[key] = positions.removeFirst() }
        }
        guard positions.isEmpty else { throw Failure("Unexpected session action arguments") }
        if args.flags.contains("double") { parameters["double"] = "true" }
        let timeout = try args.integer("timeout", default: 15, range: 1...120)
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: KeychainSessionConnection(profile: profile, profiles: profiles))
        let request = Request(action: verb, arguments: parameters, timeout: Double(timeout))
        let imageName = "image-\(request.id.uuidString).png"
        defer { backend.remove(imageName) }
        let reply = try await backend.call(request)
        var values = reply.values
        if verb == "screenshot" || verb == "snapshot" {
            guard values["image"] == imageName, let png = try backend.read(imageName, limit: 64 * 1024 * 1024) else { throw Failure("Invalid session image response") }
            let output = URL(fileURLWithPath: ((args.options["output"] ?? "agent-desktop-\(name).png") as NSString).expandingTildeInPath)
            try png.write(to: output, options: .atomic)
            values["image"] = output.path
        }
        try printJSON(values)
    }

    static let sessionHelp = """
    Agent Desktop — a separate user desktop through macOS Screen Sharing

    configure [NAME] [--host 127.0.0.1 --port 5900 --user agent]
    action [NAME] status|screenshot|click|move|drag|scroll|type|key
    approve [NAME]           Enable input after verifying a screenshot
    revoke [NAME]            Disable input for existing and new connections
    watch [NAME] [--terminal]  Watch in a browser or inside your terminal
    mcp [NAME] [--config]    Serve MCP over stdio or print its configuration
    doctor                  Check that the Screen Sharing library can load
    --version

    The default profile name is agent. Enable Screen Sharing for the separate account.
    """
}
