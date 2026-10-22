import SwiftUI
import UIKit
import Foundation
import CoreText

struct AppDetailView: View {
    let app: StoreApp
    @State private var similar: [StoreApp] = []
    @State private var extras: PackageExtras?
    @State private var reviews: ReviewsResponse?
    @State private var appleItem: AppleAppStoreItem?
    @State private var appleLookupFinished = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                detailHero
                detailInfo
                if !app.isDylibAsset { applePreviewSection }
                if let notes = app.notes, !notes.isEmpty { notesCard(notes) }
                if !app.isDylibAsset { extrasCard }
                if !app.isDylibAsset { ratingCard }
                if !app.isDylibAsset && !similar.isEmpty { similarSection }
                Color.clear.frame(height: 28)
            }
            .padding(.top, 12)
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: app.id) {
            if app.isDylibAsset {
                similar = []
                extras = nil
                reviews = nil
                appleItem = nil
                appleLookupFinished = true
                return
            }

            async let localSimilar: [StoreApp] = KiraPagesUpdatesService.shared.similarApps(to: app, limit: 8)
            async let e: PackageExtras? = try? await StoreAPI.shared.extras(appId: app.id)
            async let r: ReviewsResponse? = try? await StoreAPI.shared.reviews(appId: app.id)
            async let a: AppleAppStoreItem? = AppleAppStoreLookup.shared.item(bundleID: app.bundleId ?? "")

            similar = await localSimilar
            extras = await e
            reviews = await r
            appleItem = await a
            appleLookupFinished = true
        }
    }

    private var detailHero: some View {
        VStack(spacing: 16) {
            AppIconView(app: app, size: 112)
            VStack(spacing: 5) {
                Text(app.name)
                    .font(AppFont.black(24))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .multilineTextAlignment(.center)
                if let bundle = app.bundleId, !bundle.isEmpty {
                    Text(bundle)
                        .font(AppFont.regular(11))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            if app.isDylibAsset {
                DirectDownloadButton(app: app)
            } else {
                InstallPill(title: "تثبيت", app: app)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var detailInfo: some View {
        HStack(spacing: 0) {
            metric("الإصدار", app.version ?? "—")
            divider
            metric("الحجم", app.fileSize.map(formatBytes) ?? "—")
            divider
            metric("التصنيف", app.primaryCategoryName)
        }
        .padding(.vertical, 15)
        .storeCard(radius: 18)
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var divider: some View {
        Rectangle().fill(StoreTheme.surfaceBorder).frame(width: 1, height: 38)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(AppFont.bold(13))
                .foregroundStyle(StoreTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var applePreviewSection: some View {
        if let screenshots = appleItem?.screenshots, !screenshots.isEmpty {
            VStack(spacing: 12) {
                HStack {
                    Text("من App Store")
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                    Spacer()
                    Text("معاينات")
                        .font(AppFont.black(18))
                        .foregroundStyle(StoreTheme.textPrimary)
                }
                .padding(.horizontal, StoreTheme.pageHorizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 11) {
                        ForEach(Array(screenshots.enumerated()), id: \.offset) { _, url in
                            AppleScreenshotCard(url: url)
                        }
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)
                }
            }
            .transition(.opacity)
        } else if !appleLookupFinished, let bundle = app.bundleId, !bundle.isEmpty {
            HStack(spacing: 10) {
                ProgressView().tint(StoreTheme.accent).scaleEffect(0.85)
                Text("جاري البحث عن معاينات App Store…")
                    .font(AppFont.regular(11))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text(app.isDylibAsset ? "وصف الملف" : "وصف التطبيق")
                .font(AppFont.black(17))
                .foregroundStyle(StoreTheme.textPrimary)
            Text(notes)
                .font(AppFont.regular(13))
                .foregroundStyle(StoreTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .storeCard()
        .padding(.horizontal, StoreTheme.pageHorizontal)
    }

    @ViewBuilder
    private var extrasCard: some View {
        if let extras {
            VStack(spacing: 0) {
                optionRow(icon: "square.on.square", title: "نسخ التطبيق", enabled: extras.allowDuplicate == true)
                Divider().overlay(StoreTheme.surfaceBorder)
                optionRow(icon: "shippingbox.fill", title: "إضافة Dylib", enabled: extras.allowDylibs == true)
                Divider().overlay(StoreTheme.surfaceBorder)
                optionRow(icon: "checkmark.shield.fill", title: "الاحتفاظ بالملف التعريفي", enabled: extras.keepProfile == true)
            }
            .padding(.horizontal, 14)
            .storeCard()
            .padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }

    private func optionRow(icon: String, title: String, enabled: Bool) -> some View {
        HStack {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(enabled ? StoreTheme.accent : StoreTheme.tabInactive)
            Spacer()
            Text(title).font(AppFont.medium(13)).foregroundStyle(StoreTheme.textPrimary)
            Image(systemName: icon).foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(height: 48)
    }

    @ViewBuilder
    private var ratingCard: some View {
        if let reviews {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%.1f", reviews.average ?? 0))
                        .font(AppFont.black(28))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("من \(reviews.count ?? 0) تقييم")
                        .font(AppFont.regular(10))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(StoreTheme.badgeUpdated)
                    }
                }
            }
            .padding(16)
            .storeCard()
            .padding(.horizontal, StoreTheme.pageHorizontal)
        } else if let rating = appleItem?.rating {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%.1f", rating))
                        .font(AppFont.black(28))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("App Store · \(appleItem?.ratingCount ?? 0) تقييم")
                        .font(AppFont.regular(10))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "star.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(StoreTheme.badgeUpdated)
            }
            .padding(16)
            .storeCard()
            .padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }

    private var similarSection: some View {
        VStack(spacing: 12) {
            SectionTitle(title: app.isGameAsset ? "الألعاب المتشابهة" : "التطبيقات المتشابهة")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(similar.prefix(8)) { candidate in
                        NavigationLink(destination: AppDetailView(app: candidate)) {
                            ShowcaseCard(app: candidate)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, StoreTheme.pageHorizontal)
            }
        }
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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
