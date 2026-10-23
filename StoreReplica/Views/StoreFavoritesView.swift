import SwiftUI

/// A separate, offline-capable favorites destination. The account screen
/// only links here; it never renders every saved app in the settings sheet.
struct StoreFavoritesView: View {
    @AppStorage("store.favoriteIDs") private var favoriteIDs = ""
    @AppStorage("store.favoriteAppsJSON") private var favoriteAppsJSON = ""
    @State private var latestApps: [StoreApp] = []

    private var favorites: [StoreApp] {
        let saved = favoriteAppsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([StoreApp].self, from: $0) } ?? []
        var byID: [String: StoreApp] = [:]
        for app in saved + latestApps where !app.isDylibAsset {
            if byID[app.id] == nil { byID[app.id] = app }
        }
        return favoriteIDs.split(separator: "\n").prefix(25)
            .compactMap { byID[String($0)] }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    if favorites.isEmpty {
                        VStack(spacing: 13) {
                            Image(systemName: "heart")
                                .font(.system(size: 36))
                                .foregroundStyle(.red)
                            Text("اضغط القلب أسفل تصنيف أي تطبيق أو لعبة لإضافتها هنا")
                                .font(AppFont.medium(13))
                                .foregroundStyle(StoreTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                    }
                    ForEach(Array(favorites.enumerated()), id: \.element.id) { index, app in
                        HStack(spacing: 11) {
                            // Heart is a sibling of the link, not nested in a link.
                            StoreFavoriteButton(app: app)
                            NavigationLink(destination: AppDetailView(app: app)) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .trailing, spacing: 5) {
                                        Text(app.name)
                                            .font(AppFont.bold(15))
                                            .foregroundStyle(StoreTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(StoreLanguage.localized(app.categories?.first ?? "تطبيق"))
                                            .font(AppFont.medium(12))
                                            .foregroundStyle(StoreTheme.textSecondary)
                                            .lineLimit(1)
                                        if let version = app.version {
                                            Text("v" + version)
                                                .font(AppFont.regular(11))
                                                .foregroundStyle(StoreTheme.textSecondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    AppIconView(app: app, size: 60)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .background(
                            LinearGradient(
                                colors: [StoreTheme.accent.opacity(index.isMultiple(of: 2) ? 0.24 : 0.16),
                                         StoreTheme.surface],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(StoreTheme.accent.opacity(0.16)))
                        .shadow(color: StoreTheme.accent.opacity(0.10), radius: 8, y: 3)
                    }
                }
                .padding(16)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .navigationTitle("المفضلة")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if let home = try? await KiraSourceSearchService.shared.homeCollections() {
                latestApps = home.apps
            }
        }
    }
}
