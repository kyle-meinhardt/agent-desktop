import Foundation
import Network

@MainActor
func watchDesktop(_ connection: any SessionConnection) async throws {
    let clock = ContinuousClock()
    var startupDeadline: ContinuousClock.Instant?
    let server = try DesktopWatchServer()
    defer { server.stop() }

    // Reuse the push framebuffer. A full screenshot request every frame
    // would compete with the agent's connection and macOS Screen Sharing.
    var sequence: UInt64 = 0
    while !Task.isCancelled {
        let response = try await connection.call(Request(action: "watch-frame", arguments: ["since": String(sequence)], timeout: 5))
        if startupDeadline == nil { startupDeadline = clock.now + .seconds(15) }
        if let image = response.jpeg, let value = response.values["sequence"].flatMap(UInt64.init) {
            server.frame = (value, image)
            if sequence == 0 {
                let url = try await server.start()
                FileHandle.standardOutput.write(Data((
                    "Watch the read-only desktop at \(url.absoluteString)\n" +
                    "Open the link in your browser. Press Ctrl+C here to stop.\n"
                ).utf8))
            }
            sequence = value
        }
        if sequence == 0, let startupDeadline, clock.now >= startupDeadline {
            throw Failure("Timed out waiting for a complete Screen Sharing frame. Retry after the agent desktop has started.")
        }
        try await Task.sleep(for: .milliseconds(200))
    }
}

@MainActor
final class DesktopWatchServer {
    var frame: (sequence: UInt64, jpeg: Data)?
    private let token = UUID().uuidString.lowercased()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agent-desktop.viewer.http")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            Self.receiveHeaders(connection) { headers in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.respond(to: headers, on: connection)
                }
            }
        }
        let states = AsyncStream<NWListener.State> { stream in
            listener.stateUpdateHandler = { stream.yield($0) }
        }
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                guard let port = listener.port,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/") else {
                    throw Failure("Browser viewer has no listening URL")
                }
                return url
            case .waiting(let error), .failed(let error): throw error
            case .cancelled: throw CancellationError()
            default: continue
            }
        }
        throw CancellationError()
    }

    func stop() { listener.cancel() }

    private nonisolated static func receiveHeaders(
        _ connection: NWConnection, buffered: Data = Data(), completion: @escaping (String) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - buffered.count) { chunk, _, finished, error in
            let data = buffered + (chunk ?? Data())
            if let end = data.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: data[..<end.lowerBound], encoding: .utf8) {
                completion(headers)
            } else if error == nil, !finished, data.count < 8192 {
                receiveHeaders(connection, buffered: data, completion: completion)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to headers: String, on connection: NWConnection) {
        let lines = headers.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let host = hosts.count == 1 ? hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) : ""
        var status = "404 Not Found"
        var body = Data()
        var type = "text/plain"
        var extra = ""
        if let port = listener.port, host == "127.0.0.1:\(port.rawValue)",
           request.count == 3, request[0] == "GET" {
            let path = "/\(token)/"
            let framePath = path + "frame?since="
            if request[1] == path {
                status = "200 OK"
                type = "text/html; charset=utf-8"
                body = Data(Self.page.utf8)
            } else if request[1].hasPrefix(framePath),
                      let since = UInt64(request[1].dropFirst(framePath.count)), let frame {
                if since == frame.sequence {
                    status = "204 No Content"
                } else {
                    status = "200 OK"
                    type = "image/jpeg"
                    extra = "X-Frame-Sequence: \(frame.sequence)\r\n"
                    body = frame.jpeg
                }
            }
        }
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(type)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Cross-Origin-Resource-Policy: same-origin",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob:; connect-src 'self'; frame-ancestors 'none'"
        ].joined(separator: "\r\n") + "\r\n" + extra + "\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            guard !body.isEmpty, error == nil else { connection.cancel(); return }
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
        })
    }

    private static let page = """
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Agent Desktop</title>
    <style>
      html { color-scheme: dark; }
      body { margin: 0; height: 100dvh; display: flex; flex-direction: column;
             background: #111; color: #eee; font: 14px system-ui, sans-serif; }
      header { display: flex; flex-wrap: wrap; gap: .75rem; align-items: baseline;
               padding: .75rem 1rem; background: #222; }
      #status { color: #ccc; }
      main { flex: 1; min-height: 0; padding: .5rem; }
      img { display: block; width: 100%; height: 100%; object-fit: contain; }
      img:not([src]) { visibility: hidden; }
    </style>
    <header><strong>Agent Desktop</strong><span id="status" role="status">Connecting…</span></header>
    <main><img id="desktop" alt="Live view of the separate agent desktop"></main>
    <script>
      const desktop = document.getElementById('desktop');
      const status = document.getElementById('status');
      let sequence = '0';
      let imageURL;
      async function update() {
        let delay = 200;
        try {
          const response = await fetch('frame?since=' + sequence, {
            cache: 'no-store', signal: AbortSignal.timeout(5000)
          });
          if (response.status === 200) {
            const next = URL.createObjectURL(await response.blob());
            desktop.src = next;
            if (imageURL) URL.revokeObjectURL(imageURL);
            imageURL = next;
            sequence = response.headers.get('X-Frame-Sequence');
          } else if (response.status !== 204) {
            throw new Error('Viewer disconnected');
          }
          if (status.textContent !== 'Live · Read only') status.textContent = 'Live · Read only';
        } catch {
          if (status.textContent !== 'Disconnected · Last frame shown') {
            status.textContent = imageURL ? 'Disconnected · Last frame shown' : 'Disconnected';
          }
          delay = 1000;
        }
        setTimeout(update, delay);
      }
      update();
    </script>
    </html>
    """
}
