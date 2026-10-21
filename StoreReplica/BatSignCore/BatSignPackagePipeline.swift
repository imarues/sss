import Foundation
import Zip

enum BatSignPackageError: LocalizedError {
    case unreadablePackage
    case payloadNotFound
    case appNotFound
    case invalidMetadata
    case archiveFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePackage:
            return "تعذر قراءة حزمة IPA."
        case .payloadNotFound:
            return "لم يتم العثور على مجلد Payload داخل IPA."
        case .appNotFound:
            return "لم يتم العثور على تطبيق .app داخل Payload."
        case .invalidMetadata:
            return "تعذر قراءة Info.plist للتطبيق."
        case .archiveFailed:
            return "تعذر تجهيز IPA الموقّع للتثبيت."
        }
    }
}

struct BatSignPackageArtifact {
    let ipaURL: URL
    let name: String
    let bundleID: String
    let version: String
}

enum BatSignPackagePipeline {
    private static let fm = FileManager.default

    static func sign(
        ipaURL: URL,
        job: StoreInstallJob,
        credentials: SigningAssetProvider.Credentials,
        outputURL: URL
    ) throws -> BatSignPackageArtifact {
        let root = fm.temporaryDirectory
            .appendingPathComponent("BatSignCore-\(job.id)-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        do {
            Zip.addCustomFileExtension("ipa")
            try Zip.unzipFile(
                ipaURL,
                destination: root,
                overwrite: true,
                password: nil,
                progress: nil
            )
        } catch {
            throw BatSignPackageError.unreadablePackage
        }

        guard let payload = locatePayload(in: root) else {
            throw BatSignPackageError.payloadNotFound
        }
        guard let appURL = locateApp(in: payload) else {
            throw BatSignPackageError.appNotFound
        }

        let metadata = try readMetadata(appURL: appURL, fallback: job)
        try BatSignSigner.sign(appURL: appURL, credentials: credentials)

        let zipURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("zip")
        try? fm.removeItem(at: zipURL)
        try? fm.removeItem(at: outputURL)

        do {
            // BatSign's install path can use stored/no-compression packaging.
            // Signing already consumed the CPU-heavy work; do not spend more
            // time recompressing assets that are commonly compressed already.
            try Zip.zipFiles(
                paths: [payload],
                zipFilePath: zipURL,
                password: nil,
                compression: .NoCompression,
                progress: nil
            )
            try fm.moveItem(at: zipURL, to: outputURL)
        } catch {
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: outputURL)
            throw BatSignPackageError.archiveFailed
        }

        return BatSignPackageArtifact(
            ipaURL: outputURL,
            name: metadata.name,
            bundleID: metadata.bundleID,
            version: metadata.version
        )
    }

    /// BatSign imports packages through a work directory and follows Payload,
    /// rather than assuming that unzip always places it at one exact URL. A
    /// few stores wrap an IPA in one extra folder, so support that layout too.
    static func locatePayload(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("Payload", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: direct.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return direct
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "Payload" else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { return url }
        }
        return nil
    }

    static func locateApp(in payload: URL) -> URL? {
        if let direct = try? fm.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), let app = direct.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return app
        }

        guard let enumerator = fm.enumerator(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            return url
        }
        return nil
    }

    static func validateImportableIPA(at url: URL) -> Bool {
        let root = fm.temporaryDirectory
            .appendingPathComponent("BatSignValidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            Zip.addCustomFileExtension("ipa")
            try Zip.unzipFile(url, destination: root, overwrite: true, password: nil, progress: nil)
            guard let payload = locatePayload(in: root), locateApp(in: payload) != nil else { return false }
            return true
        } catch {
            return false
        }
    }

    private static func readMetadata(
        appURL: URL,
        fallback job: StoreInstallJob
    ) throws -> (name: String, bundleID: String, version: String) {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw BatSignPackageError.invalidMetadata
        }

        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = plist[key] as? String {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
            return nil
        }

        let name = string(["CFBundleDisplayName", "CFBundleName"]) ?? job.appName
        let bundle = string(["CFBundleIdentifier"]) ?? job.bundleID
        let version = string(["CFBundleShortVersionString", "CFBundleVersion"]) ?? job.version
        guard !bundle.isEmpty else { throw BatSignPackageError.invalidMetadata }
        return (name, bundle, version.isEmpty ? "1.0" : version)
    }
}
