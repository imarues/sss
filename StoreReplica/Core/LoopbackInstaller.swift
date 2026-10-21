import Foundation
import Network

final class LoopbackIPAInstallServer {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.ikiraplus.turath.installserver", qos: .userInitiated)
    private var listener: NWListener?

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 9800)
        listener = try NWListener(using: params)
    }

    func start(onReady: @escaping () -> Void) {
        guard let listener else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                DispatchQueue.main.async(execute: onReady)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, collected: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = collected
            if let data { buffer.append(data) }

            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, request: text)
            } else if error == nil && !isComplete && buffer.count < 128 * 1024 {
                self.receiveHeaders(connection, collected: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, String(parts[1]).hasPrefix("/app.ipa") else {
            sendText(connection, status: "404 Not Found", body: "Not Found")
            return
        }

        let method = parts.first.map(String.init) ?? "GET"
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            sendText(connection, status: "404 Not Found", body: "Missing IPA")
            return
        }

        let range = parseRange(request, size: size)
        let start = range?.0 ?? 0
        let end = range?.1 ?? (size - 1)
        let length = max(0, end - start + 1)
        let partial = range != nil

        var headers = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        headers += "Content-Type: application/octet-stream\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Content-Length: \(length)\r\n"
        if partial {
            headers += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        headers += "Connection: close\r\n\r\n"

        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard error == nil, method != "HEAD", let self else {
                connection.cancel()
                return
            }
            self.stream(connection, start: UInt64(start), length: length)
        })
    }

    private func stream(_ connection: NWConnection, start: UInt64, length: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            connection.cancel()
            return
        }
        handle.seek(toFileOffset: start)
        var remaining = length

        func pump() {
            guard remaining > 0 else {
                try? handle.close()
                connection.cancel()
                return
            }
            let amount = Int(min(Int64(512 * 1024), remaining))
            let data = handle.readData(ofLength: amount)
            guard !data.isEmpty else {
                try? handle.close()
                connection.cancel()
                return
            }
            remaining -= Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil {
                    pump()
                } else {
                    try? handle.close()
                    connection.cancel()
                }
            })
        }
        pump()
    }

    private func parseRange(_ request: String, size: Int64) -> (Int64, Int64)? {
        guard let line = request.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
              let token = line.split(separator: "=", maxSplits: 1).last else { return nil }

        let bounds = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = bounds.first, let start = Int64(first) else { return nil }
        let requestedEnd = bounds.count > 1 ? Int64(bounds[1]) : nil
        let end = min(requestedEnd ?? (size - 1), size - 1)
        guard start >= 0, start <= end else { return nil }
        return (start, end)
    }

    private func sendText(_ connection: NWConnection, status: String, body: String) {
        let data = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var packet = response.data(using: .utf8) ?? Data()
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }
}
