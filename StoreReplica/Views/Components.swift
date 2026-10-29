import SwiftUI
import UIKit
import Foundation
import CoreText
import UniformTypeIdentifiers

struct RemoteImage: View {
    let path: String?
    var cornerRadius: CGFloat = 16
    var systemFallback: String = "square.stack.3d.up.fill"

    var body: some View {
        Group {
            if let url = StoreAPI.shared.absoluteURL(path) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if phase.error != nil { fallback }
                    // Dozens of spinning placeholders caused constant invalidations
                    // in big Explore/Home lists. Use a static glass placeholder.
                    else { fallback.opacity(0.75) }
                }
            } else { fallback }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [StoreTheme.field, StoreTheme.surfaceBorder], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: systemFallback).font(.system(size: 23, weight: .semibold)).foregroundStyle(StoreTheme.accent)
        }
    }
}

struct InstallPill: View {
    var title = "تثبيت"
    var app: StoreApp? = nil
    var action: () -> Void = {}

    private let installer = StoreInstallCoordinator.shared
    @State private var observedState = StoreInstallState()
    @State private var installErrorMessage: String?

    private var installState: StoreInstallState {
        guard app != nil else { return StoreInstallState() }
        return observedState
    }

    private var displayTitle: String {
        switch installState.phase {
        case .idle: return title
        case .downloading:
            if installState.progress > 0 {
                return "\(Int((installState.progress / 0.90) * 100))%"
            }
            return "تحميل"
        case .ready: return "جاهز"
        case .signing: return "توقيع"
        case .installing: return "تثبيت"
        case .complete: return "جاهز"
        case .failed: return title
        }
    }

    private var pillColor: Color {
        if installState.phase == .ready || installState.phase == .complete {
            return .green
        }
        return StoreTheme.accent
    }

    var body: some View {
        Button {
            if let app {
                TransferActivityCenter.shared.track(app)
                if SigningAssetProvider.hasCredentials {
                    installer.start(app)
                } else {
                    SigningSetupCoordinator.shared.request(for: app)
                }
            } else {
                action()
            }
        } label: {
            HStack(spacing: 6) {
                if installState.phase == .downloading || installState.phase == .signing || installState.phase == .installing {
                    ProgressView()
                        .tint(StoreTheme.onAccent)
                        .scaleEffect(0.72)
                } else if installState.phase == .ready || installState.phase == .complete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(StoreTheme.onAccent)
                }
                Text(StoreLanguage.localized(displayTitle))
                    .font(AppFont.bold(13))
                    .foregroundStyle(StoreTheme.onAccent)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 62)
            .frame(height: 32)
            .background(pillColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(app != nil && [.downloading, .signing, .installing].contains(installState.phase))
        .opacity(app != nil && installState.phase == .failed ? 0.9 : 1)
        .onAppear {
            if let app { observedState = installer.state(for: app) }
        }
        .onChange(of: app?.id) { _ in
            if let app { observedState = installer.state(for: app) }
        }
        .onReceive(NotificationCenter.default.publisher(for: StoreInstallCoordinator.stateDidChange)) { note in
            guard let app, note.userInfo?["appID"] as? String == app.id,
                  let value = note.userInfo?["state"] as? StoreInstallState else { return }
            if observedState != value { observedState = value }
        }
        .onChange(of: installState) { newState in
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

struct SigningSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var p12URL: URL?
    @State private var profileURL: URL?
    @State private var password = ""
    @State private var pickingP12 = false
    @State private var pickingProvision = false
    @State private var errorMessage: String?
    @State private var working = false

    let onReady: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .trailing, spacing: 14) {
                    Text("إعداد شهادة التوقيع")
                        .font(AppFont.black(22))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Text("اختر شهادة .p12 وملف .mobileprovision ثم اكتب كلمة المرور. يتم فحص الثلاثة معًا وحفظ نسخة داخل التطبيق مثل BatSign.".storeForcedRTL)
                        .font(AppFont.regular(12))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    setupFileButton(
                        title: p12URL?.lastPathComponent ?? "اختيار شهادة .p12",
                        icon: p12URL == nil ? "key.fill" : "checkmark.circle.fill"
                    ) {
                        pickingP12 = true
                    }

                    setupFileButton(
                        title: profileURL?.lastPathComponent ?? "اختيار شهادة .mobileprovision",
                        icon: profileURL == nil ? "doc.badge.gearshape" : "checkmark.circle.fill"
                    ) {
                        pickingProvision = true
                    }

                    StablePasswordField(text: $password, placeholder: "كلمة مرور P12")
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .background(StoreTheme.field)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if let errorMessage {
                        Text(errorMessage.storeForcedRTL)
                            .font(AppFont.regular(11))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }

                    Button {
                        importNow()
                    } label: {
                        HStack(spacing: 8) {
                            if working {
                                ProgressView()
                                    .tint(StoreTheme.onAccent)
                            }
                            Text(working ? "جاري فحص الشهادة..." : "فحص الشهادة وحفظها")
                                .font(AppFont.bold(14))
                                .foregroundStyle(StoreTheme.onAccent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(StoreTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(p12URL == nil || profileURL == nil || password.isEmpty || working)
                    .opacity((p12URL != nil && profileURL != nil && !password.isEmpty && !working) ? 1 : 0.55)

                    Spacer(minLength: 260)
                }
                .padding(18)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $pickingP12) {
            SigningFilePicker(allowedContentTypes: [.signingP12]) { urls in
                pickingP12 = false
                guard let url = urls.first else { return }
                guard url.pathExtension.lowercased() == "p12" else {
                    errorMessage = SigningAssetError.wrongP12Extension.localizedDescription
                    return
                }
                p12URL = url
                errorMessage = nil
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $pickingProvision) {
            SigningFilePicker(allowedContentTypes: [.signingMobileProvision]) { urls in
                pickingProvision = false
                guard let url = urls.first else { return }
                guard url.pathExtension.lowercased() == "mobileprovision" else {
                    errorMessage = SigningAssetError.wrongProvisionExtension.localizedDescription
                    return
                }
                profileURL = url
                errorMessage = nil
            }
            .ignoresSafeArea()
        }
    }

    private func importNow() {
        guard let p12URL, let profileURL else { return }
        working = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SigningAssetProvider.importCertificate(
                    p12URL: p12URL,
                    profileURL: profileURL,
                    password: password
                )
                DispatchQueue.main.async {
                    working = false
                    onReady()
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func setupFileButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(StoreTheme.accent)
                Spacer()
                Text(title)
                    .font(AppFont.medium(13))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(StoreTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(StoreTheme.surfaceBorder, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SectionTitle: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(StoreLanguage.localized(title).storeForcedRTL)
                .font(AppFont.black(20))
                .foregroundStyle(StoreTheme.textPrimary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, StoreTheme.pageHorizontal)
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }
}

struct AppIconView: View {
    let app: StoreApp
    var size: CGFloat = 64
    var body: some View {
        RemoteImage(path: app.iconUrl, cornerRadius: size * 0.23)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.06),
                                 StoreTheme.accent.opacity(0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}

/// Prefer IPA-extracted artwork, then the saved IPA-AR source icon.
/// Works for older downloads without a sideload-meta.json icon sidecar.
struct SideloadLibraryIcon: View {
    let item: SideloadLibraryItem
    let trackedApp: StoreApp?
    var size: CGFloat = 58

    var body: some View {
        Group {
            if let url = item.iconURL,
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let app = trackedApp,
                      let remote = app.iconUrl, !remote.isEmpty {
                RemoteImage(path: remote, cornerRadius: size * 0.22)
            } else {
                ZStack {
                    StoreTheme.field
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(StoreTheme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.8)
        }
    }
}

struct BandCard: View {
    let app: StoreApp
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(app: app, size: 58)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(app.name.storeForcedRTL).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(2).frame(maxWidth: .infinity, alignment: .trailing)
                    Text((app.categories?.first ?? "تطبيق").storeForcedRTL).font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
                }
                InstallPill(app: app)
            }
            if let notes = app.notes, !notes.isEmpty {
                Text(notes.replacingOccurrences(of: "\n", with: " ").storeForcedRTL)
                    .font(AppFont.regular(11.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .padding(14).frame(width: 310, height: 126, alignment: .top).storeCard(radius: 19)
    }
}

struct ShowcaseCard: View {
    let app: StoreApp
    var body: some View {
        VStack(spacing: 14) {
            AppIconView(app: app, size: 76)
            VStack(spacing: 4) {
                Text(app.name.storeForcedRTL).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                Text(StoreLanguage.localized("الإصدار") + " " + (app.version.map(StoreDisplayFormat.digits) ?? "—")).font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary)
            }
            InstallPill(app: app)
        }
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .padding(16).frame(width: 168, height: 192).storeCard(radius: 22)
    }
}

struct LargeListRow: View {
    let app: StoreApp
    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 62)
            VStack(alignment: .trailing, spacing: 5) {
                Text(app.name.storeForcedRTL).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                Text((app.notes ?? "الإصدار \(app.version.map(StoreDisplayFormat.digits) ?? "—")").storeForcedRTL)
                    .font(AppFont.regular(11.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(maxWidth: .infinity, alignment: .trailing)
            InstallPill(app: app)
        }
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .padding(.vertical, 10)
    }
}

struct CategoryStripCard: View {
    let category: StoreCategory
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StoreTheme.field)
                Text(category.emoji ?? "•").font(.system(size: 20, weight: .semibold)).foregroundStyle(StoreTheme.accent)
            }.frame(width: 43, height: 43)
            VStack(alignment: .trailing, spacing: 2) {
                Text(category.name.storeForcedRTL).font(AppFont.bold(13)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                if let count = category.count { Text(StoreLanguage.isEnglish ? "\(count) apps" : "\(count) تطبيق").font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }
            }
        }
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .padding(.horizontal, 12).frame(height: 65).storeCard(radius: 17)
    }
}

struct CategoryGridTile: View {
    let category: StoreCategory
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Spacer()
                ZStack {
                    Circle().fill(StoreTheme.accent.opacity(0.13))
                    Text(category.emoji ?? "•").font(.system(size: 24, weight: .bold)).foregroundStyle(StoreTheme.accent)
                }.frame(width: 50, height: 50)
            }
            Spacer(minLength: 2)
            Text(category.name.storeForcedRTL).font(AppFont.bold(14)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
            if let count = category.count { Text(StoreLanguage.isEnglish ? "\(count) apps" : "\(count) تطبيق").font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }
        }
        .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .padding(14).frame(height: 132).storeCard(radius: 20)
    }
}

// Favorites are device-local; no account or server is required.
struct StoreFavoriteButton: View {
    let app: StoreApp
    @AppStorage("store.favoriteIDs") private var favoriteIDs = ""
    @AppStorage("store.favoriteAppsJSON") private var favoriteAppsJSON = ""
    @State private var showLimit = false

    private var ids: [String] { favoriteIDs.split(separator: "\n").map(String.init) }
    private var isFavorite: Bool { ids.contains(app.id) }

    var body: some View {
        Button {
            var current = ids
            var saved: [StoreApp] = favoriteAppsJSON.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([StoreApp].self, from: $0) } ?? []
            if isFavorite {
                current.removeAll { $0 == app.id }
                saved.removeAll { $0.id == app.id }
            } else {
                guard current.count < 25 else {
                    showLimit = true
                    return
                }
                current.append(app.id)
                saved.removeAll { $0.id == app.id }
                saved.append(app)
            }
            if let data = try? JSONEncoder().encode(saved),
               let json = String(data: data, encoding: .utf8) {
                favoriteAppsJSON = json
            }
            favoriteIDs = current.joined(separator: "\n")
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.red.opacity(isFavorite ? 1 : 0.82))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(StoreLanguage.localized(isFavorite ? "إزالة من المفضلة" : "إضافة إلى المفضلة"))
        .alert("المفضلة", isPresented: $showLimit) {
            Button("حسنًا", role: .cancel) { }
        } message: {
            Text("الحد الأقصى 25 تطبيقاً أو لعبة.")
        }
    }
}
