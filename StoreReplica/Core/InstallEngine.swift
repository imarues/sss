import Foundation
import UIKit
import ZIPFoundation
import Zip
import ZSign

enum StoreInstallPhase: String, Codable {
    case idle, downloading, ready, signing, installing, complete, failed
}

struct StoreInstallState: Equatable {
    var phase: StoreInstallPhase = .idle
    var progress: Double = 0
    var speedText: String?
    var message: String?
    var errorMessage: String? = nil
}

struct StoreInstallJob: Codable {
    let id: String
    let appID: String
    let appName: String
    let bundleID: String
    let version: String
    let iconURL: String?
    let downloadURL: String
    let expectedBytes: Int64
}

private struct SignedInstallArtifact {
    let ipaURL: URL
    let name: String
    let bundleID: String
    let version: String
}

enum StoreInstallError: LocalizedError {
    case missingDownloadURL
    case invalidDownloadURL
    case missingSigningAssets
    case invalidArchive
    case invalidAppMetadata
    case signingFailed(Int32)
    case manifestURL
    case httpStatus(Int)
    case installerRejected
    case installerTimedOut

    var errorDescription: String? {
        switch self {
        case .missingDownloadURL:
            return "رابط تحميل التطبيق غير متوفر."
        case .invalidDownloadURL:
            return "رابط تحميل التطبيق غير صالح."
        case .missingSigningAssets:
            return "ملفات الشهادة المطلوبة للتوقيع غير موجودة."
        case .invalidArchive:
            return "ملف IPA غير صالح أو لا يحتوي Payload/App."
        case .invalidAppMetadata:
            return "تعذر قراءة معلومات التطبيق الحقيقية من Info.plist."
        case .signingFailed(let code):
            return "فشل توقيع التطبيق (ZSign: \(code)). تحقق من الشهادة وMobileProvision."
        case .manifestURL:
            return "تعذر إنشاء رابط GBox للتثبيت. التطبيق ما زال محفوظًا وجاهزًا لإعادة المحاولة."
        case .httpStatus(let status):
            return "فشل تحميل التطبيق من الخادم (HTTP \(status))."
        case .installerRejected:
            return "تعذر فتح مثبت iOS. التطبيق محفوظ ويمكنك إعادة المحاولة بدون تنزيله من جديد."
        case .installerTimedOut:
            return "لم يبدأ مثبت iOS باستلام التطبيق. التطبيق محفوظ ويمكنك إعادة المحاولة."
        }
    }
}

final class StoreInstallAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        StoreInstallCoordinator.shared.backgroundSessionCompletion = completionHandler
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        StoreInstallCoordinator.shared.applicationDidBecomeActive()
    }
}

final class StoreInstallCoordinator: NSObject, ObservableObject {
    static let shared = StoreInstallCoordinator()

    @Published private(set) var states: [String: StoreInstallState] = [:]

    var backgroundSessionCompletion: (() -> Void)?

    private let lock = NSLock()
    private var jobs: [String: StoreInstallJob] = [:]
    private var samples: [String: (date: Date, bytes: Int64)] = [:]
    private var rescueAttempts: [String: Int] = [:]

    private let signingQueue = DispatchQueue(label: "com.ikiraplus.turath.signing", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "com.ikiraplus.turath.files-export", qos: .utility)

    private var installerServer: LoopbackIPAInstallServer?
    private var pendingInstallURL: URL?
    private var pendingInstallJob: StoreInstallJob?
    private var pendingSignedIPA: URL?
    private var installTransferStarted = false
    private var installTimeoutWorkItem: DispatchWorkItem?
    private var bootstrapped = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.ikiraplus.turathreplica.downloads.v2")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        restoreJobs()
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
            let known = self.snapshotJobs()

            for (id, job) in known {
                if activeIDs.contains(id) {
                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .downloading,
                            progress: 0,
                            speedText: nil,
                            message: "جاري استكمال التحميل"
                        )
                    )
                    InstallLiveActivityBridge.begin(job: job)
                    continue
                }

                if StoreDownloadStorage.hasValidStagedIPA(for: job) {
                    if let staged = try? StoreDownloadStorage.stagedURL(for: job) {
                        self.exportQueue.async {
                            StoreDownloadStorage.exportToFiles(stagedURL: staged, job: job)
                        }
                    }
                    self.publishReady(job: job, message: "محمّل ومحفوظ وجاهز للتثبيت")
                }
                self.removeJob(id)
            }
        }
    }

    func state(for appID: String) -> StoreInstallState {
        states[appID] ?? StoreInstallState()
    }

    func state(for app: StoreApp) -> StoreInstallState {
        if let current = states[app.id], current.phase != .idle {
            return current
        }
        if StoreDownloadStorage.hasValidStagedIPA(for: app) {
            return StoreInstallState(
                phase: .ready,
                progress: 1,
                speedText: nil,
                message: "محمّل ومحفوظ وجاهز للتثبيت"
            )
        }
        return StoreInstallState()
    }

    func start(_ app: StoreApp) {
        bootstrap()

        if let current = states[app.id], [.downloading, .signing, .installing].contains(current.phase) {
            return
        }

        if let other = pendingInstallJob, other.appID != app.id {
            markInstallAttemptReady(
                job: other,
                detail: "تم إيقاف محاولة التثبيت السابقة. التطبيق ما زال محفوظًا."
            )
        }

        let raw = app.effectiveDownloadURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let job = StoreInstallJob(
            id: UUID().uuidString,
            appID: app.id,
            appName: app.name,
            bundleID: app.bundleId ?? app.id,
            version: app.version ?? "1.0",
            iconURL: app.iconUrl,
            downloadURL: raw,
            expectedBytes: app.fileSize ?? 0
        )

        guard SigningAssetProvider.hasCredentials else {
            publishFailure(
                appID: app.id,
                text: StoreInstallError.missingSigningAssets.localizedDescription
            )
            return
        }

        if let staged = existingStagedIPA(for: job) {
            setJob(job)
            exportQueue.async {
                StoreDownloadStorage.exportToFiles(stagedURL: staged, job: job)
            }
            beginSigning(job: job, stagedIPA: staged, startLiveActivity: true)
            return
        }

        guard !raw.isEmpty else {
            publishFailure(appID: app.id, text: StoreInstallError.missingDownloadURL.localizedDescription)
            return
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            publishFailure(appID: app.id, text: StoreInstallError.invalidDownloadURL.localizedDescription)
            return
        }

        setJob(job)
        publish(
            appID: app.id,
            state: StoreInstallState(
                phase: .downloading,
                progress: 0,
                speedText: nil,
                message: "جاري التحميل"
            )
        )
        InstallLiveActivityBridge.begin(job: job)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")

        let task = session.downloadTask(with: request)
        task.taskDescription = job.id
        task.resume()
    }

    func applicationDidBecomeActive() {
        guard let url = pendingInstallURL, let job = pendingInstallJob else { return }
        pendingInstallURL = nil
        openInstallLink(url, job: job)
    }

    private func existingStagedIPA(for job: StoreInstallJob) -> URL? {
        if StoreDownloadStorage.hasValidStagedIPA(for: job) {
            return try? StoreDownloadStorage.stagedURL(for: job)
        }
        return StoreDownloadStorage.recoverLegacyExportIfPossible(job: job)
    }

    private func beginSigning(job: StoreInstallJob, stagedIPA: URL, startLiveActivity: Bool) {
        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .signing,
                progress: 0.92,
                speedText: nil,
                message: "جاري التوقيع"
            )
        )
        if startLiveActivity {
            InstallLiveActivityBridge.begin(job: job)
        }
        InstallLiveActivityBridge.update(
            job: job,
            phase: .signing,
            progress: 0.92,
            detail: "جاري التوقيع",
            force: true
        )

        signingQueue.async { [weak self] in
            self?.signThenInstall(job: job, ipaURL: stagedIPA)
        }
    }

    private func handleFinishedDownload(tempURL: URL, jobID: String) {
        guard let job = job(jobID) else { return }

        do {
            let staged = try StoreDownloadStorage.stageFinishedDownload(from: tempURL, job: job)

            exportQueue.async {
                StoreDownloadStorage.exportToFiles(stagedURL: staged, job: job)
            }

            publish(
                appID: job.appID,
                state: StoreInstallState(
                    phase: .signing,
                    progress: 0.92,
                    speedText: nil,
                    message: "اكتمل التحميل · محفوظ داخليًا · جاري التوقيع"
                )
            )
            InstallLiveActivityBridge.update(
                job: job,
                phase: .signing,
                progress: 0.92,
                detail: "اكتمل التحميل · جاري التوقيع",
                force: true
            )

            signingQueue.async { [weak self] in
                self?.signThenInstall(job: job, ipaURL: staged)
            }
        } catch StoreDownloadStorageError.sourceMissing {
            rescueFinishedDownload(job: job)
        } catch {
            fail(job: job, error: error)
        }
    }

    /// URLSession owns its temporary file only for the duration of the completion callback.
    /// If iOS has already reclaimed it, fetch once more and stage immediately from that callback.
    private func rescueFinishedDownload(job: StoreInstallJob) {
        lock.lock()
        let attempts = rescueAttempts[job.id] ?? 0
        rescueAttempts[job.id] = attempts + 1
        lock.unlock()

        guard attempts == 0,
              let url = URL(string: job.downloadURL) else {
            fail(job: job, error: StoreDownloadStorageError.sourceMissing)
            return
        }

        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .downloading,
                progress: 0.90,
                speedText: nil,
                message: "جاري تثبيت نسخة التحميل في التخزين الداخلي"
            )
        )

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60

        URLSession.shared.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            if let error {
                self.fail(job: job, error: error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.fail(job: job, error: StoreInstallError.httpStatus(http.statusCode))
                return
            }
            guard let location else {
                self.fail(job: job, error: StoreDownloadStorageError.sourceMissing)
                return
            }
            self.handleFinishedDownload(tempURL: location, jobID: job.id)
        }.resume()
    }

    private func signThenInstall(job: StoreInstallJob, ipaURL: URL) {
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
        DispatchQueue.main.sync {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "TurathSign") {
                if backgroundID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundID)
                    backgroundID = .invalid
                }
            }
        }

        defer {
            DispatchQueue.main.async {
                if backgroundID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundID)
                }
            }
        }

        do {
            let artifact = try sign(job: job, ipaURL: ipaURL)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publish(
                    appID: job.appID,
                    state: StoreInstallState(
                        phase: .installing,
                        progress: 0.98,
                        speedText: nil,
                        message: "جاري تجهيز GBox للتثبيت"
                    )
                )
                InstallLiveActivityBridge.update(
                    job: job,
                    phase: .installing,
                    progress: 0.98,
                    detail: "جاري تجهيز التثبيت",
                    force: true
                )
                self.startInstallServer(job: job, artifact: artifact)
            }
        } catch {
            fail(job: job, error: error)
        }
    }

    private func sign(job: StoreInstallJob, ipaURL: URL) throws -> SignedInstallArtifact {
        try StoreDownloadStorage.validateIPA(at: ipaURL)

        let fm = FileManager.default
        let credentials = try SigningAssetProvider.credentials()
        try SigningAssetProvider.validate(credentials: credentials)

        let workingRoot = fm.temporaryDirectory
            .appendingPathComponent("TurathSign-\(job.id)", isDirectory: true)
        try? fm.removeItem(at: workingRoot)
        try fm.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workingRoot) }

        do {
            try fm.unzipItem(at: ipaURL, to: workingRoot)
        } catch {
            throw StoreInstallError.invalidArchive
        }

        let payload = workingRoot.appendingPathComponent("Payload", isDirectory: true)
        let apps = (try? fm.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        guard let appURL = apps.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw StoreInstallError.invalidArchive
        }

        let metadata = try Self.readMetadata(appURL: appURL, fallback: job)

        let code: Int32 = appURL.path.withCString { appPath in
            credentials.p12.path.withCString { certPath in
                credentials.mobileProvision.path.withCString { provisionPath in
                    credentials.password.withCString { password in
                        "".withCString { emptyBundleID in
                            "".withCString { emptyName in
                                zsign(
                                    appPath,
                                    certPath,
                                    certPath,
                                    provisionPath,
                                    password,
                                    emptyBundleID,
                                    emptyName
                                )
                            }
                        }
                    }
                }
            }
        }
        guard code == 0 else { throw StoreInstallError.signingFailed(code) }

        let output = try signedFileURL(for: job)
        let zipOutput = output.deletingPathExtension().appendingPathExtension("zip")
        try? fm.removeItem(at: output)
        try? fm.removeItem(at: zipOutput)
        defer { try? fm.removeItem(at: zipOutput) }

        try Zip.zipFiles(
            paths: [payload],
            zipFilePath: zipOutput,
            password: nil,
            compression: .BestSpeed,
            progress: nil
        )
        try fm.moveItem(at: zipOutput, to: output)
        try StoreDownloadStorage.validateIPA(at: output)

        return SignedInstallArtifact(
            ipaURL: output,
            name: metadata.name,
            bundleID: metadata.bundleID,
            version: metadata.version
        )
    }

    private static func readMetadata(
        appURL: URL,
        fallback job: StoreInstallJob
    ) throws -> (name: String, bundleID: String, version: String) {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw StoreInstallError.invalidAppMetadata
        }

        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = plist[key] as? String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        let name = value(["CFBundleDisplayName", "CFBundleName"]) ?? job.appName
        let bundleID = value(["CFBundleIdentifier"]) ?? job.bundleID
        let version = value(["CFBundleShortVersionString", "CFBundleVersion"]) ?? job.version

        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreInstallError.invalidAppMetadata
        }
        return (name, bundleID, version.isEmpty ? "1.0" : version)
    }

    private func startInstallServer(job: StoreInstallJob, artifact: SignedInstallArtifact) {
        cleanupInstallAttempt(deleteSigned: true)

        pendingInstallJob = job
        pendingSignedIPA = artifact.ipaURL
        pendingInstallURL = nil
        installTransferStarted = false

        do {
            let server = try LoopbackIPAInstallServer(fileURL: artifact.ipaURL)
            installerServer = server
            server.start(
                onReady: { [weak self] in
                    guard let self else { return }
                    guard let manifest = Self.gboxManifestURL(for: artifact),
                          let link = Self.installURL(manifest: manifest) else {
                        self.fail(job: job, error: StoreInstallError.manifestURL)
                        return
                    }

                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .installing,
                            progress: 0.99,
                            speedText: nil,
                            message: "جاهز لفتح مثبت iOS عبر GBox"
                        )
                    )

                    if UIApplication.shared.applicationState == .active {
                        self.openInstallLink(link, job: job)
                    } else {
                        self.pendingInstallURL = link
                    }
                },
                onTransferStarted: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.installTransferStarted = true
                    self.installTimeoutWorkItem?.cancel()
                    self.installTimeoutWorkItem = nil
                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .installing,
                            progress: 0.99,
                            speedText: nil,
                            message: "جاري إرسال التطبيق إلى مثبت iOS"
                        )
                    )
                },
                onTransferComplete: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.publishReady(
                        job: job,
                        message: "محمّل ومحفوظ وجاهز لإعادة التثبيت"
                    )
                    InstallLiveActivityBridge.finish(
                        job: job,
                        success: true,
                        detail: "تم إرسال التطبيق إلى مثبت iOS"
                    )
                    self.cleanupInstallAttempt(deleteSigned: true)
                    self.removeJob(job.id)
                },
                onFailure: { [weak self] error in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.fail(job: job, error: error)
                }
            )
        } catch {
            fail(job: job, error: error)
        }
    }

    private func openInstallLink(_ link: URL, job: StoreInstallJob) {
        UIApplication.shared.open(link, options: [:]) { [weak self] accepted in
            guard let self else { return }
            guard self.pendingInstallJob?.id == job.id else { return }

            if !accepted {
                self.fail(job: job, error: StoreInstallError.installerRejected)
                return
            }

            let timeout = DispatchWorkItem { [weak self] in
                guard let self,
                      self.pendingInstallJob?.id == job.id,
                      !self.installTransferStarted else { return }
                self.fail(job: job, error: StoreInstallError.installerTimedOut)
            }
            self.installTimeoutWorkItem?.cancel()
            self.installTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        }
    }

    private static func gboxManifestURL(for artifact: SignedInstallArtifact) -> URL? {
        let descriptor = "\(artifact.name)/\(artifact.bundleID)/\(artifact.version)"
        let base64 = Data(descriptor.utf8).base64EncodedString()
        let encoded = base64.replacingOccurrences(of: "=", with: "%3D")
        return URL(string: "https://i.gbox.run/\(encoded).plist")
    }

    private static func installURL(manifest: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifest.absoluteString)
        ]
        return components.url
    }

    private func transientDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TurathSigning", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func internalDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TurathInternal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func signedFileURL(for job: StoreInstallJob) throws -> URL {
        try transientDirectory().appendingPathComponent(job.id + "-signed.ipa")
    }

    private func markInstallAttemptReady(job: StoreInstallJob, detail: String) {
        guard pendingInstallJob?.id == job.id else { return }
        publishReady(job: job, message: detail)
        InstallLiveActivityBridge.finish(job: job, success: true, detail: "محفوظ وجاهز للتثبيت")
        cleanupInstallAttempt(deleteSigned: true)
        removeJob(job.id)
    }

    private func cleanupInstallAttempt(deleteSigned: Bool) {
        installTimeoutWorkItem?.cancel()
        installTimeoutWorkItem = nil
        installerServer?.stop()
        installerServer = nil
        if deleteSigned, let signed = pendingSignedIPA {
            try? FileManager.default.removeItem(at: signed)
        }
        pendingInstallURL = nil
        pendingInstallJob = nil
        pendingSignedIPA = nil
        installTransferStarted = false
    }

    private func fail(job: StoreInstallJob, error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let stagedExists = StoreDownloadStorage.hasValidStagedIPA(for: job)

        if pendingInstallJob?.id == job.id {
            cleanupInstallAttempt(deleteSigned: true)
        }

        if stagedExists {
            publish(
                appID: job.appID,
                state: StoreInstallState(
                    phase: .ready,
                    progress: 1,
                    speedText: nil,
                    message: "التطبيق محفوظ وجاهز لإعادة المحاولة",
                    errorMessage: text
                )
            )
        } else {
            publishFailure(appID: job.appID, text: text)
        }

        InstallLiveActivityBridge.finish(job: job, success: false, detail: text)
        removeJob(job.id)
    }

    private func publishReady(job: StoreInstallJob, message: String) {
        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .ready,
                progress: 1,
                speedText: nil,
                message: message
            )
        )
    }

    private func publishFailure(appID: String, text: String) {
        publish(
            appID: appID,
            state: StoreInstallState(
                phase: .failed,
                progress: 0,
                speedText: nil,
                message: text,
                errorMessage: text
            )
        )
    }

    private func publish(appID: String, state: StoreInstallState) {
        DispatchQueue.main.async { [weak self] in
            self?.states[appID] = state
        }
    }

    private var jobsFile: URL? {
        guard let root = try? internalDirectory() else { return nil }
        return root.appendingPathComponent("jobs.json")
    }

    private func restoreJobs() {
        guard let file = jobsFile,
              let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: StoreInstallJob].self, from: data) else {
            return
        }
        jobs = stored
    }

    private func persistJobsLocked() {
        guard let file = jobsFile,
              let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func setJob(_ job: StoreInstallJob) {
        lock.lock()
        jobs[job.id] = job
        persistJobsLocked()
        lock.unlock()
    }

    private func removeJob(_ id: String) {
        lock.lock()
        jobs[id] = nil
        samples[id] = nil
        rescueAttempts[id] = nil
        persistJobsLocked()
        lock.unlock()
    }

    private func job(_ id: String) -> StoreInstallJob? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]
    }

    private func snapshotJobs() -> [String: StoreInstallJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs
    }
}

extension StoreInstallCoordinator: URLSessionDownloadDelegate, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription, let job = job(id) else { return }

        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : job.expectedBytes
        let progress = expected > 0
            ? min(0.90, max(0, (Double(totalBytesWritten) / Double(expected)) * 0.90))
            : 0

        let now = Date()
        var speed: Double = 0
        lock.lock()
        if let old = samples[id] {
            let dt = now.timeIntervalSince(old.date)
            if dt >= 0.8 {
                let measured = Double(max(0, totalBytesWritten - old.bytes)) / dt
                speed = measured
                samples[id] = (now, totalBytesWritten)
            }
        } else {
            samples[id] = (now, totalBytesWritten)
        }
        lock.unlock()

        let speedText = speed > 1024
            ? ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
            : nil

        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .downloading,
                progress: progress,
                speedText: speedText,
                message: "جاري التحميل"
            )
        )
        InstallLiveActivityBridge.update(
            job: job,
            phase: .downloading,
            progress: progress,
            detail: speedText ?? "جاري التحميل",
            force: false
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let job = job(id) else { return }

        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            fail(job: job, error: StoreInstallError.httpStatus(response.statusCode))
            return
        }

        handleFinishedDownload(tempURL: location, jobID: id)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let id = task.taskDescription,
              let job = job(id) else { return }

        // didFinishDownloadingTo may already have staged a valid file. A late transport
        // callback must not destroy a job that has moved on to signing.
        if StoreDownloadStorage.hasValidStagedIPA(for: job) {
            return
        }
        fail(job: job, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            let completion = self?.backgroundSessionCompletion
            self?.backgroundSessionCompletion = nil
            completion?()
        }
    }
}
