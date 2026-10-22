import SwiftUI
import UIKit
import Foundation
import CoreText

@main
struct TurathReplicaApp: App {
    @UIApplicationDelegateAdaptor(StoreInstallAppDelegate.self) private var installAppDelegate
    @StateObject private var store = StoreViewModel()
    @ObservedObject private var signingSetup = SigningSetupCoordinator.shared

    init() {
        FontLoader.registerBundledPingAR()
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.white]

        URLCache.shared.memoryCapacity = max(URLCache.shared.memoryCapacity, 64 * 1024 * 1024)
        URLCache.shared.diskCapacity = max(URLCache.shared.diskCapacity, 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootStoreView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
                .fullScreenCover(
                    isPresented: $signingSetup.isPresented,
                    onDismiss: { signingSetup.cancel() }
                ) {
                    SigningSetupSheet {
                        if let app = signingSetup.consumePendingApp() {
                            StoreInstallCoordinator.shared.start(app)
                        }
                    }
                }
                .task {
                    InstallLiveActivityBridge.cleanupStale()
                    StoreInstallCoordinator.shared.bootstrap()
                    await KiraPagesUpdatesService.shared.warm()
                }
        }
    }
}
