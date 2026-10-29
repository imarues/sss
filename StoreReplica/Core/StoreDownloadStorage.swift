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
    private static let categoryRegistryKey = "StoreDownloadStorage.categoryRegistry.v1"

    static var stagingRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TurathDownloads", isDirectory: true)
    }

    static var documentsRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func registerVisibleCategory(for app: StoreApp) {
        var map = (UserDefaults.standard.dictionary(forKey: categoryRegistryKey) as? [String: String]) ?? [:]
        map[app.id] = isGame(app) ? "games" : "apps"
        UserDefaults.standard.set(map, forKey: categoryRegistryKey)
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
        AppVisibleFolders.ensure()
        let map = (UserDefaults.standard.dictionary(forKey: categoryRegistryKey) as? [String: String]) ?? [:]
        let target = map[job.appID] == "games" ? AppVisibleFolders.games : AppVisibleFolders.apps
        try makeDirectory(target)
        return target.appendingPathComponent(fileName(for: job), isDirectory: false)
    }

    private static func legacyExportedURL(for job: StoreInstallJob) throws -> URL {
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

    static func stageFinishedDownload(from temporaryURL: URL, job: StoreInstallJob) throws -> URL {
        let destination = try stagedURL(for: job)
        let directory = destination.deletingLastPathComponent()
        try makeDirectory(directory)

        if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
            return destination
        }
        // Keep the last valid staged IPA until the replacement is verified.
        guard fm.fileExists(atPath: temporaryURL.path) else {
            if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
                return destination
            }
            throw StoreDownloadStorageError.sourceMissing
        }

        let incoming = directory.appendingPathComponent(
            destination.lastPathComponent + ".incoming-" + UUID().uuidString,
            isDirectory: false
        )
        try? fm.removeItem(at: incoming)
        defer { try? fm.removeItem(at: incoming) }

        // Copy while still inside the URLSession callback. Moving/linking
        // the system-owned temp file risks invalidating the handoff.
        do {
            try fm.copyItem(at: temporaryURL, to: incoming)
        } catch {
            if isValidIPA(at: destination), sizeIsPlausible(url: destination, expectedBytes: job.expectedBytes) {
                return destination
            }
            if !fm.fileExists(atPath: temporaryURL.path) {
                throw StoreDownloadStorageError.sourceMissing
            }
            throw StoreDownloadStorageError.cannotStage
        }

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

        var candidates: [URL] = []
        if let current = try? exportedURL(for: job) { candidates.append(current) }
        if let legacy = try? legacyExportedURL(for: job) { candidates.append(legacy) }
        guard let exported = candidates.first(where: {
            isValidIPA(at: $0) && sizeIsPlausible(url: $0, expectedBytes: job.expectedBytes)
        }) else { return nil }

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
        // A PK header alone does not mean the complete IPA was downloaded.
        guard signature.count == 4,
              signature[0] == 0x50, signature[1] == 0x4B,
              signature[2] == 0x03, signature[3] == 0x04 else {
            throw StoreDownloadStorageError.invalidIPA
        }
        let tailCount = Int(min(size, 65_557))
        try handle.seek(toOffset: UInt64(size - Int64(tailCount)))
        let tail = Array(try handle.read(upToCount: tailCount) ?? Data())
        guard tail.count >= 22 else { throw StoreDownloadStorageError.truncatedFile }
        // End-of-central-directory, allowing a ZIP comment up to 65535 bytes.
        let marker = stride(from: tail.count - 22, through: 0, by: -1).first { i in
            tail[i] == 0x50 && tail[i + 1] == 0x4B &&
            tail[i + 2] == 0x05 && tail[i + 3] == 0x06 &&
            i + 22 + Int(tail[i + 20]) + (Int(tail[i + 21]) << 8) <= tail.count
        }
        guard let i = marker else { throw StoreDownloadStorageError.truncatedFile }
        func u32(_ j: Int) -> Int64 {
            Int64(tail[j]) | (Int64(tail[j+1]) << 8) |
            (Int64(tail[j+2]) << 16) | (Int64(tail[j+3]) << 24)
        }
        let centralSize = u32(i + 12), centralOffset = u32(i + 16)
        // These sentinel values mean ZIP64, whose sizes are in an extension.
        if centralSize != 0xFFFF_FFFF && centralOffset != 0xFFFF_FFFF {
            guard centralOffset <= size, centralSize <= size - centralOffset else {
                throw StoreDownloadStorageError.truncatedFile
            }
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
        registerVisibleCategory(for: app)
        return StoreInstallJob(
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

    private static func isGame(_ app: StoreApp) -> Bool {
        let values = (app.categories ?? []).map {
            $0.lowercased()
                .replacingOccurrences(of: "أ", with: "ا")
                .replacingOccurrences(of: "إ", with: "ا")
                .replacingOccurrences(of: "آ", with: "ا")
                .replacingOccurrences(of: " ", with: "")
        }
        return values.contains { value in
            value.contains("العاب") || value == "game" || value == "games" || value.contains("gaming")
        }
    }
}
