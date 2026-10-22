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

enum BatSignPackageStage {
    case unpacking
    case signing
    case packaging
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
        outputURL: URL,
        progress: ((BatSignPackageStage, Double) -> Void)? = nil
    ) throws -> BatSignPackageArtifact {
        // A package already sealed with this exact certificate/profile/version
        // skips every expensive pass, just like BatSign reusing a signed entry.
        if let cached = BatSignSignedCache.materializeForInstall(
            job: job,
            credentials: credentials
        ) {
            prewarmGBoxManifest(name: cached.name, bundleID: cached.bundleID, version: cached.version)
            progress?(.packaging, 1)
            return cached
        }

        let root = fm.temporaryDirectory
            .appendingPathComponent("BatSignCore-\(job.id)-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        do {
            progress?(.unpacking, 0)
            Zip.addCustomFileExtension("ipa")
            try Zip.unzipFile(
                ipaURL,
                destination: root,
                overwrite: true,
                password: nil,
                progress: { value in progress?(.unpacking, value) }
            )
            progress?(.unpacking, 1)
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

        // GBox's manifest is remote HTTPS while the payload itself is localhost.
        // BatSign reaches the official prompt quickly because there is no extra
        // app-side work after packaging. Warm DNS/TLS and the tiny manifest now,
        // in parallel with the expensive signing + archive pass, so opening
        // itms-services at the end does not spend seconds establishing i.gbox.run.
        prewarmGBoxManifest(name: metadata.name, bundleID: metadata.bundleID, version: metadata.version)

        progress?(.signing, 0)
        try BatSignSigner.sign(appURL: appURL, credentials: credentials)
        progress?(.signing, 1)

        let zipURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("zip")
        try? fm.removeItem(at: zipURL)
        try? fm.removeItem(at: outputURL)

        do {
            // BatSign's automatic install path explicitly enables
            // fastestCompressionOverride, which resolves to BestSpeed.
            progress?(.packaging, 0)
            try Zip.zipFiles(
                paths: [payload],
                zipFilePath: zipURL,
                password: nil,
                compression: .BestSpeed,
                progress: { value in progress?(.packaging, value) }
            )
            try fm.moveItem(at: zipURL, to: outputURL)
            progress?(.packaging, 1)
        } catch {
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: outputURL)
            throw BatSignPackageError.archiveFailed
        }

        let artifact = BatSignPackageArtifact(
            ipaURL: outputURL,
            name: metadata.name,
            bundleID: metadata.bundleID,
            version: metadata.version
        )

        try? BatSignSignedCache.store(
            artifact: artifact,
            job: job,
            credentials: credentials
        )
        return artifact
    }

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

    private static func prewarmGBoxManifest(name: String, bundleID: String, version: String) {
        let descriptor = "\(name)/\(bundleID)/\(version)"
        let base64 = Data(descriptor.utf8).base64EncodedString()
        let encoded = base64.replacingOccurrences(of: "=", with: "%3D")
        guard let url = URL(string: "https://i.gbox.run/\(encoded).plist") else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 15
        request.setValue("text/xml,application/xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
