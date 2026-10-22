import Foundation
import UIKit

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

enum StoreInstallError: LocalizedError {
    case missingDownloadURL
    case invalidDownloadURL
    case missingSigningAssets
    case httpStatus(Int)
    case installerRejected
    case installerTimedOut
    case stalePackage

    var errorDescription: String? {
        switch self {
        case .missingDownloadURL:
            return "رابط تحميل التطبيق غير متوفر."
        case .invalidDownloadURL:
            return "رابط تحميل التطبيق غير صالح."
        case .missingSigningAssets:
            return "ملفات الشهادة المطلوبة للتوقيع غير موجودة."
        case .httpStatus(let status):
            return "فشل تحميل التطبيق من الخادم (HTTP \(status))."
        case .installerRejected:
            return "تعذر فتح مثبت iOS عبر GBox. التطبيق محفوظ ويمكن إعادة المحاولة."
        case .installerTimedOut:
            return "لم يبدأ iOS باستلام التطبيق. التطبيق محفوظ ويمكن إعادة المحاولة بدون تنزيله."
        case .stalePackage:
            return "نسخة IPA المحفوظة غير مكتملة وتم حذفها لإعادة تنزيل نسخة سليمة."
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
    private var corruptRetries: [String: Int] = [:]
    private var downloadHolds: [String: UIBackgroundTaskIdentifier] = [:]

    private let signingQueue = DispatchQueue(label: "com.ikiraplus.turath.batsign.signing", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "com.ikiraplus.turath.batsign.export", qos: .utility)

    private var installerServer: BatSignLoopbackIPAInstallServer?
    private var pendingInstallJob: StoreInstallJob?
    private var pendingSignedIPA: URL?
    private var pendingOpenURL: URL?
    private var installTransferStarted = false
    private var installTimeout: DispatchWorkItem?
    private var bootstrapped = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.ikiraplus.turathreplica.batsign.downloads.v2"
        )
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
        restoreJobs()
    }

    func bootstrap() {
        lock.lock()
        let shouldStart = !bootstrapped
        bootstrapped = true
        lock.unlock()
        guard shouldStart else { return }

        _ = session
        _ = backgroundSession
        backgroundSession.getAllTasks { [weak self] tasks in
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
                            message: "جاري استكمال التحميل"
                        )
                    )
                    InstallLiveActivityBridge.begin(job: job)
                } else if StoreDownloadStorage.hasValidStagedIPA(for: job) {
                    self.publishReady(job: job, message: "محمّل ومحفوظ وجاهز للتثبيت")
                    self.removeJob(id)
                } else {
                    self.removeJob(id)
                }
            }
        }
    }

    func state(for appID: String) -> StoreInstallState {
        states[appID] ?? StoreInstallState()
    }

    func state(for app: StoreApp) -> StoreInstallState {
        if let state = states[app.id], state.phase != .idle { return state }
        if StoreDownloadStorage.hasValidStagedIPA(for: app) {
            return StoreInstallState(
                phase: .ready,
                progress: 1,
                message: "محمّل ومحفوظ وجاهز للتثبيت"
            )
        }
        return StoreInstallState()
    }

    func start(_ app: StoreApp) {
        bootstrap()
        if let state = states[app.id], [.downloading, .signing, .installing].contains(state.phase) {
            return
        }

        if let other = pendingInstallJob, other.appID != app.id {
            finishInstallAttemptAsReady(other, message: "تم إيقاف محاولة التثبيت السابقة. الملف ما زال محفوظًا.")
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
            publishFailure(appID: app.id, text: StoreInstallError.missingSigningAssets.localizedDescription)
            return
        }

        setJob(job)
        if let staged = existingStagedIPA(job) {
            beginSigning(job: job, stagedIPA: staged, startLiveActivity: true)
            return
        }
        beginDownload(job)
    }

    func applicationDidBecomeActive() {
        // Legacy safety retry only. The primary path now mirrors BatSign and
        // opens itms-services immediately even while the app is transitioning
        // to the background/Home Screen.
        guard let url = pendingOpenURL, let job = pendingInstallJob else { return }
        pendingOpenURL = nil
        openInstallURL(url, job: job)
    }

    private func beginDownload(_ job: StoreInstallJob) {
        let raw = job.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            fail(job: job, error: StoreInstallError.missingDownloadURL)
            return
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            fail(job: job, error: StoreInstallError.invalidDownloadURL)
            return
        }

        publish(
            appID: job.appID,
            state: StoreInstallState(phase: .downloading, progress: 0, message: "جاري التحميل")
        )
        InstallLiveActivityBridge.begin(job: job)
        beginDownloadHold(job.id)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")

        let task = session.downloadTask(with: request)
        task.taskDescription = job.id
        task.resume()
    }

    private func beginDownloadHold(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.downloadHolds[id] != nil { return }
            var token: UIBackgroundTaskIdentifier = .invalid
            token = UIApplication.shared.beginBackgroundTask(withName: "TurathDownload") { [weak self] in
                self?.endDownloadHold(id)
            }
            if token != .invalid {
                self.downloadHolds[id] = token
            }
        }
    }

    private func endDownloadHold(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let token = self.downloadHolds.removeValue(forKey: id) else { return }
            if token != .invalid {
                UIApplication.shared.endBackgroundTask(token)
            }
        }
    }

    private func existingStagedIPA(_ job: StoreInstallJob) -> URL? {
        if StoreDownloadStorage.hasValidStagedIPA(for: job) {
            return try? StoreDownloadStorage.stagedURL(for: job)
        }
        return StoreDownloadStorage.recoverLegacyExportIfPossible(job: job)
    }

    private func handleFinishedDownload(_ temporaryURL: URL, jobID: String) {
        guard let job = job(jobID) else { return }

        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .signing,
                progress: 0.91,
                message: "جاري تجهيز التطبيق للتوقيع"
            )
        )
        InstallLiveActivityBridge.update(
            job: job,
            phase: .signing,
            progress: 0.91,
            detail: "جاري تجهيز التطبيق للتوقيع",
            force: true
        )

        do {
            let staged = try StoreDownloadStorage.stageFinishedDownload(from: temporaryURL, job: job)
            endDownloadHold(jobID)
            beginSigning(job: job, stagedIPA: staged, startLiveActivity: false)
        } catch StoreDownloadStorageError.sourceMissing {
            endDownloadHold(jobID)
            rescueDownload(job)
        } catch {
            endDownloadHold(jobID)
            fail(job: job, error: error)
        }
    }

    private func rescueDownload(_ job: StoreInstallJob) {
        lock.lock()
        let tries = rescueAttempts[job.id] ?? 0
        rescueAttempts[job.id] = tries + 1
        lock.unlock()

        guard tries == 0, let url = URL(string: job.downloadURL) else {
            fail(job: job, error: StoreDownloadStorageError.sourceMissing)
            return
        }
        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .downloading,
                progress: 0.90,
                message: "جاري استعادة ملف التحميل"
            )
        )
        URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            guard let self else { return }
            if let error { self.fail(job: job, error: error); return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.fail(job: job, error: StoreInstallError.httpStatus(http.statusCode)); return
            }
            guard let location else {
                self.fail(job: job, error: StoreDownloadStorageError.sourceMissing); return
            }
            self.handleFinishedDownload(location, jobID: job.id)
        }.resume()
    }

    private func beginSigning(job: StoreInstallJob, stagedIPA: URL, startLiveActivity: Bool) {
        publish(
            appID: job.appID,
            state: StoreInstallState(phase: .signing, progress: 0.92, message: "جاري التوقيع")
        )
        if startLiveActivity { InstallLiveActivityBridge.begin(job: job) }
        InstallLiveActivityBridge.update(
            job: job,
            phase: .signing,
            progress: 0.92,
            detail: "جاري التوقيع",
            force: true
        )

        // BatSign keeps in-process signing alive when the user is already on the
        // Home Screen. The installer takes its own hold before this one ends.
        StoreInstallKeepAlive.shared.begin("signing-\(job.id)")

        signingQueue.async { [weak self] in
            self?.signThenInstall(job: job, stagedIPA: stagedIPA)
        }
    }

    private func signThenInstall(job: StoreInstallJob, stagedIPA: URL) {
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
        DispatchQueue.main.sync {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "TurathBatSign") {
                if backgroundID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundID)
                    backgroundID = .invalid
                }
            }
        }

        defer {
            DispatchQueue.main.async {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            }
        }

        do {
            let credentials = try SigningAssetProvider.credentials()
            try SigningAssetProvider.validate(credentials: credentials)
            let output = try signedFileURL(job)
            let artifact = try BatSignPackagePipeline.sign(
                ipaURL: stagedIPA,
                job: job,
                credentials: credentials,
                outputURL: output
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publish(
                    appID: job.appID,
                    state: StoreInstallState(
                        phase: .installing,
                        progress: 0.98,
                        message: "جاري فتح مثبت iOS"
                    )
                )
                InstallLiveActivityBridge.update(
                    job: job,
                    phase: .installing,
                    progress: 0.98,
                    detail: "جاري فتح مثبت iOS",
                    force: true
                )

                // Start the localhost hand-off first. Its keep-alive hold is
                // acquired synchronously by start(), so there is no suspension
                // gap when the signing hold is released below.
                self.startInstallServer(job: job, artifact: artifact, originalIPA: stagedIPA)
                StoreInstallKeepAlive.shared.end("signing-\(job.id)")
            }
        } catch let error as BatSignPackageError {
            StoreInstallKeepAlive.shared.end("signing-\(job.id)")
            retryCorruptPackageIfNeeded(job: job, stagedIPA: stagedIPA, error: error)
        } catch {
            StoreInstallKeepAlive.shared.end("signing-\(job.id)")
            fail(job: job, error: error)
        }
    }

    private func retryCorruptPackageIfNeeded(job: StoreInstallJob, stagedIPA: URL, error: Error) {
        lock.lock()
        let attempts = corruptRetries[job.appID] ?? 0
        corruptRetries[job.appID] = attempts + 1
        lock.unlock()

        guard attempts == 0, !job.downloadURL.isEmpty else {
            fail(job: job, error: error)
            return
        }

        try? FileManager.default.removeItem(at: stagedIPA)
        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .downloading,
                progress: 0,
                message: "النسخة المحفوظة غير سليمة · جاري تنزيلها من جديد"
            )
        )
        beginDownload(job)
    }

    private func startInstallServer(
        job: StoreInstallJob,
        artifact: BatSignPackageArtifact,
        originalIPA: URL
    ) {
        cleanupInstallAttempt(deleteSigned: true)
        pendingInstallJob = job
        pendingSignedIPA = artifact.ipaURL
        installTransferStarted = false

        do {
            let server = try BatSignLoopbackIPAInstallServer(fileURL: artifact.ipaURL)
            installerServer = server
            server.start(
                onReady: { [weak self] in
                    guard let self else { return }
                    guard let manifest = Self.gboxManifestURL(artifact),
                          let itms = Self.itmsURL(manifest) else {
                        self.fail(job: job, error: StoreInstallError.installerRejected)
                        return
                    }

                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .installing,
                            progress: 0.99,
                            message: "بانتظار تأكيد التثبيت"
                        )
                    )

                    // This is intentionally unconditional. BatSign does not
                    // wait for applicationState == .active; delaying here is
                    // exactly what caused the long spinner while the user was
                    // looking at the Dynamic Island/Home Screen.
                    self.pendingOpenURL = nil
                    self.openInstallURL(itms, job: job, originalIPA: originalIPA)
                },
                onTransferStarted: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.installTransferStarted = true
                    self.installTimeout?.cancel()
                    self.installTimeout = nil
                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .installing,
                            progress: 0.99,
                            message: "جاري إرسال التطبيق إلى مثبت iOS"
                        )
                    )
                },
                onTransferComplete: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.publishReady(job: job, message: "محمّل ومحفوظ وجاهز لإعادة التثبيت")
                    InstallLiveActivityBridge.finish(job: job, success: true, detail: "تم إرسال التطبيق إلى iOS")
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

    private func openInstallURL(_ url: URL, job: StoreInstallJob, originalIPA: URL? = nil) {
        UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
            guard let self, self.pendingInstallJob?.id == job.id else { return }
            guard accepted else {
                self.fail(job: job, error: StoreInstallError.installerRejected)
                return
            }

            // Do not compete with the hand-off for disk I/O. The user's Files
            // copy is best-effort and starts only after the system has already
            // been asked to present the official confirmation.
            if let originalIPA {
                self.exportQueue.asyncAfter(deadline: .now() + 8) {
                    _ = StoreDownloadStorage.exportToFiles(stagedURL: originalIPA, job: job)
                }
            }

            let timeout = DispatchWorkItem { [weak self] in
                guard let self,
                      self.pendingInstallJob?.id == job.id,
                      !self.installTransferStarted else { return }
                self.finishInstallAttemptAsReady(
                    job,
                    message: "لم يبدأ مثبت iOS باستلام التطبيق. الملف محفوظ وجاهز لإعادة المحاولة."
                )
            }
            self.installTimeout?.cancel()
            self.installTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
        }
    }

    private static func gboxManifestURL(_ artifact: BatSignPackageArtifact) -> URL? {
        let descriptor = "\(artifact.name)/\(artifact.bundleID)/\(artifact.version)"
        let base64 = Data(descriptor.utf8).base64EncodedString()
        let encoded = base64.replacingOccurrences(of: "=", with: "%3D")
        return URL(string: "https://i.gbox.run/\(encoded).plist")
    }

    private static func itmsURL(_ manifest: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifest.absoluteString)
        ]
        return components.url
    }

    private func signedFileURL(_ job: StoreInstallJob) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BatSignSigned", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(job.id)-signed.ipa")
    }

    private func finishInstallAttemptAsReady(_ job: StoreInstallJob, message: String) {
        publishReady(job: job, message: message)
        InstallLiveActivityBridge.finish(job: job, success: true, detail: "محفوظ وجاهز للتثبيت")
        cleanupInstallAttempt(deleteSigned: true)
        removeJob(job.id)
    }

    private func cleanupInstallAttempt(deleteSigned: Bool) {
        installTimeout?.cancel()
        installTimeout = nil
        installerServer?.stop()
        installerServer = nil
        if deleteSigned, let signed = pendingSignedIPA { try? FileManager.default.removeItem(at: signed) }
        pendingInstallJob = nil
        pendingSignedIPA = nil
        pendingOpenURL = nil
        installTransferStarted = false
    }

    private func fail(job: StoreInstallJob, error: Error) {
        StoreInstallKeepAlive.shared.end("signing-\(job.id)")
        endDownloadHold(job.id)
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let cached = StoreDownloadStorage.hasValidStagedIPA(for: job)
        if pendingInstallJob?.id == job.id { cleanupInstallAttempt(deleteSigned: true) }

        if cached {
            publish(
                appID: job.appID,
                state: StoreInstallState(
                    phase: .ready,
                    progress: 1,
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
            state: StoreInstallState(phase: .ready, progress: 1, message: message)
        )
    }

    private func publishFailure(appID: String, text: String) {
        publish(
            appID: appID,
            state: StoreInstallState(
                phase: .failed,
                progress: 0,
                message: text,
                errorMessage: text
            )
        )
    }

    private func publish(appID: String, state: StoreInstallState) {
        DispatchQueue.main.async { [weak self] in self?.states[appID] = state }
    }

    private var jobsFile: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BatSignCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs.json")
    }

    private func restoreJobs() {
        guard let file = jobsFile,
              let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: StoreInstallJob].self, from: data) else { return }
        jobs = saved
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
        endDownloadHold(id)
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
            ? min(0.90, max(0, Double(totalBytesWritten) / Double(expected) * 0.90))
            : 0

        let now = Date()
        var speed: Double = 0
        lock.lock()
        if let previous = samples[id] {
            let dt = now.timeIntervalSince(previous.date)
            if dt >= 1.0 {
                let measured = Double(max(0, totalBytesWritten - previous.bytes)) / dt
                if measured > 0 { speed = measured }
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
        guard let id = downloadTask.taskDescription, let job = job(id) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            endDownloadHold(id)
            fail(job: job, error: StoreInstallError.httpStatus(response.statusCode))
            return
        }
        handleFinishedDownload(location, jobID: id)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let id = task.taskDescription,
              let job = job(id) else { return }
        endDownloadHold(id)
        if StoreDownloadStorage.hasValidStagedIPA(for: job) { return }
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
