import SwiftUI
import UIKit
import Foundation
import CoreText
struct SearchView: View {
    @EnvironmentObject private var store: StoreViewModel
    @State private var query = ""
    var results: [StoreApp] { store.search(query) }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    StoreHeader()
                    hero
                    searchField
                    if query.isEmpty { suggestions } else { resultsList }
                }.padding(.bottom, 24)
            }.background(StoreTheme.background).navigationBarHidden(true)
        }.navigationViewStyle(.stack)
    }

    private var hero: some View {
        VStack(alignment: .trailing, spacing: 9) {
            HStack {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ابحث عن أي تطبيق").font(AppFont.black(26)).foregroundStyle(.white)
                    Text("\((store.searchMeta.totalApps ?? store.catalog.total ?? 0).formatted()) تطبيق متوفر في المتجر").font(AppFont.regular(12)).foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 58)).foregroundStyle(.white.opacity(0.88))
            }
        }.padding(19).background(LinearGradient(colors: [StoreTheme.accent.opacity(0.62), StoreTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)).padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(StoreTheme.textSecondary)
            TextField("اسم التطبيق أو اللعبة", text: $query).font(AppFont.regular(14)).foregroundStyle(StoreTheme.textPrimary).multilineTextAlignment(.trailing)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(StoreTheme.tabInactive) } }
        }.padding(.horizontal, 14).frame(height: 50).background(StoreTheme.field).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, StoreTheme.pageHorizontal)
    }

    private var suggestions: some View {
        VStack(spacing: 14) {
            SectionTitle(title: "عمليات بحث رائجة")
            FlowTags(items: store.searchMeta.trending?.map(\.term) ?? []) { query = $0 }
        }
    }
    private var resultsList: some View {
        VStack(spacing: 0) {
            ForEach(results) { app in NavigationLink(destination: AppDetailView(app: app)) { LargeListRow(app: app) }.buttonStyle(.plain); Divider().overlay(StoreTheme.surfaceBorder.opacity(0.7)) }
        }.padding(.horizontal, 14).storeCard().padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct FlowTags: View {
    let items: [String]
    let onTap: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 9)], spacing: 9) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item).font(AppFont.medium(12)).foregroundStyle(StoreTheme.textPrimary).frame(maxWidth: .infinity).frame(height: 38).background(StoreTheme.field).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct UpdatesView: View {
    @EnvironmentObject private var store: StoreViewModel
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    StoreHeader()
                    HStack(spacing: 10) {
                        stat(title: "جديد", value: store.feed.counts?.new ?? 0, color: StoreTheme.badgeNew)
                        stat(title: "تحديث", value: store.feed.counts?.updated ?? 0, color: StoreTheme.badgeUpdated)
                    }.padding(.horizontal, StoreTheme.pageHorizontal)
                    VStack(spacing: 0) {
                        ForEach(store.feed.apps) { app in
                            NavigationLink(destination: AppDetailView(app: app)) { LargeListRow(app: app) }.buttonStyle(.plain)
                            Divider().overlay(StoreTheme.surfaceBorder.opacity(0.7))
                        }
                    }.padding(.horizontal, 14).storeCard().padding(.horizontal, StoreTheme.pageHorizontal)
                }.padding(.bottom, 24)
            }.background(StoreTheme.background).navigationBarHidden(true)
        }.navigationViewStyle(.stack)
    }
    private func stat(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 8) { Text("\(value)").font(AppFont.black(26)).foregroundStyle(StoreTheme.textPrimary); HStack { Circle().fill(color).frame(width: 7, height: 7); Text(title).font(AppFont.medium(11)).foregroundStyle(StoreTheme.textSecondary) } }.padding(15).frame(maxWidth: .infinity, alignment: .trailing).storeCard(radius: 18)
    }
}

struct ShopView: View {
    @EnvironmentObject private var store: StoreViewModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                StoreHeader()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("المتجر").font(AppFont.black(28)).foregroundStyle(StoreTheme.textPrimary)
                    Text("اشتراكات ومنتجات رقمية").font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, StoreTheme.pageHorizontal)
                if (store.cards.products ?? []).isEmpty { emptyShop }
                else {
                    LazyVGrid(columns: columns, spacing: 12) { ForEach(store.cards.products ?? []) { ProductCard(product: $0) } }.padding(.horizontal, StoreTheme.pageHorizontal)
                }
            }.padding(.bottom, 24)
        }.background(StoreTheme.background)
    }
    private var emptyShop: some View {
        VStack(spacing: 10) { Image(systemName: "bag.fill").font(.system(size: 38)).foregroundStyle(StoreTheme.accent); Text("جاري تحميل المنتجات").font(AppFont.bold(14)).foregroundStyle(StoreTheme.textPrimary); Text("سيتم عرض منتجات المتجر هنا عند توفر الاتصال.").font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary) }.frame(maxWidth: .infinity).padding(28).storeCard().padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct ProductCard: View {
    let product: CardProduct
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            RemoteImage(path: product.imageUrl, cornerRadius: 16, systemFallback: "bag.fill").frame(height: 118)
            Text(product.name).font(AppFont.bold(13)).foregroundStyle(StoreTheme.textPrimary).lineLimit(2)
            HStack { if product.soldOut == true { Text("نفد").font(AppFont.bold(10)).foregroundStyle(.red) }; Spacer(); Text(priceText).font(AppFont.black(14)).foregroundStyle(StoreTheme.accent) }
        }.padding(11).storeCard(radius: 19)
    }
    private var priceText: String { guard let p = product.price else { return "—" }; return "\(p.formatted()) \(product.currency ?? "IQD")" }
}

struct StoreSettingsView: View {
    @EnvironmentObject private var store: StoreViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            StoreTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    HStack { Button("إغلاق") { dismiss() }.font(AppFont.bold(13)).foregroundStyle(StoreTheme.accent); Spacer(); Text("الحساب").font(AppFont.black(20)).foregroundStyle(StoreTheme.textPrimary) }
                    ticket
                    VStack(spacing: 0) {
                        settingRow("عدد التطبيقات", "\((store.catalog.total ?? store.searchMeta.totalApps ?? 0).formatted())", "square.stack.3d.up.fill")
                        Divider().overlay(StoreTheme.surfaceBorder)
                        settingRow("نمط التصميم", "Night", "moon.stars.fill")
                        Divider().overlay(StoreTheme.surfaceBorder)
                        settingRow("لغة المتجر", "العربية", "globe")
                    }.padding(.horizontal, 14).storeCard()
                    VStack(alignment: .trailing, spacing: 9) {
                        Text("ربط الـAPI").font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary)
                        Text("النسخة لا تضع UDID الذي ظهر في ملف المراقبة داخل الريبو العام. إذا كان خادمك يتطلب UDID، خزّنه محليًا بالمفتاح store.deviceUDID أو اربطه بباكندك الخاص.").font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary)
                    }.padding(16).storeCard()
                }.padding(16)
            }
        }
    }
    private var ticket: some View {
        VStack(spacing: 15) {
            HStack { VStack(alignment: .trailing, spacing: 5) { Text(store.catalog.subscription?.planName ?? "الباقة الملكية").font(AppFont.black(21)).foregroundStyle(.white); Text("اشتراك فعال").font(AppFont.medium(11)).foregroundStyle(.white.opacity(0.7)) }; Spacer(); Image(systemName: "crown.fill").font(.system(size: 32)).foregroundStyle(.white) }
            Divider().overlay(Color.white.opacity(0.18))
            HStack { Text(store.catalog.subscription?.deviceModel ?? "iPhone").font(AppFont.bold(12)).foregroundStyle(.white); Spacer(); Text("حتى \(shortDate(store.catalog.subscription?.expiresAt))").font(AppFont.regular(11)).foregroundStyle(.white.opacity(0.75)) }
        }.padding(18).background(LinearGradient(colors: [StoreTheme.accent.opacity(0.82), Color(hex: "#384B8D")], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    private func settingRow(_ title: String, _ value: String, _ icon: String) -> some View { HStack { Text(value).font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary); Spacer(); Text(title).font(AppFont.medium(13)).foregroundStyle(StoreTheme.textPrimary); Image(systemName: icon).foregroundStyle(StoreTheme.accent).frame(width: 24) }.frame(height: 48) }
    private func shortDate(_ value: String?) -> String { guard let value else { return "—" }; return String(value.prefix(10)) }
}
