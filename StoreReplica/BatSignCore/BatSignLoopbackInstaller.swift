import Foundation
import Network

/// Local GBox-compatible payload server. The listener stays alive in the
/// background until MobileInstallation has actually fetched every byte.
final class BatSignLoopbackIPAInstallServer {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.ikiraplus.turath.batsign-server", qos: .userInitiated)
    private let keepAliveReason = "installer-\(UUID().uuidString)"

    private var listener: NWListener?
    private var stopped = false
    private var reportedStart = false
    private var reportedComplete = false
    private var deliveredRanges: [(Int64, Int64)] = []

    private var onTransferStarted: (() -> Void)?
    private var onTransferComplete: (() -> Void)?
    private var onFailure: ((Error) -> Void)?

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard let loopback = IPv4Address("127.0.0.1") else {
            throw NSError(
                domain: "Turath.BatSignServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر إنشاء عنوان localhost."]
            )
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: 9800)
        listener = try NWListener(using: parameters)
    }

    deinit {
        StoreInstallKeepAlive.shared.end(keepAliveReason)
    }

    func start(
        onReady: @escaping () -> Void,
        onTransferStarted: @escaping () -> Void,
        onTransferComplete: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        guard let listener else {
            onFailure(NSError(
                domain: "Turath.BatSignServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "خادم التثبيت المحلي غير متوفر."]
            ))
            return
        }

        self.onTransferStarted = onTransferStarted
        self.onTransferComplete = onTransferComplete
        self.onFailure = onFailure

        // BatSign keeps the process scheduled for the complete hand-off. A
        // short UIBackgroundTask alone expires while installd is still deciding
        // when to fetch localhost.
        StoreInstallKeepAlive.shared.begin(keepAliveReason)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // The listener is genuinely accepting 127.0.0.1:9800 now.
                // Mark the hand-off active before opening itms-services so the
                // legacy 60-second watchdog cannot cancel a valid delayed
                // MobileInstallation fetch. Completion is still reported only
                // after the entire IPA has been delivered.
                let shouldReportStart = !self.reportedStart
                self.reportedStart = true
                DispatchQueue.main.async {
                    onReady()
                    if shouldReportStart { onTransferStarted() }
                }
            case .failed(let error):
                self.reportFailure(error)
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
        deliveredRanges.removeAll()
        StoreInstallKeepAlive.shared.end(keepAliveReason)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { connection.cancel(); return }

            var combined = buffer
            if let data { combined.append(data) }
            if combined.count > 65_536 {
                self.sendText(connection, status: "431 Request Header Fields Too Large", body: "Header Too Large")
                return
            }
            if let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, request: text)
            } else if !complete {
                self.receive(connection, buffer: combined)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            sendText(connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard method == "GET" || method == "HEAD" else {
            sendText(connection, status: "405 Method Not Allowed", body: "Method Not Allowed")
            return
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            sendText(connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        switch components.path {
        case "/health":
            sendText(connection, status: "200 OK", body: "OK")
        case "/app.ipa":
            serveIPA(connection, method: method, request: request)
        default:
            sendText(connection, status: "404 Not Found", body: "Not Found")
        }
    }

    private func serveIPA(_ connection: NWConnection, method: String, request: String) {
        let size = fileSize()
        guard size > 0 else {
            sendText(connection, status: "404 Not Found", body: "Missing IPA")
            return
        }

        let hasRange = request.components(separatedBy: "\r\n")
            .contains { $0.lowercased().hasPrefix("range:") }
        let range = parseRange(request, size: size)
        if hasRange && range == nil {
            let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        let start = range?.0 ?? 0
        let end = range?.1 ?? (size - 1)
        let length = end - start + 1
        let partial = range != nil

        var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Content-Disposition: attachment; filename=\"app.ipa\"\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header += "Connection: close\r\n\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { connection.cancel(); return }
            guard error == nil else { connection.cancel(); return }
            if method == "HEAD" { connection.cancel(); return }
            self.stream(connection, start: start, end: end, totalSize: size)
        })
    }

    private func stream(_ connection: NWConnection, start: Int64, end: Int64, totalSize: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            reportFailure(NSError(
                domain: "Turath.BatSignServer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة IPA الموقّع."]
            ))
            connection.cancel()
            return
        }
        handle.seek(toFileOffset: UInt64(start))
        var left = end - start + 1

        func pump() {
            guard left > 0 else {
                try? handle.close()
                connection.cancel()
                self.recordDeliveredRange(start: start, end: end, totalSize: totalSize)
                return
            }
            let count = Int(min(left, 512 * 1024))
            let data = handle.readData(ofLength: count)
            guard !data.isEmpty else {
                try? handle.close()
                connection.cancel()
                return
            }
            left -= Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close()
                    connection.cancel()
                } else {
                    pump()
                }
            })
        }
        pump()
    }

    /// MobileInstallation can fetch the file in one request or several byte
    /// ranges. Only declare success when completed ranges cover the entire IPA.
    private func recordDeliveredRange(start: Int64, end: Int64, totalSize: Int64) {
        guard !reportedComplete, start >= 0, end >= start, totalSize > 0 else { return }
        deliveredRanges.append((start, end))
        deliveredRanges.sort { $0.0 < $1.0 }

        var merged: [(Int64, Int64)] = []
        for range in deliveredRanges {
            if let last = merged.last, range.0 <= last.1 + 1 {
                merged[merged.count - 1] = (last.0, max(last.1, range.1))
            } else {
                merged.append(range)
            }
        }
        deliveredRanges = merged

        guard merged.count == 1,
              let only = merged.first,
              only.0 == 0,
              only.1 >= totalSize - 1 else { return }

        reportedComplete = true
        DispatchQueue.main.async { [weak self] in
            self?.onTransferComplete?()
        }
    }

    private func parseRange(_ request: String, size: Int64) -> (Int64, Int64)? {
        guard let line = request.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
              let equals = line.firstIndex(of: "=") else { return nil }

        let token = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.contains(",") else { return nil }
        let pieces = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }

        let left = String(pieces[0]).trimmingCharacters(in: .whitespaces)
        let right = String(pieces[1]).trimmingCharacters(in: .whitespaces)

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
            guard let requested = Int64(right), requested >= start else { return nil }
            end = min(requested, size - 1)
        }
        return (start, end)
    }

    private func fileSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sendText(_ connection: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func reportFailure(_ error: Error) {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}
