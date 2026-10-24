import SwiftUI
import Foundation

// Unlike the old Explore tiles, every membership here comes from a verified
// Apple App Store genre/price lookup of an app published in IPA-AR.json.
// The server updates this compact index incrementally to avoid thousands
// of Apple API requests from each customer's phone.
private struct VerifiedExploreIndex: Decodable {
    let schema: Int
    let source: String
    let generatedAt: String
    let sourceCount: Int
    let eligibleCount: Int
    let checkedCount: Int
    let verifiedCount: Int
    let categories: [VerifiedExploreGenre]
}

private struct VerifiedExploreGenre: Decodable, Identifiable {
    let id: String
    let nameAr: String
    let nameEn: String
    let symbol: String
    let glow: String
    let appIDs: [String]
    let count: Int

    var localizedName: String { StoreLanguage.isEnglish ? nameEn : nameAr }
    var glowColor: Color { Color(hex: glow) }
}

private struct VerifiedExploreSection: Identifiable {
    let category: VerifiedExploreGenre
    let apps: [StoreApp]
    var id: String { category.id }
}

private enum VerifiedExploreCache {
    static let feed = URL(string: "https://raw.githubusercontent.com/imarues/sss/main/explore-index.json")!
    static let source = "https://ikiraplus.pages.dev/IPA-AR.json"

    private static func file(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }

    static func loadIndex(force: Bool) async throws -> VerifiedExploreIndex {
        var request = URLRequest(url: feed)
        request.timeoutInterval = 25
        request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count < 15_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let parsed = try decodeIndex(data)
        try? data.write(to: file("turath-verified-explore-index.json"), options: .atomic)
        return parsed
    }

    static func cachedIndex() -> VerifiedExploreIndex? {
        guard let data = try? Data(contentsOf: file("turath-verified-explore-index.json")) else {
            return nil
        }
        return try? decodeIndex(data)
    }

    static func cachedApps() -> [StoreApp]? {
        guard let data = try? Data(contentsOf: file("turath-verified-explore-apps.json")) else {
            return nil
        }
        return try? JSONDecoder().decode([StoreApp].self, from: data)
    }

    static func storeApps(_ apps: [StoreApp]) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: file("turath-verified-explore-apps.json"), options: .atomic)
    }

    private static func decodeIndex(_ data: Data) throws -> VerifiedExploreIndex {
        let result = try JSONDecoder().decode(VerifiedExploreIndex.self, from: data)
        guard result.schema == 1,
              result.source == source,
              !result.categories.isEmpty,
              Set(result.categories.map(\.id)).count == result.categories.count,
              result.categories.allSatisfy({
                  $0.count == $0.appIDs.count &&
                  $0.count >= 0 &&
                  !$0.nameAr.isEmpty &&
                  !$0.nameEn.isEmpty
              }) else {
            throw URLError(.cannotParseResponse)
        }
        return result
    }
}

@MainActor
private final class VerifiedExploreModel: ObservableObject {
    @Published private(set) var sections: [VerifiedExploreSection] = []
    @Published private(set) var ipaCount = 0
    @Published private(set) var checkedCount = 0
    @Published private(set) var eligibleCount = 0
    @Published private(set) var loading = false
    @Published private(set) var usedOfflineCache = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdated: String?

    private var currentIndex: VerifiedExploreIndex?
    private var publishedApps: [StoreApp] = []

    func reload(force: Bool = false) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }

        // Show only genuine previously verified records if the connection drops.
        if currentIndex == nil {
            currentIndex = VerifiedExploreCache.cachedIndex()
        }
        if publishedApps.isEmpty {
            publishedApps = VerifiedExploreCache.cachedApps() ?? []
        }
        recalculate()

        // These requests are independent. One source failing cannot replace
        // the previously checked category set with fabricated app counts.
        async let source = KiraSourceSearchService.shared.exploreApps(force: force)
        async let verified = VerifiedExploreCache.loadIndex(force: force)

        let newApps = try? await source
        let newIndex = try? await verified

        if let newApps, !newApps.isEmpty {
            publishedApps = newApps.filter { !$0.isDylibAsset }
            VerifiedExploreCache.storeApps(publishedApps)
        }
        if let newIndex {
            currentIndex = newIndex
        }
        usedOfflineCache = (newApps == nil || newIndex == nil)
        if currentIndex == nil {
            error = StoreLanguage.isEnglish
                ? "Verified App Store categories are not available yet. Pull down to retry."
                : "بيانات تصنيفات App Store المؤكدة غير متوفرة حالياً. اسحب للتحديث."
        } else if publishedApps.isEmpty {
            error = StoreLanguage.isEnglish
                ? "Could not load our published IPA apps."
                : "تعذر تحميل التطبيقات المنشورة من IPA-AR."
        }
        recalculate()
    }

    private func recalculate() {
        var byID: [String: StoreApp] = [:]
        for app in publishedApps where byID[app.id] == nil {
            byID[app.id] = app
        }
        guard let index = currentIndex else {
            sections = []
            ipaCount = publishedApps.count
            checkedCount = 0
            eligibleCount = 0
            lastUpdated = nil
            return
        }
        // Count is derived from real, currently published IPA-AR entries,
        // not from Apple's entire store or hardcoded example numbers.
        sections = index.categories.map { category in
            var used: Set<String> = []
            let apps = category.appIDs.compactMap { id -> StoreApp? in
                guard used.insert(id).inserted else { return nil }
                return byID[id]
            }
            return VerifiedExploreSection(category: category, apps: apps)
        }
        ipaCount = publishedApps.count
        checkedCount = index.checkedCount
        eligibleCount = index.eligibleCount
        lastUpdated = index.generatedAt
    }
}

struct VerifiedExploreView: View {
    @StateObject private var model = VerifiedExploreModel()

    private let columns = [
        GridItem(.flexible(), spacing: 13),
        GridItem(.flexible(), spacing: 13)
    ]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 17) {
                    StoreHeader()

                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(StoreLanguage.isEnglish ? "Explore" : "استكشف")
                                .font(AppFont.black(29))
                                .foregroundStyle(StoreTheme.textPrimary)
                            Text(StoreLanguage.isEnglish
                                 ? "Browse our apps by real App Store genres"
                                 : "اكتشف تطبيقاتنا حسب تصنيفات App Store الحقيقية")
                                .font(AppFont.regular(12))
                                .foregroundStyle(StoreTheme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        Spacer()
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(StoreTheme.accent)
                            .frame(width: 49, height: 49)
                            .background(StoreTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)

                    if model.ipaCount > 0 {
                        HStack(spacing: 8) {
                            Text(StoreLanguage.isEnglish
                                 ? "\(model.checkedCount) verified/checked of \(model.eligibleCount) eligible apps"
                                 : "تم فحص \(model.checkedCount) من \(model.eligibleCount) تطبيق قابل للمطابقة")
                                .font(AppFont.medium(11))
                                .foregroundStyle(StoreTheme.textSecondary)
                            Spacer()
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(StoreTheme.accent)
                            Text(StoreLanguage.isEnglish ? "IPA-AR + Apple" : "IPA-AR + Apple")
                                .font(AppFont.medium(11))
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        .padding(.horizontal, StoreTheme.pageHorizontal)
                    }

                    if model.usedOfflineCache {
                        Label(
                            StoreLanguage.isEnglish
                                ? "Showing previously checked categories; pull to refresh."
                                : "يعرض آخر بيانات مؤكدة محفوظة؛ اسحب للتحديث.",
                            systemImage: "wifi.slash"
                        )
                        .font(AppFont.medium(11))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, StoreTheme.pageHorizontal)
                    }

                    if !model.sections.isEmpty {
                        LazyVGrid(columns: columns, spacing: 13) {
                            ForEach(model.sections) { section in
                                NavigationLink(destination: VerifiedGenreAppsView(section: section)) {
                                    VerifiedGlassCategoryCard(section: section)
                                }
                                .buttonStyle(VerifiedCategoryPressStyle())
                                .accessibilityLabel(
                                    "\(section.category.localizedName), \(section.apps.count) " +
                                    (StoreLanguage.isEnglish ? "apps" : "تطبيق")
                                )
                            }
                        }
                        .padding(.horizontal, StoreTheme.pageHorizontal)
                    }

                    if model.loading && model.sections.isEmpty {
                        VStack(spacing: 13) {
                            ProgressView().tint(StoreTheme.accent)
                            Text(StoreLanguage.isEnglish
                                 ? "Matching published apps with Apple categories…"
                                 : "جاري مطابقة التطبيقات المنشورة مع تصنيفات Apple…")
                                .font(AppFont.medium(12))
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 65)
                    } else if model.sections.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "square.grid.2x2.slash")
                                .font(.system(size: 32))
                                .foregroundStyle(StoreTheme.accent)
                            Text(model.error ?? (StoreLanguage.isEnglish
                                  ? "No verified categories available"
                                  : "لا توجد تصنيفات مؤكدة حالياً"))
                                .font(AppFont.medium(13))
                                .foregroundStyle(StoreTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button {
                                Task { await model.reload(force: true) }
                            } label: {
                                Text(StoreLanguage.isEnglish ? "Retry" : "إعادة المحاولة")
                                    .font(AppFont.bold(13))
                                    .padding(.horizontal, 21)
                                    .frame(height: 40)
                                    .foregroundStyle(.white)
                                    .background(StoreTheme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 54)
                    }

                    if !model.sections.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "info.circle")
                            Text(StoreLanguage.isEnglish
                                 ? "Counts include only apps published by Turath and verified by Apple. Paid Games requires an official paid App Store price."
                                 : "الأعداد تشمل فقط تطبيقات التراث التي تمت مطابقتها مع Apple. الألعاب المدفوعة تتطلب سعراً رسمياً أكبر من صفر.")
                        }
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, StoreTheme.pageHorizontal)
                    }
                }
                .padding(.bottom, 22)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.reload(force: true) }
            .task { await model.reload() }
        }
    }
}

private struct VerifiedCategoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.easeOut(duration: 0.17), value: configuration.isPressed)
    }
}

private struct VerifiedGlassCategoryCard: View {
    let section: VerifiedExploreSection

    private var tint: Color { section.category.glowColor }
    private var picture: StoreApp? {
        section.apps.first(where: {
            if let icon = $0.iconUrl { return !icon.isEmpty }
            return false
        })
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.30),
                            Color(red: 0.115, green: 0.16, blue: 0.27).opacity(0.93),
                            StoreTheme.surface.opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            GeometryReader { geometry in
                Circle()
                    .fill(tint.opacity(0.32))
                    .frame(width: geometry.size.width * 0.84, height: 140)
                    .blur(radius: 31)
                    .offset(x: geometry.size.width * 0.35, y: -71)
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.21), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 37, height: 240)
                    .rotationEffect(.degrees(24))
                    .blur(radius: 9)
                    .offset(x: geometry.size.width * 0.60, y: -42)
            }
            .clipped()

            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: StoreLanguage.isEnglish ? "chevron.right" : "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer()
                    if let picture {
                        AppIconView(app: picture, size: 60)
                            .shadow(color: tint.opacity(0.38), radius: 12, y: 4)
                    } else {
                        Image(systemName: section.category.symbol)
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(tint.opacity(0.42), in: RoundedRectangle(cornerRadius: 17))
                            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.16)))
                    }
                }
                Spacer(minLength: 12)
                Text(section.category.localizedName)
                    .font(AppFont.black(15))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.77)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(StoreLanguage.isEnglish
                     ? "\(section.apps.count) apps"
                     : "\(section.apps.count) تطبيق")
                    .font(AppFont.medium(11))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14)
        }
        .frame(height: 159)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.37), tint.opacity(0.26), .white.opacity(0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.95
                )
        }
        .shadow(color: tint.opacity(0.16), radius: 13, y: 5)
    }
}

private struct VerifiedGenreAppsView: View {
    let section: VerifiedExploreSection

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 13) {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(section.category.localizedName)
                        .font(AppFont.black(26))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text(StoreLanguage.isEnglish
                         ? "\(section.apps.count) verified Turath apps"
                         : "\(section.apps.count) تطبيق مؤكد من تطبيقات التراث")
                        .font(AppFont.medium(12))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.bottom, 9)

                if section.apps.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: section.category.symbol)
                            .font(.system(size: 35))
                            .foregroundStyle(section.category.glowColor)
                        Text(StoreLanguage.isEnglish
                             ? "No published apps have been verified in this category yet."
                             : "ماكو تطبيقات منشورة تمت مطابقتها مع Apple بهذا التصنيف بعد.")
                            .font(AppFont.medium(13))
                            .foregroundStyle(StoreTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 85)
                }

                ForEach(section.apps) { app in
                    NavigationLink(destination: AppDetailView(app: app)) {
                        HStack(spacing: 12) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StoreTheme.textSecondary)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(app.name)
                                    .font(AppFont.bold(14))
                                    .foregroundStyle(StoreTheme.textPrimary)
                                    .lineLimit(1)
                                if let version = app.version {
                                    Text(StoreLanguage.isEnglish ? "Version \(version)" : "الإصدار \(version)")
                                        .font(AppFont.medium(11))
                                        .foregroundStyle(StoreTheme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            AppIconView(app: app, size: 62)
                        }
                        .padding(13)
                        .background(
                            LinearGradient(
                                colors: [section.category.glowColor.opacity(0.15), StoreTheme.surface],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .navigationTitle(section.category.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
