import Foundation
import Network
import UIKit

final class BatSignLoopbackIPAInstallServer {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.ikiraplus.turath.batsign-server", qos: .userInitiated)
    private var listener: NWListener?
    private var stopped = false
    private var reportedStart = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var onTransferStarted: (() -> Void)?
    private var onTransferComplete: (() -> Void)?
    private var onFailure: ((Error) -> Void)?

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard let loopback = IPv4Address("127.0.0.1") else {
            throw NSError(domain: "Turath.BatSignServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "تعذر إنشاء عنوان localhost."])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: 9800)
        listener = try NWListener(using: parameters)
    }

    deinit {
        endInstallKeepAlive()
    }

    func start(
        onReady: @escaping () -> Void,
        onTransferStarted: @escaping () -> Void,
        onTransferComplete: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        guard let listener else {
            onFailure(NSError(domain: "Turath.BatSignServer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "خادم التثبيت المحلي غير متوفر."]))
            return
        }
        self.onTransferStarted = onTransferStarted
        self.onTransferComplete = onTransferComplete
        self.onFailure = onFailure

        beginInstallKeepAlive()

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async(execute: onReady)
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
        endInstallKeepAlive()
    }

    private func beginInstallKeepAlive() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundTask == .invalid, !self.stopped else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "TurathInstallTransfer"
            ) { [weak self] in
                guard let self else { return }
                let error = NSError(
                    domain: "Turath.BatSignServer",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey:
                        "انتهى وقت التشغيل بالخلفية قبل أن يكمل iOS استلام التطبيق. الملف محفوظ ويمكن إعادة المحاولة."]
                )
                self.endInstallKeepAlive()
                self.reportFailure(error)
            }
        }
    }

    private func endInstallKeepAlive() {
        let finish = { [weak self] in
            guard let self, self.backgroundTask != .invalid else { return }
            let task = self.backgroundTask
            self.backgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(task)
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
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
        case "/install":
            serveInstallPage(connection, method: method, components: components)
        case "/health":
            sendText(connection, status: "200 OK", body: "OK")
        case "/app.ipa":
            serveIPA(connection, method: method, request: request)
        default:
            sendText(connection, status: "404 Not Found", body: "Not Found")
        }
    }

    private func serveInstallPage(_ connection: NWConnection, method: String, components: URLComponents) {
        guard let raw = components.queryItems?.first(where: { $0.name == "target" })?.value,
              let target = decodeURLSafeBase64(raw),
              target.hasPrefix("itms-services://") else {
            sendText(connection, status: "400 Bad Request", body: "Missing install target")
            return
        }

        // <script> is a raw-text HTML element. HTML-escaping '&' to '&amp;' here
        // corrupts the itms-services query instead of protecting it. Escape the
        // JavaScript string and the fallback anchor independently.
        let jsTarget = target
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "</", with: "<\\/")
        let anchorTarget = target
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Install</title></head><body style="background:#000;color:#fff">
        <script>window.location.href="\(jsTarget)";</script>
        <a href="\(anchorTarget)">Install</a></body></html>
        """
        let body = Data(html.utf8)
        sendData(connection, status: "200 OK", type: "text/html; charset=utf-8",
                 data: method == "HEAD" ? Data() : body,
                 declaredLength: body.count)
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

        if method == "GET", !reportedStart {
            reportedStart = true
            DispatchQueue.main.async { [weak self] in self?.onTransferStarted?() }
        }

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { connection.cancel(); return }
            guard error == nil else { connection.cancel(); return }
            if method == "HEAD" { connection.cancel(); return }
            self.stream(connection, offset: UInt64(start), remaining: length,
                        reportComplete: start == 0 && end == size - 1)
        })
    }

    private func stream(_ connection: NWConnection, offset: UInt64, remaining: Int64, reportComplete: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            reportFailure(NSError(domain: "Turath.BatSignServer", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة IPA الموقّع."]))
            connection.cancel()
            return
        }
        handle.seek(toFileOffset: offset)
        var left = remaining
        func pump() {
            guard left > 0 else {
                try? handle.close()
                connection.cancel()
                if reportComplete {
                    DispatchQueue.main.async { [weak self] in self?.onTransferComplete?() }
                }
                return
            }
            let count = Int(min(left, 1024 * 1024))
            let data = handle.readData(ofLength: count)
            guard !data.isEmpty else {
                try? handle.close(); connection.cancel(); return
            }
            left -= Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close(); connection.cancel()
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
              let equals = line.firstIndex(of: "=") else { return nil }
        let token = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
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
        if right.isEmpty { end = size - 1 }
        else {
            guard let requested = Int64(right), requested >= start else { return nil }
            end = min(requested, size - 1)
        }
        return (start, end)
    }

    private func decodeURLSafeBase64(_ value: String) -> String? {
        var padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fileSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sendText(_ connection: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        sendData(connection, status: status, type: "text/plain; charset=utf-8", data: data, declaredLength: data.count)
    }

    private func sendData(_ connection: NWConnection, status: String, type: String, data: Data, declaredLength: Int) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(declaredLength)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func reportFailure(_ error: Error) {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}
