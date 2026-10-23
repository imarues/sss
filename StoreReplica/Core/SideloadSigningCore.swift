import Foundation
import UIKit
import Zip
import ZsignSwift

// MARK: - Copy variants

enum SideloadCopyVariant: Int, CaseIterable, Identifiable, Codable {
    case original = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }
    var title: String { rawValue == 0 ? "الأصلية" : "\(rawValue)" }
    var number: Int? { rawValue == 0 ? nil : rawValue }
}

// MARK: - Metadata

struct SideloadIPAMetadata: Equatable {
    let name: String
    let bundleID: String
    let version: String
    let size: Int64
    let iconData: Data?
}

enum SideloadSourceKind: String, Codable {
    case file
    case link
    case updates
}

private struct SideloadLibraryRecord: Codable {
    let appID: String
    let name: String
    let bundleID: String
    let version: String
    let source: SideloadSourceKind
    let sourceURL: String?
    let copyNumber: Int?
    let dylibNames: [String]
    let iconFileName: String?
    let createdAt: Date
}

struct SideloadLibraryItem: Identifiable, Equatable {
    let appID: String
    let name: String
    let bundleID: String
    let version: String
    let size: Int64
    let ipaURL: URL
    let iconURL: URL?
    let source: SideloadSourceKind
    let modifiedAt: Date

    var id: String { appID }

    var storeApp: StoreApp {
        StoreApp(
            id: appID,
            name: name,
            bundleId: bundleID,
            version: version,
            fileSize: size,
            notes: nil,
            iconUrl: nil,
            featured: nil,
            categories: nil,
            installs: nil,
            updatedAt: nil,
            addedAt: nil,
            versionUpdatedAt: nil,
            feedKind: nil,
            downloadUrl: nil,
            downloadURL: nil
        )
    }
}

struct SideloadPreparedApp {
    let app: StoreApp
    let metadata: SideloadIPAMetadata
    let stagedIPA: URL
}

enum SideloadSigningError: LocalizedError {
    case invalidIPA
    case missingPayload
    case missingApp
    case invalidInfoPlist
    case missingExecutable
    case unsupportedDylib(String)
    case dylibInjectionFailed(String)
    case invalidURL
    case httpStatus(Int)
    case downloadFailed
    case packageFailed

    var errorDescription: String? {
        switch self {
        case .invalidIPA: return "ملف IPA غير صالح."
        case .missingPayload: return "تعذر العثور على Payload داخل ملف IPA."
        case .missingApp: return "تعذر العثور على التطبيق داخل Payload."
        case .invalidInfoPlist: return "تعذر قراءة معلومات التطبيق."
        case .missingExecutable: return "تعذر العثور على الملف التنفيذي للتطبيق."
        case .unsupportedDylib(let name): return "الملف \(name) ليس بصيغة .dylib."
        case .dylibInjectionFailed(let name): return "فشل حقن \(name) داخل التطبيق."
        case .invalidURL: return "رابط IPA غير صالح."
        case .httpStatus(let status): return "فشل تحميل IPA من الخادم (HTTP \(status))."
        case .downloadFailed: return "تعذر إكمال تحميل IPA."
        case .packageFailed: return "تعذر إعادة تجهيز ملف IPA."
        }
    }
}

// MARK: - Imported file vault

enum SideloadFileVault {
    private static let fm = FileManager.default

    private static var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let value = base.appendingPathComponent("SideloadImports", isDirectory: true)
        try? fm.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    static func importPickedFile(_ source: URL, allowedExtensions: Set<String>) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            if ext == "dylib" { throw SideloadSigningError.unsupportedDylib(source.lastPathComponent) }
            throw SideloadSigningError.invalidIPA
        }

        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)

        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }

        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            // asCopy document pickers often already return a sandbox URL. A mapped
            // data copy is a safe fallback when FileManager cannot clone it.
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    static func adoptDownloadedIPA(from temporaryURL: URL, suggestedName: String?) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawName = (suggestedName?.isEmpty == false ? suggestedName! : "Download.ipa")
        let fileName = rawName.lowercased().hasSuffix(".ipa") ? rawName : rawName + ".ipa"
        let destination = directory.appendingPathComponent(fileName)
        try? fm.removeItem(at: destination)

        do {
            try fm.moveItem(at: temporaryURL, to: destination)
        } catch {
            try fm.copyItem(at: temporaryURL, to: destination)
        }
        try StoreDownloadStorage.validateIPA(at: destination)
        return destination
    }
}

// MARK: - IPA inspection

enum SideloadIPAInspector {
    private static let fm = FileManager.default

    static func inspect(_ ipaURL: URL) throws -> SideloadIPAMetadata {
        try StoreDownloadStorage.validateIPA(at: ipaURL)
        let root = fm.temporaryDirectory
            .appendingPathComponent("SideloadInspect-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        Zip.addCustomFileExtension("ipa")
        do {
            try Zip.unzipFile(ipaURL, destination: root, overwrite: true, password: nil, progress: nil)
        } catch {
            throw SideloadSigningError.invalidIPA
        }

        guard let payload = BatSignPackagePipeline.locatePayload(in: root) else {
            throw SideloadSigningError.missingPayload
        }
        guard let appURL = BatSignPackagePipeline.locateApp(in: payload) else {
            throw SideloadSigningError.missingApp
        }
        return try metadata(appURL: appURL, ipaURL: ipaURL)
    }

    static func metadata(appURL: URL, ipaURL: URL) throws -> SideloadIPAMetadata {
        let plist = try readInfo(appURL: appURL)
        guard let bundleID = nonEmpty(plist["CFBundleIdentifier"] as? String) else {
            throw SideloadSigningError.invalidInfoPlist
        }
        let name = nonEmpty(plist["CFBundleDisplayName"] as? String)
            ?? nonEmpty(plist["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let version = nonEmpty(plist["CFBundleShortVersionString"] as? String)
            ?? nonEmpty(plist["CFBundleVersion"] as? String)
            ?? "1.0"
        let size = ((try? fm.attributesOfItem(atPath: ipaURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return SideloadIPAMetadata(
            name: name,
            bundleID: bundleID,
            version: version,
            size: size,
            iconData: iconData(appURL: appURL, plist: plist)
        )
    }

    static func readInfo(appURL: URL) throws -> [String: Any] {
        let url = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            throw SideloadSigningError.invalidInfoPlist
        }
        return dictionary
    }

    static func executableURL(appURL: URL, plist: [String: Any]) -> URL? {
        if let executable = nonEmpty(plist["CFBundleExecutable"] as? String) {
            let candidate = appURL.appendingPathComponent(executable)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle(url: appURL)?.executableURL
    }

    private static func iconData(appURL: URL, plist: [String: Any]) -> Data? {
        var names: [String] = []

        func appendIconFiles(_ value: Any?) {
            guard let icons = value as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { return }
            if let files = primary["CFBundleIconFiles"] as? [String] { names.append(contentsOf: files.reversed()) }
            if let name = primary["CFBundleIconName"] as? String { names.append(name) }
        }

        appendIconFiles(plist["CFBundleIcons"])
        appendIconFiles(plist["CFBundleIcons~ipad"])
        if let files = plist["CFBundleIconFiles"] as? [String] { names.append(contentsOf: files.reversed()) }
        if let file = plist["CFBundleIconFile"] as? String { names.append(file) }

        let rootFiles = (try? fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let pngs = rootFiles.filter { $0.pathExtension.lowercased() == "png" }

        for raw in names {
            let base = raw.replacingOccurrences(of: ".png", with: "")
            let candidate = pngs.first { url in
                let fileBase = url.deletingPathExtension().lastPathComponent
                return fileBase == base || fileBase.hasPrefix(base + "@") || fileBase.hasPrefix(base + "~")
            }
            if let candidate, let data = try? Data(contentsOf: candidate), !data.isEmpty { return data }
        }

        let fallback = pngs
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains("icon") }
            .sorted { lhs, rhs in
                let l = ((try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let r = ((try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                return l > r
            }
            .first
        return fallback.flatMap { try? Data(contentsOf: $0) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - BatSign-style preparation

enum SideloadPackagePreparer {
    private static let fm = FileManager.default

    static func prepare(
        sourceIPA: URL,
        knownMetadata: SideloadIPAMetadata? = nil,
        copyVariant: SideloadCopyVariant,
        dylibURLs: [URL],
        sourceKind: SideloadSourceKind,
        sourceURL: String? = nil,
        progress: ((Double, String) -> Void)? = nil,
        metadataReady: ((SideloadIPAMetadata) -> Void)? = nil
    ) throws -> SideloadPreparedApp {
        try StoreDownloadStorage.validateIPA(at: sourceIPA)

        let requiresRewrite = copyVariant != .original || !dylibURLs.isEmpty
        if !requiresRewrite, let knownMetadata {
            metadataReady?(knownMetadata)
            progress?(0.52, "جاري حفظ التطبيق")
            return try stage(
                ipaURL: sourceIPA,
                metadata: knownMetadata,
                sourceKind: sourceKind,
                sourceURL: sourceURL,
                copyNumber: nil,
                dylibNames: []
            )
        }

        let root = fm.temporaryDirectory
            .appendingPathComponent("SideloadPrepare-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        progress?(0.08, "جاري قراءة IPA")
        Zip.addCustomFileExtension("ipa")
        do {
            try Zip.unzipFile(
                sourceIPA,
                destination: root,
                overwrite: true,
                password: nil,
                progress: { value in progress?(0.08 + (value * 0.30), "جاري فك الحزمة") }
            )
        } catch {
            throw SideloadSigningError.invalidIPA
        }

        guard let payload = BatSignPackagePipeline.locatePayload(in: root) else {
            throw SideloadSigningError.missingPayload
        }
        guard let appURL = BatSignPackagePipeline.locateApp(in: payload) else {
            throw SideloadSigningError.missingApp
        }

        let originalMetadata = try SideloadIPAInspector.metadata(appURL: appURL, ipaURL: sourceIPA)
        metadataReady?(originalMetadata)

        var finalName = originalMetadata.name
        var finalBundle = originalMetadata.bundleID
        if let number = copyVariant.number {
            finalName = "\(originalMetadata.name) \(number)"
            // The requested behavior is literal: append the selected number to
            // the end of the existing bundle id, e.g. com.example.app -> com.example.app3.
            finalBundle = originalMetadata.bundleID + String(number)
            progress?(0.42, "جاري تجهيز النسخة \(number)")
            try rewriteIdentity(
                appURL: appURL,
                oldBundleID: originalMetadata.bundleID,
                newBundleID: finalBundle,
                newName: finalName
            )
        }

        if !dylibURLs.isEmpty {
            progress?(0.50, "جاري دمج الديلب")
            try injectDylibs(dylibURLs, into: appURL)
        }

        let output = root.appendingPathComponent("Prepared.ipa")
        do {
            progress?(0.62, "جاري تجهيز IPA")
            try Zip.zipFiles(
                paths: [payload],
                zipFilePath: output,
                password: nil,
                compression: .BestSpeed,
                progress: { value in progress?(0.62 + (value * 0.30), "جاري تجهيز IPA") }
            )
        } catch {
            throw SideloadSigningError.packageFailed
        }

        let attrs = try? fm.attributesOfItem(atPath: output.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? originalMetadata.size
        let finalMetadata = SideloadIPAMetadata(
            name: finalName,
            bundleID: finalBundle,
            version: originalMetadata.version,
            size: size,
            iconData: originalMetadata.iconData
        )

        progress?(0.95, "جاري حفظ التطبيق")
        return try stage(
            ipaURL: output,
            metadata: finalMetadata,
            sourceKind: sourceKind,
            sourceURL: sourceURL,
            copyNumber: copyVariant.number,
            dylibNames: dylibURLs.map(\.lastPathComponent)
        )
    }

    private static func rewriteIdentity(
        appURL: URL,
        oldBundleID: String,
        newBundleID: String,
        newName: String
    ) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        var info = try SideloadIPAInspector.readInfo(appURL: appURL)
        info["CFBundleIdentifier"] = newBundleID
        info["CFBundleDisplayName"] = newName
        info["CFBundleName"] = newName
        try writePlist(info, to: infoURL)

        // Keep extensions installable beside the original app as BatSign does.
        for folderName in ["PlugIns", "Extensions"] {
            let folder = appURL.appendingPathComponent(folderName, isDirectory: true)
            guard fm.fileExists(atPath: folder.path),
                  let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for appex in children where appex.pathExtension.lowercased() == "appex" {
                let url = appex.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: url),
                      var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
                if let current = plist["CFBundleIdentifier"] as? String {
                    if current.hasPrefix(oldBundleID) {
                        plist["CFBundleIdentifier"] = newBundleID + current.dropFirst(oldBundleID.count)
                    } else {
                        plist["CFBundleIdentifier"] = current + newBundleID.suffix(1)
                    }
                    try? writePlist(plist, to: url)
                }
            }
        }

        // A localized InfoPlist.strings can otherwise override the new display name.
        guard let children = try? fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for lproj in children where lproj.pathExtension.lowercased() == "lproj" {
            let stringsURL = lproj.appendingPathComponent("InfoPlist.strings")
            guard let data = try? Data(contentsOf: stringsURL),
                  var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
            plist["CFBundleDisplayName"] = newName
            plist["CFBundleName"] = newName
            try? writePlist(plist, to: stringsURL)
        }
    }

    private static func injectDylibs(_ urls: [URL], into appURL: URL) throws {
        let plist = try SideloadIPAInspector.readInfo(appURL: appURL)
        guard let executable = SideloadIPAInspector.executableURL(appURL: appURL, plist: plist) else {
            throw SideloadSigningError.missingExecutable
        }

        for source in urls {
            guard source.pathExtension.lowercased() == "dylib" else {
                throw SideloadSigningError.unsupportedDylib(source.lastPathComponent)
            }

            // User-requested layout: dylib lives in the .app root and the Mach-O
            // load command is exactly @executable_path/<file>.dylib.
            let destination = appURL.appendingPathComponent(source.lastPathComponent)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)

            _ = Zsign.changeDylibPath(
                appExecutable: destination.path,
                for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
            )

            let injected = Zsign.injectDyLib(
                appExecutable: executable.path,
                with: "@executable_path/\(destination.lastPathComponent)"
            )
            guard injected else {
                throw SideloadSigningError.dylibInjectionFailed(source.lastPathComponent)
            }
        }
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func stage(
        ipaURL: URL,
        metadata: SideloadIPAMetadata,
        sourceKind: SideloadSourceKind,
        sourceURL: String?,
        copyNumber: Int?,
        dylibNames: [String]
    ) throws -> SideloadPreparedApp {
        // Each prepared import gets its own app id. This is intentional: the
        // existing BatSignSignedCache keys by app id/version/certificate, so two
        // different dylib sets must never accidentally reuse the same signed IPA.
        let appID = "manual-" + UUID().uuidString.lowercased()
        let job = StoreInstallJob(
            id: UUID().uuidString,
            appID: appID,
            appName: metadata.name,
            bundleID: metadata.bundleID,
            version: metadata.version,
            iconURL: nil,
            downloadURL: "",
            expectedBytes: metadata.size
        )
        let destination = try StoreDownloadStorage.stagedURL(for: job)
        try? fm.removeItem(at: destination)
        do {
            try fm.copyItem(at: ipaURL, to: destination)
        } catch {
            throw StoreDownloadStorageError.cannotStage
        }
        try StoreDownloadStorage.validateIPA(at: destination)

        try SideloadLibraryStore.writeRecord(
            appID: appID,
            folder: destination.deletingLastPathComponent(),
            metadata: metadata,
            source: sourceKind,
            sourceURL: sourceURL,
            copyNumber: copyNumber,
            dylibNames: dylibNames
        )

        let app = StoreApp(
            id: appID,
            name: metadata.name,
            bundleId: metadata.bundleID,
            version: metadata.version,
            fileSize: metadata.size,
            notes: nil,
            iconUrl: nil,
            featured: nil,
            categories: nil,
            installs: nil,
            updatedAt: nil,
            addedAt: nil,
            versionUpdatedAt: nil,
            feedKind: nil,
            downloadUrl: nil,
            downloadURL: nil
        )
        return SideloadPreparedApp(app: app, metadata: metadata, stagedIPA: destination)
    }
}

// MARK: - Local library (link + update downloads)

enum SideloadLibraryStore {
    private static let fm = FileManager.default
    private static let recordName = "sideload-meta.json"
    private static let iconName = "sideload-icon.png"

    fileprivate static func writeRecord(
        appID: String,
        folder: URL,
        metadata: SideloadIPAMetadata,
        source: SideloadSourceKind,
        sourceURL: String?,
        copyNumber: Int?,
        dylibNames: [String]
    ) throws {
        var savedIcon: String?
        if let iconData = metadata.iconData, !iconData.isEmpty {
            let iconURL = folder.appendingPathComponent(iconName)
            if (try? iconData.write(to: iconURL, options: .atomic)) != nil {
                savedIcon = iconName
            }
        }

        let record = SideloadLibraryRecord(
            appID: appID,
            name: metadata.name,
            bundleID: metadata.bundleID,
            version: metadata.version,
            source: source,
            sourceURL: sourceURL,
            copyNumber: copyNumber,
            dylibNames: dylibNames,
            iconFileName: savedIcon,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: folder.appendingPathComponent(recordName), options: .atomic)
    }

    static func items() -> [SideloadLibraryItem] {
        let root = StoreDownloadStorage.stagingRoot
        guard let folders = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.compactMap { folder -> SideloadLibraryItem? in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ),
                  let ipa = files.first(where: { $0.pathExtension.lowercased() == "ipa" }),
                  StoreDownloadStorage.isValidIPA(at: ipa) else { return nil }

            let attrs = try? ipa.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let modified = attrs?.contentModificationDate ?? Date.distantPast
            let recordURL = folder.appendingPathComponent(recordName)

            if let data = try? Data(contentsOf: recordURL),
               let record = try? JSONDecoder().decode(SideloadLibraryRecord.self, from: data) {
                // Per the requested My Apps behavior, manual file imports do not
                // populate this tab; link downloads do, and store/update downloads
                // are discovered below even without a sidecar record.
                guard record.source != .file else { return nil }
                let icon = record.iconFileName.map { folder.appendingPathComponent($0) }
                return SideloadLibraryItem(
                    appID: record.appID,
                    name: record.name,
                    bundleID: record.bundleID,
                    version: record.version,
                    size: size,
                    ipaURL: ipa,
                    iconURL: icon,
                    source: record.source,
                    modifiedAt: modified
                )
            }

            // Existing update downloads predate the sideload sidecar. Their file
            // name is already "<name> - v<version>.ipa", so include them too.
            let parsed = parseFileName(ipa.deletingPathExtension().lastPathComponent)
            return SideloadLibraryItem(
                appID: folder.lastPathComponent,
                name: parsed.name,
                bundleID: folder.lastPathComponent,
                version: parsed.version,
                size: size,
                ipaURL: ipa,
                iconURL: nil,
                source: .updates,
                modifiedAt: modified
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func parseFileName(_ value: String) -> (name: String, version: String) {
        if let range = value.range(of: " - v", options: .backwards) {
            let name = String(value[..<range.lowerBound])
            let version = String(value[range.upperBound...])
            return (name.isEmpty ? "تطبيق" : name, version.isEmpty ? "1.0" : version)
        }
        return (value.isEmpty ? "تطبيق" : value, "1.0")
    }
}

// MARK: - Link download with progress

final class SideloadURLDownloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    typealias ProgressHandler = (Double, Int64, Int64) -> Void
    typealias Completion = (Result<URL, Error>) -> Void

    private var progressHandler: ProgressHandler?
    private var completion: Completion?
    private var suggestedName: String?
    private var adoptedURL: URL?
    private var responseError: Error?
    private var activeDownloadTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func start(
        url: URL,
        progress: @escaping ProgressHandler,
        completion: @escaping Completion
    ) {
        cancel()
        self.progressHandler = progress
        self.completion = completion
        self.suggestedName = url.lastPathComponent.isEmpty ? "Download.ipa" : url.lastPathComponent
        self.adoptedURL = nil
        self.responseError = nil

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        activeDownloadTask = task
        task.resume()
    }

    func cancel() {
        // getAllTasks is asynchronous and could cancel a freshly started task.
        // Cancel the known previous task synchronously instead.
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard downloadTask.taskIdentifier == activeDownloadTask?.taskIdentifier else { return }
        let expected = max(totalBytesExpectedToWrite, 0)
        let fraction = expected > 0 ? min(1, Double(totalBytesWritten) / Double(expected)) : 0
        progressHandler?(fraction, totalBytesWritten, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask.taskIdentifier == activeDownloadTask?.taskIdentifier else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            responseError = SideloadSigningError.httpStatus(http.statusCode)
            return
        }

        if let disposition = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"),
           let filename = contentDispositionFileName(disposition) {
            suggestedName = filename
        }

        do {
            adoptedURL = try SideloadFileVault.adoptDownloadedIPA(from: location, suggestedName: suggestedName)
        } catch {
            responseError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Ignore completion of an older cancelled task after a new download starts.
        guard task.taskIdentifier == activeDownloadTask?.taskIdentifier else { return }
        activeDownloadTask = nil
        let callback = completion
        completion = nil
        if let error {
            callback?(.failure(error))
        } else if let responseError {
            callback?(.failure(responseError))
        } else if let adoptedURL {
            callback?(.success(adoptedURL))
        } else {
            callback?(.failure(SideloadSigningError.downloadFailed))
        }
    }

    private func contentDispositionFileName(_ value: String) -> String? {
        for chunk in value.split(separator: ";") {
            let part = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.lowercased().hasPrefix("filename=") {
                return part.dropFirst("filename=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        return nil
    }
}
