import SwiftUI
import UIKit
import Foundation
import CoreText
struct AppDetailView: View {
    let app: StoreApp
    @State private var similar: [StoreApp] = []
    @State private var extras: PackageExtras?
    @State private var reviews: ReviewsResponse?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                detailHero
                detailInfo
                if let notes = app.notes, !notes.isEmpty { notesCard(notes) }
                extrasCard
                ratingCard
                if !similar.isEmpty { similarSection }
                Color.clear.frame(height: 28)
            }.padding(.top, 12)
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            async let s: SimilarResponse? = try? await StoreAPI.shared.similar(appId: app.id)
            async let e: PackageExtras? = try? await StoreAPI.shared.extras(appId: app.id)
            async let r: ReviewsResponse? = try? await StoreAPI.shared.reviews(appId: app.id)
            similar = await s?.apps ?? []
            extras = await e
            reviews = await r
        }
    }

    private var detailHero: some View {
        VStack(spacing: 16) {
            AppIconView(app: app, size: 112)
            VStack(spacing: 5) {
                Text(app.name).font(AppFont.black(24)).foregroundStyle(StoreTheme.textPrimary).multilineTextAlignment(.center)
                Text(app.bundleId ?? "").font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary).lineLimit(1)
            }
            InstallPill(title: "تثبيت")
        }.frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private var detailInfo: some View {
        HStack(spacing: 0) {
            metric("الإصدار", app.version ?? "—")
            divider
            metric("الحجم", app.fileSize.map(formatBytes) ?? "—")
            divider
            metric("التثبيتات", "\(app.installs ?? 0)")
        }.padding(.vertical, 15).storeCard(radius: 18).padding(.horizontal, StoreTheme.pageHorizontal)
    }
    private var divider: some View { Rectangle().fill(StoreTheme.surfaceBorder).frame(width: 1, height: 38) }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) { Text(value).font(AppFont.bold(13)).foregroundStyle(StoreTheme.textPrimary); Text(title).font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }.frame(maxWidth: .infinity)
    }
    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text("وصف التطبيق").font(AppFont.black(17)).foregroundStyle(StoreTheme.textPrimary)
            Text(notes).font(AppFont.regular(13)).foregroundStyle(StoreTheme.textSecondary).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(16).storeCard().padding(.horizontal, StoreTheme.pageHorizontal)
    }

    @ViewBuilder private var extrasCard: some View {
        if let extras {
            VStack(spacing: 0) {
                optionRow(icon: "square.on.square", title: "نسخ التطبيق", enabled: extras.allowDuplicate == true)
                Divider().overlay(StoreTheme.surfaceBorder)
                optionRow(icon: "shippingbox.fill", title: "إضافة Dylib", enabled: extras.allowDylibs == true)
                Divider().overlay(StoreTheme.surfaceBorder)
                optionRow(icon: "checkmark.shield.fill", title: "الاحتفاظ بالملف التعريفي", enabled: extras.keepProfile == true)
            }.padding(.horizontal, 14).storeCard().padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }
    private func optionRow(icon: String, title: String, enabled: Bool) -> some View {
        HStack { Image(systemName: enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(enabled ? StoreTheme.accent : StoreTheme.tabInactive); Spacer(); Text(title).font(AppFont.medium(13)).foregroundStyle(StoreTheme.textPrimary); Image(systemName: icon).foregroundStyle(StoreTheme.textSecondary) }.frame(height: 48)
    }

    @ViewBuilder private var ratingCard: some View {
        if let reviews {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text(String(format: "%.1f", reviews.average ?? 0)).font(AppFont.black(28)).foregroundStyle(StoreTheme.textPrimary); Text("من \(reviews.count ?? 0) تقييم").font(AppFont.regular(10)).foregroundStyle(StoreTheme.textSecondary) }
                Spacer()
                HStack(spacing: 3) { ForEach(0..<5, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(StoreTheme.badgeUpdated) } }
            }.padding(16).storeCard().padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }

    private var similarSection: some View {
        VStack(spacing: 12) {
            SectionTitle(title: "تطبيقات مشابهة")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { ForEach(similar.prefix(10)) { ShowcaseCard(app: $0) } }.padding(.horizontal, StoreTheme.pageHorizontal)
            }
        }
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct ExploreView: View {
    @EnvironmentObject private var store: StoreViewModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    StoreHeader()
                    HStack {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("استكشف").font(AppFont.black(29)).foregroundStyle(StoreTheme.textPrimary)
                            Text("اكتشف أكثر من \((store.explore.totalApps ?? store.catalog.total ?? 0).formatted()) تطبيق ولعبة").font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary)
                        }
                        Spacer()
                    }.padding(.horizontal, StoreTheme.pageHorizontal)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.explore.categories ?? []) { CategoryGridTile(category: $0) }
                    }.padding(.horizontal, StoreTheme.pageHorizontal)
                }.padding(.bottom, 20)
            }.background(StoreTheme.background).navigationBarHidden(true)
        }.navigationViewStyle(.stack)
    }
}
