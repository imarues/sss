import SwiftUI
import Foundation

// Homepage collections are driven exclusively by IPA-AR and deb-AR.
// No fabricated counts or placeholder application cards are displayed.
@MainActor
final class IPAHomeCollections: ObservableObject {
    @Published var apps: [StoreApp] = []
    @Published var dylibs: [StoreApp] = []
    @Published var loaded = false
    @Published private(set) var categories: [StoreCategory] = []
    @Published private(set) var recommended: [StoreApp] = []
    @Published private(set) var recentlyAdded: [StoreApp] = []
    @Published var error: String?

    func refresh() async {
        do {
            let source = try await KiraSourceSearchService.shared.homeCollections()
            apps = source.apps
            dylibs = source.dylibs
            categories = Self.makeCategories(source.apps)
            recommended = source.apps.filter { $0.featured == true }
            recentlyAdded = Self.makeRecentlyAdded(source.apps)
            error = nil
        } catch {
            self.error = "تعذر تحميل الفئات من المصدر"
        }
        loaded = true
    }

    private static func makeCategories(_ apps: [StoreApp]) -> [StoreCategory] {
        var groups: [String: [StoreApp]] = [:]
        var order: [String] = []
        for app in apps {
            for raw in app.categories ?? [] {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if groups[name] == nil { groups[name] = []; order.append(name) }
                groups[name, default: []].append(app)
            }
        }
        return order.map { name in
            let entries = groups[name] ?? []
            return StoreCategory(id: name, name: name, count: entries.count,
                                 imageUrl: entries.first?.iconUrl, apps: entries)
        }
    }

    private static func makeRecentlyAdded(_ apps: [StoreApp]) -> [StoreApp] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-3 * 24 * 60 * 60)
        return apps.compactMap { app -> (StoreApp, Date)? in
            guard let raw = app.addedAt, let date = IPAHomeDate.parse(raw),
                  date >= cutoff, date <= now else { return nil }
            return (app, date)
        }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}

@MainActor
private enum IPAHomeDate {
    // Shared formatters: don't allocate new ISO/date formatters per application.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let parsers: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "dd-MM-yyyy", "dd/MM/yyyy", "yyyy/MM/dd"
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(value), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        if let date = isoFractional.date(from: value) ?? isoStandard.date(from: value) {
            return date
        }
        for parser in parsers {
            if let date = parser.date(from: value) { return date }
        }
        return nil
    }
}

struct IPAHomeSections: View {
    @StateObject private var source = IPAHomeCollections()

    var body: some View {
        VStack(spacing: 25) {
            if !source.categories.isEmpty {
                VStack(alignment: .trailing, spacing: 13) {
                    heading("الفئات")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 11) {
                            ForEach(source.categories) { category in
                                NavigationLink(destination: IPAHomeCollectionList(
                                    title: category.name, apps: category.apps ?? [], showsBundle: true)) {
                                    IPACategoryTile(category: category)
                                }.buttonStyle(StoreGlassPressStyle())
                            }
                        }.padding(.horizontal, StoreTheme.pageHorizontal)
                    }
                }
            }
            if !source.recommended.isEmpty {
                section("ننصح به", apps: source.recommended, showsBundle: true, showsDate: true)
            }
            if !source.recentlyAdded.isEmpty {
                section("آخر الإضافات", apps: source.recentlyAdded, showsBundle: true, showsDate: true)
            }
            if !source.dylibs.isEmpty {
                section("الدايلب والإضافات", apps: source.dylibs, showsBundle: false, showsDate: true)
            }
            if source.loaded, source.apps.isEmpty, source.dylibs.isEmpty {
                Text(source.error ?? "لا توجد عناصر متاحة حالياً")
                    .font(AppFont.medium(12)).foregroundStyle(StoreTheme.textSecondary)
                    .padding(.horizontal, StoreTheme.pageHorizontal)
            }
        }
        .task { await source.refresh() }
    }

    private func heading(_ title: String) -> some View {
        HStack {
            Spacer()
            Text(StoreLanguage.localized(title)).font(AppFont.black(22)).foregroundStyle(StoreTheme.textPrimary)
        }.padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private func section(_ title: String, apps: [StoreApp], showsBundle: Bool, showsDate: Bool) -> some View {
        VStack(spacing: 13) {
            HStack {
                NavigationLink(destination: IPAHomeCollectionList(title: title, apps: apps, showsBundle: showsBundle)) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("عرض الكل").font(AppFont.medium(12))
                    }
                    .foregroundStyle(StoreTheme.textSecondary)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(StoreTheme.surface, in: Capsule())
                }
                Spacer()
                Text(StoreLanguage.localized(title)).font(AppFont.black(22)).foregroundStyle(StoreTheme.textPrimary)
            }.padding(.horizontal, StoreTheme.pageHorizontal)
            LazyVStack(spacing: 12) {
                ForEach(Array(apps.prefix(5).enumerated()), id: \.element.id) { index, app in
                    NavigationLink(destination: AppDetailView(app: app)) {
                        IPAGlowAppCard(app: app, index: index, showsBundle: showsBundle, showsDate: showsDate)
                    }.buttonStyle(StoreGlassPressStyle())
                }
            }.padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }
}


private struct IPACategoryTile: View {
    let category: StoreCategory

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: category.imageUrl, cornerRadius: 12).frame(width: 49, height: 49)
            VStack(alignment: .trailing, spacing: 6) {
                Text(StoreLanguage.localized(category.name)).font(AppFont.bold(14)).foregroundStyle(.white).lineLimit(1)
                Text(StoreLanguage.isEnglish ? "\(category.count ?? 0) apps" : "\(category.count ?? 0) تطبيق")
                    .font(AppFont.medium(11)).foregroundStyle(.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(13)
        .frame(width: 226, height: 81)
        .background(
            LinearGradient(colors: [Color(red: 0.11, green: 0.15, blue: 0.26),
                                    Color(red: 0.09, green: 0.12, blue: 0.21)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.05),
                             StoreTheme.accent.opacity(0.17)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
    }
}

private struct IPAGlowAppCard: View {
    let app: StoreApp
    let index: Int
    let showsBundle: Bool
    let showsDate: Bool

    private var glow: Color {
        let colors: [Color] = [
            Color(red: 0.55, green: 0.33, blue: 0.84),
            Color(red: 0.23, green: 0.46, blue: 0.92),
            Color(red: 0.87, green: 0.28, blue: 0.43),
            Color(red: 0.20, green: 0.73, blue: 0.55),
            Color(red: 0.77, green: 0.55, blue: 0.25)
        ]
        return colors[index % colors.count]
    }

    private var sizeText: String {
        guard let bytes = app.fileSize, bytes > 0 else { return StoreLanguage.localized("الحجم غير متوفر") }
        return StoreLanguage.isEnglish ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [glow.opacity(0.27),
                             Color(red: 0.11, green: 0.15, blue: 0.25),
                             Color(red: 0.075, green: 0.10, blue: 0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            // Liquid-looking gradients without blurred offscreen layers.
            RadialGradient(
                colors: [glow.opacity(0.36), glow.opacity(0.08), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 220
            )
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [.white.opacity(0.13), .clear, .white.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text(StoreLanguage.localized(app.isDylibAsset ? "عرض" : "تثبيت"))
                        .font(AppFont.bold(13))
                        .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.19))
                        .padding(.horizontal, 17)
                        .frame(height: 39)
                        .background(Color(red: 0.48, green: 0.65, blue: 1), in: Capsule())
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 3)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(app.name)
                        .font(AppFont.bold(15)).foregroundStyle(.white)
                        .lineLimit(1)
                    Text([app.version.map { "v" + $0 }, sizeText].compactMap { $0 }.joined(separator: " · "))
                        .font(AppFont.medium(11)).foregroundStyle(.white.opacity(0.69))
                        .lineLimit(1)
                    if showsBundle, let bundle = app.bundleId, !bundle.isEmpty {
                        Text(bundle).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52)).lineLimit(1)
                    }
                    if showsDate {
                        let date = app.updatedAt ?? app.versionUpdatedAt ?? app.addedAt
                        if let date, !date.isEmpty {
                            Text(StoreLanguage.localized("تاريخ التحديث: ") + date)
                                .font(AppFont.medium(10)).foregroundStyle(.white.opacity(0.53))
                                .lineLimit(1)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .trailing)
                AppIconView(app: app, size: 64)
            }
            .padding(16)
        }
        .frame(height: 125)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.35), glow.opacity(0.27),
                                 .white.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.85
                )
                .allowsHitTesting(false)
        }
        .shadow(color: glow.opacity(0.12), radius: 6, y: 3)
    }
}

private struct IPAHomeCollectionList: View {
    let title: String
    let apps: [StoreApp]
    let showsBundle: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    NavigationLink(destination: AppDetailView(app: app)) {
                        IPAGlowAppCard(app: app, index: index, showsBundle: showsBundle, showsDate: true)
                    }.buttonStyle(StoreGlassPressStyle())
                }
            }.padding(16)
        }
        .background(StoreTheme.background)
        .navigationTitle(StoreLanguage.localized(title))
    }
}
