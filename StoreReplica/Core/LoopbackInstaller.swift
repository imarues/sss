import Foundation
import Network

final class LoopbackIPAInstallServer {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.ikiraplus.turath.installserver", qos: .userInitiated)
    private var listener: NWListener?
    private var onFailure: ((Error) -> Void)?
    private var stopped = false

    init(fileURL: URL) throws {
        self.fileURL = fileURL

        guard let loopback = IPv4Address("127.0.0.1") else {
            throw NSError(
                domain: "TurathReplica.LoopbackInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر إنشاء عنوان التثبيت المحلي."]
            )
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: 9800)
        listener = try NWListener(using: params)
    }

    func start(
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        guard let listener else {
            onFailure(NSError(
                domain: "TurathReplica.LoopbackInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "خادم التثبيت المحلي غير متوفر."]
            ))
            return
        }

        self.onFailure = onFailure
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async(execute: onReady)
            case .failed(let error):
                self.report(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        listener = nil
        onFailure = nil
    }

    private func report(_ error: Error) {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, collected: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.report(error)
                connection.cancel()
                return
            }

            var buffer = collected
            if let data { buffer.append(data) }

            if buffer.count > 65_536 {
                self.sendText(connection, status: "431 Request Header Fields Too Large", body: "Header Too Large")
                return
            }

            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, request: text)
            } else if !isComplete {
                self.receiveHeaders(connection, collected: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendText(connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        guard method == "GET" || method == "HEAD" else {
            sendText(connection, status: "405 Method Not Allowed", body: "Method Not Allowed")
            return
        }
        guard path.hasPrefix("/app.ipa") else {
            sendText(connection, status: "404 Not Found", body: "Not Found")
            return
        }

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
        headers += "Cache-Control: no-store\r\n"
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
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.report(error)
                connection.cancel()
                return
            }
            if method == "HEAD" {
                connection.cancel()
                return
            }
            self.stream(connection, start: UInt64(start), length: length)
        })
    }

    private func stream(_ connection: NWConnection, start: UInt64, length: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            report(NSError(
                domain: "TurathReplica.LoopbackInstaller",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة ملف IPA الموقّع."]
            ))
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
                self.report(NSError(
                    domain: "TurathReplica.LoopbackInstaller",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "توقف إرسال ملف IPA قبل اكتماله."]
                ))
                connection.cancel()
                return
            }

            remaining -= Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    try? handle.close()
                    self.report(error)
                    connection.cancel()
                } else {
                    pump()
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
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var packet = response.data(using: .utf8) ?? Data()
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }
}
