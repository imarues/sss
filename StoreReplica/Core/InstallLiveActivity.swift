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
    private var pendingUpdate: PendingUpdate?
    private var pendingIsUrgent = false
    private var isPushing = false
    private var flushTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var generation = 0

    private var lastState: PendingUpdate?
    private var lastPushedAt: Date?
    private var lastPushedPhase: InstallActivityAttributes.Phase?
    private var lastPublishedProgress: Double = 0
    private var jobStartedAt: Date?
    private var firstContentIsFree = false

    private func currentGap() -> TimeInterval {
        guard let started = jobStartedAt else { return 2.0 }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 600 { return 15.0 }
        if elapsed > 120 { return 5.0 }
        return 2.0
    }

    /// End cards left behind by an older process/build. ActivityKit keeps them
    /// outside this singleton, so only looking at `activity` misses exactly the
    /// stale red-X card seen after a relaunch.
    func cleanupStale() {
        Task { @MainActor in
            let keepID = self.activeJobID == nil ? nil : self.activity?.id
            await self.endSystemActivities(except: keepID)
            if keepID == nil {
                self.activity = nil
                self.activeJobID = nil
            }
        }
    }

    func begin(job: StoreInstallJob) {
        Task { @MainActor in
            await self.beginOnMain(job: job)
        }
    }

    @MainActor
    private func beginOnMain(job: StoreInstallJob) async {
        if activeJobID == job.id, activity != nil { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        generation &+= 1
        let myGeneration = generation
        resetTransientState()
        jobStartedAt = Date()
        firstContentIsFree = true

        if let old = activity {
            await old.end(using: nil, dismissalPolicy: .immediate)
        }
        activity = nil
        activeJobID = nil

        // One install = one fresh card. Remove every orphan from prior runs
        // before requesting the new activity so iOS never shows an old failure
        // in place of the current download.
        await endSystemActivities(except: nil)

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
            let fresh = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            guard generation == myGeneration else {
                await fresh.end(using: nil, dismissalPolicy: .immediate)
                return
            }
            activity = fresh
            activeJobID = job.id
            lastPushedAt = Date()
            lastPushedPhase = .downloading
            lastState = PendingUpdate(
                phase: .downloading,
                progress: 0,
                detail: "جاري التحميل",
                speed: nil
            )
            startKeepAlive(generation: myGeneration)
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
            let visible = self.visibleProgress(for: phase, rawProgress: progress)
            let monotonic = mappedPhase == .failed
                ? visible
                : max(self.lastPublishedProgress, visible)
            let phaseChanged = mappedPhase != self.lastPushedPhase

            self.pendingUpdate = PendingUpdate(
                phase: mappedPhase,
                progress: monotonic,
                detail: detail,
                speed: phase == .downloading ? detail : nil
            )
            self.pendingIsUrgent = self.pendingIsUrgent || force || phaseChanged
            await self.drain()
        }
    }

    @MainActor
    private func drain() async {
        guard !isPushing, let update = pendingUpdate, let activity else { return }

        let now = Date()
        let elapsed = lastPushedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let urgent = pendingIsUrgent || firstContentIsFree || update.phase != lastPushedPhase
        let gap = currentGap()

        if !urgent && elapsed < gap {
            scheduleDrain(after: max(0.05, gap - elapsed))
            return
        }

        flushTask?.cancel()
        flushTask = nil
        pendingUpdate = nil
        pendingIsUrgent = false
        isPushing = true

        let content = InstallActivityAttributes.ContentState(
            phase: update.phase,
            progress: update.progress,
            detail: update.detail,
            speed: update.speed
        )
        await activity.update(using: content)

        isPushing = false
        firstContentIsFree = false
        lastPushedAt = Date()
        lastPushedPhase = update.phase
        lastPublishedProgress = max(lastPublishedProgress, update.progress)
        lastState = update

        if pendingUpdate != nil {
            await drain()
        }
    }

    @MainActor
    private func scheduleDrain(after delay: TimeInterval) {
        guard flushTask == nil else { return }
        let ns = UInt64(max(0.05, delay) * 1_000_000_000)
        let expectedGeneration = generation
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
            self.flushTask = nil
            await self.drain()
        }
    }

    /// Signing/installing may be quiet for a while. Reassert the phase slowly
    /// so the card stays alive without exhausting ActivityKit's update budget.
    @MainActor
    private func startKeepAlive(generation expectedGeneration: Int) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.activity != nil,
                      let state = self.lastState else { return }
                guard state.phase == .signing || state.phase == .installing else { continue }
                self.pendingUpdate = state
                await self.drain()
            }
        }
    }

    func finish(job: StoreInstallJob, success: Bool, detail: String) {
        Task { @MainActor in
            guard self.activeJobID == job.id, let activity = self.activity else {
                // Even if this process lost its in-memory reference, clear an
                // orphaned system card for this old run.
                await self.endSystemActivities(except: nil)
                return
            }

            let finaleReason = "live-finale-\(job.id)"
            StoreInstallKeepAlive.shared.begin(finaleReason)

            self.generation &+= 1
            let endingGeneration = self.generation
            self.flushTask?.cancel()
            self.flushTask = nil
            self.keepAliveTask?.cancel()
            self.keepAliveTask = nil
            self.pendingUpdate = nil
            self.pendingIsUrgent = false

            let progress = success ? 1 : self.lastPublishedProgress
            let state = InstallActivityAttributes.ContentState(
                phase: success ? .complete : .failed,
                progress: progress,
                detail: detail,
                speed: nil
            )
            await activity.update(using: state)

            // Keep the result just long enough to read, then actually dismiss
            // it while the process is still scheduled. This prevents the old
            // red failure card surviving into the next install.
            try? await Task.sleep(nanoseconds: success ? 2_500_000_000 : 2_000_000_000)
            guard self.generation == endingGeneration else {
                StoreInstallKeepAlive.shared.end(finaleReason)
                return
            }

            await activity.end(using: state, dismissalPolicy: .immediate)
            await self.endSystemActivities(except: nil)
            self.activity = nil
            self.activeJobID = nil
            self.resetTransientState()
            self.jobStartedAt = nil
            StoreInstallKeepAlive.shared.end(finaleReason)
        }
    }

    @MainActor
    private func endSystemActivities(except keepID: String?) async {
        for existing in Activity<InstallActivityAttributes>.activities {
            if let keepID, existing.id == keepID { continue }
            await existing.end(using: nil, dismissalPolicy: .immediate)
        }
    }

    @MainActor
    private func resetTransientState() {
        flushTask?.cancel()
        flushTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        pendingUpdate = nil
        pendingIsUrgent = false
        isPushing = false
        lastState = nil
        lastPushedAt = nil
        lastPushedPhase = nil
        lastPublishedProgress = 0
        firstContentIsFree = false
    }

    @MainActor
    private func activityPhase(for phase: StoreInstallPhase) -> InstallActivityAttributes.Phase {
        switch phase {
        case .idle, .downloading: return .downloading
        case .ready, .complete: return .complete
        case .signing: return .signing
        case .installing: return .installing
        case .failed: return .failed
        }
    }

    @MainActor
    private func visibleProgress(for phase: StoreInstallPhase, rawProgress: Double) -> Double {
        switch phase {
        case .downloading:
            return max(0, min(1, rawProgress / 0.90))
        case .ready, .signing, .installing, .complete:
            return 1
        case .idle, .failed:
            return max(0, min(1, rawProgress))
        }
    }
}

enum InstallLiveActivityBridge {
    static func cleanupStale() {
        if #available(iOS 16.1, *) {
            InstallLiveActivityController.shared.cleanupStale()
        }
    }

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
