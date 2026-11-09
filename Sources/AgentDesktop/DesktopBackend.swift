import Foundation

protocol SessionConnection: AnyObject {
    func call(_ request: Request) async throws -> VNCResponse
}
extension VNCConnection: SessionConnection {}

@MainActor
final class VNCDesktopBackend {
    private let connection: any SessionConnection
    private let profile: SessionProfile
    private let profiles: SessionProfiles
    private var images: [String: Data] = [:]

    convenience init(profile: SessionProfile, password: String, profiles: SessionProfiles = SessionProfiles(store: Store())) throws {
        try self.init(profile: profile, profiles: profiles,
                      connection: VNCConnection(host: profile.host, port: profile.port, username: profile.username, password: password,
                                                inputAuthorization: { try profiles.requireInputApproval(for: profile) }))
    }

    init(profile: SessionProfile, profiles: SessionProfiles, connection: any SessionConnection) {
        self.profile = profile; self.profiles = profiles; self.connection = connection
    }

    func call(_ request: Request) async throws -> Reply {
        guard request.deadline > Date() else { throw Failure("Session request expired") }
        let observing = ["status", "screenshot", "snapshot"].contains(request.action)
        // Re-read approval for every mutation: revocation also applies to existing MCP connections.
        let current = try profiles.load(profile.name)
        guard observing || (current.inputApproved && current.host == profile.host &&
                            current.port == profile.port && current.username == profile.username) else {
            throw Failure("Session input is disabled. Inspect `agent-desktop action \(profile.name) screenshot`, then run `agent-desktop approve \(profile.name)`.")
        }
        let response = try await connection.call(request)
        var values = response.values
        if let png = response.png {
            let name = "image-\(request.id.uuidString).png"
            // Single outstanding frame per consumer. Bound memory even if a client abandons a read.
            images.removeAll(keepingCapacity: true)
            images[name] = png
            values["image"] = name
        }
        if request.action == "status" {
            values["backend"] = "screen-sharing"
            values["username"] = profile.username
            values["inputApproved"] = String(current.inputApproved && current.host == profile.host && current.port == profile.port && current.username == profile.username)
        }
        return Reply(id: request.id, values: values)
    }
    func read(_ name: String, limit: Int) throws -> Data? {
        guard let data = images[name] else { return nil }
        guard data.count <= limit else { throw Failure("Session image exceeds size limit") }
        return data
    }
    func remove(_ name: String) { images.removeValue(forKey: name) }
}
