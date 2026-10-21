import Foundation
import ActivityKit

@available(iOS 16.1, *)
final class InstallLiveActivityController {
    static let shared = InstallLiveActivityController()

    private struct PendingUpdate {
        let phase: InstallActivityAttributes.Phase
        let progress: Double
        let detail: String
        let speed: String?
    }

    private var activity: Activity<InstallActivityAttributes>?
    private var activeJobID: String?
    private var lastPush = Date.distantPast
    private var lastPublishedProgress: Double = 0
    private var pendingUpdate: PendingUpdate?
    private var flushTask: Task<Void, Never>?

    /// Keep local ActivityKit updates responsive without flooding the system.
    /// The newest skipped update is queued and flushed instead of being lost.
    private let updateCadence: TimeInterval = 0.8

    func begin(job: StoreInstallJob) {
        Task { @MainActor in
            await self.beginOnMain(job: job)
        }
    }

    @MainActor
    private func beginOnMain(job: StoreInstallJob) async {
        if activeJobID == job.id, activity != nil {
            return
        }

        flushTask?.cancel()
        flushTask = nil
        pendingUpdate = nil
        lastPublishedProgress = 0

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
            activity = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            activeJobID = job.id
            lastPush = Date()
        } catch {
            activity = nil
            activeJobID = nil
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
            if self.activeJobID != job.id || self.activity == nil {
                await self.beginOnMain(job: job)
            }

            guard self.activeJobID == job.id, self.activity != nil else { return }

            let mappedPhase = self.activityPhase(for: phase)
            let visibleProgress = self.visibleProgress(for: phase, rawProgress: progress)
            let monotonicProgress = max(self.lastPublishedProgress, visibleProgress)

            self.pendingUpdate = PendingUpdate(
                phase: mappedPhase,
                progress: monotonicProgress,
                detail: detail,
                speed: phase == .downloading ? detail : nil
            )

            if force || Date().timeIntervalSince(self.lastPush) >= self.updateCadence {
                await self.flushPendingUpdate()
            } else {
                self.schedulePendingFlush()
            }
        }
    }

    @MainActor
    private func activityPhase(for phase: StoreInstallPhase) -> InstallActivityAttributes.Phase {
        switch phase {
        case .idle, .downloading:
            return .downloading
        case .ready, .complete:
            return .complete
        case .signing:
            return .signing
        case .installing:
            return .installing
        case .failed:
            return .failed
        }
    }

    @MainActor
    private func visibleProgress(for phase: StoreInstallPhase, rawProgress: Double) -> Double {
        switch phase {
        case .downloading:
            // InstallEngine reserves the last 10% for signing/install.
            // The in-app pill already converts 0...0.90 back to true download 0...100%.
            // Do the same here so Dynamic Island always matches the app.
            return max(0, min(1, rawProgress / 0.90))
        case .ready, .signing, .installing, .complete:
            return 1
        case .idle, .failed:
            return max(0, min(1, rawProgress))
        }
    }

    @MainActor
    private func schedulePendingFlush() {
        guard flushTask == nil else { return }

        let elapsed = Date().timeIntervalSince(lastPush)
        let delay = max(0.05, updateCadence - elapsed)
        let nanoseconds = UInt64(delay * 1_000_000_000)

        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            await self.flushPendingUpdate()
        }
    }

    @MainActor
    private func flushPendingUpdate() async {
        guard let activity, let update = pendingUpdate else { return }

        pendingUpdate = nil
        let state = InstallActivityAttributes.ContentState(
            phase: update.phase,
            progress: update.progress,
            detail: update.detail,
            speed: update.speed
        )

        await activity.update(using: state)
        lastPublishedProgress = max(lastPublishedProgress, update.progress)
        lastPush = Date()

        // If a newer URLSession progress callback arrived while ActivityKit was updating,
        // do not drop it. Queue one more flush at the normal cadence.
        if pendingUpdate != nil {
            schedulePendingFlush()
        }
    }

    func finish(job: StoreInstallJob, success: Bool, detail: String) {
        Task { @MainActor in
            guard activeJobID == job.id, let activity else { return }

            flushTask?.cancel()
            flushTask = nil
            pendingUpdate = nil

            let state = InstallActivityAttributes.ContentState(
                phase: success ? .complete : .failed,
                progress: success ? 1 : lastPublishedProgress,
                detail: detail,
                speed: nil
            )
            await activity.update(using: state)
            try? await Task.sleep(nanoseconds: success ? 2_500_000_000 : 5_000_000_000)
            await activity.end(using: state, dismissalPolicy: .immediate)

            self.activity = nil
            self.activeJobID = nil
            self.lastPublishedProgress = 0
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
