import Foundation
import Network

final class LoopbackIPAInstallServer {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.ikiraplus.turath.installserver", qos: .userInitiated)
    private var listener: NWListener?
    private var onFailure: ((Error) -> Void)?
    private var onTransferStarted: (() -> Void)?
    private var onTransferComplete: (() -> Void)?
    private var stopped = false
    private var didReportTransferStart = false

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
        onTransferStarted: @escaping () -> Void,
        onTransferComplete: @escaping () -> Void,
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
        self.onTransferStarted = onTransferStarted
        self.onTransferComplete = onTransferComplete

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async(execute: onReady)
            case .failed(let error):
                self.reportFatal(error)
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
        onTransferStarted = nil
        onTransferComplete = nil
    }

    private func reportFatal(_ error: Error) {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
    }

    private func reportTransferStarted() {
        guard !stopped, !didReportTransferStart else { return }
        didReportTransferStart = true
        DispatchQueue.main.async { [weak self] in
            self?.onTransferStarted?()
        }
    }

    private func reportTransferComplete() {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onTransferComplete?()
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

            // Client-side cancellation is normal for HEAD probes and range retries.
            // It must not be promoted to a global installation failure.
            if error != nil {
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
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        guard method == "GET" || method == "HEAD" else {
            sendText(connection, status: "405 Method Not Allowed", body: "Method Not Allowed")
            return
        }
        guard path == "/app.ipa" || path.hasPrefix("/app.ipa/") else {
            sendText(connection, status: "404 Not Found", body: "Not Found")
            return
        }

        let size = fileSize()
        guard size > 0 else {
            sendText(connection, status: "404 Not Found", body: "Missing IPA")
            return
        }

        let hasRangeHeader = request.components(separatedBy: "\r\n")
            .contains(where: { $0.lowercased().hasPrefix("range:") })
        let range = parseRange(request, size: size)

        if hasRangeHeader && range == nil {
            sendRangeNotSatisfiable(connection, size: size)
            return
        }

        let start = range?.0 ?? 0
        let end = range?.1 ?? (size - 1)
        let length = max(0, end - start + 1)
        let partial = range != nil
        let wholeFile = start == 0 && end == size - 1

        var headers = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        headers += "Content-Type: application/octet-stream\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Cache-Control: no-store\r\n"
        headers += "Content-Length: \(length)\r\n"
        headers += "Content-Disposition: attachment; filename=\"app.ipa\"\r\n"
        if partial {
            headers += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        headers += "Connection: close\r\n\r\n"

        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }

        if method == "GET" {
            reportTransferStarted()
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }
            if method == "HEAD" {
                connection.cancel()
                return
            }
            self.stream(connection, start: UInt64(start), length: length, wholeFile: wholeFile)
        })
    }

    private func stream(_ connection: NWConnection, start: UInt64, length: Int64, wholeFile: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            reportFatal(NSError(
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
                if wholeFile {
                    self.reportTransferComplete()
                }
                return
            }

            let amount = Int(min(Int64(1024 * 1024), remaining))
            let data = handle.readData(ofLength: amount)
            guard !data.isEmpty else {
                try? handle.close()
                self.reportFatal(NSError(
                    domain: "TurathReplica.LoopbackInstaller",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "توقف إرسال ملف IPA قبل اكتماله."]
                ))
                connection.cancel()
                return
            }

            remaining -= Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    // iOS can deliberately close one range request and retry another.
                    // The next request is authoritative; do not fail the whole install.
                    try? handle.close()
                    connection.cancel()
                } else {
                    pump()
                }
            })
        }
        pump()
    }

    private func fileSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func parseRange(_ request: String, size: Int64) -> (Int64, Int64)? {
        guard size > 0,
              let line = request.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") }),
              let equals = line.firstIndex(of: "=") else {
            return nil
        }

        let token = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.contains(",") else { return nil }

        let bounds = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        let left = String(bounds[0]).trimmingCharacters(in: .whitespaces)
        let right = String(bounds[1]).trimmingCharacters(in: .whitespaces)

        if left.isEmpty {
            guard let suffix = Int64(right), suffix > 0 else { return nil }
            let count = min(suffix, size)
            return (size - count, size - 1)
        }

        guard let start = Int64(left), start >= 0, start < size else { return nil }
        let end: Int64
        if right.isEmpty {
            end = size - 1
        } else {
            guard let requestedEnd = Int64(right), requestedEnd >= start else { return nil }
            end = min(requestedEnd, size - 1)
        }
        return (start, end)
    }

    private func sendRangeNotSatisfiable(_ connection: NWConnection, size: Int64) {
        let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendText(_ connection: NWConnection, status: String, body: String) {
        let data = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var packet = response.data(using: .utf8) ?? Data()
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
