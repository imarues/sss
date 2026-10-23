import SwiftUI
import UIKit
import Foundation
import CoreText
struct RootStoreView: View {
    @EnvironmentObject private var store: StoreViewModel
    @State private var splashVisible = true

    var body: some View {
        ZStack {
            MainStoreShell().opacity(splashVisible ? 0 : 1)
            if splashVisible {
                SplashView(spec: store.config.splash)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(10)
            }
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .task {
            async let data: Void = store.load()
            let seconds = store.config.splash?.seconds ?? 3
            try? await Task.sleep(nanoseconds: UInt64(max(1.2, seconds) * 1_000_000_000))
            withAnimation(.easeInOut(duration: 0.42)) { splashVisible = false }
            _ = await data
        }
    }
}

struct SplashView: View {
    let spec: SplashSpec?
    @State private var breathe = false
    @State private var sweep = false

    var body: some View {
        ZStack {
            StoreTheme.splashBlue.ignoresSafeArea()
            RadialGradient(colors: [Color.white.opacity(0.13), .clear], center: .center, startRadius: 4, endRadius: 270)
                .scaleEffect(breathe ? 1.18 : 0.88).opacity(breathe ? 0.8 : 0.45)
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 31, style: .continuous).fill(Color.white.opacity(0.08)).frame(width: 118, height: 118)
                    RoundedRectangle(cornerRadius: 31, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1).frame(width: 118, height: 118)
                    Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 48, weight: .bold)).foregroundStyle(.white)
                }.scaleEffect(breathe ? 1.04 : 0.96)
                VStack(spacing: 9) {
                    Text(spec?.title ?? "التراث بلس").font(AppFont.black(31)).foregroundStyle(.white)
                    Text(spec?.subtitle ?? "أقوى متجر لتطبيقات البلس والاشتراكات الرقمية")
                        .font(AppFont.medium(13)).foregroundStyle(Color.white.opacity(0.74)).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                if let count = spec?.appCount {
                    Text("+\(count.formatted()) تطبيق")
                        .font(AppFont.bold(12)).foregroundStyle(.white)
                        .padding(.horizontal, 15).frame(height: 31).background(Color.white.opacity(0.1)).clipShape(Capsule())
                }
            }
            Rectangle().fill(LinearGradient(colors: [.clear, Color.white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: 110, height: 600).rotationEffect(.degrees(17)).offset(x: sweep ? 300 : -300).blur(radius: 7)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.55).repeatForever(autoreverses: true)) { breathe = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

enum StoreTab: String, CaseIterable, Identifiable {
    case home = "الرئيسية", explore = "استكشف", updates = "التحديثات", shop = "المتجر", search = "البحث"
    var id: String { rawValue }
    var icon: String {
        switch self { case .home: return "house.fill"; case .explore: return "square.grid.2x2.fill"; case .updates: return "arrow.triangle.2.circlepath"; case .shop: return "bag.fill"; case .search: return "magnifyingglass" }
    }
}

struct MainStoreShell: View {
    @State private var selected: StoreTab = .home
    var body: some View {
        ZStack(alignment: .bottom) {
            StoreTheme.background.ignoresSafeArea()
            Group {
                switch selected {
                case .home: HomeView()
                case .explore: ExploreView()
                case .updates: LiveUpdatesView()
                case .shop: ShopView()
                case .search: SearchFastView()
                }
            }.padding(.bottom, 84)
            FloatingStoreTabBar(selected: $selected)
        }
    }
}

struct FloatingStoreTabBar: View {
    @Binding var selected: StoreTab
    @Namespace private var animation
    var body: some View {
        HStack(spacing: 2) {
            ForEach(StoreTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selected = tab }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 17, weight: .semibold))
                        Text(tab.rawValue).font(AppFont.medium(9.5)).lineLimit(1)
                    }
                    .foregroundStyle(selected == tab ? StoreTheme.accent : StoreTheme.tabInactive)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background {
                        if selected == tab { RoundedRectangle(cornerRadius: 15, style: .continuous).fill(StoreTheme.accent.opacity(0.10)).matchedGeometryEffect(id: "active", in: animation) }
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(7).frame(maxWidth: 460)
        .background(.ultraThinMaterial).background(StoreTheme.sheet.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(StoreTheme.surfaceBorder.opacity(0.85), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

struct StoreHeader: View {
    @EnvironmentObject private var store: StoreViewModel
    @State private var showSettings = false
    @State private var showSigningHub = false
    @ObservedObject private var installer = StoreInstallCoordinator.shared
    @ObservedObject private var detailCenter = DetailPreparationCenter.shared
    @ObservedObject private var transfers = TransferActivityCenter.shared

    private var activeTransferCount: Int {
        transfers.activeCount(using: installer, detail: detailCenter)
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Button { showSettings = true } label: {
                    ZStack {
                        Circle().fill(StoreTheme.surface)
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(StoreTheme.textPrimary)
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)

                Button { showSigningHub = true } label: {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Circle().fill(StoreTheme.surface)
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(StoreTheme.textPrimary)
                        }
                        .frame(width: 42, height: 42)

                        if activeTransferCount > 0 {
                            Text(activeTransferCount > 99 ? "99+" : "\(activeTransferCount)")
                                .font(.system(size: activeTransferCount > 99 ? 7.5 : 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .padding(.horizontal, activeTransferCount > 9 ? 3 : 0)
                                .background(Color.red)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(StoreTheme.background, lineWidth: 2))
                                .offset(x: 5, y: -5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activeTransferCount > 0 ? "التنزيلات، \(activeTransferCount) عمليات جارية" : "التنزيلات")
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(store.config.storeName ?? "التراث بلس")
                    .font(AppFont.black(18))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text(store.config.tagline ?? "متجر التطبيقات")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, StoreTheme.pageHorizontal)
        .sheet(isPresented: $showSettings) {
            StoreSettingsView().environmentObject(store)
        }
        .sheet(isPresented: $showSigningHub) {
            SigningHubView()
                .environmentObject(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: StoreViewModel
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: StoreTheme.sectionGap, pinnedViews: []) {
                    StoreHeader()
                    // Live IPA-Ar/deb-Ar collections appear immediately below
                    // the settings and downloads buttons.
                    IPAHomeSections()
                    if !(store.home.banners ?? []).isEmpty { BannerCarousel(banners: store.home.banners ?? []) }
                    ForEach(Array(store.home.sections.enumerated()), id: \.offset) { _, section in
                        HomeSectionRenderer(section: section)
                    }
                    Color.clear.frame(height: 20)
                }.padding(.top, 2)
            }
            .background(StoreTheme.background)
            .navigationBarHidden(true)
        }.navigationViewStyle(.stack)
    }
}

struct BannerCarousel: View {
    let banners: [HomeBanner]
    var body: some View {
        TabView {
            ForEach(banners) { banner in
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(path: banner.imageUrl, cornerRadius: 24).frame(height: 184)
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom).clipShape(RoundedRectangle(cornerRadius: 24))
                    VStack(alignment: .trailing, spacing: 4) {
                        if let title = banner.title { Text(title).font(AppFont.black(19)).foregroundStyle(.white) }
                        if let subtitle = banner.subtitle { Text(subtitle).font(AppFont.medium(11.5)).foregroundStyle(.white.opacity(0.8)).lineLimit(2) }
                    }.padding(17)
                }.padding(.horizontal, StoreTheme.pageHorizontal)
            }
        }.frame(height: 192).tabViewStyle(.page(indexDisplayMode: .never))
    }
}

struct HomeSectionRenderer: View {
    let section: HomeSection
    var body: some View {
        VStack(spacing: 13) {
            SectionTitle(title: section.title ?? "")
            switch (section.layout ?? "").uppercased() {
            case "CARD_BAND": band
            case "SHOWCASE": showcase
            case "CATEGORY_STRIP": categoryStrip
            case "CATEGORY_GRID": categoryGrid
            case "LIST_LARGE": listLarge
            default: band
            }
        }
    }

    private var band: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(section.apps ?? []) { app in NavigationLink(destination: AppDetailView(app: app)) { BandCard(app: app) }.buttonStyle(.plain) }
            }.padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }
    private var showcase: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { ForEach(section.apps ?? []) { app in NavigationLink(destination: AppDetailView(app: app)) { ShowcaseCard(app: app) }.buttonStyle(.plain) } }
                .padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }
    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) { ForEach(section.categories ?? []) { CategoryStripCard(category: $0) } }.padding(.horizontal, StoreTheme.pageHorizontal)
        }
    }
    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array((section.categories ?? []).prefix(8))) { CategoryGridTile(category: $0) }
        }.padding(.horizontal, StoreTheme.pageHorizontal)
    }
    private var listLarge: some View {
        VStack(spacing: 0) {
            ForEach(Array((section.apps ?? []).prefix(10).enumerated()), id: \.offset) { index, app in
                NavigationLink(destination: AppDetailView(app: app)) { LargeListRow(app: app) }.buttonStyle(.plain)
                if index < (section.apps?.prefix(10).count ?? 0) - 1 { Divider().overlay(StoreTheme.surfaceBorder.opacity(0.7)).padding(.trailing, 74) }
            }
        }.padding(.horizontal, 14).storeCard(radius: 20).padding(.horizontal, StoreTheme.pageHorizontal)
    }
}
