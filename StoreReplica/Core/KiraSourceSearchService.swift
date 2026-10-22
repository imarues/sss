import Foundation

private struct KiraSearchSource: Decodable {
    let apps: [KiraSearchEntry]
}

private struct KiraSearchVersion: Decodable {
    let version: String?
    let downloadURL: String?
    let downloadUrl: String?
    let url: String?
    let size: Int64?

    private enum CodingKeys: String, CodingKey {
        case version, downloadURL, downloadUrl, url, size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
        downloadUrl = try? c.decodeIfPresent(String.self, forKey: .downloadUrl)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        let numeric = try? c.decode(Int64.self, forKey: .size)
        let text = try? c.decode(String.self, forKey: .size)
        size = numeric ?? text.flatMap(Int64.init)
    }

    var effectiveDownloadURL: String? {
        [downloadURL, downloadUrl, url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

private struct KiraSearchEntry: Decodable {
    let id: String?
    let name: String
    let bundleIdentifier: String?
    let bundleId: String?
    let iconURL: String?
    let localizedDescription: String?
    let category: String?
    let fileType: String?
    let version: String?
    let size: Int64?
    let downloadURL: String?
    let downloadUrl: String?
    let ipaUrl: String?
    let url: String?
    let versions: [KiraSearchVersion]?

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, bundleId, iconURL, localizedDescription
        case category, fileType, version, size, downloadURL, downloadUrl, ipaUrl, url, versions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "App"
        bundleIdentifier = try? c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        bundleId = try? c.decodeIfPresent(String.self, forKey: .bundleId)
        iconURL = try? c.decodeIfPresent(String.self, forKey: .iconURL)
        localizedDescription = try? c.decodeIfPresent(String.self, forKey: .localizedDescription)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        fileType = try? c.decodeIfPresent(String.self, forKey: .fileType)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
        downloadUrl = try? c.decodeIfPresent(String.self, forKey: .downloadUrl)
        ipaUrl = try? c.decodeIfPresent(String.self, forKey: .ipaUrl)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        versions = try? c.decodeIfPresent([KiraSearchVersion].self, forKey: .versions)
        let numeric = try? c.decode(Int64.self, forKey: .size)
        let text = try? c.decode(String.self, forKey: .size)
        size = numeric ?? text.flatMap(Int64.init)
    }

    private var currentVersion: KiraSearchVersion? {
        guard let versions, !versions.isEmpty else { return nil }
        if let version, let exact = versions.first(where: { $0.version == version }) { return exact }
        return versions.first
    }

    private var cleanCategory: String? {
        if let value = category?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        if let type = fileType?.lowercased(), type == "dylib" || type == "zip" { return "دايلب" }
        return nil
    }

    private var effectiveDownloadURL: String? {
        [downloadURL, downloadUrl, ipaUrl, url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? currentVersion?.effectiveDownloadURL
    }

    var storeApp: StoreApp {
        let effectiveVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = (effectiveVersion?.isEmpty == false ? effectiveVersion : nil) ?? currentVersion?.version
        let stableID = id ?? bundleIdentifier ?? bundleId ?? "search-\(name)-\(resolvedVersion ?? "")"
        return StoreApp(
            id: stableID,
            name: name,
            bundleId: bundleIdentifier ?? bundleId,
            version: resolvedVersion,
            fileSize: size ?? currentVersion?.size,
            notes: localizedDescription,
            iconUrl: iconURL,
            featured: nil,
            categories: cleanCategory.map { [$0] },
            installs: nil,
            updatedAt: nil,
            addedAt: nil,
            versionUpdatedAt: nil,
            feedKind: nil,
            downloadUrl: effectiveDownloadURL,
            downloadURL: effectiveDownloadURL
        )
    }
}

actor KiraSourceSearchService {
    static let shared = KiraSourceSearchService()

    private let appsURL = URL(string: "https://ikiraplus.pages.dev/IPA-AR.json")!
    private let dylibsURL = URL(string: "https://ikiraplus.pages.dev/deb-AR.json")!
    private var cachedApps: [StoreApp] = []
    private var cachedAt: Date?

    func catalog(force: Bool = false) async throws -> [StoreApp] {
        if !force,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < 300,
           !cachedApps.isEmpty {
            return cachedApps
        }

        async let appData = Self.fetch(appsURL, force: force)
        async let dylibData = Self.fetch(dylibsURL, force: force)
        let (rawApps, rawDylibs) = try await (appData, dylibData)

        let apps = try JSONDecoder().decode(KiraSearchSource.self, from: rawApps).apps.map(\.storeApp)
        let dylibs = try JSONDecoder().decode(KiraSearchSource.self, from: rawDylibs).apps.map(\.storeApp)

        var seen = Set<String>()
        let combined = (apps + dylibs).filter { seen.insert($0.id).inserted }
        cachedApps = combined
        cachedAt = Date()
        return combined
    }

    private static func fetch(_ url: URL, force: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ar-IQ,ar;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreAPIError.invalidResponse
        }
        return data
    }
}
