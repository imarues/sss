import SwiftUI
import Foundation

private enum UpdatesViewDateTools {
    static var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Baghdad") ?? .current
        return value
    }()

    static func formatter(_ format: String, locale: String) -> DateFormatter {
        let value = DateFormatter()
        value.calendar = calendar
        value.timeZone = calendar.timeZone
        value.locale = Locale(identifier: locale)
        value.dateFormat = format
        return value
    }

    static func date(from key: String) -> Date? {
        formatter("yyyy-MM-dd", locale: "en_US_POSIX").date(from: key)
    }

    static func weekday(for key: String) -> String {
        guard let date = date(from: key) else { return "—" }
        return formatter("EEEE", locale: "ar_IQ").string(from: date)
    }

    static func dayNumber(for key: String) -> Int {
        guard let date = date(from: key) else { return 0 }
        return calendar.component(.day, from: date)
    }

    static func relativeTitle(for key: String) -> String {
        guard let date = date(from: key) else { return key }
        let today = calendar.startOfDay(for: Date())
        let selected = calendar.startOfDay(for: date)
        let delta = calendar.dateComponents([.day], from: selected, to: today).day ?? 0
        if delta == 0 { return "اليوم" }
        if delta == 1 { return "أمس" }
        return formatter("d MMM", locale: "ar_IQ").string(from: date)
    }
}

struct LiveUpdatesView: View {
    @State private var selectedDay = KiraUpdatesClock.lastSevenDayKeys().first ?? ""
    @State private var days: [KiraUpdatesDay] = KiraUpdatesClock.lastSevenDayKeys().map {
        KiraUpdatesDay(date: $0, new: 0, updated: 0)
    }
    @State private var appsByDay: [String: [StoreApp]] = [:]
    @State private var visibleLimit = 35
    @State private var loadingInitial = true
    @State private var refreshing = false
    @State private var errorMessage: String?

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
                    if let errorMessage, selectedAllApps.isEmpty, !loadingInitial {
                        errorView(errorMessage)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
            .refreshable { await refresh(force: true) }
            .task { await bootstrap() }
        }
        .navigationViewStyle(.stack)
    }

    private var selectedAllApps: [StoreApp] { appsByDay[selectedDay] ?? [] }
    private var visibleApps: ArraySlice<StoreApp> { selectedAllApps.prefix(visibleLimit) }

    private var selectedCounts: (new: Int, updated: Int) {
        guard let day = days.first(where: { $0.date == selectedDay }) else { return (0, 0) }
        return (day.new, day.updated)
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
                if refreshing {
                    ProgressView().tint(StoreTheme.accent)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(StoreTheme.accent)
                }
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
                ForEach(days) { day in dayButton(day) }
            }
            .padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }

    private func dayButton(_ day: KiraUpdatesDay) -> some View {
        let selected = day.date == selectedDay
        let weekday = UpdatesViewDateTools.weekday(for: day.date)
        let number = UpdatesViewDateTools.dayNumber(for: day.date)

        return Button {
            guard day.date != selectedDay else { return }
            visibleLimit = 35
            withAnimation(.easeInOut(duration: 0.16)) { selectedDay = day.date }
        } label: {
            VStack(spacing: 5) {
                Text(shortWeekday(weekday))
                    .font(AppFont.medium(10.5))
                    .foregroundStyle(selected ? StoreTheme.onAccent : StoreTheme.textSecondary)
                    .lineLimit(1)
                Text("\(number)")
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
            if loadingInitial {
                ProgressView().tint(StoreTheme.accent).scaleEffect(0.85)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(UpdatesViewDateTools.relativeTitle(for: selectedDay))
                    .font(AppFont.black(18))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text("\(selectedAllApps.count) تطبيق")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    @ViewBuilder
    private var appsList: some View {
        if !selectedAllApps.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleApps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 8) {
                        NavigationLink(destination: AppDetailView(app: app)) {
                            updateRowContent(app)
                        }
                        .buttonStyle(.plain)

                        InstallPill(app: app)
                    }
                    .padding(.vertical, 10)

                    if index < visibleApps.count - 1 {
                        Divider()
                            .overlay(StoreTheme.surfaceBorder.opacity(0.65))
                            .padding(.trailing, 74)
                    }

                    if index == visibleApps.count - 1 && visibleLimit < selectedAllApps.count {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                visibleLimit = min(visibleLimit + 35, selectedAllApps.count)
                            }
                    }
                }
            }
            .padding(.horizontal, 14)
            .storeCard(radius: 20)
            .padding(.horizontal, StoreTheme.pageHorizontal)
        } else if loadingInitial {
            loadingCard
        } else if errorMessage == nil {
            emptyView
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(StoreTheme.accent)
            Text("جاري تجهيز التحديثات…")
                .font(AppFont.medium(12))
                .foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private func updateRowContent(_ app: StoreApp) -> some View {
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
        }
        .frame(maxWidth: .infinity)
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
            Text("تعذر تحديث IPA-AR.json")
                .font(AppFont.bold(14))
                .foregroundStyle(StoreTheme.textPrimary)
            Text(message)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("إعادة المحاولة") {
                Task { await refresh(force: true) }
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

    private func bootstrap() async {
        var hadCache = false
        if let cached = await service.cached() {
            apply(cached)
            hadCache = true
            loadingInitial = false
        }

        if !hadCache { loadingInitial = true }
        await refresh(force: false)
        loadingInitial = false
    }

    private func refresh(force: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        do {
            let fresh = try await service.refreshIfNeeded(force: force)
            apply(fresh)
            errorMessage = nil
        } catch {
            if appsByDay.values.allSatisfy({ $0.isEmpty }) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: KiraUpdatesSnapshot) {
        days = snapshot.days
        appsByDay = snapshot.appsByDay
        if !days.contains(where: { $0.date == selectedDay }) {
            selectedDay = days.first?.date ?? selectedDay
        }
        visibleLimit = 35
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
