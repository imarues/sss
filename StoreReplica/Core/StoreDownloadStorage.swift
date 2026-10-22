import Foundation

enum StoreDownloadStorageError: LocalizedError {
    case cannotCreateDirectory
    case sourceMissing
    case emptyFile
    case invalidIPA
    case truncatedFile
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
        case .truncatedFile:
            return "ملف IPA المحفوظ أصغر بكثير من الحجم المتوقع ويبدو أن التحميل لم يكتمل."
        case .cannotStage:
            return "تعذر حفظ التطبيق في التخزين الداخلي الآمن."
        }
    }
}

enum StoreDownloadStorage {
    private static let fm = FileManager.default

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
        let job = jobForCacheCheck(app)
        return try? stagedURL(for: job)
    }

    static func exportedURL(for job: StoreInstallJob) throws -> URL {
        let folder = documentsRoot
            .appendingPathComponent(safe(job.appName, fallback: "App"), isDirectory: true)
        try makeDirectory(folder)
        return folder.appendingPathComponent(fileName(for: job), isDirectory: false)
    }

    static func hasValidStagedIPA(for job: StoreInstallJob) -> Bool {
        guard let url = try? stagedURL(for: job), isValidIPA(at: url) else { return false }
        return sizeIsPlausible(url: url, expectedBytes: job.expectedBytes)
    }

    static func hasValidStagedIPA(for app: StoreApp) -> Bool {
        let job = jobForCacheCheck(app)
        return hasValidStagedIPA(for: job)
    }

    /// Take ownership of URLSession's completed file as quickly as possible.
    /// Moving is the normal URLSession completion handoff and is effectively
    /// instant when the temporary file and Application Support share a volume.
    /// If iOS places the temp file on a different volume, fall back to a hard
    /// link and finally to a copy.
    static func stageFinishedDownload(from temporaryURL: URL, job: StoreInstallJob) throws -> URL {
        let destination = try stagedURL(for: job)
        let directory = destination.deletingLastPathComponent()
        try makeDirectory(directory)

        if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
            return destination
        }
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
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

        var staged = false

        // URLSession explicitly hands ownership of this temporary file to the
        // delegate for the duration of didFinishDownloadingTo. Moving it here
        // avoids a second full write of large IPAs before signing can start.
        do {
            try fm.moveItem(at: temporaryURL, to: incoming)
            staged = true
        } catch {
            // Cross-volume or protection failures use the non-destructive paths below.
        }

        if !staged {
            do {
                try fm.linkItem(at: temporaryURL, to: incoming)
                staged = true
            } catch {
                // Hard links can be refused for URLSession-managed temp files.
            }
        }

        if !staged {
            do {
                try fm.copyItem(at: temporaryURL, to: incoming)
                staged = true
            } catch {
                if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
                    return destination
                }
                if !fm.fileExists(atPath: temporaryURL.path) {
                    throw StoreDownloadStorageError.sourceMissing
                }
                throw StoreDownloadStorageError.cannotStage
            }
        }

        guard staged else { throw StoreDownloadStorageError.cannotStage }
        try validateIPA(at: incoming)
        guard sizeIsPlausible(url: incoming, expectedBytes: job.expectedBytes) else {
            throw StoreDownloadStorageError.truncatedFile
        }
        try protect(incoming)

        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: incoming)
            } else {
                try fm.moveItem(at: incoming, to: destination)
            }
        } catch {
            if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
                return destination
            }
            throw StoreDownloadStorageError.cannotStage
        }

        try validateIPA(at: destination)
        guard sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) else {
            try? fm.removeItem(at: destination)
            throw StoreDownloadStorageError.truncatedFile
        }
        try protect(destination)
        return destination
    }

    static func recoverLegacyExportIfPossible(job: StoreInstallJob) -> URL? {
        guard let staged = try? stagedURL(for: job) else { return nil }
        if isValidIPA(at: staged), sizeIsPlausible(url: staged, expectedBytes: job.expectedBytes) {
            return staged
        }
        guard let exported = try? exportedURL(for: job),
              isValidIPA(at: exported),
              sizeIsPlausible(url: exported, expectedBytes: job.expectedBytes) else { return nil }

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

    /// Best-effort Files export. It intentionally runs after signing so this copy
    /// cannot make the 100%/Signing stage slower.
    @discardableResult
    static func exportToFiles(stagedURL: URL, job: StoreInstallJob) -> Bool {
        guard isValidIPA(at: stagedURL),
              sizeIsPlausible(url: stagedURL, expectedBytes: job.expectedBytes),
              let destination = try? exportedURL(for: job) else { return false }

        if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
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
            guard sizeIsPlausible(url: incoming, expectedBytes: job.expectedBytes) else { return false }
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

    /// Cheap hot-path validation. Full extraction is deliberately deferred to
    /// BatSignPackagePipeline so reaching 100% does not spend another full unzip pass.
    static func validateIPA(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else {
            throw StoreDownloadStorageError.sourceMissing
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 4 else { throw StoreDownloadStorageError.emptyFile }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signature = handle.readData(ofLength: 4)
        guard signature.count >= 2,
              signature[signature.startIndex] == 0x50,
              signature[signature.index(after: signature.startIndex)] == 0x4B else {
            throw StoreDownloadStorageError.invalidIPA
        }
    }

    private static func sizeIsPlausible(url: URL, expectedBytes: Int64) -> Bool {
        guard expectedBytes >= 5 * 1024 * 1024 else { return true }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let value = attrs[.size] as? NSNumber else { return false }
        let actual = value.int64Value
        return actual >= expectedBytes / 2
    }

    private static func jobForCacheCheck(_ app: StoreApp) -> StoreInstallJob {
        StoreInstallJob(
            id: "cache-check",
            appID: app.id,
            appName: app.name,
            bundleID: app.bundleId ?? app.id,
            version: app.version ?? "1.0",
            iconURL: app.iconUrl,
            downloadURL: app.effectiveDownloadURL ?? "",
            expectedBytes: app.fileSize ?? 0
        )
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
