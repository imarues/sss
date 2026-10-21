import SwiftUI
import UIKit
import Foundation
import CoreText
@main
struct TurathReplicaApp: App {
    @StateObject private var store = StoreViewModel()

    init() {
        FontLoader.registerBundledPingAR()
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.white]
    }

    var body: some Scene {
        WindowGroup {
            RootStoreView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
    }
}
