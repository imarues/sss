import Foundation

struct KiraUpdatesDay: Codable, Identifiable, Hashable {
    let date: String
    let new: Int
    let updated: Int

    var id: String { date }
    var total: Int { new + updated }
}

struct KiraUpdatesSnapshot: Codable {
    let refreshedAt: Date
    let days: [KiraUpdatesDay]
    let appsByDay: [String: [StoreApp]]
    let catalog: [StoreApp]?
}

private struct KiraPagesSource: Decodable {
    let apps: [KiraPagesApp]
}

private struct KiraPagesVersion: Decodable {
    let version: String?
    let date: String?
    let size: Int64?
    let downloadURL: String?
    let downloadUrl: String?
    let url: String?

    private enum CodingKeys: String, CodingKey {
        case version, date, size, downloadURL, downloadUrl, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
        downloadUrl = try? c.decodeIfPresent(String.self, forKey: .downloadUrl)
        url = try? c.decodeIfPresent(String.self, forKey: .url)

        let numericSize = try? c.decode(Int64.self, forKey: .size)
        let textSize = try? c.decode(String.self, forKey: .size)
        size = numericSize ?? textSize.flatMap { Int64($0) }
    }

    var effectiveDownloadURL: String? {
        [downloadURL, downloadUrl, url].compactMap { $0?.nilWhenBlank }.first
    }
}

private struct KiraPagesApp: Decodable {
    let id: String?
    let name: String
    let bundleIdentifier: String?
    let bundleId: String?
    let iconURL: String?
    let localizedDescription: String?
    let category: String?
    let fileType: String?
    let version: String?
    let versionDate: String?
    let size: Int64?
    let addedAt: String?
    let updatedAt: String?
    let downloadURL: String?
    let downloadUrl: String?
    let ipaUrl: String?
    let url: String?
    let versions: [KiraPagesVersion]?

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, bundleId, iconURL, localizedDescription, category, fileType
        case version, versionDate, size, addedAt, updatedAt
        case downloadURL, downloadUrl, ipaUrl, url, versions
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
        versionDate = try? c.decodeIfPresent(String.self, forKey: .versionDate)
        addedAt = try? c.decodeIfPresent(String.self, forKey: .addedAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
        downloadUrl = try? c.decodeIfPresent(String.self, forKey: .downloadUrl)
        ipaUrl = try? c.decodeIfPresent(String.self, forKey: .ipaUrl)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        versions = try? c.decodeIfPresent([KiraPagesVersion].self, forKey: .versions)

        let numericSize = try? c.decode(Int64.self, forKey: .size)
        let textSize = try? c.decode(String.self, forKey: .size)
        size = numericSize ?? textSize.flatMap { Int64($0) }
    }

    private var currentVersionObject: KiraPagesVersion? {
        guard let versions, !versions.isEmpty else { return nil }
        if let exact = versions.first(where: { $0.version == version }) { return exact }
        return versions.first
    }

    var effectiveVersion: String? {
        version?.nilWhenBlank ?? currentVersionObject?.version?.nilWhenBlank
    }

    var effectiveVersionDate: String? {
        versionDate?.nilWhenBlank ?? currentVersionObject?.date?.nilWhenBlank
    }

    var effectiveSize: Int64? {
        size ?? currentVersionObject?.size
    }

    var effectiveDownloadURL: String? {
        [downloadURL, downloadUrl, ipaUrl, url].compactMap { $0?.nilWhenBlank }.first
            ?? currentVersionObject?.effectiveDownloadURL
    }

    var stableID: String {
        id ?? bundleIdentifier ?? bundleId ?? "\(name)-\(effectiveVersion ?? "")"
    }

    var effectiveCategory: String? {
        if let category = category?.nilWhenBlank { return category }
        if let fileType = fileType?.nilWhenBlank,
           ["dylib", "zip"].contains(fileType.lowercased()) {
            return "دايلب"
        }
        return nil
    }

    func storeApp(kind: String?, addedDay: String?, updatedDay: String?) -> StoreApp {
        StoreApp(
            id: stableID,
            name: name,
            bundleId: bundleIdentifier ?? bundleId,
            version: effectiveVersion,
            fileSize: effectiveSize,
            notes: localizedDescription,
            iconUrl: iconURL,
            featured: nil,
            categories: effectiveCategory.map { [$0] },
            installs: nil,
            updatedAt: updatedDay,
            addedAt: addedDay,
            versionUpdatedAt: KiraUpdatesClock.normalizedDay(effectiveVersionDate),
            feedKind: kind,
            downloadUrl: effectiveDownloadURL,
            downloadURL: effectiveDownloadURL
        )
    }
}

private extension String {
    var nilWhenBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum KiraUpdatesClock {
    private static var baghdad: TimeZone {
        TimeZone(identifier: "Asia/Baghdad") ?? .current
    }

    static func normalizedDay(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 10 else { return nil }
        let day = String(value.prefix(10))
        guard day.count == 10,
              day[day.index(day.startIndex, offsetBy: 4)] == "-",
              day[day.index(day.startIndex, offsetBy: 7)] == "-" else { return nil }
        return day
    }

    static func lastSevenDayKeys() -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = baghdad
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = baghdad
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return formatter.string(from: date)
        }
    }
}

actor KiraPagesUpdatesService {
    static let shared = KiraPagesUpdatesService()

    private let appsSourceURL = URL(string: "https://ikiraplus.pages.dev/IPA-AR.json")!
    private let dylibSourceURL = URL(string: "https://ikiraplus.pages.dev/deb-AR.json")!
    private var memorySnapshot: KiraUpdatesSnapshot?
    private var refreshTask: Task<KiraUpdatesSnapshot, Error>?

    private var cacheFile: URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return root.appendingPathComponent("iKiraPlus-updates-snapshot-v2.json", isDirectory: false)
    }

    func cached() -> KiraUpdatesSnapshot? {
        if let memorySnapshot {
            return alignedToCurrentWeek(memorySnapshot)
        }
        guard let cacheFile,
              let data = try? Data(contentsOf: cacheFile),
              let snapshot = try? JSONDecoder().decode(KiraUpdatesSnapshot.self, from: data) else {
            return nil
        }
        memorySnapshot = snapshot
        return alignedToCurrentWeek(snapshot)
    }

    func warm() async {
        _ = cached()
        _ = try? await refreshIfNeeded()
    }

    func refreshIfNeeded(force: Bool = false) async throws -> KiraUpdatesSnapshot {
        if !force, let current = cached(), Date().timeIntervalSince(current.refreshedAt) < 300 {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }

        let appsURL = appsSourceURL
        let dylibsURL = dylibSourceURL
        let task = Task<KiraUpdatesSnapshot, Error> {
            async let appsData = Self.fetchData(from: appsURL, force: force)
            async let dylibsDataResult: Data? = try? Self.fetchData(from: dylibsURL, force: force)

            let primaryData = try await appsData
            let appSource = try JSONDecoder().decode(KiraPagesSource.self, from: primaryData)
            let secondaryData = await dylibsDataResult
            let dylibSource = secondaryData.flatMap { try? JSONDecoder().decode(KiraPagesSource.self, from: $0) }

            return Self.buildSnapshot(
                fromApps: appSource.apps,
                dylibs: dylibSource?.apps ?? []
            )
        }
        refreshTask = task

        do {
            let snapshot = try await task.value
            refreshTask = nil
            memorySnapshot = snapshot
            persist(snapshot)
            return alignedToCurrentWeek(snapshot)
        } catch {
            refreshTask = nil
            throw error
        }
    }

    func similarApps(to app: StoreApp, limit: Int = 8) async -> [StoreApp] {
        guard !app.isDylibAsset else { return [] }

        var source = cached()?.catalog ?? []
        if source.isEmpty, let refreshed = try? await refreshIfNeeded() {
            source = refreshed.catalog ?? []
        }
        guard !source.isEmpty else { return [] }

        let targetCategory = app.normalizedPrimaryCategory
        let hasCategory = targetCategory != "غيرمصنف" && !targetCategory.isEmpty

        var candidates = source.filter { candidate in
            guard candidate.id != app.id, !candidate.isDylibAsset else { return false }
            if hasCategory {
                return candidate.normalizedPrimaryCategory == targetCategory
            }
            return true
        }

        candidates.sort { lhs, rhs in
            let lb = Self.bundleSimilarity(lhs.bundleId, app.bundleId)
            let rb = Self.bundleSimilarity(rhs.bundleId, app.bundleId)
            if lb != rb { return lb > rb }

            let ln = Self.nameSimilarity(lhs.name, app.name)
            let rn = Self.nameSimilarity(rhs.name, app.name)
            if ln != rn { return ln > rn }

            let lc = lhs.normalizedPrimaryCategory == targetCategory ? 1 : 0
            let rc = rhs.normalizedPrimaryCategory == targetCategory ? 1 : 0
            if lc != rc { return lc > rc }

            let lv = Self.versionDistance(lhs.version, app.version)
            let rv = Self.versionDistance(rhs.version, app.version)
            if lv != rv { return lv < rv }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return Array(candidates.prefix(max(0, limit)))
    }

    private static func fetchData(from url: URL, force: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ar-IQ,ar;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw StoreAPIError.invalidResponse
        }
        return data
    }

    private func persist(_ snapshot: KiraUpdatesSnapshot) {
        guard let cacheFile,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }

    private func alignedToCurrentWeek(_ snapshot: KiraUpdatesSnapshot) -> KiraUpdatesSnapshot {
        let keys = KiraUpdatesClock.lastSevenDayKeys()
        let oldDays = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) })
        var alignedApps: [String: [StoreApp]] = [:]
        let days = keys.map { key -> KiraUpdatesDay in
            if let old = oldDays[key] {
                alignedApps[key] = snapshot.appsByDay[key] ?? []
                return old
            }
            alignedApps[key] = []
            return KiraUpdatesDay(date: key, new: 0, updated: 0)
        }
        return KiraUpdatesSnapshot(
            refreshedAt: snapshot.refreshedAt,
            days: days,
            appsByDay: alignedApps,
            catalog: snapshot.catalog
        )
    }

    private static func buildSnapshot(fromApps sourceApps: [KiraPagesApp], dylibs: [KiraPagesApp]) -> KiraUpdatesSnapshot {
        let dayKeys = KiraUpdatesClock.lastSevenDayKeys()
        let validDays = Set(dayKeys)
        var newCounts = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, 0) })
        var updatedCounts = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, 0) })
        var buckets = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, [StoreApp]()) })

        let catalog = sourceApps.map { source in
            source.storeApp(
                kind: nil,
                addedDay: KiraUpdatesClock.normalizedDay(source.addedAt),
                updatedDay: KiraUpdatesClock.normalizedDay(source.updatedAt ?? source.effectiveVersionDate)
            )
        }

        func appendUpdates(_ sourceCollection: [KiraPagesApp]) {
            for source in sourceCollection {
                let addedDay = KiraUpdatesClock.normalizedDay(source.addedAt)
                let updatedDay = KiraUpdatesClock.normalizedDay(source.updatedAt ?? source.effectiveVersionDate)

                if let addedDay, validDays.contains(addedDay) {
                    newCounts[addedDay, default: 0] += 1
                    buckets[addedDay, default: []].append(
                        source.storeApp(kind: "new", addedDay: addedDay, updatedDay: updatedDay)
                    )
                } else if let updatedDay, validDays.contains(updatedDay) {
                    updatedCounts[updatedDay, default: 0] += 1
                    buckets[updatedDay, default: []].append(
                        source.storeApp(kind: "updated", addedDay: addedDay, updatedDay: updatedDay)
                    )
                }
            }
        }

        appendUpdates(sourceApps)
        appendUpdates(dylibs)

        let days = dayKeys.map {
            KiraUpdatesDay(date: $0, new: newCounts[$0] ?? 0, updated: updatedCounts[$0] ?? 0)
        }
        return KiraUpdatesSnapshot(
            refreshedAt: Date(),
            days: days,
            appsByDay: buckets,
            catalog: catalog
        )
    }

    private static func normalizedText(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == " " }
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (a, b) in zip(lhs, rhs) {
            guard a == b else { break }
            count += 1
        }
        return count
    }

    private static func bundleSimilarity(_ lhs: String?, _ rhs: String?) -> Int {
        let a = normalizedText(lhs).replacingOccurrences(of: " ", with: "")
        let b = normalizedText(rhs).replacingOccurrences(of: " ", with: "")
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 10_000 }

        let ac = a.split(separator: ".")
        let bc = b.split(separator: ".")
        var matchingComponents = 0
        for (x, y) in zip(ac, bc) {
            guard x == y else { break }
            matchingComponents += 1
        }
        return matchingComponents * 1_000 + commonPrefixCount(a, b) * 10
    }

    private static func nameSimilarity(_ lhs: String, _ rhs: String) -> Int {
        let a = normalizedText(lhs)
        let b = normalizedText(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 10_000 }

        let aCompact = a.replacingOccurrences(of: " ", with: "")
        let bCompact = b.replacingOccurrences(of: " ", with: "")
        let prefix = commonPrefixCount(aCompact, bCompact)
        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        let sharedTokens = aTokens.intersection(bTokens).count
        let containsBonus = (aCompact.contains(bCompact) || bCompact.contains(aCompact)) ? 600 : 0
        return prefix * 20 + sharedTokens * 400 + containsBonus
    }

    private static func versionDistance(_ lhs: String?, _ rhs: String?) -> Int64 {
        func vector(_ raw: String?) -> [Int64] {
            let parts = (raw ?? "")
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int64($0) }
            return Array((parts + [0, 0, 0, 0]).prefix(4))
        }

        let a = vector(lhs)
        let b = vector(rhs)
        let weights: [Int64] = [1_000_000_000, 1_000_000, 1_000, 1]
        return zip(zip(a, b), weights).reduce(Int64(0)) { result, pair in
            let ((x, y), weight) = pair
            return result + abs(x - y) * weight
        }
    }
}
