import SwiftUI
import UIKit
import Foundation
import CoreText
struct StoreRuntimeConfig {
    static let shared = StoreRuntimeConfig()
    let apiBase = URL(string: "https://alturath-store.com")!
    let slug = "alturath-store"
    let language = "ar"

    var deviceUDID: String? {
        let value = UserDefaults.standard.string(forKey: "store.deviceUDID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

enum StoreAPIError: Error { case invalidURL, invalidResponse }

final class StoreAPI {
    static let shared = StoreAPI()
    private let config = StoreRuntimeConfig.shared

    func configResponse() async throws -> StoreConfigResponse { try await get("app/config") }
    func home() async throws -> HomeResponse { try await get("app/home") }
    func explore() async throws -> ExploreResponse { try await get("app/explore") }
    func searchMeta() async throws -> SearchMetaResponse { try await get("app/search/meta", extra: [URLQueryItem(name: "tz", value: "180")]) }
    func catalog(page: Int = 1, pageSize: Int = 50) async throws -> CatalogResponse {
        try await get("app/catalog", extra: [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "pageSize", value: "\(pageSize)")])
    }
    func feed(tab: String = "updated") async throws -> FeedResponse {
        let date = ISO8601DateFormatter.dayString.string(from: Date())
        return try await get("app/feed", extra: [
            URLQueryItem(name: "tab", value: tab), URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "tz", value: "180"), URLQueryItem(name: "day", value: date)
        ])
    }
    func similar(appId: String) async throws -> SimilarResponse { try await get("app/similar/\(appId)") }
    func extras(appId: String) async throws -> PackageExtras { try await get("app/package-extras/\(appId)", includeUDID: false) }
    func reviews(appId: String) async throws -> ReviewsResponse { try await get("app/reviews/\(appId)") }
    func cards() async throws -> CardsResponse {
        guard var c = URLComponents(url: config.apiBase.appendingPathComponent("a").appendingPathComponent(config.slug).appendingPathComponent("cards"), resolvingAgainstBaseURL: false) else { throw StoreAPIError.invalidURL }
        c.queryItems = [URLQueryItem(name: "lang", value: config.language)]
        guard let url = c.url else { throw StoreAPIError.invalidURL }
        return try await request(url)
    }

    func absoluteURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let direct = URL(string: value), direct.scheme != nil { return direct }
        return URL(string: value, relativeTo: config.apiBase)?.absoluteURL
    }

    private func get<T: Decodable>(_ route: String, includeUDID: Bool = true, extra: [URLQueryItem] = []) async throws -> T {
        let root = config.apiBase.appendingPathComponent("a").appendingPathComponent(config.slug).appendingPathComponent("app")
        let routePart = route.hasPrefix("app/") ? String(route.dropFirst(4)) : route
        guard var components = URLComponents(url: root.appendingPathComponent(routePart), resolvingAgainstBaseURL: false) else { throw StoreAPIError.invalidURL }
        var items = [URLQueryItem(name: "lang", value: config.language)]
        if includeUDID, let udid = config.deviceUDID { items.append(URLQueryItem(name: "udid", value: udid)) }
        items.append(contentsOf: extra)
        components.queryItems = items
        guard let url = components.url else { throw StoreAPIError.invalidURL }
        return try await request(url)
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ar", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw StoreAPIError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension ISO8601DateFormatter {
    static let dayString: DateFormatter = {
        let f = DateFormatter(); f.calendar = .init(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
