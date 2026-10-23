import SwiftUI
import UIKit
import Foundation
import CoreText

struct AppDetailView: View {
    let app: StoreApp

    @State private var similar: [StoreApp] = []
    @State private var reviews: ReviewsResponse?
    @State private var appleItem: AppleAppStoreItem?
    @State private var appleLookupFinished = false
    @State private var showDuplicate = false
    @State private var showDylib = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                turathHero

                detailInfo
                    .padding(.top, 8)

                if let notes = app.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notesSection(notes)
                        .padding(.top, 26)
                }

                if !app.isDylibAsset {
                    applePreviewSection
                        .padding(.top, 26)
                }

                if !app.isDylibAsset {
                    ratingCard
                        .padding(.top, 26)
                }

                if !app.isDylibAsset && !similar.isEmpty {
                    similarSection
                        .padding(.top, 28)
                }

                Color.clear.frame(height: 34)
            }
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.id) {
            if app.isDylibAsset {
                similar = []
                reviews = nil
                appleItem = nil
                appleLookupFinished = true
                return
            }

            async let localSimilar: [StoreApp] = KiraPagesUpdatesService.shared.similarApps(to: app, limit: 8)
            async let r: ReviewsResponse? = try? await StoreAPI.shared.reviews(appId: app.id)
            async let a: AppleAppStoreItem? = AppleAppStoreLookup.shared.item(bundleID: app.bundleId ?? "")

            similar = await localSimilar
            reviews = await r
            appleItem = await a
            appleLookupFinished = true
        }
        .sheet(isPresented: $showDuplicate) {
            AppCloneSheet(app: app)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showDylib) {
            AppDylibMergeSheet(app: app)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    private func openDuplicateSheet() {
        if SigningAssetProvider.hasCredentials {
            showDuplicate = true
        } else {
            SigningSetupCoordinator.shared.request {
                showDuplicate = true
            }
        }
    }

    private func openDylibSheet() {
        if SigningAssetProvider.hasCredentials {
            showDylib = true
        } else {
            SigningSetupCoordinator.shared.request {
                showDylib = true
            }
        }
    }

    private var turathHero: some View {
        ZStack(alignment: .top) {
            heroBackdrop

            VStack(spacing: 0) {
                detailTopBar
                    .padding(.top, 7)

                Spacer().frame(height: 62)

                AppIconView(app: app, size: 122)
                    .shadow(color: .black.opacity(0.34), radius: 22, y: 10)

                VStack(spacing: 7) {
                    Text(app.name)
                        .font(AppFont.black(25))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.80)

                    if let bundle = app.bundleId, !bundle.isEmpty {
                        Text(bundle)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(StoreTheme.textSecondary)
                            .lineLimit(1)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                if app.isDylibAsset {
                    DirectDownloadButton(app: app)
                        .padding(.horizontal, 16)
                        .padding(.top, 27)
                } else {
                    TurathDetailInstallButton(app: app)
                        .padding(.horizontal, 16)
                        .padding(.top, 27)

                    HStack(spacing: 12) {
                        detailActionButton(
                            title: "دمج ديلب مع التطبيق",
                            icon: "puzzlepiece.extension.fill"
                        ) {
                            openDylibSheet()
                        }

                        detailActionButton(
                            title: "تكرار",
                            icon: "plus.square.on.square"
                        ) {
                            openDuplicateSheet()
                        }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var heroBackdrop: some View {
        ZStack {
            StoreTheme.background

            RemoteImage(path: app.iconUrl, cornerRadius: 0)
                .frame(width: UIScreen.main.bounds.width, height: 440)
                .scaleEffect(1.22)
                .blur(radius: 58)
                .saturation(1.32)
                .opacity(0.62)
                .offset(y: -50)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.14),
                    StoreTheme.background.opacity(0.14),
                    StoreTheme.background.opacity(0.46),
                    StoreTheme.background.opacity(0.88),
                    StoreTheme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Color.white.opacity(0.06), .clear],
                center: .top,
                startRadius: 8,
                endRadius: 320
            )
        }
        .ignoresSafeArea(edges: .top)
    }

    private var detailTopBar: some View {
        ZStack {
            Text(app.name)
                .font(AppFont.bold(17))
                .foregroundStyle(StoreTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .padding(.horizontal, 126)

            HStack(spacing: 10) {
                categoryBadge

                Spacer(minLength: 8)

                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 7) {
                        Text("رجوع")
                            .font(AppFont.medium(15))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 21, weight: .semibold))
                    }
                    .foregroundStyle(StoreTheme.accent)
                }
                .buttonStyle(.plain)
                .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: 54)
        .padding(.horizontal, 16)
    }

    private var categoryBadge: some View {
        HStack(spacing: 8) {
            Text(StoreLanguage.localized(app.primaryCategoryName))
                .font(AppFont.bold(12))
                .foregroundStyle(StoreTheme.accent)
                .lineLimit(1)

            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(StoreTheme.accent)
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(StoreTheme.accent.opacity(0.12))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(StoreTheme.accent.opacity(0.12), lineWidth: 0.8)
        }
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }

    private func detailActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(StoreLanguage.localized(title))
                    .font(AppFont.black(14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(StoreTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(StoreTheme.surface.opacity(0.90))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(StoreTheme.surfaceBorder.opacity(0.92), lineWidth: 0.9)
            }
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }

    private var detailInfo: some View {
        HStack(spacing: 0) {
            metric("آخر تحديث", formattedUpdateDate)
            divider
            metric("الحجم", app.fileSize.map(formatBytes) ?? "—")
            divider
            metric("الإصدار", app.version ?? "—")
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(.vertical, 17)
        .background(StoreTheme.surface.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(StoreTheme.surfaceBorder.opacity(0.52), lineWidth: 0.7)
        }
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(StoreTheme.surfaceBorder.opacity(0.95))
            .frame(width: 1, height: 48)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 7) {
            Text(value)
                .font(AppFont.black(13.5))
                .foregroundStyle(StoreTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.64)

            Text(StoreLanguage.localized(title))
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(StoreLanguage.localized(app.isDylibAsset ? "وصف الملف" : "وصف التطبيق"))
                .font(AppFont.black(20))
                .foregroundStyle(StoreTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            RTLDescriptionText(text: notes, fontSize: 14, lineSpacing: 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }

    @ViewBuilder
    private var applePreviewSection: some View {
        if let screenshots = appleItem?.screenshots, !screenshots.isEmpty {
            VStack(spacing: 14) {
                HStack {
                    Text("من App Store")
                        .font(AppFont.regular(11))
                        .foregroundStyle(StoreTheme.textSecondary)
                    Spacer()
                    Text("معاينات")
                        .font(AppFont.black(20))
                        .foregroundStyle(StoreTheme.textPrimary)
                }
                .padding(.horizontal, 18)
                .environment(\.layoutDirection, .leftToRight)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(screenshots.enumerated()), id: \.offset) { _, url in
                            AppleScreenshotCard(url: url)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
            .transition(.opacity)
        } else if !appleLookupFinished, let bundle = app.bundleId, !bundle.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(StoreTheme.accent)
                    .scaleEffect(0.85)
                Text("جاري البحث عن معاينات App Store…")
                    .font(AppFont.regular(11))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var ratingCard: some View {
        if let reviews,
           reviews.enabled != false,
           (reviews.count ?? 0) > 0,
           (reviews.average ?? 0) > 0 {
            VStack(spacing: 12) {
                Text("التقييم")
                    .font(AppFont.black(20))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "%.1f", reviews.average ?? 0))
                            .font(AppFont.black(29))
                            .foregroundStyle(StoreTheme.textPrimary)
                        Text("من \(reviews.count ?? 0) تقييم")
                            .font(AppFont.regular(10.5))
                            .foregroundStyle(StoreTheme.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(StoreTheme.badgeUpdated)
                        }
                    }
                }
                .padding(17)
                .storeCard(radius: 20)
            }
            .padding(.horizontal, 18)
        } else if let rating = appleItem?.rating,
                  rating > 0,
                  (appleItem?.ratingCount ?? 0) > 0 {
            VStack(spacing: 12) {
                Text("التقييم")
                    .font(AppFont.black(20))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "%.1f", rating))
                            .font(AppFont.black(29))
                            .foregroundStyle(StoreTheme.textPrimary)
                        Text("App Store · \(appleItem?.ratingCount ?? 0) تقييم")
                            .font(AppFont.regular(10.5))
                            .foregroundStyle(StoreTheme.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "star.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(StoreTheme.badgeUpdated)
                }
                .padding(17)
                .storeCard(radius: 20)
            }
            .padding(.horizontal, 18)
        }
    }

    private var similarSection: some View {
        VStack(spacing: 14) {
            Text(StoreLanguage.localized(app.isGameAsset ? "الألعاب المتشابهة" : "التطبيقات المتشابهة"))
                .font(AppFont.black(20))
                .foregroundStyle(StoreTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(similar.prefix(8)) { candidate in
                        NavigationLink(destination: AppDetailView(app: candidate)) {
                            ShowcaseCard(app: candidate)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    private var formattedUpdateDate: String {
        let raw = [app.versionUpdatedAt, app.updatedAt, app.addedAt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let raw else { return "—" }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = iso.date(from: raw)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: raw)
        }
        if date == nil {
            let simple = DateFormatter()
            simple.locale = Locale(identifier: "en_US_POSIX")
            simple.dateFormat = "yyyy-MM-dd"
            date = simple.date(from: String(raw.prefix(10)))
        }

        guard let date else { return String(raw.prefix(10)) }

        let output = DateFormatter()
        output.locale = Locale(identifier: "ar_IQ")
        output.calendar = Calendar(identifier: .gregorian)
        output.dateFormat = "d MMMM yyyy"
        return output.string(from: date)
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct TurathDetailInstallButton: View {
    let app: StoreApp

    @ObservedObject private var installer = StoreInstallCoordinator.shared
    @State private var installErrorMessage: String?

    private var state: StoreInstallState {
        installer.state(for: app)
    }

    private var readyLike: Bool {
        state.phase == .ready || state.phase == .complete || state.phase == .installing
    }

    private var title: String {
        switch state.phase {
        case .idle: return "تثبيت"
        case .downloading:
            if state.progress > 0 {
                return "\(Int((state.progress / 0.90) * 100))%"
            }
            return "تحميل"
        case .ready: return "جاهز"
        case .signing: return "توقيع"
        case .installing: return "جاهز"
        case .complete: return "جاهز"
        case .failed: return "تثبيت"
        }
    }

    private var isWorking: Bool {
        [.downloading, .signing].contains(state.phase)
    }

    var body: some View {
        Button {
            TransferActivityCenter.shared.track(app)

            if state.phase == .installing {
                installer.applicationDidBecomeActive()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                    if installer.state(for: app).phase == .ready {
                        installer.start(app)
                    }
                }
                return
            }

            if SigningAssetProvider.hasCredentials {
                installer.start(app)
            } else {
                SigningSetupCoordinator.shared.request(for: app)
            }
        } label: {
            HStack(spacing: 9) {
                Text(StoreLanguage.localized(title))
                    .font(AppFont.black(17))

                if isWorking {
                    ProgressView()
                        .tint(StoreTheme.onAccent)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: readyLike ? "checkmark.circle.fill" : "arrow.down.square.fill")
                        .font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(StoreTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                if readyLike {
                    Color.green
                } else {
                    LinearGradient(
                        colors: [StoreTheme.accent.opacity(0.86), StoreTheme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .onChange(of: state) { newState in
            if let error = newState.errorMessage, !error.isEmpty {
                installErrorMessage = error
            } else if newState.phase == .failed {
                installErrorMessage = newState.message ?? "تعذر إكمال عملية التثبيت."
            }
        }
        .alert(
            "تعذر التثبيت",
            isPresented: Binding(
                get: { installErrorMessage != nil },
                set: { if !$0 { installErrorMessage = nil } }
            )
        ) {
            Button("حسنًا", role: .cancel) {
                installErrorMessage = nil
            }
        } message: {
            Text(installErrorMessage ?? "")
        }
    }
}

private struct AppleScreenshotCard: View {
    let url: URL

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StoreTheme.field)

            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(1)
                case .failure:
                    Image(systemName: "photo")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(StoreTheme.textSecondary)
                case .empty:
                    ProgressView().tint(StoreTheme.accent)
                @unknown default:
                    EmptyView()
                }
            }
        }
        .frame(width: 230, height: 390)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StoreTheme.surfaceBorder.opacity(0.75), lineWidth: 0.8)
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject private var store: StoreViewModel
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    StoreHeader()
                    HStack {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("استكشف")
                                .font(AppFont.black(29))
                                .foregroundStyle(StoreTheme.textPrimary)
                            Text("اكتشف أكثر من \((store.explore.totalApps ?? store.catalog.total ?? 0).formatted()) تطبيق ولعبة")
                                .font(AppFont.regular(12))
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.explore.categories ?? []) {
                            CategoryGridTile(category: $0)
                        }
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)
                }
                .padding(.bottom, 20)
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}
