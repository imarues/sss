import Foundation
import UIKit
import Network
import ActivityKit
import ZIPFoundation
import Zip
import ZSign
import Security

enum StoreInstallPhase: String, Codable {
    case idle, downloading, signing, installing, complete, failed
}

struct StoreInstallState: Equatable {
    var phase: StoreInstallPhase = .idle
    var progress: Double = 0
    var speedText: String?
    var message: String?
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
    case invalidArchive
    case signingFailed
    case manifestURL
    case httpStatus(Int)
    case installerRejected

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
        case .signingFailed:
            return "فشل توقيع التطبيق. تحقق من الشهادة وملف MobileProvision."
        case .manifestURL:
            return "تعذر إنشاء رابط التثبيت."
        case .httpStatus(let status):
            return "فشل تحميل التطبيق من الخادم (HTTP \(status))."
        case .installerRejected:
            return "تعذر فتح مثبت iOS. أعد المحاولة وتأكد من السماح بفتح رابط التثبيت."
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
        StoreInstallCoordinator.shared.retryPendingInstallHandOff()
    }
}

final class StoreInstallCoordinator: NSObject, ObservableObject {
    static let shared = StoreInstallCoordinator()

    @Published private(set) var states: [String: StoreInstallState] = [:]

    var backgroundSessionCompletion: (() -> Void)?
    private let lock = NSLock()
    private var jobs: [String: StoreInstallJob] = [:]
    private var samples: [String: (date: Date, bytes: Int64)] = [:]
    private let signingQueue = DispatchQueue(label: "com.ikiraplus.turath.signing", qos: .userInitiated)
    private var installerServer: LoopbackIPAInstallServer?
    private var pendingInstallURL: URL?
    private var bootstrapped = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.ikiraplus.turathreplica.downloads")
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
            for (id, job) in known where activeIDs.contains(id) {
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
            }
        }
    }

    func state(for appID: String) -> StoreInstallState {
        states[appID] ?? StoreInstallState()
    }

    func start(_ app: StoreApp) {
        bootstrap()

        guard let raw = app.effectiveDownloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            publish(
                appID: app.id,
                state: StoreInstallState(
                    phase: .failed,
                    progress: 0,
                    speedText: nil,
                    message: StoreInstallError.missingDownloadURL.localizedDescription
                )
            )
            return
        }

        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            publish(
                appID: app.id,
                state: StoreInstallState(
                    phase: .failed,
                    progress: 0,
                    speedText: nil,
                    message: StoreInstallError.invalidDownloadURL.localizedDescription
                )
            )
            return
        }

        if let current = states[app.id], [.downloading, .signing, .installing].contains(current.phase) {
            return
        }

        guard SigningAssetProvider.hasCredentials else {
            publish(
                appID: app.id,
                state: StoreInstallState(
                    phase: .failed,
                    progress: 0,
                    speedText: nil,
                    message: StoreInstallError.missingSigningAssets.localizedDescription
                )
            )
            return
        }

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

        setJob(job)
        publish(
            appID: app.id,
            state: StoreInstallState(phase: .downloading, progress: 0, speedText: nil, message: "جاري التحميل")
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

    func retryPendingInstallHandOff() {
        guard UIApplication.shared.applicationState == .active,
              let url = pendingInstallURL else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
            if accepted {
                self?.pendingInstallURL = nil
            }
        }
    }

    private func downloadedFileURL(for job: StoreInstallJob) throws -> URL {
        let root = try downloadsDirectory()
        return root.appendingPathComponent(job.id + ".ipa")
    }

    private func signedFileURL(for job: StoreInstallJob) throws -> URL {
        let root = try downloadsDirectory()
        return root.appendingPathComponent(job.id + "-signed.ipa")
    }

    private func downloadsDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("TurathDownloads", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func handleFinishedDownload(tempURL: URL, jobID: String) {
        guard let job = job(jobID) else { return }

        do {
            let target = try downloadedFileURL(for: job)
            let fm = FileManager.default
            try? fm.removeItem(at: target)
            try fm.moveItem(at: tempURL, to: target)

            publish(
                appID: job.appID,
                state: StoreInstallState(phase: .signing, progress: 0.92, speedText: nil, message: "جاري التوقيع")
            )
            InstallLiveActivityBridge.update(
                job: job,
                phase: .signing,
                progress: 0.92,
                detail: "جاري التوقيع",
                force: true
            )

            signingQueue.async { [weak self] in
                self?.signThenInstall(job: job, ipaURL: target)
            }
        } catch {
            fail(job: job, error: error)
        }
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
            try? FileManager.default.removeItem(at: ipaURL)
            DispatchQueue.main.async {
                if backgroundID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundID)
                }
            }
        }

        do {
            let signed = try sign(job: job, ipaURL: ipaURL)
            DispatchQueue.main.async { [weak self] in
                self?.publish(
                    appID: job.appID,
                    state: StoreInstallState(
                        phase: .installing,
                        progress: 0.98,
                        speedText: nil,
                        message: "جاري تجهيز التثبيت"
                    )
                )
                InstallLiveActivityBridge.update(
                    job: job,
                    phase: .installing,
                    progress: 0.98,
                    detail: "جاري تجهيز التثبيت",
                    force: true
                )
                self?.startInstallServer(job: job, signedIPA: signed)
            }
        } catch {
            fail(job: job, error: error)
        }
    }

    private func sign(job: StoreInstallJob, ipaURL: URL) throws -> URL {
        let fm = FileManager.default
        let credentials = try SigningAssetProvider.credentials()
        try SigningAssetProvider.validate(credentials: credentials)

        let workingRoot = fm.temporaryDirectory.appendingPathComponent("TurathSign-\(job.id)", isDirectory: true)
        try? fm.removeItem(at: workingRoot)
        try fm.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workingRoot) }

        do {
            try fm.unzipItem(at: ipaURL, to: workingRoot)
        } catch {
            throw StoreInstallError.invalidArchive
        }

        let payload = workingRoot.appendingPathComponent("Payload", isDirectory: true)
        let apps = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let appURL = apps.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw StoreInstallError.invalidArchive
        }

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
        guard code == 0 else { throw StoreInstallError.signingFailed }

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
        return output
    }

    private func startInstallServer(job: StoreInstallJob, signedIPA: URL) {
        installerServer?.stop()
        installerServer = nil

        do {
            let server = try LoopbackIPAInstallServer(fileURL: signedIPA)
            installerServer = server
            server.start(
                onReady: { [weak self] in
                    guard let self else { return }
                    guard let link = Self.installURL(job: job) else {
                        self.installerServer?.stop()
                        self.installerServer = nil
                        try? FileManager.default.removeItem(at: signedIPA)
                        self.fail(job: job, error: StoreInstallError.manifestURL)
                        return
                    }

                    self.pendingInstallURL = link
                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .installing,
                            progress: 0.99,
                            speedText: nil,
                            message: "جاري إرسال التطبيق إلى مثبت iOS"
                        )
                    )

                    if UIApplication.shared.applicationState == .active {
                        UIApplication.shared.open(link, options: [:]) { [weak self] accepted in
                            guard let self else { return }
                            if accepted {
                                self.pendingInstallURL = nil
                            } else {
                                self.installerServer?.stop()
                                self.installerServer = nil
                                try? FileManager.default.removeItem(at: signedIPA)
                                self.fail(job: job, error: StoreInstallError.installerRejected)
                            }
                        }
                    }
                },
                onTransferComplete: { [weak self] in
                    guard let self else { return }
                    self.pendingInstallURL = nil
                    self.publish(
                        appID: job.appID,
                        state: StoreInstallState(
                            phase: .complete,
                            progress: 1,
                            speedText: nil,
                            message: "تم إرسال التطبيق إلى مثبت iOS"
                        )
                    )
                    InstallLiveActivityBridge.finish(job: job, success: true, detail: "تم إرسال التطبيق للتثبيت")
                    self.removeJob(job.id)
                    self.installerServer?.stop()
                    self.installerServer = nil
                    try? FileManager.default.removeItem(at: signedIPA)
                },
                onFailure: { [weak self] error in
                    guard let self else { return }
                    self.pendingInstallURL = nil
                    self.installerServer?.stop()
                    self.installerServer = nil
                    try? FileManager.default.removeItem(at: signedIPA)
                    self.fail(job: job, error: error)
                }
            )
        } catch {
            try? FileManager.default.removeItem(at: signedIPA)
            fail(job: job, error: error)
        }
    }

    private static func installURL(job: StoreInstallJob) -> URL? {
        let descriptor = "\(job.appName)/\(job.bundleID)/\(job.version)"
        let token = Data(descriptor.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "%3D")
        guard let manifest = URL(string: "https://i.gbox.run/\(token).plist") else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifest.absoluteString)
        ]
        return components.url
    }

    private func fail(job: StoreInstallJob, error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        publish(
            appID: job.appID,
            state: StoreInstallState(phase: .failed, progress: 0, speedText: nil, message: text)
        )
        InstallLiveActivityBridge.finish(job: job, success: false, detail: text)
        removeJob(job.id)
    }

    private func publish(appID: String, state: StoreInstallState) {
        DispatchQueue.main.async { [weak self] in
            self?.states[appID] = state
        }
    }

    private var jobsFile: URL? {
        guard let root = try? downloadsDirectory() else { return nil }
        return root.appendingPathComponent("jobs.json")
    }

    private func restoreJobs() {
        guard let file = jobsFile,
              let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: StoreInstallJob].self, from: data) else { return }
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
        let progress = expected > 0 ? min(0.90, (Double(totalBytesWritten) / Double(expected)) * 0.90) : 0

        let now = Date()
        var speed: Double = 0
        lock.lock()
        if let old = samples[id] {
            let dt = now.timeIntervalSince(old.date)
            if dt > 0.35 {
                speed = Double(totalBytesWritten - old.bytes) / dt
                samples[id] = (now, totalBytesWritten)
            }
        } else {
            samples[id] = (now, totalBytesWritten)
        }
        lock.unlock()

        let speedText = speed > 0
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
