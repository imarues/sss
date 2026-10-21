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
                    else { ZStack { StoreTheme.field; ProgressView().tint(StoreTheme.accent) } }
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

    @ObservedObject private var installer = StoreInstallCoordinator.shared
    @State private var showSigningSetup = false

    private var installState: StoreInstallState {
        guard let app else { return StoreInstallState() }
        return installer.state(for: app.id)
    }

    private var displayTitle: String {
        switch installState.phase {
        case .idle: return title
        case .downloading:
            if installState.progress > 0 {
                return "\(Int((installState.progress / 0.90) * 100))%"
            }
            return "تحميل"
        case .signing: return "توقيع"
        case .installing: return "تثبيت"
        case .complete: return "جاهز"
        case .failed: return title
        }
    }

    var body: some View {
        Button {
            if let app {
                if app.effectiveDownloadURL == nil || SigningAssetProvider.hasCredentials {
                    installer.start(app)
                } else {
                    showSigningSetup = true
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
                }
                Text(displayTitle)
                    .font(AppFont.bold(13))
                    .foregroundStyle(StoreTheme.onAccent)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 62, height: 32)
            .background(StoreTheme.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(app != nil && [.downloading, .signing, .installing].contains(installState.phase))
        .opacity(app != nil && installState.phase == .failed ? 0.9 : 1)
        .sheet(isPresented: $showSigningSetup) {
            SigningSetupSheet {
                showSigningSetup = false
                if let app {
                    installer.start(app)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct SigningSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pickingP12 = false
    @State private var pickingProvision = false
    @State private var hasP12 = false
    @State private var hasProvision = false
    @State private var password = ""
    @State private var errorMessage: String?

    let onReady: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .trailing, spacing: 14) {
                Text("إعداد شهادة التوقيع")
                    .font(AppFont.black(22))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Text("تُضاف الشهادة مرة واحدة فقط. بعدها يصير التحميل والتوقيع والتثبيت تلقائيًا مثل BatSign.")
                    .font(AppFont.regular(12))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .multilineTextAlignment(.trailing)

                setupFileButton(
                    title: hasP12 ? "تمت إضافة P12" : "اختيار ملف P12",
                    icon: hasP12 ? "checkmark.circle.fill" : "key.fill"
                ) { pickingP12 = true }

                setupFileButton(
                    title: hasProvision ? "تمت إضافة MobileProvision" : "اختيار MobileProvision",
                    icon: hasProvision ? "checkmark.circle.fill" : "doc.badge.gearshape"
                ) { pickingProvision = true }

                SecureField("كلمة مرور P12", text: $password)
                    .textContentType(.password)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(StoreTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppFont.regular(11))
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Button {
                    do {
                        try SigningAssetProvider.savePassword(password)
                        guard SigningAssetProvider.hasCredentials else {
                            errorMessage = "أضف ملف P12 وMobileProvision أولًا."
                            return
                        }
                        onReady()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Text("حفظ وبدء التثبيت")
                        .font(AppFont.bold(14))
                        .foregroundStyle(StoreTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(StoreTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!hasP12 || !hasProvision)
                .opacity((hasP12 && hasProvision) ? 1 : 0.55)

                Spacer(minLength: 0)
            }
            .padding(18)
            .background(StoreTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $pickingP12, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                try SigningAssetProvider.importP12(from: url)
                hasP12 = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $pickingProvision, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                try SigningAssetProvider.importProvision(from: url)
                hasProvision = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            hasP12 = SigningAssetProvider.hasP12File
            hasProvision = SigningAssetProvider.hasProvisionFile
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
            Text(title).font(AppFont.black(20)).foregroundStyle(StoreTheme.textPrimary)
            Spacer(minLength: 8)
        }.padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct AppIconView: View {
    let app: StoreApp
    var size: CGFloat = 64
    var body: some View {
        RemoteImage(path: app.iconUrl, cornerRadius: size * 0.23)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.23).stroke(Color.white.opacity(0.08), lineWidth: 0.7))
    }
}

struct BandCard: View {
    let app: StoreApp
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(app: app, size: 58)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(app.name).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(2).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(app.categories?.first ?? "تطبيق").font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary).lineLimit(1)
                }
                InstallPill(app: app)
            }
            if let notes = app.notes, !notes.isEmpty {
                Text(notes.replacingOccurrences(of: "\n", with: " "))
                    .font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary).lineLimit(2)
            }
        }
        .padding(14).frame(width: 310, height: 126, alignment: .top).storeCard(radius: 19)
    }
}

struct ShowcaseCard: View {
    let app: StoreApp
    var body: some View {
        VStack(spacing: 14) {
            AppIconView(app: app, size: 76)
            VStack(spacing: 4) {
                Text(app.name).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                Text("الإصدار \(app.version ?? "—")").font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary)
            }
            InstallPill(app: app)
        }
        .padding(16).frame(width: 168, height: 192).storeCard(radius: 22)
    }
}

struct LargeListRow: View {
    let app: StoreApp
    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 62)
            VStack(alignment: .trailing, spacing: 5) {
                Text(app.name).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                Text(app.notes ?? "الإصدار \(app.version ?? "—")").font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .trailing)
            InstallPill(app: app)
        }.padding(.vertical, 10)
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
                Text(category.name).font(AppFont.bold(13)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                if let count = category.count { Text("\(count) تطبيق").font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }
            }
        }.padding(.horizontal, 12).frame(height: 65).storeCard(radius: 17)
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
            Text(category.name).font(AppFont.bold(14)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
            if let count = category.count { Text("\(count) تطبيق").font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }
        }.padding(14).frame(height: 132).storeCard(radius: 20)
    }
}
