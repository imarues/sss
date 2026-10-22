import Foundation
import UIKit
import AVFoundation

/// Keeps the local GBox payload server scheduled while iOS is fetching the IPA.
/// A normal UIBackgroundTask is only a short grace period; BatSign keeps a
/// silent playback session alive for the whole hand-off and uses the assertion
/// underneath it as a safety net.
final class StoreInstallKeepAlive {
    static let shared = StoreInstallKeepAlive()

    private var holders: Set<String> = []
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var watchdog: DispatchSourceTimer?
    private var rearmBudget = 240

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reaffirm() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reaffirm() }
    }

    func begin(_ reason: String) {
        onMain { [weak self] in
            guard let self else { return }
            let wasEmpty = self.holders.isEmpty
            self.holders.insert(reason)
            guard wasEmpty else { return }
            self.rearmBudget = 240
            self.beginAssertion()
            StoreSilentAudioHold.shared.start()
            self.startWatchdog()
        }
    }

    func end(_ reason: String) {
        onMain { [weak self] in
            guard let self else { return }
            self.holders.remove(reason)
            guard self.holders.isEmpty else { return }
            self.stopWatchdog()
            StoreSilentAudioHold.shared.stop()
            self.endAssertion()
        }
    }

    func reaffirm() {
        onMain { [weak self] in
            guard let self, !self.holders.isEmpty else { return }
            self.rearmBudget = 240
            if self.assertion == .invalid { self.beginAssertion() }
            if !StoreSilentAudioHold.shared.isRunning {
                StoreSilentAudioHold.shared.restart()
            }
            self.startWatchdog()
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.holders.isEmpty else { return }
            if !StoreSilentAudioHold.shared.isRunning {
                StoreSilentAudioHold.shared.restart()
            }
            if self.assertion == .invalid {
                self.beginAssertion()
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        var token: UIBackgroundTaskIdentifier = .invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "TurathInstallKeepAlive") { [weak self] in
            guard let self else { return }
            self.onMain {
                guard !self.holders.isEmpty, self.rearmBudget > 0 else {
                    self.endAssertion()
                    return
                }
                self.rearmBudget -= 1
                self.endAssertion()
                self.beginAssertion()
                if !StoreSilentAudioHold.shared.isRunning {
                    StoreSilentAudioHold.shared.restart()
                }
            }
        }
        assertion = token
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        let token = assertion
        assertion = .invalid
        UIApplication.shared.endBackgroundTask(token)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() }
        else { DispatchQueue.main.async(execute: block) }
    }
}

/// One second of generated PCM silence looped with AVAudioPlayer. There is no
/// bundled media file and `.mixWithOthers` avoids interrupting user audio.
private final class StoreSilentAudioHold {
    static let shared = StoreSilentAudioHold()

    private var player: AVAudioPlayer?
    private var fileURL: URL?
    private var wanted = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self?.restart() }
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in self?.restart() }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in self?.restart() }
    }

    var isRunning: Bool { wanted && (player?.isPlaying ?? false) }

    func start() {
        wanted = true
        guard !(player?.isPlaying ?? false) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let source = try silentFileURL()
            let p = try AVAudioPlayer(contentsOf: source)
            p.numberOfLoops = -1
            p.volume = 1
            p.prepareToPlay()
            guard p.play() else { return }
            player = p
        } catch {
            player = nil
        }
    }

    func restart() {
        guard wanted else { return }
        player?.stop()
        player = nil
        start()
    }

    func stop() {
        wanted = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func silentFileURL() throws -> URL {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurathInstallHold", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("hold.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.silentWAV(seconds: 1, sampleRate: 44_100).write(to: url, options: .atomic)
        }
        fileURL = url
        return url
    }

    private static func silentWAV(seconds: Double, sampleRate: UInt32) -> Data {
        let frames = UInt32(Double(sampleRate) * seconds)
        let byteCount = frames * 2
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func append(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        append("RIFF")
        append(UInt32(36) + byteCount)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        append("data")
        append(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }
}
