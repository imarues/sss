import Foundation
import SwiftUI
import UIKit
import Zip

// Persistent worker for duplicate / dylib operations launched from app details.
// The downloaded IPA is copied out of URLSession's temporary location before
// any expensive work begins, so leaving the sheet or app cannot invalidate it.
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
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var errorText: String?

    var backgroundSessionCompletion: (() -> Void)?

    private let fm = FileManager.default
    private let lock = NSLock()
    private var record: DetailPreparationRecord?
    private var preparingRecordID: String?
    private var downloadRecoveryAttempts: [String: Int] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
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
        guard let current = snapshotRecord() else { return }

        TransferActivityCenter.shared.track(current.app)
        DispatchQueue.main.async {
            self.activeAppID = current.app.id
            self.activeKind = current.kind
            self.busy = true
            self.statusText = "جاري استكمال العملية"
        }
        InstallLiveActivityBridge.begin(job: liveJob(for: current))

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if tasks.contains(where: { $0.taskDescription == current.id }) { return }

            let stable = self.persistentSourceURL(for: current)
            if StoreDownloadStorage.isValidIPA(at: stable) {
                self.prepare(record: current, sourceIPA: stable)
                return
            }

            if StoreDownloadStorage.hasValidStagedIPA(for: current.app),
               let cached = StoreDownloadStorage.stagedURL(for: current.app) {
                self.prepare(record: current, sourceIPA: cached)
                return
            }

            self.restartDownload(record: current, reason: "جاري استكمال التحميل")
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundSessionCompletion = completionHandler
        _ = session
    }

    func isActive(appID: String, kind: DetailPreparationKind) -> Bool {
        activeAppID == appID && activeKind == kind && busy
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
        if busy { return }

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
                self.progress = 0
                self.statusText = "جاري تحميل التطبيق"
                self.errorText = nil
            }

            StoreDownloadStorage.registerVisibleCategory(for: app)
            InstallLiveActivityBridge.begin(job: liveJob(for: next))

            let stable = persistentSourceURL(for: next)
            if StoreDownloadStorage.isValidIPA(at: stable) {
                publishProgress(0.50, text: "استخدام الملف المحفوظ", record: next)
                prepare(record: next, sourceIPA: stable)
                return
            }

            if StoreDownloadStorage.hasValidStagedIPA(for: app),
               let cached = StoreDownloadStorage.stagedURL(for: app) {
                publishProgress(0.48, text: "استخدام النسخة المحفوظة", record: next)
                prepare(record: next, sourceIPA: cached)
                return
            }

            try startDownload(record: next)
        } catch {
            publishError(error.localizedDescription)
        }
    }

    private func startDownload(record: DetailPreparationRecord) throws {
        guard let raw = record.app.effectiveDownloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SideloadSigningError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        task.taskDescription = record.id
        task.resume()
    }

    private func restartDownload(record: DetailPreparationRecord, reason: String) {
        lock.lock()
        let attempts = downloadRecoveryAttempts[record.id] ?? 0
        downloadRecoveryAttempts[record.id] = attempts + 1
        preparingRecordID = nil
        lock.unlock()

        guard attempts < 2 else {
            fail(record: record, error: StoreDownloadStorageError.sourceMissing)
            return
        }

        let stable = persistentSourceURL(for: record)
        if StoreDownloadStorage.isValidIPA(at: stable) {
            prepare(record: record, sourceIPA: stable)
            return
        }

        if StoreDownloadStorage.hasValidStagedIPA(for: record.app),
           let cached = StoreDownloadStorage.stagedURL(for: record.app) {
            prepare(record: record, sourceIPA: cached)
            return
        }

        publishProgress(0.48, text: reason, record: record)
        do {
            try startDownload(record: record)
        } catch {
            fail(record: record, error: error)
        }
    }

    private func prepare(record: DetailPreparationRecord, sourceIPA: URL) {
        lock.lock()
        if preparingRecordID == record.id {
            lock.unlock()
            return
        }
        preparingRecordID = record.id
        lock.unlock()

        let hold = "detail-preparation-\(record.id)"
        StoreInstallKeepAlive.shared.begin(hold)
        publishProgress(0.55, text: record.kind == .duplicate ? "جاري تجهيز النسخة" : "جاري دمج الديلب", record: record)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let preparedApp: StoreApp
                switch record.kind {
                case .duplicate:
                    guard let number = record.copyNumber else { throw SideloadSigningError.packageFailed }
                    preparedApp = try AppCloneEngine.prepareFromSource(
                        app: record.app,
                        number: number,
                        sourceIPA: sourceIPA,
                        progress: { value, text in
                            self.publishProgress(0.55 + (value * 0.42), text: text, record: record)
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
                            self.publishProgress(0.55 + (value * 0.42), text: text, record: record)
                        }
                    )
                    preparedApp = prepared.app
                }

                StoreInstallKeepAlive.shared.end(hold)
                DispatchQueue.main.async {
                    self.progress = 1
                    self.statusText = "جاري التوقيع والتثبيت"
                    self.busy = false
                    TransferActivityCenter.shared.track(preparedApp)

                    NotificationCenter.default.post(
                        name: Self.completedNotification,
                        object: nil,
                        userInfo: ["appID": record.app.id, "kind": record.kind.rawValue]
                    )

                    self.clearRecordFiles(record)
                    self.clearRecord()

                    if SigningAssetProvider.hasCredentials {
                        StoreInstallCoordinator.shared.start(preparedApp)
                    } else {
                        InstallLiveActivityBridge.finish(
                            job: self.liveJob(for: record),
                            success: true,
                            detail: "جاهز للتوقيع"
                        )
                        SigningSetupCoordinator.shared.request(for: preparedApp)
                    }
                    self.finishBackgroundEventsIfPossible()
                }
            } catch StoreDownloadStorageError.sourceMissing {
                StoreInstallKeepAlive.shared.end(hold)
                self.restartDownload(record: record, reason: "إعادة استلام ملف التطبيق")
            } catch {
                StoreInstallKeepAlive.shared.end(hold)
                self.fail(record: record, error: error)
            }
        }
    }

    private func publishProgress(_ value: Double, text: String, record: DetailPreparationRecord) {
        let p = max(0, min(0.99, value))
        DispatchQueue.main.async {
            guard self.activeAppID == record.app.id, self.activeKind == record.kind else { return }
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
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        InstallLiveActivityBridge.finish(job: liveJob(for: record), success: false, detail: text)
        DispatchQueue.main.async {
            self.busy = false
            self.statusText = ""
            self.errorText = text
            self.clearRecordFiles(record)
            self.clearRecord()
            self.finishBackgroundEventsIfPossible()
        }
    }

    private func publishError(_ text: String) {
        DispatchQueue.main.async { self.errorText = text }
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
                name = UUID().uuidString.prefix(6) + "-" + name
            }
            used.insert(name.lowercased())
            let destination = dir.appendingPathComponent(String(name))
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
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

    private func persistDownloadedSource(from temporaryURL: URL, record: DetailPreparationRecord) throws -> URL {
        let dir = operationRoot.appendingPathComponent(record.id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = persistentSourceURL(for: record)

        if StoreDownloadStorage.isValidIPA(at: destination) {
            return destination
        }
        try? fm.removeItem(at: destination)

        guard fm.fileExists(atPath: temporaryURL.path) else {
            throw StoreDownloadStorageError.sourceMissing
        }

        do {
            try fm.moveItem(at: temporaryURL, to: destination)
        } catch {
            do {
                try fm.copyItem(at: temporaryURL, to: destination)
            } catch {
                if !fm.fileExists(atPath: temporaryURL.path) {
                    throw StoreDownloadStorageError.sourceMissing
                }
                let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
                try data.write(to: destination, options: .atomic)
            }
        }

        try StoreDownloadStorage.validateIPA(at: destination)
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private func persistentSourceURL(for record: DetailPreparationRecord) -> URL {
        operationRoot
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent("source.ipa", isDirectory: false)
    }

    private var operationRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DetailPreparation", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var recordFile: URL {
        operationRoot.appendingPathComponent("active.json")
    }

    private func setRecord(_ value: DetailPreparationRecord) {
        lock.lock()
        record = value
        preparingRecordID = nil
        downloadRecoveryAttempts[value.id] = 0
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: recordFile, options: .atomic)
        }
        lock.unlock()
    }

    private func restoreRecord() {
        guard let data = try? Data(contentsOf: recordFile),
              let saved = try? JSONDecoder().decode(DetailPreparationRecord.self, from: data) else { return }
        record = saved
        TransferActivityCenter.shared.track(saved.app)
        DispatchQueue.main.async {
            self.activeAppID = saved.app.id
            self.activeKind = saved.kind
            self.busy = true
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
        let oldID = record?.id
        record = nil
        preparingRecordID = nil
        if let oldID { downloadRecoveryAttempts[oldID] = nil }
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

extension DetailPreparationCenter: URLSessionDownloadDelegate, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription, let current = record(id: id) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (current.app.fileSize ?? 0)
        let fraction = expected > 0 ? min(1, Double(totalBytesWritten) / Double(expected)) : 0
        publishProgress(fraction * 0.50, text: "جاري تحميل التطبيق", record: current)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription, let current = record(id: id) else { return }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            fail(record: current, error: SideloadSigningError.httpStatus(http.statusCode))
            return
        }

        do {
            let stable = try persistDownloadedSource(from: location, record: current)
            publishProgress(0.52, text: "تم التحميل · جاري تجهيز التطبيق", record: current)
            prepare(record: current, sourceIPA: stable)
        } catch StoreDownloadStorageError.sourceMissing {
            restartDownload(record: current, reason: "اكتمل التحميل · إعادة استلام الملف")
        } catch {
            fail(record: current, error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let id = task.taskDescription,
              let current = record(id: id) else { return }

        let stable = persistentSourceURL(for: current)
        if StoreDownloadStorage.isValidIPA(at: stable) { return }
        restartDownload(record: current, reason: "انقطع التحميل · جاري الاستكمال")
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
        guard (1...99).contains(number) else { throw SideloadSigningError.packageFailed }
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
                progress: { value in progress(0.04 + (value * 0.30), "جاري فك التطبيق") }
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
                progress: { value in progress(0.45 + (value * 0.48), "جاري تجهيز IPA") }
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
                  let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for appex in children where appex.pathExtension.lowercased() == "appex" {
                let url = appex.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: url),
                      var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
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

        guard let children = try? fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for lproj in children where lproj.pathExtension.lowercased() == "lproj" {
            let stringsURL = lproj.appendingPathComponent("InfoPlist.strings")
            guard let data = try? Data(contentsOf: stringsURL),
                  var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
            plist["CFBundleDisplayName"] = newName
            plist["CFBundleName"] = newName
            try? writePlist(plist, to: stringsURL)
        }
    }

    private static func numberSuffix(from bundle: String) -> String {
        String(bundle.reversed().prefix { $0.isNumber }.reversed())
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
