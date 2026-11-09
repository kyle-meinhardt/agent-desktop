import Darwin
import Foundation

@MainActor
struct GuidedSetup {
    let store: Store
    let resources: URL

    private let sharingGroup = "com.apple.access_screensharing"
    private let environment = ProcessInfo.processInfo.environment
    private let files = FileManager.default

    func run(checkOnly: Bool, command: ([String]) async throws -> Void) async throws {
        let account = try localAgentUID()
        if checkOnly {
            let access = if let account, account >= 501, try sharingAccessGroupExists() {
                try hasSharingAccess()
            } else { false }
            try printJSON([
                "agentUID": account.map(String.init) ?? "missing",
                "agentInScreenSharingAccessGroup": String(access),
                "screenSharingPortReachable": String(try screenSharingPortReachable()),
                "sessionLibraryAvailable": String(VNCConnection.available)
            ])
            return
        }

        guard isatty(STDIN_FILENO) == 1, geteuid() != 0, NSUserName() != "agent" else {
            throw Failure("Run setup interactively from your regular macOS account, without sudo")
        }
        guard let codex = executableOnPath("codex") else {
            throw Failure("Install Codex and put its executable on PATH, then rerun setup")
        }
        guard VNCConnection.available, files.fileExists(atPath: resources.appendingPathComponent("agent-desktop/SKILL.md").path) else {
            throw Failure("Build Agent Desktop with bash scripts/build.sh before running setup")
        }

        let profiles = SessionProfiles(store: store)
        let profileFile = try profiles.directory("agent").appendingPathComponent("session.json")
        let existing = files.fileExists(atPath: profileFile.path) ? try profiles.load("agent") : nil
        if let existing {
            guard existing.username == "agent", existing.port == 5900, account != nil else {
                throw Failure("The saved profile targets a different session or its account is missing. Inspect it before running guided setup.")
            }
        }

        if account == nil {
            try confirm("Create a standard local macOS account named agent? macOS will prompt for authorization and a password.")
            try requireSuccess("/usr/bin/sudo", ["/usr/sbin/sysadminctl", "-addUser", "agent",
                                              "-fullName", "Agent Desktop", "-password", "-"])
            guard try localAgentUID() != nil else { throw Failure("macOS did not create the agent account") }
            try continueAfter("Log in to agent once, complete macOS’s first-login steps, then return to this account.")
        }
        try verifySeparateStandardAccount()

        if try !screenSharingPortReachable() {
            try continueAfter("Turn on Screen Sharing in System Settings → General → Sharing.")
            guard try screenSharingPortReachable() else { throw Failure("Screen Sharing is still unavailable on 127.0.0.1:5900") }
        }
        if try sharingAccessGroupExists() {
            if try !hasSharingAccess() {
                try confirm("Add agent to the existing Screen Sharing access group? macOS may prompt for administrator authorization.")
                try requireSuccess("/usr/bin/sudo", ["/usr/sbin/dseditgroup", "-o", "edit", "-a", "agent",
                                                  "-t", "user", sharingGroup])
                guard try hasSharingAccess() else { throw Failure("The Screen Sharing access group did not grant access to agent") }
            }
        } else {
            try continueAfter("In Screen Sharing’s details, select Only these users and add agent to the list.")
            guard try sharingAccessGroupExists(), try hasSharingAccess() else {
                throw Failure("Could not verify that agent is in the Screen Sharing access group")
            }
        }

        if existing == nil { try await command(["configure", "agent"]) }
        let preview = files.temporaryDirectory.appendingPathComponent("agent-desktop-setup-\(UUID().uuidString)")
        try files.createDirectory(at: preview, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: preview) }
        let screenshot = preview.appendingPathComponent("agent.png")
        do {
            try await command(["action", "agent", "screenshot", "--output", screenshot.path])
        } catch {
            stderr("Check that agent finished the first login. If the saved password is wrong, run agent-desktop configure agent, then rerun setup.")
            throw error
        }
        try requireSuccess("/usr/bin/open", [screenshot.path])
        if existing?.inputApproved == true {
            try continueAfter("Verify that the preview shows the separate agent desktop. This profile already has input approval.")
        } else {
            try await command(["approve", "agent"])
        }

        try installSkill()
        try registerMCP(codex)
        try installShortcut()
        stderr("Setup complete. Start a new Codex session to load the MCP configuration and skill.")
    }

    private func localAgentUID() throws -> Int? {
        let record = try run("/usr/bin/dscl", [".", "-read", "/Users/agent", "UniqueID"], capture: true)
        if record.status == 56 { return nil } // dscl uses the low byte of 14136 (record not found)
        guard record.status == 0, let uid = record.output.split(whereSeparator: \.isWhitespace).last.flatMap({ Int($0) }) else {
            throw Failure("Could not inspect the local agent account")
        }
        return uid
    }

    private func verifySeparateStandardAccount() throws {
        guard let uid = try localAgentUID(), uid >= 501, uid != Int(geteuid()) else {
            throw Failure("Setup requires a separate standard local account named agent")
        }
        let groups = try run("/usr/bin/id", ["-Gn", "agent"], capture: true)
        guard groups.status == 0, !groups.output.split(whereSeparator: \.isWhitespace).contains("admin") else {
            throw Failure("Use a standard agent account. Setup cannot reuse an administrator account.")
        }
    }

    private func sharingAccessGroupExists() throws -> Bool {
        let record = try run("/usr/bin/dscl", [".", "-read", "/Groups/\(sharingGroup)", "RecordName"], capture: true)
        guard [0, 56].contains(record.status) else { throw Failure("Could not inspect Screen Sharing permissions") }
        return record.status == 0
    }

    private func hasSharingAccess() throws -> Bool {
        let result = try run("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", "agent", sharingGroup], capture: true)
        guard [0, 67].contains(result.status) else { throw Failure("Could not check agent’s Screen Sharing access") }
        return result.status == 0
    }

    private func screenSharingPortReachable() throws -> Bool {
        try run("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", "5900"], capture: true).status == 0
    }

    private func confirm(_ message: String) throws {
        stderr(message + " Type yes to continue.")
        guard readLine() == "yes" else { throw Failure("Setup stopped. Rerun setup to resume.") }
    }

    private func continueAfter(_ message: String) throws {
        stderr(message + " Press Return when finished.")
        guard readLine() == "" else { throw Failure("Setup stopped. Rerun setup to resume.") }
    }

    private func installSkill() throws {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let skills = codexHome.appendingPathComponent("skills")
        let destination = skills.appendingPathComponent("agent-desktop")
        try files.createDirectory(at: skills, withIntermediateDirectories: true)
        if !files.fileExists(atPath: destination.path) {
            try files.copyItem(at: resources.appendingPathComponent("agent-desktop"), to: destination)
        }
        stderr("Agent Desktop skill is available at \(destination.path).")
    }

    private func registerMCP(_ codex: String) throws {
        let listing = try run(codex, ["mcp", "list", "--json"], capture: true)
        guard listing.status == 0,
              let servers = try JSONSerialization.jsonObject(with: Data(listing.output.utf8)) as? [[String: Any]] else {
            throw Failure("Could not read existing Codex MCP registrations")
        }
        guard !servers.contains(where: { $0["name"] as? String == "agent-desktop" }) else {
            stderr("Kept the existing agent-desktop MCP registration. Use codex mcp get agent-desktop to review it.")
            return
        }
        let options = environment["AGENT_DESKTOP_HOME"] == nil ? [] : ["--env", "AGENT_DESKTOP_HOME=\(store.root.path)"]
        try requireSuccess(codex, ["mcp", "add", "agent-desktop"] + options + ["--", launcherPath, "mcp", "agent"])
    }

    private func installShortcut() throws {
        if executableOnPath("agent-desktop") != nil { return }
        let bin = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let shortcut = bin.appendingPathComponent("agent-desktop")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        if (try? files.attributesOfItem(atPath: shortcut.path)) == nil {
            try files.createSymbolicLink(atPath: shortcut.path, withDestinationPath: launcherPath)
        }
        if executableOnPath("agent-desktop") == nil {
            stderr("To use the Terminal shortcut, add this line to your shell configuration:")
            stderr("export PATH=\"$HOME/.local/bin:$PATH\"")
        }
    }

    private func executableOnPath(_ name: String) -> String? {
        (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
            .first(where: files.isExecutableFile(atPath:))
    }

    private func requireSuccess(_ path: String, _ args: [String]) throws {
        guard try run(path, args).status == 0 else {
            throw Failure("\(URL(fileURLWithPath: path).lastPathComponent) failed. Fix the error above and rerun setup.")
        }
    }

    private func run(_ path: String, _ args: [String], capture: Bool = false) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = capture ? Pipe() : nil
        if let pipe {
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let output = pipe.map { String(decoding: $0.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) } ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
