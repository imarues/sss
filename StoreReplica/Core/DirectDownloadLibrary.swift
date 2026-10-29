import Foundation
import SwiftUI

extension StoreApp {
    var isDylibAsset: Bool {
        if id.lowercased().hasPrefix("dylib-") { return true }
        return (categories ?? []).contains { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "أ", with: "ا")
                .replacingOccurrences(of: "إ", with: "ا")
                .replacingOccurrences(of: "آ", with: "ا")
            return normalized == "دايلب" || normalized == "dylib" || normalized == "dylibs"
        }
    }

    var primaryCategoryName: String {
        (categories ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "غير مصنف"
    }

    var normalizedPrimaryCategory: String {
        primaryCategoryName
            .lowercased()
            .replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
            .replacingOccurrences(of: "ة", with: "ه")
            .replacingOccurrences(of: " ", with: "")
    }

    var isGameAsset: Bool {
        // Classify every current game category, including genres that do not
        // contain the English word "game" (Action, Racing and Simulation).
        let gameTypes: Set<String> = [
            "action", "racing", "simulation", "arcade", "adventure",
            "strategy", "sports games", "paid games",
            "اكشن", "سباق", "سباقات", "محاكاه", "مغامرات", "استراتيجيه"
        ]
        let values = categories ?? []
        return values.contains { raw in
            let category = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "أ", with: "ا")
                .replacingOccurrences(of: "إ", with: "ا")
                .replacingOccurrences(of: "آ", with: "ا")
                .replacingOccurrences(of: "ة", with: "ه")
            return category.contains("العاب") || category.contains("games") ||
                category == "game" || category.contains("gaming") ||
                gameTypes.contains(category)
        }
    }
}

struct DirectDownloadItem: Identifiable, Equatable {
    let id: String
    let appID: String
    let name: String
    let version: String
    let size: Int64
    let fileURL: URL
    let iconURL: URL?
    let fileType: String
    let createdAt: Date
}

private struct DirectDownloadRecord: Codable {
    let id: String
    let appID: String
    let name: String
    let version: String
    let iconURL: String?
    let fileName: String
    let fileType: String
    let createdAt: Date
}

enum DirectDownloadError: LocalizedError {
    case missingURL
    case invalidResponse
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .missingURL: return "رابط التحميل غير متوفر."
        case .invalidResponse: return "تعذر تحميل الملف من الخادم."
        case .writeFailed: return "تعذر حفظ الملف على الجهاز."
        }
    }
}

actor DirectDownloadLibrary {
    static let shared = DirectDownloadLibrary()
    static let changedNotification = Notification.Name("DirectDownloadLibraryChanged")

    private let fm = FileManager.default
    private let recordName = "download-meta.json"

    private var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let value = base.appendingPathComponent("DirectDownloads", isDirectory: true)
        try? fm.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func items() -> [DirectDownloadItem] {
        let folders = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return folders.compactMap { folder in
            let recordURL = folder.appendingPathComponent(recordName)
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(DirectDownloadRecord.self, from: data) else { return nil }
            let fileURL = folder.appendingPathComponent(record.fileName)
            guard fm.fileExists(atPath: fileURL.path) else { return nil }

            _ = AppVisibleFolders.mirrorFile(
                from: fileURL,
                to: AppVisibleFolders.dylib,
                fileName: record.fileName
            )

            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return DirectDownloadItem(
                id: record.id,
                appID: record.appID,
                name: record.name,
                version: record.version,
                size: size,
                fileURL: fileURL,
                iconURL: record.iconURL.flatMap(URL.init(string:)),
                fileType: record.fileType,
                createdAt: record.createdAt
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func contains(appID: String, version: String?) -> Bool {
        let targetVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return items().contains {
            $0.appID == appID && (targetVersion.isEmpty || $0.version == targetVersion)
        }
    }

    func download(app: StoreApp) async throws -> DirectDownloadItem {
        guard let raw = app.effectiveDownloadURL,
              let url = URL(string: raw) else {
            throw DirectDownloadError.missingURL
        }

        let currentVersion = app.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let existing = items().first(where: {
            $0.appID == app.id && (currentVersion.isEmpty || $0.version == currentVersion)
        }) {
            return existing
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw DirectDownloadError.invalidResponse
        }

        let extensionName = preferredExtension(response: response, sourceURL: url)
        let suggested = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSuggested = suggested.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            let ext = (value as NSString).pathExtension.lowercased()
            if ["dylib", "zip"].contains(ext) {
                return String(value.dropLast(ext.count + 1))
            }
            return value
        }
        let baseName = sanitizeFileName(baseSuggested ?? app.name)
        let fileName = "\(baseName).\(extensionName)"

        let folderID = UUID().uuidString.lowercased()
        let folder = root.appendingPathComponent(folderID, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)

        do {
            try fm.moveItem(at: temporaryURL, to: destination)
        } catch {
            do {
                try fm.copyItem(at: temporaryURL, to: destination)
            } catch {
                try? fm.removeItem(at: folder)
                throw DirectDownloadError.writeFailed
            }
        }

        let record = DirectDownloadRecord(
            id: folderID,
            appID: app.id,
            name: app.name,
            version: currentVersion.isEmpty ? "—" : currentVersion,
            iconURL: app.iconUrl,
            fileName: fileName,
            fileType: extensionName,
            createdAt: Date()
        )
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: folder.appendingPathComponent(recordName), options: .atomic)

        guard AppVisibleFolders.mirrorFile(
            from: destination,
            to: AppVisibleFolders.dylib,
            fileName: fileName
        ) != nil else {
            throw DirectDownloadError.writeFailed
        }

        let attrs = try? fm.attributesOfItem(atPath: destination.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? app.fileSize ?? 0
        let item = DirectDownloadItem(
            id: folderID,
            appID: app.id,
            name: app.name,
            version: record.version,
            size: size,
            fileURL: destination,
            iconURL: app.iconUrl.flatMap(URL.init(string:)),
            fileType: extensionName,
            createdAt: record.createdAt
        )

        await MainActor.run {
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
        return item
    }

    private func preferredExtension(response: URLResponse, sourceURL: URL) -> String {
        if let suggested = response.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if ["dylib", "zip"].contains(ext) { return ext }
        }
        let sourceExt = sourceURL.pathExtension.lowercased()
        if ["dylib", "zip"].contains(sourceExt) { return sourceExt }
        if response.mimeType?.lowercased().contains("zip") == true { return "zip" }
        return "dylib"
    }

    private func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }
}

enum DownloadAssetTheme {
    static let gold = Color(red: 0.86, green: 0.64, blue: 0.18)
    static let goldSoft = Color(red: 0.32, green: 0.24, blue: 0.08)
}

struct DirectDownloadButton: View {
    let app: StoreApp
    var compact = false

    private let transfers = TransferActivityCenter.shared
    @State private var downloaded = false
    @State private var operation: DirectTransferOperation?

    var body: some View {
        Button {
            guard operation == nil && !downloaded else { return }
            transfers.startDirectDownload(app)
        } label: {
            HStack(spacing: 6) {
                if let operation, !operation.failed {
                    ProgressView(value: operation.progress)
                        .tint(Color.black)
                        .scaleEffect(0.78)
                        .frame(width: 16, height: 16)
                    Text("\(Int(operation.progress * 100))%")
                        .font(AppFont.bold(compact ? 10.5 : 12))
                        .lineLimit(1)
                } else {
                    Text(downloaded ? "تم التحميل" : ((operation?.failed == true) ? "إعادة" : "تحميل"))
                        .font(AppFont.bold(compact ? 10.5 : 12))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.black)
            .frame(width: compact ? 78 : 104, height: compact ? 34 : 40)
            .background(downloaded ? DownloadAssetTheme.gold.opacity(0.62) : DownloadAssetTheme.gold)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled((operation != nil && operation?.failed == false) || downloaded || app.effectiveDownloadURL == nil)
        .task(id: app.id + (app.version ?? "")) {
            operation = transfers.directOperation(for: app)
            downloaded = await DirectDownloadLibrary.shared.contains(appID: app.id, version: app.version)
        }
        // Only repaint this row if the active operation belongs to this app.
        .onReceive(transfers.$directOperations) { values in
            let current = values.values.first {
                $0.app.id == app.id && ($0.app.version ?? "") == (app.version ?? "")
            }
            if operation?.id != current?.id ||
               operation?.progress != current?.progress ||
               operation?.failed != current?.failed ||
               operation?.statusText != current?.statusText {
                operation = current
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DirectDownloadLibrary.changedNotification)) { _ in
            Task {
                let value = await DirectDownloadLibrary.shared.contains(appID: app.id, version: app.version)
                await MainActor.run { downloaded = value }
            }
        }
    }
}
