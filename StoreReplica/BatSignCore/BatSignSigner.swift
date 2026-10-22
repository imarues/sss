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
    /// Mirrors BatSign's signing-options flow: identity overrides are handed to
    /// zsign in the same pass that applies the certificate. This avoids a
    /// separate unzip/rewrite/repack cycle for duplicate installs.
    static func sign(
        appURL: URL,
        credentials: SigningAssetProvider.Credentials,
        bundleID: String? = nil,
        displayName: String? = nil,
        version: String? = nil
    ) throws {
        var callbackError: Error?
        let signed = Zsign.sign(
            appPath: appURL.path,
            provisionPath: credentials.mobileProvision.path,
            p12Path: credentials.p12.path,
            p12Password: credentials.password,
            entitlementsPath: "",
            customIdentifier: bundleID ?? "",
            customName: displayName ?? "",
            customVersion: version ?? "",
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
