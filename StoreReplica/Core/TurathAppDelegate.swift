import UIKit

final class TurathAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == DetailPreparationCenter.backgroundSessionIdentifier {
            DetailPreparationCenter.shared.handleBackgroundEvents(completionHandler: completionHandler)
        } else if identifier == TransferActivityCenter.backgroundSessionIdentifier {
            TransferActivityCenter.shared.handleBackgroundEvents(completionHandler: completionHandler)
        } else {
            StoreInstallCoordinator.shared.backgroundSessionCompletion = completionHandler
            StoreInstallCoordinator.shared.bootstrap()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        StoreInstallCoordinator.shared.applicationDidBecomeActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        StoreInstallKeepAlive.shared.reaffirm()
    }
}
