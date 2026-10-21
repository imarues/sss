import Foundation

enum StoreDownloadStorageError: LocalizedError {
    case cannotCreateDirectory
    case sourceMissing
    case emptyFile
    case invalidIPA
    case cannotStage

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory:
            return "تعذر إنشاء مجلد التخزين الداخلي للتطبيق."
        case .sourceMissing:
            return "اكتمل التحميل لكن ملف النظام المؤقت لم يعد متاحًا. أعد المحاولة."
        case .emptyFile:
            return "ملف IPA الذي تم تنزيله فارغ."
        case .invalidIPA:
            return "الملف الذي تم تنزيله ليس ملف IPA صالحًا."
        case .cannotStage:
            return "تعذر حفظ التطبيق في التخزين الداخلي الآمن."
        }
    }
}

enum StoreDownloadStorage {
    private static let fm = FileManager.default

    /// Durable storage used by the install pipeline. This is the authoritative copy.
    /// Files/Documents is intentionally only an export surface and can never block signing/install.
    static var stagingRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TurathDownloads", isDirectory: true)
    }

    static var documentsRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func stagedURL(for job: StoreInstallJob) throws -> URL {
        let folder = stagingRoot
            .appendingPathComponent(safe(job.appID, fallback: "app"), isDirectory: true)
        try makeDirectory(folder)
        return folder.appendingPathComponent(fileName(for: job), isDirectory: false)
    }

    static func stagedURL(for app: StoreApp) -> URL? {
        let job = StoreInstallJob(
            id: "cache-check",
            appID: app.id,
            appName: app.name,
            bundleID: app.bundleId ?? app.id,
            version: app.version ?? "1.0",
            iconURL: app.iconUrl,
            downloadURL: app.effectiveDownloadURL ?? "",
            expectedBytes: app.fileSize ?? 0
        )
        return try? stagedURL(for: job)
    }

    static func exportedURL(for job: StoreInstallJob) throws -> URL {
        let folder = documentsRoot
            .appendingPathComponent(safe(job.appName, fallback: "App"), isDirectory: true)
        try makeDirectory(folder)
        return folder.appendingPathComponent(fileName(for: job), isDirectory: false)
    }

    static func hasValidStagedIPA(for job: StoreInstallJob) -> Bool {
        guard let url = try? stagedURL(for: job) else { return false }
        return isValidIPA(at: url)
    }

    static func hasValidStagedIPA(for app: StoreApp) -> Bool {
        guard let url = stagedURL(for: app) else { return false }
        return isValidIPA(at: url)
    }

    /// Copy the URLSession-owned temporary file into Application Support first.
    /// The copy is made to a unique sibling and only promoted after verification,
    /// mirroring BatSign's staging approach so a partial file is never considered ready.
    static func stageFinishedDownload(from temporaryURL: URL, job: StoreInstallJob) throws -> URL {
        let destination = try stagedURL(for: job)
        let directory = destination.deletingLastPathComponent()
        try makeDirectory(directory)

        if isValidIPA(at: destination) {
            return destination
        }

        guard fm.fileExists(atPath: temporaryURL.path) else {
            throw StoreDownloadStorageError.sourceMissing
        }

        let incoming = directory.appendingPathComponent(
            destination.lastPathComponent + ".incoming-" + UUID().uuidString,
            isDirectory: false
        )
        try? fm.removeItem(at: incoming)
        defer { try? fm.removeItem(at: incoming) }

        do {
            try fm.copyItem(at: temporaryURL, to: incoming)
        } catch {
            if isValidIPA(at: destination) { return destination }
            if !fm.fileExists(atPath: temporaryURL.path) {
                throw StoreDownloadStorageError.sourceMissing
            }
            throw StoreDownloadStorageError.cannotStage
        }

        try validateIPA(at: incoming)
        try protect(incoming)

        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: incoming)
            } else {
                try fm.moveItem(at: incoming, to: destination)
            }
        } catch {
            if isValidIPA(at: destination) { return destination }
            throw StoreDownloadStorageError.cannotStage
        }

        try validateIPA(at: destination)
        try protect(destination)
        return destination
    }

    /// Import a previously exported Documents copy into durable staging if an older
    /// build downloaded it before the staging architecture existed.
    static func recoverLegacyExportIfPossible(job: StoreInstallJob) -> URL? {
        guard let staged = try? stagedURL(for: job) else { return nil }
        if isValidIPA(at: staged) { return staged }
        guard let exported = try? exportedURL(for: job), isValidIPA(at: exported) else { return nil }

        let incoming = staged.deletingLastPathComponent().appendingPathComponent(
            staged.lastPathComponent + ".legacy-" + UUID().uuidString
        )
        do {
            try fm.copyItem(at: exported, to: incoming)
            try validateIPA(at: incoming)
            if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: staged) }
            try fm.moveItem(at: incoming, to: staged)
            try protect(staged)
            return staged
        } catch {
            try? fm.removeItem(at: incoming)
            return nil
        }
    }

    /// Best-effort Files export. Failure here must never fail signing or installation.
    @discardableResult
    static func exportToFiles(stagedURL: URL, job: StoreInstallJob) -> Bool {
        guard isValidIPA(at: stagedURL), let destination = try? exportedURL(for: job) else {
            return false
        }

        if isValidIPA(at: destination) {
            return true
        }

        let incoming = destination.deletingLastPathComponent().appendingPathComponent(
            destination.lastPathComponent + ".incoming-" + UUID().uuidString
        )
        try? fm.removeItem(at: incoming)
        defer { try? fm.removeItem(at: incoming) }

        do {
            try fm.copyItem(at: stagedURL, to: incoming)
            try validateIPA(at: incoming)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: incoming)
            } else {
                try fm.moveItem(at: incoming, to: destination)
            }
            try validateIPA(at: destination)
            try protect(destination)
            return true
        } catch {
            return false
        }
    }

    static func isValidIPA(at url: URL) -> Bool {
        (try? validateIPA(at: url)) != nil
    }

    static func validateIPA(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else {
            throw StoreDownloadStorageError.sourceMissing
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 4 else { throw StoreDownloadStorageError.emptyFile }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signature = handle.readData(ofLength: 2)
        guard signature == Data([0x50, 0x4B]) else {
            throw StoreDownloadStorageError.invalidIPA
        }
    }

    private static func fileName(for job: StoreInstallJob) -> String {
        let app = safe(job.appName, fallback: "App")
        let version = safe(job.version, fallback: "1.0")
        return "\(app) - v\(version).ipa"
    }

    private static func makeDirectory(_ url: URL) throws {
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try protect(url)
        } catch {
            throw StoreDownloadStorageError.cannotCreateDirectory
        }
    }

    private static func protect(_ url: URL) throws {
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func safe(_ value: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = value
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
        return String(cleaned.prefix(100))
    }
}
