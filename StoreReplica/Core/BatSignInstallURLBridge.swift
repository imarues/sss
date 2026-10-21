import Foundation
import UIKit
import ObjectiveC.runtime

/// BatSign's iOS 18-compatible server flow does not rely on opening the
/// itms-services URL straight from the app. It first opens a local HTTP page in
/// Safari, and that page redirects to itms-services. This interceptor keeps the
/// rest of the install engine unchanged while applying that handoff globally.
enum BatSignInstallURLBridge {
    private static var didInstall = false
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !didInstall else { return }
        didInstall = true

        let original = NSSelectorFromString("openURL:options:completionHandler:")
        let replacement = NSSelectorFromString("turath_openURL:options:completionHandler:")
        guard let originalMethod = class_getInstanceMethod(UIApplication.self, original),
              let replacementMethod = class_getInstanceMethod(UIApplication.self, replacement) else {
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    static func bridgeURL(for installURL: URL) -> URL? {
        let encoded = Data(installURL.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 9800
        components.path = "/install"
        components.queryItems = [URLQueryItem(name: "target", value: encoded)]
        return components.url
    }
}

extension UIApplication {
    /// After swizzling, calling `turath_openURL` invokes UIApplication's original
    /// implementation. Only itms-services is rerouted; every other URL is left
    /// untouched.
    @objc(turath_openURL:options:completionHandler:)
    dynamic func turath_openURL(
        _ url: URL,
        options: [UIApplication.OpenExternalURLOptionsKey: Any],
        completionHandler: ((Bool) -> Void)?
    ) {
        guard url.scheme?.lowercased() == "itms-services",
              let bridge = BatSignInstallURLBridge.bridgeURL(for: url) else {
            turath_openURL(url, options: options, completionHandler: completionHandler)
            return
        }

        // Open the local HTML handoff in Safari first. Safari then redirects to
        // the original itms-services URL, matching BatSign's fallback route.
        turath_openURL(bridge, options: [:], completionHandler: completionHandler)
    }
}
