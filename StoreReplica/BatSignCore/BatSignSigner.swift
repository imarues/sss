import Foundation
import ZsignSwift

enum BatSignSignerError: LocalizedError {
    case signingFailed
    case callback(Error)

    var errorDescription: String? {
        switch self {
        case .signingFailed:
            return "فشل Zsign في توقيع التطبيق."
        case .callback(let error):
            return error.localizedDescription
        }
    }
}

enum BatSignSigner {
    /// Mirrors BatSign's ZsignHandler: both the completion error and the
    /// boolean return value are authoritative. Some early zsign failures never
    /// call the completion block, so checking only one of the two is unsafe.
    static func sign(appURL: URL, credentials: SigningAssetProvider.Credentials) throws {
        var callbackError: Error?
        let signed = Zsign.sign(
            appPath: appURL.path,
            provisionPath: credentials.mobileProvision.path,
            p12Path: credentials.p12.path,
            p12Password: credentials.password,
            entitlementsPath: "",
            customIdentifier: "",
            customName: "",
            customVersion: "",
            adhoc: false,
            removeProvision: false,
            completion: { _, error in
                callbackError = error
            }
        )

        if let callbackError {
            throw BatSignSignerError.callback(callbackError)
        }
        guard signed else {
            throw BatSignSignerError.signingFailed
        }
    }
}
