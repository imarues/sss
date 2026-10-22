import Foundation
import Combine

final class SigningSetupCoordinator: ObservableObject {
    static let shared = SigningSetupCoordinator()

    @Published var isPresented = false
    private(set) var pendingApp: StoreApp?
    private var pendingAction: (() -> Void)?

    private init() {}

    func request(for app: StoreApp) {
        pendingApp = app
        pendingAction = nil
        isPresented = true
    }

    func request(action: @escaping () -> Void) {
        pendingApp = nil
        pendingAction = action
        isPresented = true
    }

    func completeAfterSetup() {
        let app = pendingApp
        let action = pendingAction
        pendingApp = nil
        pendingAction = nil
        isPresented = false

        if let action {
            action()
            return
        }

        if let app {
            TransferActivityCenter.shared.track(app)
            StoreInstallCoordinator.shared.start(app)
        }
    }

    func consumePendingApp() -> StoreApp? {
        let app = pendingApp
        pendingApp = nil
        pendingAction = nil
        isPresented = false
        return app
    }

    func cancel() {
        pendingApp = nil
        pendingAction = nil
        isPresented = false
    }
}
