import Foundation
import SwiftUI

struct TransferInstallSnapshot: Identifiable {
    let app: StoreApp
    let state: StoreInstallState
    var id: String { app.id }
}

struct DirectTransferOperation: Identifiable {
    let id: String
    let app: StoreApp
    var progress: Double
    var statusText: String
    var writtenBytes: Int64
    var expectedBytes: Int64
    var failed: Bool
    var errorText: String?
}

private struct PersistedDirectTransfer: Codable {
    let id: String
    let app: StoreApp
    let sourceURL: String
    let createdAt: Date
}

private struct DirectLibraryRecordCompat: Codable {
    let id: String
    let appID: String
    let name: String
    let version: String
    let iconURL: String?
    let fileName: String
    let fileType: String
    let createdAt: Date
}

final class TransferActivityCenter: NSObject, ObservableObject {
    static let shared = TransferActivityCenter()
    static let backgroundSessionIdentifier = "com.ikiraplus.turathreplica.direct-downloads.v1"

    @Published private(set) var trackedApps: [String: StoreApp] = [:]
    @Published private(set) var directOperations: [String: DirectTransferOperation] = [:]

    var backgroundSessionCompletion: (() -> Void)?

    private let fm = FileManager.default
    private let lock = NSLock()
    private var directRecords: [String: PersistedDirectTransfer] = [:]
    private var bootstrapped = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        restoreTrackedApps()
        restoreDirectRecords()
    }

    func bootstrap() {
        lock.lock()
        let shouldStart = !bootstrapped
        bootstrapped = true
        lock.unlock()
        guard shouldStart else { return }

        _ = session
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let activeIDs = Set(tasks.compactMap(\.taskDescription))
            let records = self.snapshotDirectRecords()

            DispatchQueue.main.async {
                for (id, record) in records where activeIDs.contains(id) {
                    self.directOperations[id] = DirectTransferOperation(
                        id: id,
                        app: record.app,
                        progress: 0,
                        statusText: "جاري استكمال التحميل",
                        writtenBytes: 0,
                        expectedBytes: record.app.fileSize ?? 0,
                        failed: false,
                        errorText: nil
                    )
                }
            }

            for (id, _) in records where !activeIDs.contains(id) {
                self.removeDirectRecord(id)
            }
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundSessionCompletion = completionHandler
        _ = session
    }

    func track(_ app: StoreApp) {
        DispatchQueue.main.async {
            // Downloads-library rows can represent a saved IPA without
            // carrying its original icon URL. Never overwrite previously
            // persisted artwork with nil when that row is installed again.
            var stored = app
            if stored.iconUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let previous = self.trackedApps[app.id],
               let icon = previous.iconUrl, !icon.isEmpty {
                stored.iconUrl = icon
            }
            self.trackedApps[app.id] = stored
            self.persistTrackedApps()
        }
    }

    func trackedApp(id: String?) -> StoreApp? {
        guard let id else { return nil }
        return trackedApps[id]
    }

    func activeInstallOperations(using installer: StoreInstallCoordinator) -> [TransferInstallSnapshot] {
        trackedApps.values.compactMap { app in
            let state = installer.state(for: app)
            guard [.downloading, .signing, .installing].contains(state.phase) else { return nil }
            return TransferInstallSnapshot(app: app, state: state)
        }
        .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    var activeDirectOperations: [DirectTransferOperation] {
        directOperations.values
            .filter { !$0.failed && $0.progress < 1 }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    func activeCount(using installer: StoreInstallCoordinator, detail: DetailPreparationCenter) -> Int {
        activeInstallOperations(using: installer).count
            + activeDirectOperations.count
            + (detail.busy ? 1 : 0)
    }

    func directOperation(for app: StoreApp) -> DirectTransferOperation? {
        directOperations.values.first {
            $0.app.id == app.id && ($0.app.version ?? "") == (app.version ?? "")
        }
    }

    func startDirectDownload(_ app: StoreApp) {
        track(app)

        if directOperation(for: app) != nil { return }

        Task {
            if await DirectDownloadLibrary.shared.contains(appID: app.id, version: app.version) {
                return
            }

            guard let raw = app.effectiveDownloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                await MainActor.run {
                    let id = UUID().uuidString
                    self.directOperations[id] = DirectTransferOperation(
                        id: id,
                        app: app,
                        progress: 0,
                        statusText: "رابط التحميل غير صالح",
                        writtenBytes: 0,
                        expectedBytes: app.fileSize ?? 0,
                        failed: true,
                        errorText: "رابط التحميل غير صالح"
                    )
                }
                return
            }

            await MainActor.run {
                if self.directOperation(for: app) != nil { return }

                let id = UUID().uuidString.lowercased()
                let record = PersistedDirectTransfer(id: id, app: app, sourceURL: raw, createdAt: Date())
                self.setDirectRecord(record)
                self.directOperations[id] = DirectTransferOperation(
                    id: id,
                    app: app,
                    progress: 0,
                    statusText: "جاري تحميل الديلب",
                    writtenBytes: 0,
                    expectedBytes: app.fileSize ?? 0,
                    failed: false,
                    errorText: nil
                )

                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 60
                request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")
                let task = self.session.downloadTask(with: request)
                task.taskDescription = id
                task.resume()
            }
        }
    }

    private var supportRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TransferActivity", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var trackedAppsFile: URL {
        supportRoot.appendingPathComponent("tracked-apps.json")
    }

    private var directRecordsFile: URL {
        supportRoot.appendingPathComponent("direct-operations.json")
    }

    private func persistTrackedApps() {
        let apps = Array(trackedApps.values)
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: trackedAppsFile, options: .atomic)
    }

    private func restoreTrackedApps() {
        guard let data = try? Data(contentsOf: trackedAppsFile),
              let apps = try? JSONDecoder().decode([StoreApp].self, from: data) else { return }
        trackedApps = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
    }

    private func setDirectRecord(_ record: PersistedDirectTransfer) {
        lock.lock()
        directRecords[record.id] = record
        persistDirectRecordsLocked()
        lock.unlock()
    }

    private func removeDirectRecord(_ id: String) {
        lock.lock()
        directRecords[id] = nil
        persistDirectRecordsLocked()
        lock.unlock()
    }

    private func snapshotDirectRecords() -> [String: PersistedDirectTransfer] {
        lock.lock(); defer { lock.unlock() }
        return directRecords
    }

    private func persistDirectRecordsLocked() {
        guard let data = try? JSONEncoder().encode(directRecords) else { return }
        try? data.write(to: directRecordsFile, options: .atomic)
    }

    private func restoreDirectRecords() {
        guard let data = try? Data(contentsOf: directRecordsFile),
              let records = try? JSONDecoder().decode([String: PersistedDirectTransfer].self, from: data) else { return }
        directRecords = records
        for (id, record) in records {
            directOperations[id] = DirectTransferOperation(
                id: id,
                app: record.app,
                progress: 0,
                statusText: "جاري استكمال التحميل",
                writtenBytes: 0,
                expectedBytes: record.app.fileSize ?? 0,
                failed: false,
                errorText: nil
            )
        }
    }

    private func saveFinishedDirectDownload(
        location: URL,
        response: URLResponse?,
        record: PersistedDirectTransfer
    ) throws {
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw DirectDownloadError.invalidResponse
        }

        let extensionName = preferredExtension(response: response, sourceURL: URL(string: record.sourceURL))
        let suggested = response?.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSuggested = suggested.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            let ext = (value as NSString).pathExtension.lowercased()
            if ["dylib", "zip"].contains(ext) {
                return String(value.dropLast(ext.count + 1))
            }
            return value
        }
        let baseName = sanitizeFileName(baseSuggested ?? record.app.name)
        let fileName = "\(baseName).\(extensionName)"

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("DirectDownloads", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(record.id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: location, to: destination)

        let version = record.app.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = DirectLibraryRecordCompat(
            id: record.id,
            appID: record.app.id,
            name: record.app.name,
            version: (version?.isEmpty == false ? version! : "—"),
            iconURL: record.app.iconUrl,
            fileName: fileName,
            fileType: extensionName,
            createdAt: record.createdAt
        )
        let metadata = try JSONEncoder().encode(saved)
        try metadata.write(to: folder.appendingPathComponent("download-meta.json"), options: .atomic)

        guard AppVisibleFolders.mirrorFile(
            from: destination,
            to: AppVisibleFolders.dylib,
            fileName: fileName
        ) != nil else {
            throw DirectDownloadError.writeFailed
        }
    }

    private func preferredExtension(response: URLResponse?, sourceURL: URL?) -> String {
        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if ["dylib", "zip"].contains(ext) { return ext }
        }
        if let sourceURL {
            let ext = sourceURL.pathExtension.lowercased()
            if ["dylib", "zip"].contains(ext) { return ext }
        }
        if response?.mimeType?.lowercased().contains("zip") == true { return "zip" }
        return "dylib"
    }

    private func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    private func failDirect(id: String, text: String) {
        DispatchQueue.main.async {
            guard var operation = self.directOperations[id] else { return }
            operation.failed = true
            operation.statusText = "فشل التحميل"
            operation.errorText = text
            self.directOperations[id] = operation
            self.removeDirectRecord(id)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                self.directOperations[id] = nil
            }
        }
    }
}

extension TransferActivityCenter: URLSessionDownloadDelegate, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        DispatchQueue.main.async {
            guard var operation = self.directOperations[id] else { return }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : operation.expectedBytes
            operation.writtenBytes = totalBytesWritten
            operation.expectedBytes = expected
            operation.progress = expected > 0 ? min(0.99, Double(totalBytesWritten) / Double(expected)) : operation.progress
            operation.statusText = "جاري تحميل الديلب"
            self.directOperations[id] = operation
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let record = snapshotDirectRecords()[id] else { return }

        do {
            try saveFinishedDirectDownload(location: location, response: downloadTask.response, record: record)
            removeDirectRecord(id)
            DispatchQueue.main.async {
                guard var operation = self.directOperations[id] else { return }
                operation.progress = 1
                operation.statusText = "تم التحميل"
                operation.writtenBytes = max(operation.writtenBytes, operation.expectedBytes)
                self.directOperations[id] = operation
                NotificationCenter.default.post(name: DirectDownloadLibrary.changedNotification, object: nil)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.directOperations[id] = nil
                }
            }
        } catch {
            failDirect(id: id, text: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        failDirect(id: id, text: error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let completion = self.backgroundSessionCompletion
            self.backgroundSessionCompletion = nil
            completion?()
        }
    }
}
