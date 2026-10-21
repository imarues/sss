import SwiftUI
import Foundation

private struct KiraPagesSource: Decodable {
    let apps: [KiraPagesApp]
}

private struct KiraPagesApp: Decodable {
    let id: String?
    let name: String
    let bundleIdentifier: String?
    let bundleId: String?
    let iconURL: String?
    let localizedDescription: String?
    let category: String?
    let version: String?
    let versionDate: String?
    let size: Int64?
    let addedAt: String?
    let updatedAt: String?

    var stableID: String {
        id ?? bundleIdentifier ?? bundleId ?? "\(name)-\(version ?? "")"
    }

    var normalizedAddedDay: String? { UpdatesDateTools.normalizedDay(addedAt) }
    var normalizedUpdatedDay: String? { UpdatesDateTools.normalizedDay(updatedAt ?? versionDate) }

    func eventKind(on day: String) -> String? {
        if normalizedAddedDay == day { return "new" }
        if normalizedUpdatedDay == day { return "updated" }
        return nil
    }

    func storeApp(on day: String) -> StoreApp {
        StoreApp(
            id: stableID,
            name: name,
            bundleId: bundleIdentifier ?? bundleId,
            version: version,
            fileSize: size,
            notes: localizedDescription,
            iconUrl: iconURL,
            categories: category.map { [$0] },
            updatedAt: normalizedUpdatedDay,
            addedAt: normalizedAddedDay,
            versionUpdatedAt: UpdatesDateTools.normalizedDay(versionDate),
            feedKind: eventKind(on: day)
        )
    }
}

private actor KiraPagesUpdatesService {
    static let shared = KiraPagesUpdatesService()
    private let sourceURL = URL(string: "https://ikiraplus.pages.dev/IPA-AR.json")!
    private var cachedApps: [KiraPagesApp]?

    func fetch(force: Bool = false) async throws -> [KiraPagesApp] {
        if !force, let cachedApps { return cachedApps }

        var request = URLRequest(url: sourceURL)
        request.cachePolicy = force ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ar-IQ,ar;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw StoreAPIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(KiraPagesSource.self, from: data)
        cachedApps = decoded.apps
        return decoded.apps
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

    static func normalizedDay(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count >= 10 {
            let firstTen = String(value.prefix(10))
            if keyFormatter.date(from: firstTen) != nil { return firstTen }
        }
        return keyFormatter.date(from: value).map { keyFormatter.string(from: $0) }
    }

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

private struct LocalFeedDay: Identifiable {
    let date: String
    let new: Int
    let updated: Int
    var id: String { date }
    var total: Int { new + updated }
}

struct LiveUpdatesView: View {
    @State private var selectedDay = UpdatesDateTools.key(for: Date())
    @State private var sourceApps: [KiraPagesApp] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var lastRefresh: Date?

    private let service = KiraPagesUpdatesService.shared

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
                    if let errorMessage, sourceApps.isEmpty {
                        errorView(errorMessage)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
            .refreshable { await loadSource(force: true) }
            .task { await loadSource(force: false) }
        }
        .navigationViewStyle(.stack)
    }

    private var titleBlock: some View {
        HStack {
            VStack(alignment: .trailing, spacing: 4) {
                Text("التحديثات")
                    .font(AppFont.black(27))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text("آخر الإضافات والتحديثات من مصدر iKiraPlus")
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
            statCard(title: "مضاف", value: selectedCounts.new, color: StoreTheme.badgeNew, icon: "sparkles")
            statCard(title: "محدّث", value: selectedCounts.updated, color: StoreTheme.badgeUpdated, icon: "arrow.clockwise")
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

    private func dayButton(_ day: LocalFeedDay) -> some View {
        let selected = day.date == selectedDay
        let date = UpdatesDateTools.date(from: day.date)
        let weekday = date.map { UpdatesDateTools.weekdayFormatter.string(from: $0) } ?? "—"
        let dayNumber = date.map { UpdatesDateTools.calendar.component(.day, from: $0) } ?? 0

        return Button {
            guard day.date != selectedDay else { return }
            withAnimation(.easeInOut(duration: 0.2)) { selectedDay = day.date }
        } label: {
            VStack(spacing: 5) {
                Text(shortWeekday(weekday))
                    .font(AppFont.medium(10.5))
                    .foregroundStyle(selected ? StoreTheme.onAccent : StoreTheme.textSecondary)
                    .lineLimit(1)
                Text("\(dayNumber)")
                    .font(AppFont.black(18))
                    .foregroundStyle(selected ? StoreTheme.onAccent : StoreTheme.textPrimary)
                Text("\(day.total)")
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
                Text("\(selectedApps.count) تطبيق")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    @ViewBuilder
    private var appsList: some View {
        if !selectedApps.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(selectedApps.enumerated()), id: \.element.id) { index, app in
                    NavigationLink(destination: AppDetailView(app: app)) {
                        updateRow(app)
                    }
                    .buttonStyle(.plain)

                    if index < selectedApps.count - 1 {
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
        let isNew = (app.feedKind ?? "").lowercased() == "new"
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
            Text("ماكو تطبيقات مسجلة بهذا اليوم في IPA-AR.json")
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
            Text("تعذر تحميل IPA-AR.json")
                .font(AppFont.bold(14))
                .foregroundStyle(StoreTheme.textPrimary)
            Text(message)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("إعادة المحاولة") {
                Task { await loadSource(force: true) }
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

    private var displayWeek: [LocalFeedDay] {
        UpdatesDateTools.lastSevenDays().map { date in
            let day = UpdatesDateTools.key(for: date)
            let newCount = sourceApps.reduce(into: 0) { count, app in
                if app.normalizedAddedDay == day { count += 1 }
            }
            let updatedCount = sourceApps.reduce(into: 0) { count, app in
                if app.normalizedAddedDay != day && app.normalizedUpdatedDay == day { count += 1 }
            }
            return LocalFeedDay(date: day, new: newCount, updated: updatedCount)
        }
    }

    private var selectedCounts: (new: Int, updated: Int) {
        guard let day = displayWeek.first(where: { $0.date == selectedDay }) else { return (0, 0) }
        return (day.new, day.updated)
    }

    private var selectedApps: [StoreApp] {
        sourceApps.compactMap { app in
            guard app.eventKind(on: selectedDay) != nil else { return nil }
            return app.storeApp(on: selectedDay)
        }
    }

    private func loadSource(force: Bool) async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }

        do {
            sourceApps = try await service.fetch(force: force)
            lastRefresh = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shortWeekday(_ value: String) -> String {
        switch value {
        case "الأحد": return "أحد"
        case "الاثنين", "الإثنين": return "اثن"
        case "الثلاثاء": return "ثلا"
        case "الأربعاء": return "أرب"
        case "الخميس": return "خمي"
        case "الجمعة": return "جمع"
        case "السبت": return "سبت"
        default: return String(value.prefix(3))
        }
    }
}
