import SwiftUI
import Foundation

private struct LiveUpdatesFeedService {
    static let shared = LiveUpdatesFeedService()
    private let config = StoreRuntimeConfig.shared

    func fetch(day: String, page: Int = 1) async throws -> FeedResponse {
        let root = config.apiBase
            .appendingPathComponent("a")
            .appendingPathComponent(config.slug)
            .appendingPathComponent("app")
            .appendingPathComponent("feed")

        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else {
            throw StoreAPIError.invalidURL
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "tab", value: "updated"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "tz", value: "180"),
            URLQueryItem(name: "day", value: day),
            URLQueryItem(name: "lang", value: config.language)
        ]
        if let udid = config.deviceUDID {
            queryItems.insert(URLQueryItem(name: "udid", value: udid), at: 0)
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw StoreAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ar", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw StoreAPIError.invalidResponse
        }
        return try JSONDecoder().decode(FeedResponse.self, from: data)
    }
}

private enum UpdatesDateTools {
    static var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Baghdad") ?? .current
        return value
    }()

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "ar_IQ")
        f.dateFormat = "EEEE"
        return f
    }()

    static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "ar_IQ")
        f.dateFormat = "d MMM"
        return f
    }()

    static func key(for date: Date) -> String { keyFormatter.string(from: date) }
    static func date(from key: String) -> Date? { keyFormatter.date(from: key) }

    static func lastSevenDays() -> [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    static func relativeTitle(for key: String) -> String {
        guard let date = date(from: key) else { return key }
        let today = calendar.startOfDay(for: Date())
        let selected = calendar.startOfDay(for: date)
        let delta = calendar.dateComponents([.day], from: selected, to: today).day ?? 0
        if delta == 0 { return "اليوم" }
        if delta == 1 { return "أمس" }
        return monthDayFormatter.string(from: date)
    }
}

struct LiveUpdatesView: View {
    @EnvironmentObject private var store: StoreViewModel

    @State private var selectedDay = UpdatesDateTools.key(for: Date())
    @State private var remoteWeek: [FeedDay] = []
    @State private var apps: [StoreApp] = []
    @State private var cachedFirstPages: [String: FeedResponse] = [:]
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorMessage: String?

    private let service = LiveUpdatesFeedService.shared

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    StoreHeader()
                    titleBlock
                    stats
                    weekStrip
                    listHeader
                    appsList
                    if loadingMore {
                        ProgressView().tint(StoreTheme.accent).padding(.vertical, 12)
                    }
                    if let errorMessage, apps.isEmpty {
                        errorView(errorMessage)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
            .refreshable { await reloadSelectedDay(force: true) }
            .task { await bootstrap() }
        }
        .navigationViewStyle(.stack)
    }

    private var titleBlock: some View {
        HStack {
            VStack(alignment: .trailing, spacing: 4) {
                Text("التحديثات")
                    .font(AppFont.black(27))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text("التطبيقات المضافة أو المعدلة خلال آخر 7 أيام")
                    .font(AppFont.regular(11.5))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
            Spacer()
            ZStack {
                Circle().fill(StoreTheme.accent.opacity(0.12))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(StoreTheme.accent)
            }
            .frame(width: 52, height: 52)
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var stats: some View {
        HStack(spacing: 10) {
            statCard(
                title: "مضاف",
                value: selectedCounts.new,
                color: StoreTheme.badgeNew,
                icon: "sparkles"
            )
            statCard(
                title: "محدّث",
                value: selectedCounts.updated,
                color: StoreTheme.badgeUpdated,
                icon: "arrow.clockwise"
            )
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private func statCard(title: String, value: Int, color: Color, icon: String) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack {
                ZStack {
                    Circle().fill(color.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: 28, height: 28)
                Spacer()
                Text("\(value)")
                    .font(AppFont.black(28))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(AppFont.medium(11.5))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .trailing)
        .storeCard(radius: 19)
    }

    private var weekStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(displayWeek) { day in
                    dayButton(day)
                }
            }
            .padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }

    private func dayButton(_ day: FeedDay) -> some View {
        let selected = day.date == selectedDay
        let date = UpdatesDateTools.date(from: day.date)
        let weekday = date.map { UpdatesDateTools.weekdayFormatter.string(from: $0) } ?? "—"
        let dayNumber = date.map { UpdatesDateTools.calendar.component(.day, from: $0) } ?? 0
        let total = (day.new ?? 0) + (day.updated ?? 0)

        return Button {
            guard day.date != selectedDay else { return }
            withAnimation(.easeInOut(duration: 0.2)) { selectedDay = day.date }
            Task { await reloadSelectedDay(force: false) }
        } label: {
            VStack(spacing: 5) {
                Text(shortWeekday(weekday))
                    .font(AppFont.medium(10.5))
                    .foregroundStyle(selected ? StoreTheme.onAccent : StoreTheme.textSecondary)
                    .lineLimit(1)
                Text("\(dayNumber)")
                    .font(AppFont.black(18))
                    .foregroundStyle(selected ? StoreTheme.onAccent : StoreTheme.textPrimary)
                Text("\(total)")
                    .font(AppFont.medium(9.5))
                    .foregroundStyle(selected ? StoreTheme.onAccent.opacity(0.75) : StoreTheme.textSecondary)
            }
            .frame(width: 56, height: 72)
            .background(selected ? StoreTheme.accent : StoreTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(selected ? StoreTheme.accent : StoreTheme.surfaceBorder.opacity(0.8), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private var listHeader: some View {
        HStack {
            if loading {
                ProgressView().tint(StoreTheme.accent).scaleEffect(0.85)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(UpdatesDateTools.relativeTitle(for: selectedDay))
                    .font(AppFont.black(18))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text("\(apps.count) تطبيق محمّل من المصدر")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    @ViewBuilder
    private var appsList: some View {
        if !apps.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    NavigationLink(destination: AppDetailView(app: app)) {
                        updateRow(app)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if index >= apps.count - 5, hasMore {
                            Task { await loadMoreIfNeeded() }
                        }
                    }

                    if index < apps.count - 1 {
                        Divider()
                            .overlay(StoreTheme.surfaceBorder.opacity(0.65))
                            .padding(.trailing, 74)
                    }
                }
            }
            .padding(.horizontal, 14)
            .storeCard(radius: 20)
            .padding(.horizontal, StoreTheme.pageHorizontal)
        } else if !loading && errorMessage == nil {
            emptyView
        }
    }

    private func updateRow(_ app: StoreApp) -> some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 62)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 7) {
                    feedBadge(for: app)
                    Spacer(minLength: 4)
                    Text(app.name)
                        .font(AppFont.bold(14.5))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .lineLimit(1)
                }
                Text("الإصدار \(app.version ?? "—")")
                    .font(AppFont.regular(11))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if let notes = app.notes, !notes.isEmpty {
                    Text(notes.replacingOccurrences(of: "\n", with: " "))
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary.opacity(0.88))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            InstallPill()
        }
        .padding(.vertical, 10)
    }

    private func feedBadge(for app: StoreApp) -> some View {
        let isNew = ["new", "added", "latest"].contains((app.feedKind ?? "").lowercased())
        let color = isNew ? StoreTheme.badgeNew : StoreTheme.badgeUpdated
        return Text(isNew ? "جديد" : "تحديث")
            .font(AppFont.bold(9.5))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(StoreTheme.accent)
            Text("لا توجد إضافات أو تحديثات")
                .font(AppFont.bold(14))
                .foregroundStyle(StoreTheme.textPrimary)
            Text("ماكو تطبيقات مسجلة بهذا اليوم.")
                .font(AppFont.regular(11))
                .foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(StoreTheme.badgeUpdated)
            Text("تعذر تحميل التحديثات")
                .font(AppFont.bold(14))
                .foregroundStyle(StoreTheme.textPrimary)
            Text(message)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("إعادة المحاولة") {
                Task { await reloadSelectedDay(force: true) }
            }
            .font(AppFont.bold(12))
            .foregroundStyle(StoreTheme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(StoreTheme.accent)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var displayWeek: [FeedDay] {
        let remote = Dictionary(uniqueKeysWithValues: remoteWeek.map { ($0.date, $0) })
        return UpdatesDateTools.lastSevenDays().map { date in
            let key = UpdatesDateTools.key(for: date)
            return remote[key] ?? FeedDay(date: key, new: 0, updated: 0)
        }
    }

    private var selectedCounts: (new: Int, updated: Int) {
        if let day = remoteWeek.first(where: { $0.date == selectedDay }) {
            return (day.new ?? 0, day.updated ?? 0)
        }
        let newCount = apps.filter { ["new", "added", "latest"].contains(($0.feedKind ?? "").lowercased()) }.count
        let updatedCount = apps.filter { ($0.feedKind ?? "").lowercased() == "updated" }.count
        return (newCount, updatedCount)
    }

    private func bootstrap() async {
        if remoteWeek.isEmpty, !(store.feed.week ?? []).isEmpty {
            remoteWeek = store.feed.week ?? []
        }
        await reloadSelectedDay(force: false)
    }

    @MainActor
    private func reloadSelectedDay(force: Bool) async {
        let requestedDay = selectedDay

        if !force, let cached = cachedFirstPages[requestedDay] {
            applyFirstPage(cached, requestedDay: requestedDay)
        }

        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }

        do {
            let response = try await service.fetch(day: requestedDay, page: 1)
            guard selectedDay == requestedDay else { return }
            cachedFirstPages[requestedDay] = response
            applyFirstPage(response, requestedDay: requestedDay)
        } catch {
            guard selectedDay == requestedDay else { return }
            if apps.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    @MainActor
    private func loadMoreIfNeeded() async {
        guard hasMore, !loadingMore, !loading else { return }
        loadingMore = true
        defer { loadingMore = false }
        let requestedDay = selectedDay
        let nextPage = page + 1

        do {
            let response = try await service.fetch(day: requestedDay, page: nextPage)
            guard selectedDay == requestedDay else { return }
            apps = mergeUnique(apps + response.apps)
            page = nextPage
            hasMore = response.hasMore ?? false
            if let week = response.week, !week.isEmpty { remoteWeek = week }
        } catch {
            // Keep the already loaded page visible if a later page fails.
        }
    }

    @MainActor
    private func applyFirstPage(_ response: FeedResponse, requestedDay: String) {
        guard selectedDay == requestedDay else { return }
        apps = mergeUnique(response.apps)
        page = response.page ?? 1
        hasMore = response.hasMore ?? false
        if let week = response.week, !week.isEmpty { remoteWeek = week }
        errorMessage = nil
    }

    private func mergeUnique(_ values: [StoreApp]) -> [StoreApp] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func shortWeekday(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "ال", with: "")
        return String(clean.prefix(4))
    }
}
