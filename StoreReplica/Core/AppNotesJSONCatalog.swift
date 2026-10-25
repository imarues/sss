import Foundation

/// Two read-only public sources maintained in ikiraplus/freeapps.
/// Only app IDs and descriptions are decoded, not full 2 MB app objects.
actor AppNotesJSONCatalog {
    static let shared = AppNotesJSONCatalog()

    enum Language: String, Hashable {
        case arabic = "AR"
        case english = "EN"

        var primaryURL: URL {
            URL(string: "https://ikiraplus.pages.dev/IPA-\(rawValue).json")!
        }
        var backupURL: URL {
            URL(string: "https://raw.githubusercontent.com/ikiraplus/freeapps/main/IPA-\(rawValue).json")!
        }
        var cacheFileName: String { "turath-descriptions-\(rawValue).json" }
    }

    private struct Source: Decodable {
        let apps: [Entry]
    }
    private struct Entry: Decodable {
        let id: String
        let localizedDescription: String?
    }
    private struct Snapshot {
        let values: [String: String]
        let fetchedAt: Date
    }

    private let refreshInterval: TimeInterval = 900
    private var memory: [Language: Snapshot] = [:]
    private var running: [Language: Task<[String: String], Error>] = [:]

    func description(appID: String, language: Language) async throws -> String? {
        if let current = memory[language], let value = current.values[appID] {
            if Date().timeIntervalSince(current.fetchedAt) >= refreshInterval {
                scheduleRefresh(language)
            }
            return value
        }

        // Disk cache allows immediate return on later launches, including offline.
        if memory[language] == nil, let saved = readDisk(language) {
            memory[language] = saved
            if let value = saved.values[appID] {
                if Date().timeIntervalSince(saved.fetchedAt) >= refreshInterval {
                    scheduleRefresh(language)
                }
                return value
            }
        }

        let values = try await refresh(language)
        return values[appID]
    }

    private func scheduleRefresh(_ language: Language) {
        guard running[language] == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.refresh(language)
        }
    }

    private func refresh(_ language: Language) async throws -> [String: String] {
        if let existing = running[language] {
            return try await existing.value
        }

        let operation = Task<[String: String], Error> {
            do {
                return try await Self.fetch(language.primaryURL)
            } catch {
                return try await Self.fetch(language.backupURL)
            }
        }
        running[language] = operation
        defer { running[language] = nil }

        do {
            let values = try await operation.value
            let snapshot = Snapshot(values: values, fetchedAt: Date())
            memory[language] = snapshot
            saveDisk(snapshot, language: language)
            return values
        } catch {
            // Network failure must never erase translations already cached.
            if let stale = memory[language] { return stale.values }
            if let saved = readDisk(language) {
                memory[language] = saved
                return saved.values
            }
            throw error
        }
    }

    private static func fetch(_ url: URL) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.cachePolicy = .useProtocolCachePolicy
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let source = try JSONDecoder().decode(Source.self, from: data)
        guard !source.apps.isEmpty else { throw URLError(.cannotParseResponse) }
        var map: [String: String] = [:]
        map.reserveCapacity(source.apps.count)
        for app in source.apps {
            let value = app.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { map[app.id] = value }
        }
        return map
    }

    private func fileURL(_ language: Language) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(language.cacheFileName)
    }

    private func readDisk(_ language: Language) -> Snapshot? {
        guard let file = fileURL(language),
              let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              !values.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
        return Snapshot(values: values, fetchedAt: modifiedAt)
    }

    private func saveDisk(_ snapshot: Snapshot, language: Language) {
        guard let file = fileURL(language),
              let data = try? JSONEncoder().encode(snapshot.values) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
