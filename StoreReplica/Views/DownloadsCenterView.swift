import SwiftUI

struct DownloadsCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var installer = StoreInstallCoordinator.shared
    @ObservedObject private var detailCenter = DetailPreparationCenter.shared
    @ObservedObject private var transfers = TransferActivityCenter.shared

    @State private var libraryItems: [SideloadLibraryItem] = []
    @State private var directDownloads: [DirectDownloadItem] = []

    private var installOperations: [TransferInstallSnapshot] {
        transfers.activeInstallOperations(using: installer)
    }

    private var activeCount: Int {
        transfers.activeCount(using: installer, detail: detailCenter)
    }

    private var detailApp: StoreApp? {
        transfers.trackedApp(id: detailCenter.activeAppID)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header

                    if activeCount > 0 {
                        activeSection
                    }

                    completedSection
                    Color.clear.frame(height: 26)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                        .font(AppFont.bold(13))
                        .foregroundStyle(StoreTheme.accent)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear {
            TransferActivityCenter.shared.bootstrap()
            refreshLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: DirectDownloadLibrary.changedNotification)) { _ in
            refreshLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: DetailPreparationCenter.completedNotification)) { _ in
            refreshLibrary()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(AppFont.black(12))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(Color.red)
                    .clipShape(Capsule())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("تنزيلاتي")
                    .font(AppFont.black(27))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text(activeCount > 0 ? "تابع كل عمليات التحميل والتجهيز من مكان واحد" : "التطبيقات وملفات الديلب المحمّلة")
                    .font(AppFont.regular(11.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var activeSection: some View {
        VStack(alignment: .trailing, spacing: 11) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("العمليات الجارية")
                    .font(AppFont.black(18))
                    .foregroundStyle(StoreTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            ForEach(transfers.activeDirectOperations) { operation in
                activeRow(
                    app: operation.app,
                    kind: "تحميل ديلب",
                    progress: operation.progress,
                    status: operation.statusText,
                    accent: DownloadAssetTheme.gold,
                    bytesText: bytesText(written: operation.writtenBytes, expected: operation.expectedBytes)
                )
            }

            if detailCenter.busy, let app = detailApp {
                activeRow(
                    app: app,
                    kind: detailCenter.activeKind == .duplicate ? "تكرار التطبيق" : "دمج ديلب مع التطبيق",
                    progress: detailCenter.progress,
                    status: detailCenter.statusText.isEmpty ? "جاري التجهيز" : detailCenter.statusText,
                    accent: detailCenter.activeKind == .duplicate ? StoreTheme.accent : Color(red: 0.04, green: 0.65, blue: 0.59),
                    bytesText: nil
                )
            }

            ForEach(installOperations) { operation in
                activeRow(
                    app: operation.app,
                    kind: installKind(operation.state.phase),
                    progress: normalizedInstallProgress(operation.state),
                    status: operation.state.message ?? installKind(operation.state.phase),
                    accent: StoreTheme.accent,
                    bytesText: operation.state.speedText
                )
            }
        }
    }

    private func activeRow(
        app: StoreApp,
        kind: String,
        progress: Double,
        status: String,
        accent: Color,
        bytesText: String?
    ) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AppIconView(app: app, size: 58)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(app.name)
                        .font(AppFont.black(14))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .lineLimit(1)
                    Text(kind)
                        .font(AppFont.bold(10.5))
                        .foregroundStyle(accent)
                    Text(status.storeForcedRTL)
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                VStack(spacing: 3) {
                    Text("\(Int(max(0, min(1, progress)) * 100))%")
                        .font(AppFont.black(18))
                        .foregroundStyle(accent)
                    if let bytesText, !bytesText.isEmpty {
                        Text(bytesText)
                            .font(AppFont.regular(8.5))
                            .foregroundStyle(StoreTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(StoreTheme.field)
                    Capsule().fill(accent)
                        .frame(width: max(5, proxy.size.width * max(0, min(1, progress))))
                }
            }
            .frame(height: 9)
        }
        .padding(14)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(accent.opacity(0.42), lineWidth: 0.9)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var completedSection: some View {
        VStack(alignment: .trailing, spacing: 11) {
            HStack {
                Button { refreshLibrary() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(StoreTheme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("المكتملة")
                    .font(AppFont.black(18))
                    .foregroundStyle(StoreTheme.textPrimary)
            }

            if libraryItems.isEmpty && directDownloads.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: activeCount > 0 ? "arrow.down.circle" : "square.stack.3d.up.slash")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(StoreTheme.textSecondary)
                    Text(activeCount > 0 ? "التحميلات المكتملة راح تظهر هنا" : "ماكو تنزيلات محفوظة بعد")
                        .font(AppFont.bold(13))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("أي IPA أو dylib أو zip يكتمل تحميله يظهر هنا تلقائياً.".storeForcedRTL)
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(StoreTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(directDownloads) { item in
                        directDownloadRow(item)
                    }
                    ForEach(libraryItems) { item in
                        libraryRow(item)
                    }
                }
            }
        }
    }

    private func directDownloadRow(_ item: DirectDownloadItem) -> some View {
        HStack(spacing: 11) {
            remoteIcon(url: item.iconURL, size: 58, gold: true)

            VStack(alignment: .trailing, spacing: 5) {
                Text(item.name)
                    .font(AppFont.black(14))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .lineLimit(1)
                Text("v\(item.version) • \(formatBytes(item.size))")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                Text("ملف ديلب")
                    .font(AppFont.medium(9.5))
                    .foregroundStyle(DownloadAssetTheme.gold)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            ShareLink(item: item.fileURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 38, height: 38)
                    .background(DownloadAssetTheme.gold)
                    .clipShape(Circle())
            }
        }
        .padding(13)
        .background(DownloadAssetTheme.goldSoft.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DownloadAssetTheme.gold.opacity(0.78), lineWidth: 1)
        }
    }

    private func libraryRow(_ item: SideloadLibraryItem) -> some View {
        HStack(spacing: 11) {
            localIcon(url: item.iconURL, size: 58)

            VStack(alignment: .trailing, spacing: 5) {
                Text(item.name)
                    .font(AppFont.black(14))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .lineLimit(1)
                Text("v\(item.version) • \(formatBytes(item.size))")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                Text(item.source == .link ? "عبر رابط" : "من التحديثات")
                    .font(AppFont.medium(9.5))
                    .foregroundStyle(item.source == .link ? StoreTheme.accent : StoreTheme.badgeUpdated)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(spacing: 7) {
                InstallPill(title: "تثبيت", app: item.storeApp)
                ShareLink(item: item.ipaURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(StoreTheme.accent)
                }
            }
        }
        .padding(13)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StoreTheme.surfaceBorder.opacity(0.70), lineWidth: 0.8)
        }
    }

    private func refreshLibrary() {
        DispatchQueue.global(qos: .utility).async {
            let items = SideloadLibraryStore.items()
            DispatchQueue.main.async { self.libraryItems = items }
        }
        Task {
            let direct = await DirectDownloadLibrary.shared.items()
            await MainActor.run { self.directDownloads = direct }
        }
    }

    private func normalizedInstallProgress(_ state: StoreInstallState) -> Double {
        switch state.phase {
        case .downloading:
            return state.progress > 0 ? min(1, state.progress / 0.90) : 0
        case .signing:
            return max(0.72, state.progress)
        case .installing:
            return max(0.95, state.progress)
        case .ready, .complete:
            return 1
        case .idle, .failed:
            return 0
        }
    }

    private func installKind(_ phase: StoreInstallPhase) -> String {
        switch phase {
        case .downloading: return "تحميل التطبيق"
        case .signing: return "توقيع التطبيق"
        case .installing: return "تثبيت التطبيق"
        case .ready: return "جاهز"
        case .complete: return "مكتمل"
        case .idle: return "انتظار"
        case .failed: return "فشل"
        }
    }

    private func bytesText(written: Int64, expected: Int64) -> String? {
        guard written > 0 else { return nil }
        if expected > 0 {
            return "\(formatBytes(written)) / \(formatBytes(expected))"
        }
        return formatBytes(written)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        bytes > 0 ? StoreDisplayFormat.bytes(bytes) : "—"
    }

    private func localIcon(url: URL?, size: CGFloat) -> some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
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
    }

    private func remoteIcon(url: URL?, size: CGFloat, gold: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(gold ? DownloadAssetTheme.gold.opacity(0.16) : StoreTheme.field)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(gold ? DownloadAssetTheme.gold : StoreTheme.accent)
                    } else {
                        ProgressView().tint(gold ? DownloadAssetTheme.gold : StoreTheme.accent)
                    }
                }
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(gold ? DownloadAssetTheme.gold : StoreTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
