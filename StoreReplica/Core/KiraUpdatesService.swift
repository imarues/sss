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
    let version: String?
    let versionDate: String?
    let size: Int64?
    let addedAt: String?
    let updatedAt: String?
    let downloadURL: String?
    let downloadUrl: String?
    let url: String?
    let versions: [KiraPagesVersion]?

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, bundleId, iconURL, localizedDescription, category
        case version, versionDate, size, addedAt, updatedAt
        case downloadURL, downloadUrl, url, versions
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
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        versionDate = try? c.decodeIfPresent(String.self, forKey: .versionDate)
        addedAt = try? c.decodeIfPresent(String.self, forKey: .addedAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
        downloadUrl = try? c.decodeIfPresent(String.self, forKey: .downloadUrl)
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
        [downloadURL, downloadUrl, url].compactMap { $0?.nilWhenBlank }.first
            ?? currentVersionObject?.effectiveDownloadURL
    }

    var stableID: String {
        id ?? bundleIdentifier ?? bundleId ?? "\(name)-\(effectiveVersion ?? "")"
    }

    func storeApp(kind: String, addedDay: String?, updatedDay: String?) -> StoreApp {
        StoreApp(
            id: stableID,
            name: name,
            bundleId: bundleIdentifier ?? bundleId,
            version: effectiveVersion,
            fileSize: effectiveSize,
            notes: localizedDescription,
            iconUrl: iconURL,
            categories: category.map { [$0] },
            updatedAt: updatedDay,
            addedAt: addedDay,
            versionUpdatedAt: KiraUpdatesClock.normalizedDay(effectiveVersionDate),
            feedKind: kind,
            downloadUrl: effectiveDownloadURL
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

    private let sourceURL = URL(string: "https://ikiraplus.pages.dev/IPA-AR.json")!
    private var memorySnapshot: KiraUpdatesSnapshot?
    private var refreshTask: Task<KiraUpdatesSnapshot, Error>?

    private var cacheFile: URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return root.appendingPathComponent("iKiraPlus-updates-snapshot.json", isDirectory: false)
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

        let url = sourceURL
        let task = Task<KiraUpdatesSnapshot, Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 35
            request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("ar-IQ,ar;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw StoreAPIError.invalidResponse
            }

            let source = try JSONDecoder().decode(KiraPagesSource.self, from: data)
            return Self.buildSnapshot(from: source.apps)
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
        return KiraUpdatesSnapshot(refreshedAt: snapshot.refreshedAt, days: days, appsByDay: alignedApps)
    }

    private static func buildSnapshot(from sourceApps: [KiraPagesApp]) -> KiraUpdatesSnapshot {
        let dayKeys = KiraUpdatesClock.lastSevenDayKeys()
        let validDays = Set(dayKeys)
        var newCounts = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, 0) })
        var updatedCounts = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, 0) })
        var buckets = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, [StoreApp]()) })

        for source in sourceApps {
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

        let days = dayKeys.map {
            KiraUpdatesDay(date: $0, new: newCounts[$0] ?? 0, updated: updatedCounts[$0] ?? 0)
        }
        return KiraUpdatesSnapshot(refreshedAt: Date(), days: days, appsByDay: buckets)
    }
}
