import Foundation
import ActivityKit

@available(iOS 16.1, *)
final class InstallLiveActivityController {
    static let shared = InstallLiveActivityController()

    private var activity: Activity<InstallActivityAttributes>?
    private var activeJobID: String?
    private var lastPush = Date.distantPast
    private var startedAt = Date.distantPast

    func begin(job: StoreInstallJob) {
        Task { @MainActor in
            if activeJobID != job.id {
                if let old = activity {
                    await old.end(using: nil, dismissalPolicy: .immediate)
                }
                let attributes = InstallActivityAttributes(
                    appName: job.appName,
                    bundleID: job.bundleID,
                    iconURL: job.iconURL
                )
                let state = InstallActivityAttributes.ContentState(
                    phase: .downloading,
                    progress: 0,
                    detail: "جاري التحميل",
                    speed: nil
                )
                do {
                    activity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
                    activeJobID = job.id
                    lastPush = Date()
                    startedAt = Date()
                } catch {
                    activity = nil
                    activeJobID = nil
                }
            }
        }
    }

    func update(
        job: StoreInstallJob,
        phase: StoreInstallPhase,
        progress: Double,
        detail: String,
        force: Bool
    ) {
        Task { @MainActor in
            guard activeJobID == job.id, let activity else {
                begin(job: job)
                return
            }

            let age = Date().timeIntervalSince(startedAt)
            let cadence: TimeInterval
            switch age {
            case 0..<120: cadence = 1.8
            case 120..<600: cadence = 4.5
            default: cadence = 12
            }
            guard force || Date().timeIntervalSince(lastPush) >= cadence else { return }

            let state = InstallActivityAttributes.ContentState(
                phase: InstallActivityAttributes.Phase(rawValue: phase.rawValue) ?? .downloading,
                progress: progress,
                detail: detail,
                speed: phase == .downloading ? detail : nil
            )
            await activity.update(using: state)
            lastPush = Date()
        }
    }

    func finish(job: StoreInstallJob, success: Bool, detail: String) {
        Task { @MainActor in
            guard activeJobID == job.id, let activity else { return }
            let state = InstallActivityAttributes.ContentState(
                phase: success ? .complete : .failed,
                progress: success ? 1 : 0,
                detail: detail,
                speed: nil
            )
            await activity.update(using: state)
            try? await Task.sleep(nanoseconds: success ? 2_500_000_000 : 5_000_000_000)
            await activity.end(using: state, dismissalPolicy: .immediate)
            self.activity = nil
            self.activeJobID = nil
        }
    }
}

enum InstallLiveActivityBridge {
    static func begin(job: StoreInstallJob) {
        if #available(iOS 16.1, *) {
            InstallLiveActivityController.shared.begin(job: job)
        }
    }

    static func update(
        job: StoreInstallJob,
        phase: StoreInstallPhase,
        progress: Double,
        detail: String,
        force: Bool
    ) {
        if #available(iOS 16.1, *) {
            InstallLiveActivityController.shared.update(
                job: job,
                phase: phase,
                progress: progress,
                detail: detail,
                force: force
            )
        }
    }

    static func finish(job: StoreInstallJob, success: Bool, detail: String) {
        if #available(iOS 16.1, *) {
            InstallLiveActivityController.shared.finish(job: job, success: success, detail: detail)
        }
    }
}
