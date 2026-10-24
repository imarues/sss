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
            return "تعذر تسليم طلب التثبيت إلى iOS. التطبيق محفوظ ويمكن إعادة المحاولة."
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

    func applicationDidEnterBackground(_ application: UIApplication) {
        StoreInstallKeepAlive.shared.reaffirm()
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

    // BatSign keeps the server alive before the install package exists. The
    // finished archive is assigned to it at the last possible moment.
    private var installerServer: BatSignLoopbackIPAInstallServer?
    private var installerServerReady = false
    private var pendingInstallJob: StoreInstallJob?
    private var pendingArtifact: BatSignPackageArtifact?
    private var pendingSignedIPA: URL?
    private var pendingOriginalIPA: URL?
    private var installTransferStarted = false

    // UIApplication.open only tells us whether the system accepted the ask.
    // A refused hand-off is left Ready for manual retry; accepted asks are never duplicated.
    private var pendingHandOffURL: URL?
    private var handOffAccepted = false
    private var handOffAttempts = 0
    private var handOffRetry: DispatchWorkItem?
    private var handOffStallTimeout: DispatchWorkItem?
    // A transfer can be canceled after it starts; reset this watchdog only
    // while the loopback server continues sending data.
    private var transferStallTimeout: DispatchWorkItem?

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
        let sourceIcon = app.iconUrl?.isEmpty == false
            ? app.iconUrl
            : TransferActivityCenter.shared.trackedApp(id: app.id)?.iconUrl
        let job = StoreInstallJob(
            id: UUID().uuidString,
            appID: app.id,
            appName: app.name,
            bundleID: app.bundleId ?? app.id,
            version: app.version ?? "1.0",
            iconURL: sourceIcon,
            downloadURL: raw,
            expectedBytes: app.fileSize ?? 0
        )

        // Download and preserve IPA even when a certificate is not yet set up.
        setJob(job)
        if let staged = existingStagedIPA(job) {
            beginSigning(job: job, stagedIPA: staged, startLiveActivity: true)
            return
        }
        beginDownload(job)
    }

    func applicationDidBecomeActive() {
        StoreInstallKeepAlive.shared.reaffirm()

        // iOS never reports whether the user pressed Install or Cancel in
        // its system sheet. The row is already Ready when the sheet opens.
        // Keep the server available for an eventual real IPA GET request:
        // foregrounding alone is not evidence that installation was denied.
        if handOffAccepted { return }

        // If iOS explicitly refused an earlier background ask, foregrounding is
        // a free moment to offer it again. Never repeat an accepted request.
        guard !handOffAccepted,
              let url = pendingHandOffURL,
              let job = pendingInstallJob,
              !installTransferStarted else { return }
        offerInstallURL(url, job: job)
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

        // BatSign treats transfer + unpacking as one progress journey. Do not
        // park the UI at a fake final 100% before the package has been adopted.
        publish(
            appID: job.appID,
            state: StoreInstallState(
                phase: .downloading,
                progress: 0.64,
                message: "جاري تجهيز الحزمة"
            )
        )
        InstallLiveActivityBridge.update(
            job: job,
            phase: .downloading,
            progress: 0.64,
            detail: "جاري تجهيز الحزمة",
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
                progress: 0.63,
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
        // Export the unmodified source into Downloads before any signing attempt.
        // Never make certificate problems invalidate or remove this saved IPA.
        _ = StoreDownloadStorage.exportToFiles(stagedURL: stagedIPA, job: job)
        guard SigningAssetProvider.hasCredentials else {
            publish(
                appID: job.appID,
                state: StoreInstallState(
                    phase: .ready,
                    progress: 1,
                    message: "تم حفظ IPA في تنزيلاتي. أضف شهادة صالحة ثم أعد المحاولة."
                )
            )
            return
        }
        if startLiveActivity { InstallLiveActivityBridge.begin(job: job) }

        // Exactly like BatSign's ServerInstaller: bind 9800 before archive work
        // begins. When the archive becomes ready there is no server startup on
        // the critical path to the official confirmation.
        let prewarm = {
            self.prepareInstallServer(job: job, originalIPA: stagedIPA)
        }
        if Thread.isMainThread { prewarm() }
        else { DispatchQueue.main.sync(execute: prewarm) }

        StoreInstallKeepAlive.shared.begin("signing-\(job.id)")
        signingQueue.async { [weak self] in
            self?.signThenInstall(job: job, stagedIPA: stagedIPA)
        }
    }

    private func signThenInstall(job: StoreInstallJob, stagedIPA: URL) {
        do {
            let credentials = try SigningAssetProvider.credentials()
            try SigningAssetProvider.validate(credentials: credentials)
            let output = try signedFileURL(job)

            let artifact = try BatSignPackagePipeline.sign(
                ipaURL: stagedIPA,
                job: job,
                credentials: credentials,
                outputURL: output,
                progress: { [weak self] stage, value in
                    self?.publishPackageProgress(job: job, stage: stage, value: value)
                }
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingInstallJob?.id == job.id else { return }
                self.pendingArtifact = artifact
                self.pendingSignedIPA = artifact.ipaURL
                self.installerServer?.fileURL = artifact.ipaURL

                self.publish(
                    appID: job.appID,
                    state: StoreInstallState(
                        phase: .ready,
                        progress: 1,
                        message: "IPA موقّع ومحفوظ · جاري فتح تأكيد iOS"
                    )
                )
                InstallLiveActivityBridge.update(
                    job: job,
                    phase: .installing,
                    progress: 0.99,
                    detail: "جاري فتح مثبت iOS",
                    force: true
                )

                // The server's hold has been active since beginSigning, so the
                // signing hold can end with no suspendable gap.
                StoreInstallKeepAlive.shared.end("signing-\(job.id)")
                self.offerInstallIfReady(job: job)
            }
        } catch let error as BatSignPackageError {
            StoreInstallKeepAlive.shared.end("signing-\(job.id)")
            retryCorruptPackageIfNeeded(job: job, stagedIPA: stagedIPA, error: error)
        } catch {
            StoreInstallKeepAlive.shared.end("signing-\(job.id)")
            fail(job: job, error: error)
        }
    }

    private func publishPackageProgress(job: StoreInstallJob, stage: BatSignPackageStage, value: Double) {
        let p = max(0, min(1, value))
        switch stage {
        case .unpacking:
            // BatSign's Download.overallProgress gives transfer 70% and
            // unpacking 30%. Our pill expects download progress in 0...0.90,
            // so the equivalent visible range is roughly 70...100%.
            let raw = 0.63 + (0.27 * p)
            publish(
                appID: job.appID,
                state: StoreInstallState(phase: .downloading, progress: raw, message: "جاري فك الحزمة")
            )
            InstallLiveActivityBridge.update(
                job: job,
                phase: .downloading,
                progress: raw,
                detail: "جاري فك الحزمة",
                force: false
            )
        case .signing:
            publish(
                appID: job.appID,
                state: StoreInstallState(phase: .signing, progress: 0.93, message: "جاري التوقيع")
            )
            InstallLiveActivityBridge.update(
                job: job,
                phase: .signing,
                progress: 0.93,
                detail: "جاري التوقيع",
                force: p >= 1
            )
        case .packaging:
            publish(
                appID: job.appID,
                state: StoreInstallState(phase: .signing, progress: 0.95 + (0.03 * p), message: "جاري تجهيز IPA")
            )
            InstallLiveActivityBridge.update(
                job: job,
                phase: .signing,
                progress: 0.95 + (0.03 * p),
                detail: "جاري تجهيز IPA",
                force: false
            )
        }
    }

    private func prepareInstallServer(job: StoreInstallJob, originalIPA: URL) {
        cleanupInstallAttempt(deleteSigned: true)
        pendingInstallJob = job
        pendingOriginalIPA = originalIPA
        pendingArtifact = nil
        pendingSignedIPA = nil
        installerServerReady = false
        installTransferStarted = false
        pendingHandOffURL = nil
        handOffAccepted = false
        handOffAttempts = 0

        do {
            let server = try BatSignLoopbackIPAInstallServer()
            installerServer = server
            server.start(
                onReady: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.installerServerReady = true
                    self.offerInstallIfReady(job: job)
                },
                onTransferStarted: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id else { return }
                    self.installTransferStarted = true
                    self.handOffRetry?.cancel()
                    self.handOffRetry = nil
                    self.handOffStallTimeout?.cancel()
                    self.handOffStallTimeout = nil
                    self.scheduleTransferStallSafety(job: job)
                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .installing,
                            progress: 0.995,
                            message: "جاري إرسال التطبيق إلى iOS"
                        )
                    )
                },
                onTransferActivity: { [weak self] in
                    guard let self, self.pendingInstallJob?.id == job.id,
                          self.installTransferStarted else { return }
                    self.scheduleTransferStallSafety(job: job)
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

    private func offerInstallIfReady(job: StoreInstallJob) {
        guard pendingInstallJob?.id == job.id,
              installerServerReady,
              let artifact = pendingArtifact,
              installerServer?.fileURL != nil else { return }

        guard let manifest = Self.gboxManifestURL(artifact),
              let itms = Self.itmsURL(manifest) else {
            fail(job: job, error: StoreInstallError.installerRejected)
            return
        }

        // Only one initial ask. A second ask is legal only when iOS explicitly
        // declined the previous UIApplication.open call.
        if pendingHandOffURL == nil {
            pendingHandOffURL = itms
            offerInstallURL(itms, job: job)
        }
    }

    private func offerInstallURL(_ url: URL, job: StoreInstallJob) {
        guard pendingInstallJob?.id == job.id, !installTransferStarted else { return }
        if handOffAccepted { return }

        handOffRetry?.cancel()
        handOffRetry = nil
        handOffAttempts += 1

        UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
            guard let self, self.pendingInstallJob?.id == job.id else { return }
            self.handOffAccepted = accepted

            if accepted {
                // UIApplication.open means iOS showed/accepted the system
                // hand-off request, NOT that the user approved installation.
                // Display Ready immediately. Never spin for up to 180 seconds
                // after the user chooses Cancel in the iOS prompt.
                if !self.installTransferStarted {
                    self.publishReady(
                        job: job,
                        message: "IPA محفوظ وجاهز · يمكنك تأكيد أو إلغاء التثبيت من iOS"
                    )
                    InstallLiveActivityBridge.finish(
                        job: job,
                        success: true,
                        detail: "IPA جاهز · تم عرض طلب التثبيت"
                    )
                }

                if let original = self.pendingOriginalIPA {
                    self.exportQueue.asyncAfter(deadline: .now() + 6) {
                        _ = StoreDownloadStorage.exportToFiles(stagedURL: original, job: job)
                    }
                }

                // Do not stop the server yet. If the user actually confirms,
                // iOS will request /app.ipa and onTransferStarted will track it.
                self.scheduleAcceptedHandOffSafety(job: job)
                return
            }

            // An explicitly refused system URL request isn't a reason to
            // retry the iOS popup repeatedly. Keep the signed/staged IPA.
            if !self.installTransferStarted {
                self.finishInstallAttemptAsReady(
                    job,
                    message: "لم يُفتح تأكيد التثبيت. IPA محفوظ وجاهز لإعادة المحاولة."
                )
            }
        }
    }

    private func scheduleAcceptedHandOffSafety(job: StoreInstallJob) {
        handOffStallTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingInstallJob?.id == job.id,
                  !self.installTransferStarted else { return }
            self.finishInstallAttemptAsReady(
                job,
                message: "تم عرض طلب التثبيت ولم يبدأ نقل IPA. الملف محفوظ وجاهز لإعادة المحاولة."
            )
        }
        handOffStallTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: work)
    }

    private func scheduleTransferStallSafety(job: StoreInstallJob) {
        transferStallTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingInstallJob?.id == job.id,
                  self.installTransferStarted else { return }
            self.finishInstallAttemptAsReady(
                job,
                message: "توقف نقل IPA إلى iOS. الملف محفوظ وجاهز لإعادة المحاولة."
            )
        }
        transferStallTimeout = work
        // This timer is reset as long as iOS keeps receiving bytes, so large
        // valid installations are not cut off by a fixed overall timeout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 95, execute: work)
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

        cleanupInstallAttempt(deleteSigned: true)
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
        handOffRetry?.cancel()
        handOffRetry = nil
        handOffStallTimeout?.cancel()
        handOffStallTimeout = nil
        transferStallTimeout?.cancel()
        transferStallTimeout = nil
        installerServer?.stop()
        installerServer = nil
        installerServerReady = false

        if deleteSigned, let signed = pendingSignedIPA {
            try? FileManager.default.removeItem(at: signed)
        }
        pendingInstallJob = nil
        pendingArtifact = nil
        pendingSignedIPA = nil
        pendingOriginalIPA = nil
        installTransferStarted = false
        pendingHandOffURL = nil
        handOffAccepted = false
        handOffAttempts = 0
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

        // BatSign's overall progress assigns 70% to the network transfer and
        // the final 30% to package preparation. Components.swift maps 0...0.90
        // to 0...100%, so 0.63 is the equivalent 70% hand-off point.
        let progress = expected > 0
            ? min(0.63, max(0, Double(totalBytesWritten) / Double(expected) * 0.63))
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
