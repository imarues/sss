import SwiftUI
import UIKit
import Foundation
import CoreText

struct SearchView: View {
    @State private var query = ""
    @State private var sourceCatalog: [StoreApp] = []
    @State private var loading = true
    @State private var errorText: String?

    private var results: [StoreApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return sourceCatalog
            .filter { app in
                [
                    app.name,
                    app.bundleId ?? "",
                    app.notes ?? "",
                    (app.categories ?? []).joined(separator: " ")
                ]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(q)
            }
            .sorted { lhs, rhs in
                let lStarts = lhs.name.localizedCaseInsensitiveHasPrefix(q)
                let rStarts = rhs.name.localizedCaseInsensitiveHasPrefix(q)
                if lStarts != rStarts { return lStarts && !rStarts }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var sourceTags: [String] {
        var seen = Set<String>()
        return sourceCatalog
            .flatMap { $0.categories ?? [] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    StoreHeader()
                    hero
                    searchField
                    if loading && sourceCatalog.isEmpty {
                        loadingCard
                    } else if query.isEmpty {
                        suggestions
                    } else {
                        resultsList
                    }
                    if let errorText, sourceCatalog.isEmpty {
                        errorCard(errorText)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
            .refreshable { await loadCatalog(force: true) }
            .task { await loadCatalog(force: false) }
        }
        .navigationViewStyle(.stack)
    }

    private var hero: some View {
        VStack(alignment: .trailing, spacing: 9) {
            HStack {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ابحث في كيرا بلس")
                        .font(AppFont.black(26))
                        .foregroundStyle(.white)
                    Text("\(sourceCatalog.count.formatted()) عنصر من IPA-AR و deb-AR")
                        .font(AppFont.regular(12))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(19)
        .background(
            LinearGradient(
                colors: [StoreTheme.accent.opacity(0.62), StoreTheme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StoreTheme.textSecondary)
            TextField("اسم التطبيق أو اللعبة أو الديلب", text: $query)
                .font(AppFont.regular(14))
                .foregroundStyle(StoreTheme.textPrimary)
                .multilineTextAlignment(.trailing)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(StoreTheme.tabInactive)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(StoreTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var suggestions: some View {
        VStack(spacing: 14) {
            SectionTitle(title: "التصنيفات")
            if sourceTags.isEmpty {
                Text("ابدأ بالبحث عن اسم تطبيق أو لعبة أو ديلب")
                    .font(AppFont.regular(12))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, StoreTheme.pageHorizontal)
            } else {
                FlowTags(items: sourceTags) { query = $0 }
            }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(StoreTheme.textSecondary)
                    Text("ماكو نتائج")
                        .font(AppFont.bold(13))
                        .foregroundStyle(StoreTheme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 10) {
                        VStack(alignment: .trailing, spacing: 3) {
                            NavigationLink(destination: AppDetailView(app: app)) {
                                HStack(spacing: 12) {
                                    AppIconView(app: app, size: 62)
                                    VStack(alignment: .trailing, spacing: 5) {
                                        Text(app.name)
                                            .font(AppFont.bold(15))
                                            .foregroundStyle(StoreTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(StoreLanguage.localized(app.categories?.first ?? (app.isDylibAsset ? "دايلب" : "تطبيق")))
                                            .font(AppFont.medium(11))
                                            .foregroundStyle(StoreTheme.textSecondary)
                                            .lineLimit(1)
                                        Text(app.notes ?? "الإصدار \(app.version ?? "—")")
                                            .font(AppFont.regular(10.5))
                                            .foregroundStyle(StoreTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                            .buttonStyle(.plain)
                            if !app.isDylibAsset {
                                StoreFavoriteButton(app: app)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }

                        if app.isDylibAsset {
                            DirectDownloadButton(app: app, compact: true)
                        } else {
                            InstallPill(app: app)
                        }
                    }
                    .padding(.vertical, 10)

                    if index < results.count - 1 {
                        Divider().overlay(StoreTheme.surfaceBorder.opacity(0.7))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().tint(StoreTheme.accent)
            Text("جاري تحميل المصدرين…")
                .font(AppFont.medium(12))
                .foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StoreTheme.badgeUpdated)
            Text("تعذر تحميل مصادر البحث")
                .font(AppFont.bold(13))
                .foregroundStyle(StoreTheme.textPrimary)
            Text(text)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private func loadCatalog(force: Bool) async {
        if sourceCatalog.isEmpty { loading = true }
        defer { loading = false }
        do {
            sourceCatalog = try await KiraSourceSearchService.shared.catalog(force: force)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct FlowTags: View {
    let items: [String]
    let onTap: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 9)], spacing: 9) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item)
                        .font(AppFont.medium(12))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(StoreTheme.field)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct UpdatesView: View {
    @EnvironmentObject private var store: StoreViewModel
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    StoreHeader()
                    HStack(spacing: 10) {
                        stat(title: "جديد", value: store.feed.counts?.new ?? 0, color: StoreTheme.badgeNew)
                        stat(title: "تحديث", value: store.feed.counts?.updated ?? 0, color: StoreTheme.badgeUpdated)
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)
                    VStack(spacing: 0) {
                        ForEach(store.feed.apps) { app in
                            NavigationLink(destination: AppDetailView(app: app)) { LargeListRow(app: app) }
                                .buttonStyle(.plain)
                            Divider().overlay(StoreTheme.surfaceBorder.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 14)
                    .storeCard()
                    .padding(.horizontal, StoreTheme.pageHorizontal)
                }
                .padding(.bottom, 24)
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    private func stat(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("\(value)").font(AppFont.black(26)).foregroundStyle(StoreTheme.textPrimary)
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(AppFont.medium(11)).foregroundStyle(StoreTheme.textSecondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .storeCard(radius: 18)
    }
}

struct ShopView: View {
    @EnvironmentObject private var store: StoreViewModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                StoreHeader()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("المتجر").font(AppFont.black(28)).foregroundStyle(StoreTheme.textPrimary)
                    Text("اشتراكات ومنتجات رقمية").font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, StoreTheme.pageHorizontal)
                if (store.cards.products ?? []).isEmpty {
                    emptyShop
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.cards.products ?? []) { ProductCard(product: $0) }
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .background(StoreTheme.background)
    }

    private var emptyShop: some View {
        VStack(spacing: 10) {
            Image(systemName: "bag.fill").font(.system(size: 38)).foregroundStyle(StoreTheme.accent)
            Text("جاري تحميل المنتجات").font(AppFont.bold(14)).foregroundStyle(StoreTheme.textPrimary)
            Text("سيتم عرض منتجات المتجر هنا عند توفر الاتصال.").font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct ProductCard: View {
    let product: CardProduct
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            RemoteImage(path: product.imageUrl, cornerRadius: 16, systemFallback: "bag.fill").frame(height: 118)
            Text(product.name).font(AppFont.bold(13)).foregroundStyle(StoreTheme.textPrimary).lineLimit(2)
            HStack {
                if product.soldOut == true {
                    Text("نفد").font(AppFont.bold(10)).foregroundStyle(.red)
                }
                Spacer()
                Text(priceText).font(AppFont.black(14)).foregroundStyle(StoreTheme.accent)
            }
        }
        .padding(11)
        .storeCard(radius: 19)
    }

    private var priceText: String {
        guard let p = product.price else { return "—" }
        return "\(p.formatted()) \(product.currency ?? "IQD")"
    }
}

@MainActor
struct StoreSettingsView: View {
    @EnvironmentObject private var store: StoreViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var certificateVault = SigningCertificateVault.shared
    @AppStorage("store.favoriteIDs") private var favoriteIDs = ""
    @AppStorage("store.favoriteAppsJSON") private var favoriteAppsJSON = ""
    @AppStorage("store.language") private var selectedLanguage = "ar"
    @State private var favoriteApps: [StoreApp] = []
    @State private var selectedFavorite: StoreApp?
    @State private var showCertificates = false

    var body: some View {
        ZStack {
            StoreTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 18) {
                    HStack {
                        Button("إغلاق") { dismiss() }
                            .font(AppFont.bold(13))
                            .foregroundStyle(StoreTheme.accent)
                        Spacer()
                        Text("الحساب").font(AppFont.black(20)).foregroundStyle(StoreTheme.textPrimary)
                    }
                    ticket
                    certificateManagerRow
                    favoritesSection
                    VStack(spacing: 0) {
                        settingRow("عدد التطبيقات", "\((store.catalog.total ?? store.searchMeta.totalApps ?? 0).formatted())", "square.stack.3d.up.fill")
                        Divider().overlay(StoreTheme.surfaceBorder)
                        settingRow("نمط التصميم", "Night", "moon.stars.fill")
                        Divider().overlay(StoreTheme.surfaceBorder)
                        HStack {
                            Picker("لغة المتجر", selection: $selectedLanguage) {
                                Text("العربية").tag("ar")
                                Text("English").tag("en")
                            }
                            .pickerStyle(.menu)
                            Spacer()
                            Text("لغة المتجر").font(AppFont.medium(13)).foregroundStyle(StoreTheme.textPrimary)
                            Image(systemName: "globe").foregroundStyle(StoreTheme.accent).frame(width: 24)
                        }.frame(height: 48)
                    }
                    .padding(.horizontal, 14)
                    .storeCard()
                }
                .padding(16)
            }
        }
        .sheet(isPresented: $showCertificates) {
            SigningCertificateManagerView()
        }
        .sheet(item: $selectedFavorite) { app in
            NavigationStack { AppDetailView(app: app) }
        }
        .task {
            certificateVault.refresh()
            if let home = try? await KiraSourceSearchService.shared.homeCollections() {
                favoriteApps = home.apps
            }
        }
    }

    private var certificateManagerRow: some View {
        Button { showCertificates = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(StoreTheme.textSecondary)
                if let active = certificateVault.active {
                    Text(active.name).font(AppFont.medium(11))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("إدارة الشهادات").font(AppFont.bold(16))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("\(certificateVault.certificates.count) " + StoreLanguage.localized("شهادات محفوظة"))
                        .font(AppFont.medium(11))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(StoreTheme.accent)
            }
            .padding(16)
            .storeCard(radius: 21)
        }
        .buttonStyle(.plain)
    }

    private var favoritesSection: some View {
        let ids = favoriteIDs.split(separator: "\n").map(String.init)
        let locallySaved = favoriteAppsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([StoreApp].self, from: $0) } ?? []
        let catalog = Dictionary((favoriteApps + locallySaved).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let favorites = ids.compactMap { catalog[$0] }.filter { !$0.isDylibAsset }
        return VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Text("\(favorites.count)/25")
                    .font(AppFont.medium(12)).foregroundStyle(StoreTheme.textSecondary)
                Spacer()
                Text("المفضلة").font(AppFont.bold(18)).foregroundStyle(StoreTheme.textPrimary)
                Image(systemName: "heart.fill").foregroundStyle(.red)
            }
            if favorites.isEmpty {
                Text("اضغط القلب أسفل تصنيف أي تطبيق أو لعبة لإضافتها هنا")
                    .font(AppFont.medium(12))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(favorites) { app in
                        HStack(spacing: 10) {
                            StoreFavoriteButton(app: app)
                            Button { selectedFavorite = app } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(app.name)
                                            .font(AppFont.bold(13))
                                            .foregroundStyle(.white).lineLimit(1)
                                        Text(app.categories?.first ?? "تطبيق")
                                            .font(AppFont.medium(10))
                                            .foregroundStyle(.white.opacity(0.58))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    AppIconView(app: app, size: 49)
                                }
                            }.buttonStyle(.plain)
                        }
                        .padding(11)
                        .background(
                            LinearGradient(colors: [StoreTheme.accent.opacity(0.28),
                                                    StoreTheme.surface],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 17)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.07)))
                    }
                }
            }
        }
        .padding(16)
        .storeCard(radius: 21)
    }

    private var ticket: some View {
        let current = certificateVault.active
        return VStack(spacing: 15) {
            HStack {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(StoreLanguage.localized(current == nil ? "لا توجد شهادة" : "شهادة سنوية"))
                        .font(AppFont.black(21))
                        .foregroundStyle(.white)
                    Text(StoreLanguage.localized(current == nil ? "أضف شهادة للبدء" :
                         (current!.isValid ? "اشتراك فعال" : "الشهادة منتهية")))
                        .font(AppFont.medium(11))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
            Divider().overlay(Color.white.opacity(0.18))
            HStack {
                Text(SigningCertificateVault.actualDeviceName)
                    .font(AppFont.bold(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if let current {
                    Text(current.expiresAt, format: .dateTime.year().month().day())
                        .font(AppFont.regular(11))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("—").font(AppFont.regular(11)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [StoreTheme.accent.opacity(0.82), Color(hex: "#384B8D")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func settingRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Text(value).font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary)
            Spacer()
            Text(title).font(AppFont.medium(13)).foregroundStyle(StoreTheme.textPrimary)
            Image(systemName: icon).foregroundStyle(StoreTheme.accent).frame(width: 24)
        }
        .frame(height: 48)
    }
}
