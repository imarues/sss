import Foundation
import ZsignSwift

enum BatSignSignerError: LocalizedError {
    case signingFailed
    case callback(Error)
    case invalidExecutable
    case injectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .signingFailed:
            return "فشل Zsign في توقيع التطبيق."
        case .callback(let error):
            return error.localizedDescription
        case .invalidExecutable:
            return "تعذر تحديد الملف التنفيذي للتطبيق."
        case .injectionFailed(let name):
            return "فشل BatSign في حقن \(name)."
        }
    }
}

enum BatSignSigner {
    /// BatSign-style tweak injection: copy every dylib into the .app snapshot and
    /// add its Mach-O load command immediately before the same zsign pass.
    static func inject(dylibs: [URL], into appURL: URL) throws {
        guard !dylibs.isEmpty else { return }
        let plistURL = appURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty else {
            throw BatSignSignerError.invalidExecutable
        }
        let executableURL = appURL.appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw BatSignSignerError.invalidExecutable
        }

        var used = Set<String>()
        for source in dylibs {
            var name = source.lastPathComponent
            if !name.lowercased().hasSuffix(".dylib") { name += ".dylib" }
            if used.contains(name.lowercased()) {
                name = String(UUID().uuidString.prefix(6)) + "-" + name
            }
            used.insert(name.lowercased())

            let target = appURL.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)

            let loadPath = "@executable_path/\(name)"
            guard Zsign.injectDyLib(appExecutable: executableURL.path, with: loadPath, weak: false) else {
                throw BatSignSignerError.injectionFailed(name)
            }
        }
    }

    /// Mirrors BatSign's signing-options flow: identity overrides and injected
    /// tweaks are applied to one durable app snapshot before the certificate pass.
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
