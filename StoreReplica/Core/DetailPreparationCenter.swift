import Foundation
import SwiftUI
import UIKit
import Zip

// Persistent worker for duplicate / dylib operations launched from app details.
// The source IPA always goes through the same durable StoreDownloadStorage staging
// used by a normal install before any clone / injection work begins.
enum DetailPreparationKind: String, Codable {
    case duplicate
    case dylib
}

private struct DetailPreparationRecord: Codable {
    let id: String
    let kind: DetailPreparationKind
    let app: StoreApp
    let copyNumber: Int?
    let dylibPaths: [String]
}

final class DetailPreparationCenter: NSObject, ObservableObject {
    static let shared = DetailPreparationCenter()
    static let backgroundSessionIdentifier = "com.ikiraplus.turathreplica.detail-preparation.v1"
    static let completedNotification = Notification.Name("DetailPreparationCenterCompleted")

    @Published private(set) var activeAppID: String?
    @Published private(set) var activeKind: DetailPreparationKind?
    @Published private(set) var busy = false
    @Published private(set) var isPaused = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var errorText: String?

    var backgroundSessionCompletion: (() -> Void)?

    private let fm = FileManager.default
    private let lock = NSLock()
    private var record: DetailPreparationRecord?
    private var preparingRecordID: String?
    private var downloadRecoveryAttempts: [String: Int] = [:]
    private var rescueTasks: [String: URLSessionDataTask] = [:]
    private var rescueFiles: [String: (URL, FileHandle, Int64, Int64)] = [:]

    private lazy var rescueSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // v2 record layout intentionally ignores the older active.json operation.
        // This prevents a stale pre-fix operation from being revived after update.
        try? fm.removeItem(at: operationRoot.appendingPathComponent("active.json"))
        restoreRecord()
    }

    var activeApp: StoreApp? {
        snapshotRecord()?.app
    }

    var activeTargetBundleID: String? {
        guard let current = snapshotRecord() else { return nil }
        let base = (current.app.bundleId?.isEmpty == false ? current.app.bundleId : nil) ?? current.app.id
        if current.kind == .duplicate, let number = current.copyNumber {
            return base + String(number)
        }
        return base
    }

    var activeVersion: String? {
        snapshotRecord()?.app.version
    }

    func bootstrap() {
        _ = session

        guard let current = snapshotRecord() else {
            // Do not asynchronously cancel all tasks here: that callback can
            // arrive after a new operation has started and kill its download.
            return
        }

        TransferActivityCenter.shared.track(current.app)
        DispatchQueue.main.async {
            self.activeAppID = current.app.id
            self.activeKind = current.kind
            self.busy = true
            self.isDownloading = true
            self.statusText = "جاري استكمال العملية"
        }
        InstallLiveActivityBridge.begin(job: liveJob(for: current))
        StoreInstallKeepAlive.shared.begin("detail-download-\(current.id)")

        session.getAllTasks { [weak self] tasks in
            guard let self, self.record(id: current.id) != nil else { return }
            if tasks.contains(where: { $0.taskDescription == current.id }) { return }
            self.lock.lock()
            let rescuing = self.rescueTasks[current.id] != nil
            self.lock.unlock()
            if rescuing { return }

            if let cached = self.recoverSourceIPA(for: current) {
                self.publishProgress(0.54, text: "التطبيق محمّل · جاري التجهيز", record: current)
                self.prepare(record: current, sourceIPA: cached)
                return
            }

            // The background task may have been evicted during relaunch.
            // Retry the network transfer instead of discarding the operation.
            self.retrySourceDownload(record: current, error: SideloadSigningError.downloadFailed)
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundSessionCompletion = completionHandler
        _ = session
    }

    func isActive(appID: String, kind: DetailPreparationKind) -> Bool {
        activeAppID == appID && activeKind == kind && busy
    }

    func togglePause() {
        guard isDownloading, let current = snapshotRecord() else { return }
        lock.lock()
        let streaming = rescueTasks[current.id]
        lock.unlock()
        if let streaming {
            if isPaused { streaming.resume() } else { streaming.suspend() }
            isPaused.toggle()
            statusText = isPaused ? "التحميل متوقف مؤقتاً" : "جاري استكمال التحميل"
            return
        }
        session.getAllTasks { [weak self] tasks in
            guard let self, let task = tasks.first(where: { $0.taskDescription == current.id }) else { return }
            DispatchQueue.main.async {
                if self.isPaused { task.resume() } else { task.suspend() }
                self.isPaused.toggle()
                self.statusText = self.isPaused ? "التحميل متوقف مؤقتاً" : "جاري استكمال التحميل"
            }
        }
    }

    func cancelActiveDownload() {
        guard isDownloading, let current = snapshotRecord() else { return }
        lock.lock()
        let streaming = rescueTasks.removeValue(forKey: current.id)
        let partial = rescueFiles.removeValue(forKey: current.id)
        lock.unlock()
        clearRecord()
        busy = false
        isDownloading = false
        isPaused = false
        statusText = ""
        progress = 0
        streaming?.cancel()
        try? partial?.1.close()
        if let partial { try? fm.removeItem(at: partial.0) }
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == current.id }.forEach { $0.cancel() }
        }
        StoreInstallKeepAlive.shared.end("detail-download-\(current.id)")
        InstallLiveActivityBridge.finish(job: liveJob(for: current), success: false, detail: "تم إلغاء التحميل")
        clearRecordFiles(current)
        finishBackgroundEventsIfPossible()
    }

    func beginDuplicate(app: StoreApp, number: Int) {
        guard (1...99).contains(number) else {
            publishError("رقم النسخة يجب أن يكون من 1 إلى 99.")
            return
        }
        start(app: app, kind: .duplicate, copyNumber: number, dylibs: [])
    }

    func beginDylib(app: StoreApp, dylibs: [URL]) {
        guard !dylibs.isEmpty else {
            publishError("اختر ملف Dylib واحدًا على الأقل.")
            return
        }
        start(app: app, kind: .dylib, copyNumber: nil, dylibs: dylibs)
    }

    private func start(app: StoreApp, kind: DetailPreparationKind, copyNumber: Int?, dylibs: [URL]) {
        guard !busy else { return }

        // Source download and preparation must not depend on certificate setup.
        // Signing is requested only after the resulting IPA is safely staged.
        do {
            let id = UUID().uuidString
            let storedDylibs = try persistDylibs(dylibs, operationID: id)
            let next = DetailPreparationRecord(
                id: id,
                kind: kind,
                app: app,
                copyNumber: copyNumber,
                dylibPaths: storedDylibs.map(\.path)
            )
            setRecord(next)
            TransferActivityCenter.shared.track(app)

            DispatchQueue.main.async {
                self.activeAppID = app.id
                self.activeKind = kind
                self.busy = true
                self.isDownloading = true
                self.isPaused = false
                self.progress = 0
                self.statusText = "جاري تحميل التطبيق الأصلي"
                self.errorText = nil
            }

            StoreDownloadStorage.registerVisibleCategory(for: app)
            InstallLiveActivityBridge.begin(job: liveJob(for: next))

            // Exact normal-install behavior: first reuse the durable staged IPA if
            // already available. Only after a valid source exists do we clone/inject.
            if let cached = recoverSourceIPA(for: next) {
                preserveOriginalForDownloads(cached, record: next)
                publishProgress(0.54, text: "التطبيق محمّل · جاري التجهيز", record: next)
                prepare(record: next, sourceIPA: cached)
                return
            }

            try startDownload(record: next)
        } catch {
            let fallback = snapshotRecord() ?? DetailPreparationRecord(
                id: UUID().uuidString,
                kind: kind,
                app: app,
                copyNumber: copyNumber,
                dylibPaths: []
            )
            fail(record: fallback, error: error)
        }
    }

    // Each clone/injection job owns an immutable copy of its original IPA.
    // Store installs and other jobs may replace the shared download cache,
    // but they must never mutate the file currently being unpacked here.
    private func sourceSnapshotURL(for record: DetailPreparationRecord) -> URL {
        operationRoot
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent("Original.ipa")
    }

    private func captureSourceIPA(from source: URL, record: DetailPreparationRecord) throws -> URL {
        let destination = sourceSnapshotURL(for: record)
        if StoreDownloadStorage.isValidIPA(at: destination) {
            return destination
        }
        guard fm.fileExists(atPath: source.path) else {
            throw StoreDownloadStorageError.sourceMissing
        }
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let incoming = directory.appendingPathComponent("Original.incoming-" + UUID().uuidString + ".ipa")
        defer { try? fm.removeItem(at: incoming) }
        // Do not move/link URLSession's temp file: copy its bytes synchronously
        // while the download completion callback still owns the file.
        try fm.copyItem(at: source, to: incoming)
        try StoreDownloadStorage.validateIPA(at: incoming)

        // Reject obvious interrupted/truncated responses before the original
        // is handed to either clone or dylib preparation.
        let actual = (try fm.attributesOfItem(atPath: incoming.path)[.size] as? NSNumber)?.int64Value ?? 0
        let expected = record.app.fileSize ?? 0
        if expected >= 5 * 1024 * 1024 && actual < expected / 2 {
            throw StoreDownloadStorageError.truncatedFile
        }

        if fm.fileExists(atPath: destination.path) {
            // The old snapshot was invalid; replacement bytes are now complete.
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: incoming, to: destination)
        try StoreDownloadStorage.validateIPA(at: destination)
        return destination
    }

    private func preserveOriginalForDownloads(_ snapshot: URL, record: DetailPreparationRecord) {
        let job = sourceJob(for: record)
        // Shared store cache and user-visible Downloads are separate copies.
        // Failure exporting them must not destroy the immutable working IPA.
        if let staged = try? StoreDownloadStorage.stageFinishedDownload(from: snapshot, job: job) {
            _ = StoreDownloadStorage.exportToFiles(stagedURL: staged, job: job)
        }
    }

    private func recoverSourceIPA(for record: DetailPreparationRecord) -> URL? {
        let snapshot = sourceSnapshotURL(for: record)
        if StoreDownloadStorage.isValidIPA(at: snapshot) { return snapshot }

        let job = sourceJob(for: record)
        let shared: URL?
        if StoreDownloadStorage.hasValidStagedIPA(for: job) {
            shared = try? StoreDownloadStorage.stagedURL(for: job)
        } else {
            shared = StoreDownloadStorage.recoverLegacyExportIfPossible(job: job)
        }
        guard let source = shared else { return nil }
        return try? captureSourceIPA(from: source, record: record)
    }

    private func retrySourceDownload(record: DetailPreparationRecord, error: Error) {
        guard self.record(id: record.id) != nil else { return }
        if let cached = recoverSourceIPA(for: record) {
            prepare(record: record, sourceIPA: cached)
            return
        }

        lock.lock()
        // The old background delivery may finish with TWO callbacks. Once a
        // streaming task owns this job, never let a stale callback abort it.
        if rescueTasks[record.id] != nil {
            lock.unlock()
            return
        }
        let attempts = downloadRecoveryAttempts[record.id] ?? 0
        downloadRecoveryAttempts[record.id] = attempts + 1
        lock.unlock()

        guard attempts == 0 else {
            fail(record: record, error: error)
            return
        }
        publishProgress(0.02, text: "جاري استئناف تحميل IPA", record: record)
        do {
            try startDownload(record: record)
        } catch {
            fail(record: record, error: error)
        }
    }

    private func startDownload(record: DetailPreparationRecord) throws {
        // Unlike a URLSessionDownloadTask, the bytes from URLSessionDataTask
        // are immediately written to our own Application Support file. There
        // is no CFNetwork temp URL to vanish at the download hand-off.
        guard let raw = record.app.effectiveDownloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SideloadSigningError.invalidURL
        }
        let partial = sourceSnapshotURL(for: record)
            .appendingPathExtension("downloading")
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw StoreDownloadStorageError.cannotStage
        }
        do {
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: partial.path
            )
            let handle = try FileHandle(forWritingTo: partial)
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 120
            request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")
            let task = rescueSession.dataTask(with: request)
            lock.lock()
            rescueTasks[record.id] = task
            rescueFiles[record.id] = (partial, handle, 0, 0)
            lock.unlock()
            StoreInstallKeepAlive.shared.begin("detail-download-\(record.id)")
            task.taskDescription = record.id
            task.resume()
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private func prepare(record: DetailPreparationRecord, sourceIPA: URL) {
        DispatchQueue.main.async {
            self.isDownloading = false
            self.isPaused = false
        }
        lock.lock()
        if preparingRecordID == record.id {
            lock.unlock()
            return
        }
        preparingRecordID = record.id
        lock.unlock()

        guard StoreDownloadStorage.isValidIPA(at: sourceIPA) else {
            fail(record: record, error: StoreDownloadStorageError.invalidIPA)
            return
        }

        let hold = "detail-preparation-\(record.id)"
        StoreInstallKeepAlive.shared.begin(hold)
        StoreInstallKeepAlive.shared.end("detail-download-\(record.id)")
        publishProgress(
            0.56,
            text: record.kind == .duplicate ? "اكتمل التحميل · جاري تعديل الباندل" : "اكتمل التحميل · جاري حقن الديلب",
            record: record
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let preparedApp: StoreApp

                switch record.kind {
                case .duplicate:
                    guard let number = record.copyNumber else {
                        throw SideloadSigningError.packageFailed
                    }
                    preparedApp = try AppCloneEngine.prepareFromSource(
                        app: record.app,
                        number: number,
                        sourceIPA: sourceIPA,
                        progress: { value, text in
                            self.publishProgress(0.56 + (value * 0.40), text: text, record: record)
                        }
                    )

                case .dylib:
                    let dylibs = record.dylibPaths.map(URL.init(fileURLWithPath:))
                    let prepared = try SideloadPackagePreparer.prepare(
                        sourceIPA: sourceIPA,
                        knownMetadata: nil,
                        copyVariant: .original,
                        dylibURLs: dylibs,
                        sourceKind: .updates,
                        sourceURL: record.app.effectiveDownloadURL,
                        progress: { value, text in
                            self.publishProgress(0.56 + (value * 0.40), text: text, record: record)
                        }
                    )
                    preparedApp = prepared.app
                }

                StoreInstallKeepAlive.shared.end(hold)

                DispatchQueue.main.async {
                    self.progress = 1
                    self.statusText = "جاهز للتوقيع والتثبيت"
                    self.busy = false
                    var displayedApp = preparedApp
                    if displayedApp.iconUrl?.isEmpty != false {
                        displayedApp.iconUrl = record.app.iconUrl
                    }
                    TransferActivityCenter.shared.track(displayedApp)

                    NotificationCenter.default.post(
                        name: Self.completedNotification,
                        object: nil,
                        userInfo: ["appID": record.app.id, "kind": record.kind.rawValue, "preparedApp": displayedApp]
                    )

                    self.clearRecordFiles(record)
                    self.clearRecord()

                    // The prepared IPA has already been staged by AppCloneEngine /
                    // SideloadPackagePreparer, so StoreInstallCoordinator signs it
                    // immediately without downloading the original IPA again.
                    if SigningAssetProvider.hasCredentials {
                        StoreInstallCoordinator.shared.start(displayedApp)
                    } else {
                        InstallLiveActivityBridge.finish(
                            job: self.liveJob(for: record),
                            success: true,
                            detail: "جاهز للتوقيع"
                        )
                        SigningSetupCoordinator.shared.request(for: displayedApp)
                    }
                    self.finishBackgroundEventsIfPossible()
                }
            } catch {
                StoreInstallKeepAlive.shared.end(hold)
                self.fail(record: record, error: error)
            }
        }
    }

    private func publishProgress(_ value: Double, text: String, record: DetailPreparationRecord) {
        let p = max(0, min(0.99, value))
        DispatchQueue.main.async {
            guard self.activeAppID == record.app.id,
                  self.activeKind == record.kind else { return }
            self.progress = p
            self.statusText = text
            self.busy = true
        }

        InstallLiveActivityBridge.update(
            job: liveJob(for: record),
            phase: .downloading,
            progress: min(0.89, p * 0.90),
            detail: text,
            force: false
        )
    }

    private func fail(record: DetailPreparationRecord, error: Error) {
        guard self.record(id: record.id) != nil else { return }
        StoreInstallKeepAlive.shared.end("detail-download-\(record.id)")
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        InstallLiveActivityBridge.finish(job: liveJob(for: record), success: false, detail: text)

        DispatchQueue.main.async {
            guard self.record(id: record.id) != nil else { return }
            self.busy = false
            self.isDownloading = false
            self.isPaused = false
            self.progress = 0
            self.statusText = ""
            self.errorText = text
            self.clearRecordFiles(record)
            self.clearRecord()
            self.finishBackgroundEventsIfPossible()
        }
    }

    private func publishError(_ text: String) {
        DispatchQueue.main.async {
            self.errorText = text
        }
    }

    private func sourceJob(for record: DetailPreparationRecord) -> StoreInstallJob {
        StoreInstallJob(
            id: record.id + "-source",
            appID: record.app.id,
            appName: record.app.name,
            bundleID: record.app.bundleId ?? record.app.id,
            version: record.app.version ?? "1.0",
            iconURL: record.app.iconUrl,
            downloadURL: record.app.effectiveDownloadURL ?? "",
            expectedBytes: record.app.fileSize ?? 0
        )
    }

    private func liveJob(for record: DetailPreparationRecord) -> StoreInstallJob {
        let targetBundle: String = {
            let base = (record.app.bundleId?.isEmpty == false ? record.app.bundleId : nil) ?? record.app.id
            if record.kind == .duplicate, let number = record.copyNumber {
                return base + String(number)
            }
            return base
        }()

        return StoreInstallJob(
            id: record.id,
            appID: "detail-\(record.kind.rawValue)-\(record.app.id)",
            appName: record.kind == .duplicate ? "تكرار \(record.app.name)" : "دمج ديلب · \(record.app.name)",
            bundleID: targetBundle,
            version: record.app.version ?? "1.0",
            iconURL: record.app.iconUrl,
            downloadURL: record.app.effectiveDownloadURL ?? "",
            expectedBytes: record.app.fileSize ?? 0
        )
    }

    private func persistDylibs(_ urls: [URL], operationID: String) throws -> [URL] {
        guard !urls.isEmpty else { return [] }

        let dir = operationRoot.appendingPathComponent(operationID, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var result: [URL] = []
        var used = Set<String>()

        for source in urls {
            guard source.pathExtension.lowercased() == "dylib" else {
                throw SideloadSigningError.unsupportedDylib(source.lastPathComponent)
            }

            var name = source.lastPathComponent
            if used.contains(name.lowercased()) {
                name = String(UUID().uuidString.prefix(6)) + "-" + name
            }
            used.insert(name.lowercased())

            let destination = dir.appendingPathComponent(name)
            let access = source.startAccessingSecurityScopedResource()
            defer {
                if access { source.stopAccessingSecurityScopedResource() }
            }

            try? fm.removeItem(at: destination)

            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                try data.write(to: destination, options: .atomic)
            }
            result.append(destination)
        }

        return result
    }

    private var operationRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DetailPreparation", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var recordFile: URL {
        operationRoot.appendingPathComponent("active-v2.json")
    }

    private func setRecord(_ value: DetailPreparationRecord) {
        lock.lock()
        record = value
        preparingRecordID = nil
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: recordFile, options: .atomic)
        }
        lock.unlock()
    }

    private func restoreRecord() {
        guard let data = try? Data(contentsOf: recordFile),
              let saved = try? JSONDecoder().decode(DetailPreparationRecord.self, from: data) else {
            return
        }

        record = saved
        TransferActivityCenter.shared.track(saved.app)

        DispatchQueue.main.async {
            self.activeAppID = saved.app.id
            self.activeKind = saved.kind
            self.busy = true
            self.isDownloading = true
            self.statusText = "جاري استكمال العملية"
        }
    }

    private func snapshotRecord() -> DetailPreparationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    private func record(id: String) -> DetailPreparationRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard record?.id == id else { return nil }
        return record
    }

    private func clearRecord() {
        lock.lock()
        record = nil
        preparingRecordID = nil
        downloadRecoveryAttempts.removeAll()
        try? fm.removeItem(at: recordFile)
        lock.unlock()

        activeAppID = nil
        activeKind = nil
    }

    private func clearRecordFiles(_ record: DetailPreparationRecord) {
        try? fm.removeItem(at: operationRoot.appendingPathComponent(record.id, isDirectory: true))
    }

    private func finishBackgroundEventsIfPossible() {
        guard snapshotRecord() == nil else { return }
        let completion = backgroundSessionCompletion
        backgroundSessionCompletion = nil
        completion?()
    }
}

extension DetailPreparationCenter: URLSessionDownloadDelegate, URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription,
              let current = record(id: id) else { return }

        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (current.app.fileSize ?? 0)
        let fraction = expected > 0
            ? min(1, Double(totalBytesWritten) / Double(expected))
            : 0

        publishProgress(
            fraction * 0.52,
            text: "جاري تحميل التطبيق الأصلي",
            record: current
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let current = record(id: id) else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            fail(record: current, error: SideloadSigningError.httpStatus(http.statusCode))
            return
        }

        do {
            // This is deliberately the exact same staging primitive used by a
            // normal install. Once this returns, the source IPA is durable and no
            // later clone/injection step depends on the URLSession temp file.
            let staged = try captureSourceIPA(from: location, record: current)
            preserveOriginalForDownloads(staged, record: current)
            publishProgress(
                0.54,
                text: "اكتمل التحميل · تم حفظ IPA",
                record: current
            )
            prepare(record: current, sourceIPA: staged)
        } catch {
            retrySourceDownload(record: current, error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task is URLSessionDataTask, let id = task.taskDescription {
            finishRescue(id: id, error: error)
            return
        }
        guard let error,
              let id = task.taskDescription,
              let current = record(id: id) else { return }

        // A completion error after didFinishDownloadingTo can race with staging.
        // If the durable IPA exists, continue from it instead of restarting or
        // surfacing a temporary-file error.
        if let cached = recoverSourceIPA(for: current) {
            prepare(record: current, sourceIPA: cached)
            return
        }

        retrySourceDownload(record: current, error: error)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let id = dataTask.taskDescription, record(id: id) != nil else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finishRescue(id: id, error: SideloadSigningError.httpStatus(http.statusCode))
            return
        }
        lock.lock()
        if let entry = rescueFiles[id] {
            rescueFiles[id] = (entry.0, entry.1, entry.2, max(0, response.expectedContentLength))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription else { return }
        lock.lock()
        guard let entry = rescueFiles[id] else {
            lock.unlock()
            return
        }
        do {
            try entry.1.write(contentsOf: data)
            rescueFiles[id] = (entry.0, entry.1, entry.2 + Int64(data.count), entry.3)
            let fraction = entry.3 > 0 ? Double(entry.2 + Int64(data.count)) / Double(entry.3) : 0
            lock.unlock()
            if let current = record(id: id) {
                publishProgress(min(0.52, fraction * 0.52), text: "جاري حفظ IPA مباشرة", record: current)
            }
        } catch {
            lock.unlock()
            finishRescue(id: id, error: error)
            dataTask.cancel()
        }
    }

    private func finishRescue(id: String, error: Error?) {
        lock.lock()
        let entry = rescueFiles.removeValue(forKey: id)
        rescueTasks.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        try? entry.1.close()
        guard let current = record(id: id) else {
            try? fm.removeItem(at: entry.0)
            return
        }
        if let error {
            try? fm.removeItem(at: entry.0)
            if case SideloadSigningError.httpStatus = error {
                fail(record: current, error: error)
            } else {
                retrySourceDownload(record: current, error: error)
            }
            return
        }
        if entry.3 > 0 && entry.2 < entry.3 {
            try? fm.removeItem(at: entry.0)
            retrySourceDownload(record: current, error: StoreDownloadStorageError.truncatedFile)
            return
        }
        do {
            let staged = try captureSourceIPA(from: entry.0, record: current)
            try? fm.removeItem(at: entry.0)
            preserveOriginalForDownloads(staged, record: current)
            prepare(record: current, sourceIPA: staged)
        } catch {
            try? fm.removeItem(at: entry.0)
            retrySourceDownload(record: current, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.finishBackgroundEventsIfPossible()
        }
    }
}

enum AppCloneEngine {
    private static let fm = FileManager.default

    static func prepareFromSource(
        app: StoreApp,
        number: Int,
        sourceIPA: URL,
        progress: @escaping (Double, String) -> Void
    ) throws -> StoreApp {
        guard (1...99).contains(number) else {
            throw SideloadSigningError.packageFailed
        }
        try StoreDownloadStorage.validateIPA(at: sourceIPA)

        let root = fm.temporaryDirectory
            .appendingPathComponent("AppClone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        progress(0.04, "جاري فك التطبيق")
        Zip.addCustomFileExtension("ipa")

        do {
            try Zip.unzipFile(
                sourceIPA,
                destination: root,
                overwrite: true,
                password: nil,
                progress: { value in
                    progress(0.04 + (value * 0.30), "جاري فك التطبيق")
                }
            )
        } catch {
            throw SideloadSigningError.invalidIPA
        }

        guard let payload = BatSignPackagePipeline.locatePayload(in: root) else {
            throw SideloadSigningError.missingPayload
        }
        guard let appURL = BatSignPackagePipeline.locateApp(in: payload) else {
            throw SideloadSigningError.missingApp
        }

        let metadata = try SideloadIPAInspector.metadata(appURL: appURL, ipaURL: sourceIPA)
        let newName = "\(metadata.name) \(number)"
        let newBundle = metadata.bundleID + String(number)

        progress(0.38, "جاري تجهيز النسخة \(number)")
        try rewriteIdentity(
            appURL: appURL,
            oldBundleID: metadata.bundleID,
            newBundleID: newBundle,
            newName: newName
        )

        let output = root.appendingPathComponent("Cloned.ipa")
        do {
            try Zip.zipFiles(
                paths: [payload],
                zipFilePath: output,
                password: nil,
                compression: .BestSpeed,
                progress: { value in
                    progress(0.45 + (value * 0.48), "جاري تجهيز IPA")
                }
            )
        } catch {
            throw SideloadSigningError.packageFailed
        }

        let attrs = try? fm.attributesOfItem(atPath: output.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? metadata.size

        let clone = StoreApp(
            id: "clone-\(app.id)-\(number)-\(UUID().uuidString.lowercased())",
            name: newName,
            bundleId: newBundle,
            version: metadata.version,
            buildNumber: app.buildNumber,
            minIosVersion: app.minIosVersion,
            fileSize: size,
            notes: app.notes,
            iconUrl: app.iconUrl,
            featured: app.featured,
            categories: app.categories,
            installs: nil,
            updatedAt: app.updatedAt,
            addedAt: app.addedAt,
            versionUpdatedAt: app.versionUpdatedAt,
            feedKind: app.feedKind,
            downloadUrl: app.effectiveDownloadURL,
            downloadURL: app.effectiveDownloadURL
        )

        progress(0.95, "جاري حفظ النسخة")
        guard let destination = StoreDownloadStorage.stagedURL(for: clone) else {
            throw StoreDownloadStorageError.cannotStage
        }

        try? fm.removeItem(at: destination)
        try fm.copyItem(at: output, to: destination)
        try StoreDownloadStorage.validateIPA(at: destination)

        let cloneMetadata = SideloadIPAMetadata(
            name: newName,
            bundleID: newBundle,
            version: metadata.version,
            size: size,
            iconData: metadata.iconData
        )
        // A missing icon must never prevent an otherwise valid clone from
        // being signed. Existing downloads also have remote artwork fallback.
        try? SideloadLibraryStore.writeRecord(
            appID: clone.id,
            folder: destination.deletingLastPathComponent(),
            metadata: cloneMetadata,
            source: .updates,
            sourceURL: app.effectiveDownloadURL,
            copyNumber: number,
            dylibNames: [],
            isGameDuplicate: app.isGameAsset
        )
        progress(1, "جاهز للتوقيع والتثبيت")
        return clone
    }

    private static func rewriteIdentity(
        appURL: URL,
        oldBundleID: String,
        newBundleID: String,
        newName: String
    ) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        var info = try SideloadIPAInspector.readInfo(appURL: appURL)
        info["CFBundleIdentifier"] = newBundleID
        info["CFBundleDisplayName"] = newName
        info["CFBundleName"] = newName
        try writePlist(info, to: infoURL)

        for folderName in ["PlugIns", "Extensions"] {
            let folder = appURL.appendingPathComponent(folderName, isDirectory: true)
            guard fm.fileExists(atPath: folder.path),
                  let children = try? fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for appex in children where appex.pathExtension.lowercased() == "appex" {
                let url = appex.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: url),
                      var plist = (try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                      )) as? [String: Any] else {
                    continue
                }

                if let current = plist["CFBundleIdentifier"] as? String {
                    if current.hasPrefix(oldBundleID) {
                        plist["CFBundleIdentifier"] = newBundleID + current.dropFirst(oldBundleID.count)
                    } else {
                        plist["CFBundleIdentifier"] = current + String(numberSuffix(from: newBundleID))
                    }
                    try? writePlist(plist, to: url)
                }
            }
        }

        guard let children = try? fm.contentsOfDirectory(
            at: appURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for lproj in children where lproj.pathExtension.lowercased() == "lproj" {
            let stringsURL = lproj.appendingPathComponent("InfoPlist.strings")
            guard let data = try? Data(contentsOf: stringsURL),
                  var plist = (try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  )) as? [String: Any] else {
                continue
            }
            plist["CFBundleDisplayName"] = newName
            plist["CFBundleName"] = newName
            try? writePlist(plist, to: stringsURL)
        }
    }

    private static func numberSuffix(from bundle: String) -> String {
        String(bundle.reversed().prefix { $0.isNumber }.reversed())
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}
