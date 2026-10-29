import SwiftUI
import UIKit
import Foundation
import CoreText

@main
struct TurathReplicaApp: App {
    @UIApplicationDelegateAdaptor(TurathAppDelegate.self) private var installAppDelegate
    @StateObject private var store = StoreViewModel()
    @ObservedObject private var signingSetup = SigningSetupCoordinator.shared
    @AppStorage("store.appearance") private var appearance = "night"

    init() {
        FontLoader.registerBundledPingAR()
        AppVisibleFolders.bootstrap()

        URLCache.shared.memoryCapacity = max(URLCache.shared.memoryCapacity, 64 * 1024 * 1024)
        URLCache.shared.diskCapacity = max(URLCache.shared.diskCapacity, 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootStoreView()
                .environmentObject(store)
                .preferredColorScheme(appearance == "day" ? .light : .dark)
                .fullScreenCover(
                    isPresented: $signingSetup.isPresented,
                    onDismiss: { signingSetup.cancel() }
                ) {
                    SigningSetupSheet {
                        signingSetup.completeAfterSetup()
                    }
                }
                .task {
                    InstallLiveActivityBridge.cleanupStale()
                    StoreInstallCoordinator.shared.bootstrap()
                    DetailPreparationCenter.shared.bootstrap()
                    TransferActivityCenter.shared.bootstrap()
                    await KiraPagesUpdatesService.shared.warm()
                }
        }
    }
}
