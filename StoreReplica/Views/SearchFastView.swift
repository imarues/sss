import SwiftUI
import Foundation

private struct FastSearchEntry {
    let app: StoreApp
    let normalizedName: String
    let normalizedBundle: String
    let haystack: String
}

private enum FastSearchIndex {
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ar_IQ"))
            .lowercased()
            .replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
            .replacingOccurrences(of: "ى", with: "ي")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func build(_ apps: [StoreApp]) -> (entries: [FastSearchEntry], tags: [String]) {
        var entries: [FastSearchEntry] = []
        entries.reserveCapacity(apps.count)

        var tags: [String] = []
        var seenTags = Set<String>()

        for app in apps {
            let categories = app.categories ?? []
            for category in categories {
                let clean = category.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && seenTags.insert(clean).inserted && tags.count < 12 {
                    tags.append(clean)
                }
            }

            let name = normalize(app.name)
            let bundle = normalize(app.bundleId ?? "")
            let notes = normalize(app.notes ?? "")
            let categoryText = normalize(categories.joined(separator: " "))
            let haystack = [name, bundle, notes, categoryText]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            entries.append(
                FastSearchEntry(
                    app: app,
                    normalizedName: name,
                    normalizedBundle: bundle,
                    haystack: haystack
                )
            )
        }

        return (entries, tags)
    }

    static func search(_ query: String, in entries: [FastSearchEntry], limit: Int = 80) -> [StoreApp] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }

        var matched: [(Int, String, StoreApp)] = []
        matched.reserveCapacity(min(limit * 2, entries.count))

        for entry in entries where entry.haystack.contains(q) {
            let score: Int
            if entry.normalizedName.hasPrefix(q) {
                score = 0
            } else if entry.normalizedBundle.hasPrefix(q) {
                score = 1
            } else if entry.normalizedName.contains(q) {
                score = 2
            } else if entry.normalizedBundle.contains(q) {
                score = 3
            } else {
                score = 4
            }
            matched.append((score, entry.normalizedName, entry.app))
        }

        matched.sort {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1 < $1.1
        }

        return matched.prefix(limit).map(\.2)
    }
}

@MainActor
private enum FastSearchIndexCache {
    static var entries: [FastSearchEntry] = []
    static var tags: [String] = []
    static var storedAt = Date.distantPast
    static var isFresh: Bool {
        !entries.isEmpty && Date().timeIntervalSince(storedAt) < 300
    }
}

struct SearchFastView: View {
    @State private var query = ""
    @State private var index: [FastSearchEntry] = []
    @State private var results: [StoreApp] = []
    @State private var sourceTags: [String] = []
    @State private var visibleLimit = 24
    @State private var loading = true
    @State private var searching = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 20) {
                    StoreHeader()
                    hero
                    searchField

                    if loading && index.isEmpty {
                        loadingCard
                    } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suggestions
                    } else {
                        resultsList
                    }

                    if let errorText, index.isEmpty {
                        errorCard(errorText)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(StoreTheme.background)
            .navigationBarHidden(true)
            .refreshable { await loadCatalog(force: true) }
            .task { await loadCatalog(force: false) }
            .onChange(of: query) { value in
                scheduleSearch(value)
            }
            .onDisappear {
                searchTask?.cancel()
                searchTask = nil
            }
        }
        .navigationViewStyle(.stack)
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }

    private var hero: some View {
        HStack {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(.white.opacity(0.88))
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text((StoreLanguage.isEnglish ? "Search the store" : "ابحث في التراث بلس").storeForcedRTL)
                    .font(AppFont.black(26))
                    .foregroundStyle(.white)
                Text((StoreLanguage.isEnglish ? "Find your favorite apps and games" : "ابحث عن تطبيقاتك وألعابك المفضلة").storeForcedRTL)
                    .font(AppFont.regular(12))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.trailing)
            }
        }
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
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
            if searching {
                ProgressView()
                    .tint(StoreTheme.accent)
                    .scaleEffect(0.72)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(StoreTheme.tabInactive)
                }
                .buttonStyle(.plain)
            }

            TextField("اسم التطبيق أو اللعبة أو الديلب", text: $query)
                .focused($searchFocused)
                .font(AppFont.regular(14))
                .foregroundStyle(StoreTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)

            Image(systemName: "magnifyingglass")
                .foregroundStyle(StoreTheme.textSecondary)
        }
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(StoreTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, StoreTheme.pageHorizontal)
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    private var suggestions: some View {
        VStack(spacing: 14) {
            SectionTitle(title: "التصنيفات")
            if sourceTags.isEmpty {
                Text("ابدأ بالبحث عن اسم تطبيق أو لعبة أو ديلب".storeForcedRTL)
                    .font(AppFont.regular(12))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, StoreTheme.pageHorizontal)
            } else {
                FlowTags(items: sourceTags) { value in
                    query = value
                    searchFocused = true
                }
            }
        }
    }

    private var resultsList: some View {
        LazyVStack(spacing: 0) {
            if results.isEmpty && !searching {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(StoreTheme.textSecondary)
                    Text("ماكو نتائج".storeForcedRTL)
                        .font(AppFont.bold(13))
                        .foregroundStyle(StoreTheme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(Array(results.prefix(visibleLimit).enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 10) {
                        NavigationLink(destination: AppDetailView(app: app)) {
                            HStack(spacing: 12) {
                                AppIconView(app: app, size: 62)
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(app.name.storeForcedRTL)
                                        .font(AppFont.bold(15))
                                        .foregroundStyle(StoreTheme.textPrimary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    Text((app.notes ?? "الإصدار \(app.version.map(StoreDisplayFormat.digits) ?? "—")").storeForcedRTL)
                                        .font(AppFont.regular(11.5))
                                        .foregroundStyle(StoreTheme.textSecondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.trailing)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .buttonStyle(.plain)

                        if app.isDylibAsset {
                            DirectDownloadButton(app: app, compact: true)
                        } else {
                            InstallPill(app: app)
                        }
                    }
                     .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
                    .padding(.vertical, 10)

                    if index < min(results.count, visibleLimit) - 1 {
                        Divider().overlay(StoreTheme.surfaceBorder.opacity(0.7))
                    }
                }
                if visibleLimit < results.count {
                    HStack {
                        ProgressView().tint(StoreTheme.accent)
                        Text(StoreLanguage.isEnglish ? "More results" : "المزيد من النتائج")
                            .font(AppFont.medium(12))
                            .foregroundStyle(StoreTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .onAppear { visibleLimit = min(results.count, visibleLimit + 24) }
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
            Text("جاري تجهيز البحث…".storeForcedRTL)
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
            Text("تعذر تحميل مصادر البحث".storeForcedRTL)
                .font(AppFont.bold(13))
                .foregroundStyle(StoreTheme.textPrimary)
            Text(text.storeForcedRTL)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    @MainActor
    private func loadCatalog(force: Bool) async {
        if !force && FastSearchIndexCache.isFresh {
            index = FastSearchIndexCache.entries
            sourceTags = FastSearchIndexCache.tags
            errorText = nil
            loading = false
            if !query.isEmpty { scheduleSearch(query, immediate: true) }
            return
        }
        if index.isEmpty { loading = true }
        defer { loading = false }

        do {
            let catalog = try await KiraSourceSearchService.shared.catalog(force: force)
            let built = await Task.detached(priority: .userInitiated) {
                FastSearchIndex.build(catalog)
            }.value

            index = built.entries
            sourceTags = built.tags
            FastSearchIndexCache.entries = built.entries
            FastSearchIndexCache.tags = built.tags
            FastSearchIndexCache.storedAt = Date()
            errorText = nil

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleSearch(query, immediate: true)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func scheduleSearch(_ value: String, immediate: Bool = false) {
        searchTask?.cancel()
        visibleLimit = 24

        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            results = []
            searching = false
            return
        }

        searching = true
        let snapshot = index
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
            guard !Task.isCancelled else { return }

            let found = await Task.detached(priority: .userInitiated) {
                FastSearchIndex.search(clean, in: snapshot, limit: 80)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard FastSearchIndex.normalize(query) == FastSearchIndex.normalize(clean) else { return }
                results = found
                searching = false
            }
        }
    }
}
