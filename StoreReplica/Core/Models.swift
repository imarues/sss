import SwiftUI
import UIKit
import Foundation
import CoreText

struct StoreConfigResponse: Codable {
    var slug: String? = nil
    var storeName: String? = nil
    var tagline: String? = nil
    var iconUrl: String? = nil
    var design: DesignSpec? = nil
    var splash: SplashSpec? = nil
    var shop: ShopConfig? = nil
}

struct ShopConfig: Codable { var enabled: Bool? = nil }

struct DesignSpec: Codable {
    var v: Int? = nil
    var preset: String? = nil
    var mode: String? = nil
    var colors: DesignColors? = nil
    var shape: ShapeSpec? = nil
    var type: TypeSpec? = nil
    var tabBar: StyleSpec? = nil
    var install: StyleSpec? = nil
    var badges: StyleSpec? = nil
}

struct DesignColors: Codable {
    var accent: String? = nil; var onAccent: String? = nil; var background: String? = nil; var surface: String? = nil
    var surfaceBorder: String? = nil; var sheet: String? = nil; var field: String? = nil; var textPrimary: String? = nil
    var textSecondary: String? = nil; var installBg: String? = nil; var installText: String? = nil
    var badgeNewBg: String? = nil; var badgeNewText: String? = nil; var badgeUpdatedBg: String? = nil
    var badgeUpdatedText: String? = nil; var tabBarBg: String? = nil; var tabActive: String? = nil; var tabInactive: String? = nil
}

struct ShapeSpec: Codable { var radius: String? = nil; var card: String? = nil }
struct TypeSpec: Codable { var font: String? = nil; var scale: String? = nil }
struct StyleSpec: Codable { var style: String? = nil }

struct SplashSpec: Codable {
    var enabled: Bool? = nil; var title: String? = nil; var subtitle: String? = nil; var bgColor: String? = nil
    var inkColor: String? = nil; var accentColor: String? = nil; var seconds: Double? = nil; var imageUrl: String? = nil
    var layout: String? = nil; var appCount: Int? = nil
}

struct HomeResponse: Codable {
    var layout: String? = nil
    var top10Ids: [String]? = nil
    var bannersAutoplay: Bool? = nil
    var bannerApps: [StoreApp]? = nil
    var banners: [HomeBanner]? = nil
    var sections: [HomeSection] = []
}

struct HomeBanner: Codable, Identifiable, Hashable {
    var id: String
    var title: String? = nil
    var subtitle: String? = nil
    var imageUrl: String? = nil
    var url: String? = nil
    var action: String? = nil
    var appPackageId: String? = nil
    var categoryId: String? = nil
}

struct HomeSection: Codable, Identifiable {
    var id: String? = nil
    var title: String? = nil
    var kind: String? = nil
    var layout: String? = nil
    var screen: String? = nil
    var presetKey: String? = nil
    var apps: [StoreApp]? = nil
    var categories: [StoreCategory]? = nil
    var categoryId: String? = nil

    var stableId: String { id ?? "\(title ?? "section")-\(layout ?? "")" }
}

struct StoreApp: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleId: String? = nil
    var version: String? = nil
    var buildNumber: String? = nil
    var minIosVersion: String? = nil
    var fileSize: Int64? = nil
    var notes: String? = nil
    var iconUrl: String? = nil
    var featured: Bool? = nil
    var categories: [String]? = nil
    var installs: Int? = nil
    var updatedAt: String? = nil
    var addedAt: String? = nil
    var versionUpdatedAt: String? = nil
    var feedKind: String? = nil
    var downloadUrl: String? = nil
    var downloadURL: String? = nil

    var effectiveDownloadURL: String? {
        let candidates = [downloadUrl, downloadURL]
        return candidates.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }
}

struct StoreCategory: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var emoji: String? = nil
    var count: Int? = nil
    var imageUrl: String? = nil
    var apps: [StoreApp]? = nil
}

struct ExploreResponse: Codable {
    var layout: String? = nil
    var totalApps: Int? = nil
    var categories: [StoreCategory]? = nil
}

struct SearchMetaResponse: Codable {
    var layout: String? = nil
    var totalApps: Int? = nil
    var newToday: Int? = nil
    var trending: [TrendingSearch]? = nil
}

struct TrendingSearch: Codable, Identifiable {
    var term: String
    var count: Int? = nil
    var app: StoreApp? = nil
    var id: String { term }
}

struct FeedResponse: Codable {
    var tab: String? = nil
    var page: Int? = nil
    var counts: FeedCounts? = nil
    var week: [FeedDay]? = nil
    var day: String? = nil
    var hasMore: Bool? = nil
    var apps: [StoreApp] = []
}

struct FeedCounts: Codable { var new: Int? = nil; var updated: Int? = nil }
struct FeedDay: Codable, Identifiable { var date: String; var new: Int? = nil; var updated: Int? = nil; var id: String { date } }

struct CatalogResponse: Codable {
    var settingsLayout: String? = nil
    var subscription: SubscriptionInfo? = nil
    var page: Int? = nil
    var pageSize: Int? = nil
    var total: Int? = nil
    var pages: Int? = nil
    var apps: [StoreApp]? = nil
}

struct SubscriptionInfo: Codable {
    var planName: String? = nil
    var expiresAt: String? = nil
    var startsAt: String? = nil
    var certificateName: String? = nil
    var deviceModel: String? = nil
    var fullName: String? = nil
    var showUdid: Bool? = nil
    var pushMuted: Bool? = nil
}

struct SimilarResponse: Codable { var byCategory: Bool? = nil; var apps: [StoreApp]? = nil }
struct PackageExtras: Codable { var allowDuplicate: Bool? = nil; var allowDylibs: Bool? = nil; var keepProfile: Bool? = nil }
struct ReviewsResponse: Codable { var enabled: Bool? = nil; var average: Double? = nil; var count: Int? = nil }

struct CardsResponse: Codable {
    var store: CardStoreInfo? = nil
    var categories: [CardCategory]? = nil
    var products: [CardProduct]? = nil
}

struct CardStoreInfo: Codable {
    var slug: String? = nil
    var storeName: String? = nil
    var logoUrl: String? = nil
    var theme: String? = nil
    var themeColor: String? = nil
}

struct CardCategory: Codable, Identifiable {
    var id: String
    var name: String
    var imageUrl: String? = nil
}

struct CardProduct: Codable, Identifiable {
    var id: String
    var name: String
    var seoSlug: String? = nil
    var description: String? = nil
    var categoryId: String? = nil
    var kind: String? = nil
    var soldOut: Bool? = nil
    var price: Int? = nil
    var compareAtPrice: Int? = nil
    var currency: String? = nil
    var stock: Int? = nil
    var imageUrl: String? = nil
}
