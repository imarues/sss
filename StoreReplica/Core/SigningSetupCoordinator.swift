import Foundation
import Combine

final class SigningSetupCoordinator: ObservableObject {
    static let shared = SigningSetupCoordinator()

    @Published var isPresented = false
    private(set) var pendingApp: StoreApp?

    private init() {}

    func request(for app: StoreApp) {
        pendingApp = app
        isPresented = true
    }

    func consumePendingApp() -> StoreApp? {
        let app = pendingApp
        pendingApp = nil
        isPresented = false
        return app
    }

    func cancel() {
        pendingApp = nil
        isPresented = false
    }
}
