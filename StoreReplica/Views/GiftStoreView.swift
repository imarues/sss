import SwiftUI
import Foundation

// Gift-store content is managed in the separate ipa-store repository.
// The store's Telegram recipient is fixed in the iOS app, not supplied by
// untrusted remote JSON. Updating gift.json updates the public catalog.
struct GiftCatalog: Decodable {
    let version: Int
    let store: String?
    let notice: String?
    let noticeEn: String?
    let products: [GiftProduct]
}

struct GiftProduct: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let titleEn: String?
    let category: String?
    let categoryEn: String?
    let subtitle: String?
    let subtitleEn: String?
    let description: String
    let descriptionEn: String?
    let features: [String]
    let featuresEn: [String]?
    let price: Int
    let compareAtPrice: Int?
    let currency: String
    let image: String?
    let symbol: String?
    let colors: [String]?
    let available: Bool
    let featured: Bool?
    let demo: Bool?
    let purchaseUrl: String?

    var shownTitle: String {
        StoreLanguage.isEnglish ? (titleEn ?? title) : title
    }
    var shownCategory: String {
        StoreLanguage.isEnglish ? (categoryEn ?? category ?? "Products") : (category ?? "المنتجات")
    }
    var shownSubtitle: String {
        StoreLanguage.isEnglish ? (subtitleEn ?? subtitle ?? "") : (subtitle ?? "")
    }
    var shownDescription: String {
        StoreLanguage.isEnglish ? (descriptionEn ?? description) : description
    }
    var shownFeatures: [String] {
        StoreLanguage.isEnglish ? (featuresEn ?? features) : features
    }
    var colorA: Color { Color(hex: colors?.first ?? "#6D5DEB") }
    var colorB: Color { Color(hex: colors?.dropFirst().first ?? "#2357C8") }
    var icon: String { symbol ?? "gift.fill" }
}

@MainActor
final class GiftCatalogStore: ObservableObject {
    @Published private(set) var catalog: GiftCatalog?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isOfflineCopy = false

    // Exactly the user-requested Cloudflare Pages endpoint.
    static let feedURL = URL(string: "https://ipastore.pages.dev/gift.json")!

    private var cachedFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("turath-gift-catalog.json")
    }

    func load(force: Bool = false) async {
        guard !loading else { return }
        if catalog == nil, let data = try? Data(contentsOf: cachedFile),
           let cached = try? decode(data) {
            catalog = cached
            isOfflineCopy = true
        }
        loading = true
        errorMessage = nil
        defer { loading = false }

        do {
            var request = URLRequest(url: Self.feedURL)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if force {
                request.cachePolicy = .reloadIgnoringLocalCacheData
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GiftStoreError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            guard data.count <= 1_000_000 else { throw GiftStoreError.tooLarge }
            let decoded = try decode(data)
            catalog = decoded
            isOfflineCopy = false
            try? data.write(to: cachedFile, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
            if catalog == nil { isOfflineCopy = false }
        }
    }

    private func decode(_ data: Data) throws -> GiftCatalog {
        let value = try JSONDecoder().decode(GiftCatalog.self, from: data)
        guard value.version >= 1, !value.products.isEmpty,
              value.products.count <= 200,
              Set(value.products.map(\.id)).count == value.products.count,
              value.products.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && $0.price >= 0 })
        else { throw GiftStoreError.invalidCatalog }
        return value
    }

    private enum GiftStoreError: LocalizedError {
        case invalidCatalog, tooLarge, httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .invalidCatalog: return "ملف العروض يحتوي بيانات ناقصة أو غير صالحة."
            case .tooLarge: return "ملف العروض أكبر من الحجم المسموح."
            case .httpStatus(let status): return "تعذر تحميل العروض (HTTP \(status))."
            }
        }
    }
}

struct GiftStoreView: View {
    @StateObject private var store = GiftCatalogStore()
    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 18) {
                    StoreHeader()

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(StoreLanguage.isEnglish ? "Store" : "المتجر")
                                .font(AppFont.black(29))
                                .foregroundStyle(StoreTheme.textPrimary)
                            Text(StoreLanguage.isEnglish ? "Offers & digital products" : "العروض والمنتجات الرقمية")
                                .font(AppFont.regular(12))
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "bag.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(StoreTheme.accent)
                            .frame(width: 50, height: 50)
                            .background(StoreTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                    }
                    .padding(.horizontal, StoreTheme.pageHorizontal)

                    if let catalog = store.catalog {
                        if let notice = StoreLanguage.isEnglish ? catalog.noticeEn : catalog.notice,
                           !notice.isEmpty {
                            Label(notice, systemImage: "info.circle.fill")
                                .font(AppFont.medium(11))
                                .foregroundStyle(StoreTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .background(StoreTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                                .padding(.horizontal, StoreTheme.pageHorizontal)
                        }

                        if store.isOfflineCopy {
                            Label(
                                StoreLanguage.isEnglish ? "Saved catalog — refresh to check new offers" :
                                    "قائمة محفوظة — اسحب للتحديث",
                                systemImage: "wifi.slash"
                            )
                            .font(AppFont.medium(11))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, StoreTheme.pageHorizontal)
                        }

                        if let error = store.errorMessage {
                            Text(StoreLanguage.isEnglish ? "Could not refresh; displaying the saved catalog." :
                                    "تعذر التحديث، يجري عرض القائمة المحفوظة.")
                                .font(AppFont.medium(11))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, StoreTheme.pageHorizontal)
                                .accessibilityHint(error)
                        }

                        LazyVGrid(columns: columns, spacing: 13) {
                            ForEach(catalog.products) { product in
                                NavigationLink(destination: GiftProductDetailView(product: product)) {
                                    GiftProductTile(product: product)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, StoreTheme.pageHorizontal)
                    } else if store.loading {
                        VStack(spacing: 12) {
                            ProgressView().tint(StoreTheme.accent)
                            Text(StoreLanguage.isEnglish ? "Loading offers…" : "جاري تحميل العروض…")
                                .font(AppFont.medium(12))
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 75)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 32))
                                .foregroundStyle(StoreTheme.accent)
                            Text(StoreLanguage.isEnglish ? "Could not load store offers" : "تعذر تحميل عروض المتجر")
                                .font(AppFont.bold(15))
                                .foregroundStyle(StoreTheme.textPrimary)
                            if let error = store.errorMessage {
                                Text(error)
                                    .font(AppFont.medium(11))
                                    .foregroundStyle(StoreTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            Button {
                                Task { await store.load(force: true) }
                            } label: {
                                Text(StoreLanguage.isEnglish ? "Try Again" : "إعادة المحاولة")
                                    .font(AppFont.bold(13))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24)
                                    .frame(height: 42)
                                    .background(StoreTheme.accent, in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 58)
                    }
                }
                .padding(.bottom, 26)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.load(force: true) }
            .task { await store.load() }
        }
    }
}

private struct GiftProductTile: View {
    let product: GiftProduct

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [product.colorA, product.colorB],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 96, height: 96)
                    .blur(radius: 24)
                    .offset(x: -60, y: -34)
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, .white.opacity(0.17), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 33, height: 140)
                    .rotationEffect(.degrees(24))
                    .offset(x: 47, y: -14)

                if let image = product.image, !image.isEmpty {
                    RemoteImage(path: image, cornerRadius: 14, systemFallback: product.icon)
                        .padding(6)
                } else {
                    Image(systemName: product.icon)
                        .font(.system(size: 49, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                }
            }
            .frame(height: 116)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(alignment: .topLeading) {
                if product.demo == true {
                    Text(StoreLanguage.isEnglish ? "SAMPLE" : "تجريبي")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 21)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .padding(7)
                }
            }

            Text(product.shownTitle)
                .font(AppFont.bold(14))
                .foregroundStyle(StoreTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(product.shownSubtitle)
                .font(AppFont.regular(11))
                .foregroundStyle(StoreTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StoreTheme.accent)
                Spacer()
                Text(product.priceLabel)
                    .font(AppFont.black(13))
                    .foregroundStyle(StoreTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            if !product.available {
                Text(StoreLanguage.isEnglish ? "Unavailable" : "غير متوفر")
                    .font(AppFont.medium(10))
                    .foregroundStyle(.red)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .background(StoreTheme.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.11), lineWidth: 0.7))
        .shadow(color: product.colorA.opacity(0.13), radius: 9, y: 4)
    }
}

private extension GiftProduct {
    var priceLabel: String {
        if price == 0 { return StoreLanguage.isEnglish ? "Ask for price" : "السعر عند الطلب" }
        return "\(price.formatted()) \(currency)"
    }
}

struct GiftProductDetailView: View {
    let product: GiftProduct
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(LinearGradient(colors: [product.colorA, product.colorB],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle()
                        .fill(.white.opacity(0.17))
                        .frame(width: 185, height: 185)
                        .blur(radius: 25)
                        .offset(x: -94, y: -85)
                    if let image = product.image, !image.isEmpty {
                        RemoteImage(path: image, cornerRadius: 21, systemFallback: product.icon)
                            .padding(10)
                    } else {
                        Image(systemName: product.icon)
                            .font(.system(size: 86, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.19), radius: 18, y: 5)
                    }
                }
                .frame(height: 235)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                VStack(alignment: .trailing, spacing: 10) {
                    Text(product.shownCategory)
                        .font(AppFont.medium(12))
                        .foregroundStyle(StoreTheme.accent)
                    Text(product.shownTitle)
                        .font(AppFont.black(24))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(product.shownSubtitle)
                        .font(AppFont.medium(13))
                        .foregroundStyle(StoreTheme.textSecondary)
                    HStack {
                        if let old = product.compareAtPrice, old > product.price {
                            Text("\(old.formatted()) \(product.currency)")
                                .font(AppFont.medium(12))
                                .strikethrough()
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        Spacer()
                        Text(product.priceLabel)
                            .font(AppFont.black(22))
                            .foregroundStyle(StoreTheme.accent)
                    }
                }

                VStack(alignment: .trailing, spacing: 12) {
                    Text(StoreLanguage.isEnglish ? "Description" : "تفاصيل المنتج")
                        .font(AppFont.black(18))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text(product.shownDescription)
                        .font(AppFont.regular(13))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                if !product.shownFeatures.isEmpty {
                    VStack(alignment: .trailing, spacing: 13) {
                        Text(StoreLanguage.isEnglish ? "Features" : "المميزات")
                            .font(AppFont.black(18))
                            .foregroundStyle(StoreTheme.textPrimary)
                        ForEach(product.shownFeatures, id: \.self) { feature in
                            HStack(alignment: .top, spacing: 9) {
                                Spacer(minLength: 2)
                                Text(feature)
                                    .font(AppFont.medium(12))
                                    .foregroundStyle(StoreTheme.textPrimary)
                                    .multilineTextAlignment(.trailing)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(15)
                    .background(StoreTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                }

                if product.demo == true {
                    Label(
                        StoreLanguage.isEnglish ?
                            "Demo listing — confirm the offer and final price with support before paying." :
                            "هذا عرض تجريبي. تأكد من التوفر والسعر النهائي قبل الدفع.",
                        systemImage: "info.circle"
                    )
                    .font(AppFont.medium(11))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Button(action: openTelegramPurchase) {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill")
                        Text(StoreLanguage.isEnglish ? "Buy via Telegram" : "شراء")
                            .font(AppFont.black(17))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(
                        LinearGradient(colors: [StoreTheme.accent, product.colorB],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 19)
                    )
                    .shadow(color: StoreTheme.accent.opacity(0.30), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                .disabled(!product.available)
                .opacity(product.available ? 1 : 0.5)

                Text(StoreLanguage.isEnglish ?
                     "Telegram opens with your message ready. You decide whether to send it." :
                     "راح تفتح محادثة Telegram والرسالة جاهزة، وإنت تقرر ترسلها.")
                    .font(AppFont.medium(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(17)
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .navigationTitle(product.shownTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func openTelegramPurchase() {
        // Deliberately ignore the remote purchaseUrl. The user requested a
        // fixed recipient, and URLComponents safely encodes Arabic and newlines.
        let draft = "السلام عليكم\nاريد شراء المنتج \(product.title)\nممكن تفاصيل."
        var url = URLComponents()
        url.scheme = "https"
        url.host = "t.me"
        url.path = "/iKira18"
        url.queryItems = [URLQueryItem(name: "text", value: draft)]
        if let destination = url.url {
            openURL(destination)
        }
    }
}
