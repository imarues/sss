import Foundation

struct AppleAppStoreItem {
    let screenshots: [URL]
    let rating: Double?
    let ratingCount: Int?
    let developer: String?
    let category: String?
}

actor AppleAppStoreLookup {
    static let shared = AppleAppStoreLookup()

    private var cache: [String: AppleAppStoreItem] = [:]
    private var misses: Set<String> = []
    private var inFlight: [String: Task<AppleAppStoreItem?, Never>] = [:]

    func item(bundleID rawBundleID: String) async -> AppleAppStoreItem? {
        var normalizedBundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBundleID.hasSuffix("Beta") {
            normalizedBundleID = String(normalizedBundleID.dropLast(4))
        }
        guard !normalizedBundleID.isEmpty else { return nil }

        let bundleID = normalizedBundleID

        if let cached = cache[bundleID] { return cached }
        if misses.contains(bundleID) { return nil }
        if let running = inFlight[bundleID] { return await running.value }

        let task = Task<AppleAppStoreItem?, Never> {
            let local = (Locale.current.region?.identifier ?? "us").lowercased()
            if let result = await Self.fetch(bundleID: bundleID, country: local) {
                return result
            }
            if local != "us" {
                return await Self.fetch(bundleID: bundleID, country: "us")
            }
            return nil
        }
        inFlight[bundleID] = task
        let result = await task.value
        inFlight[bundleID] = nil

        if let result {
            cache[bundleID] = result
        } else {
            misses.insert(bundleID)
        }
        return result
    }

    private static func fetch(bundleID: String, country: String) async -> AppleAppStoreItem? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let entry = decoded.results.first else {
            return nil
        }

        let rawShots: [String]
        if let phone = entry.screenshotUrls, !phone.isEmpty {
            rawShots = phone
        } else {
            rawShots = entry.ipadScreenshotUrls ?? []
        }

        return AppleAppStoreItem(
            screenshots: rawShots.compactMap { sizedScreenshotURL($0, width: 900) },
            rating: entry.averageUserRating,
            ratingCount: entry.userRatingCount,
            developer: entry.sellerName,
            category: entry.primaryGenreName
        )
    }

    private static func sizedScreenshotURL(_ raw: String, width: Int) -> URL? {
        guard let url = URL(string: raw) else { return nil }
        let filename = url.lastPathComponent
        guard let x = filename.firstIndex(of: "x"), Int(filename[..<x]) != nil else { return url }

        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let replacement = "\(width)x0w.\(ext)"
        var base = url.deletingLastPathComponent().absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + replacement) ?? url
    }

    private struct LookupResponse: Decodable {
        let results: [LookupEntry]
    }

    private struct LookupEntry: Decodable {
        let screenshotUrls: [String]?
        let ipadScreenshotUrls: [String]?
        let averageUserRating: Double?
        let userRatingCount: Int?
        let sellerName: String?
        let primaryGenreName: String?
    }
}
