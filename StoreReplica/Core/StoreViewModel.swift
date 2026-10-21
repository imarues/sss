import SwiftUI
import UIKit
import Foundation
import CoreText
@MainActor
final class StoreViewModel: ObservableObject {
    @Published var config: StoreConfigResponse = MockStoreData.config
    @Published var home: HomeResponse = MockStoreData.home
    @Published var explore: ExploreResponse = MockStoreData.explore
    @Published var searchMeta: SearchMetaResponse = MockStoreData.searchMeta
    @Published var feed: FeedResponse = MockStoreData.feed
    @Published var catalog: CatalogResponse = MockStoreData.catalog
    @Published var cards: CardsResponse = MockStoreData.cards
    @Published var loading = false
    @Published var lastError: String?

    private let api = StoreAPI.shared

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadConfig() }
            group.addTask { await self.loadHome() }
            group.addTask { await self.loadExplore() }
            group.addTask { await self.loadSearch() }
            group.addTask { await self.loadFeed() }
            group.addTask { await self.loadCatalog() }
            group.addTask { await self.loadCards() }
        }
    }

    private func loadConfig() async { do { config = try await api.configResponse() } catch { lastError = error.localizedDescription } }
    private func loadHome() async { do { home = try await api.home() } catch { lastError = error.localizedDescription } }
    private func loadExplore() async { do { explore = try await api.explore() } catch { lastError = error.localizedDescription } }
    private func loadSearch() async { do { searchMeta = try await api.searchMeta() } catch { lastError = error.localizedDescription } }
    private func loadFeed() async { do { feed = try await api.feed() } catch { lastError = error.localizedDescription } }
    private func loadCatalog() async { do { catalog = try await api.catalog() } catch { lastError = error.localizedDescription } }
    private func loadCards() async { do { cards = try await api.cards() } catch { lastError = error.localizedDescription } }

    func search(_ query: String) -> [StoreApp] {
        let all = uniqueApps(home.sections.flatMap { $0.apps ?? [] } + (catalog.apps ?? []) + feed.apps)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return all.filter { app in
            [app.name, app.bundleId ?? "", app.notes ?? "", (app.categories ?? []).joined(separator: " ")]
                .joined(separator: " ").localizedCaseInsensitiveContains(q)
        }
    }

    func allApps() -> [StoreApp] { uniqueApps(home.sections.flatMap { $0.apps ?? [] } + (catalog.apps ?? []) + feed.apps) }

    private func uniqueApps(_ apps: [StoreApp]) -> [StoreApp] {
        var ids = Set<String>(); return apps.filter { ids.insert($0.id).inserted }
    }
}

enum MockStoreData {
    static let config = StoreConfigResponse(
        slug: "alturath-store", storeName: "التراث بلس", tagline: "أقوى متجر لتطبيقات البلس والاشتراكات الرقمية", iconUrl: nil,
        design: DesignSpec(v: 1, preset: "night", mode: "dark", colors: nil, shape: ShapeSpec(radius: "round", card: "flat"), type: TypeSpec(font: "ping", scale: "m"), tabBar: StyleSpec(style: "floating"), install: StyleSpec(style: "pill"), badges: StyleSpec(style: "pill")),
        splash: SplashSpec(enabled: true, title: "التراث بلس", subtitle: "أقوى متجر لتطبيقات البلس والاشتراكات الرقمية", bgColor: "#011D57", inkColor: "#FFFFFF", accentColor: "#FFFFFF", seconds: 3, imageUrl: nil, layout: "FLOAT", appCount: 10920), shop: ShopConfig(enabled: true))

    static let sampleApps: [StoreApp] = [
        StoreApp(id: "reddit", name: "Reddit", bundleId: "com.reddit.Reddit", version: "2026.42.0", fileSize: 148915606, notes: "تطبيق Reddit مدموج بأداة Deluxe.", iconUrl: nil, featured: true, categories: ["تواصل إجتماعي"], installs: 1),
        StoreApp(id: "athan", name: "Athan Pro", bundleId: "Quanticapps.Athan", version: "9.0.3", fileSize: 53630502, notes: "مفتوح المميزات بالكامل", iconUrl: nil, featured: true, categories: ["التطبيقات الاسلاميه"], installs: 34),
        StoreApp(id: "8ball", name: "8 Ball Pool free", bundleId: "com.miniclip.8ballpoolmult", version: "56.31.1", fileSize: 99362517, notes: "نسخة مميزة مع تحسينات متعددة.", iconUrl: nil, featured: true, categories: ["تطبيقات مميزة"], installs: 15),
        StoreApp(id: "quizlet", name: "Quizlet", bundleId: "com.quizlet.quizlet", version: "10.57", fileSize: 88006634, notes: "مفتوح المميزات", iconUrl: nil, featured: false, categories: ["تطبيقات"], installs: 0)
    ]

    static let categories: [StoreCategory] = [
        StoreCategory(id: "featured", name: "تطبيقات مميزة", emoji: "✦", count: 120),
        StoreCategory(id: "apps", name: "تطبيقات", emoji: "▣", count: 5300),
        StoreCategory(id: "games", name: "ألعاب", emoji: "◆", count: 4200),
        StoreCategory(id: "paid", name: "مدفوعة", emoji: "●", count: 800),
        StoreCategory(id: "social", name: "تواصل إجتماعي", emoji: "◎", count: 250),
        StoreCategory(id: "islamic", name: "إسلامية", emoji: "◇", count: 150)
    ]

    static let home = HomeResponse(layout: "CLASSIC", top10Ids: [], bannersAutoplay: true, bannerApps: sampleApps, banners: [], sections: [
        HomeSection(title: "تطبيقات رئيسية في كل جهاز", kind: "PRESET", layout: "CARD_BAND", screen: "HOME", presetKey: "most_downloaded", apps: sampleApps),
        HomeSection(title: "الفئات", kind: "PRESET", layout: "CATEGORY_STRIP", screen: "HOME", presetKey: "categories", categories: categories),
        HomeSection(title: "اخر التطبيقات المضافة", kind: "PRESET", layout: "CARD_BAND", screen: "HOME", presetKey: "latest", apps: Array(sampleApps.reversed())),
        HomeSection(title: "الأكثر تحميلاً", kind: "PRESET", layout: "SHOWCASE", screen: "HOME", presetKey: "most_downloaded", apps: sampleApps),
        HomeSection(title: "اقسام تسهل عليك البحث", kind: "PRESET", layout: "CATEGORY_GRID", screen: "HOME", presetKey: "categories", categories: categories),
        HomeSection(title: "اخر التحديثات", kind: "PRESET", layout: "LIST_LARGE", screen: "HOME", presetKey: "recently_updated", apps: sampleApps)
    ])
    static let explore = ExploreResponse(layout: "TILES", totalApps: 10920, categories: categories)
    static let searchMeta = SearchMetaResponse(layout: "HERO", totalApps: 10920, newToday: 0, trending: [TrendingSearch(term: "network", count: 15, app: sampleApps.first), TrendingSearch(term: "gta", count: 6, app: sampleApps.last)])
    static let feed = FeedResponse(tab: "day", page: 1, counts: FeedCounts(new: 47, updated: 855), week: [], day: nil, hasMore: false, apps: sampleApps)
    static let catalog = CatalogResponse(settingsLayout: "TICKET", subscription: SubscriptionInfo(planName: "الباقة الملكية", expiresAt: "2027-04-22", startsAt: "2026-04-22", deviceModel: "iPhone", showUdid: false, pushMuted: false), page: 1, pageSize: 50, total: 10920, pages: 219, apps: sampleApps)
    static let cards = CardsResponse(store: CardStoreInfo(slug: "alturath-store", storeName: "التراث بلس", logoUrl: nil, theme: "NIGHT", themeColor: "#1D1D1F"), categories: [], products: [])
}
