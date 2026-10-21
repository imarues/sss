import Foundation
import ActivityKit

@available(iOS 16.1, *)
struct InstallActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case downloading
        case signing
        case installing
        case complete
        case failed
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var progress: Double
        var detail: String
        var speed: String?
    }

    var appName: String
    var bundleID: String
    var iconURL: String?
}
