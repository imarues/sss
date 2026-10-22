import SwiftUI

struct ActiveTransfersInlineView: View {
    @ObservedObject private var installer = StoreInstallCoordinator.shared
    @ObservedObject private var detailCenter = DetailPreparationCenter.shared
    @ObservedObject private var transfers = TransferActivityCenter.shared

    private var installOperations: [TransferInstallSnapshot] {
        transfers.activeInstallOperations(using: installer)
    }

    private var detailApp: StoreApp? {
        transfers.trackedApp(id: detailCenter.activeAppID)
    }

    var activeCount: Int {
        transfers.activeCount(using: installer, detail: detailCenter)
    }

    var body: some View {
        if activeCount > 0 {
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 7) {
                    Text("العمليات الجارية")
                        .font(AppFont.black(16))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                ForEach(transfers.activeDirectOperations) { operation in
                    transferRow(
                        app: operation.app,
                        kind: "تحميل ديلب",
                        progress: operation.progress,
                        status: operation.statusText,
                        accent: DownloadAssetTheme.gold
                    )
                }

                if detailCenter.busy {
                    if let app = detailApp {
                        transferRow(
                            app: app,
                            kind: detailCenter.activeKind == .duplicate ? "تكرار التطبيق" : "دمج ديلب مع التطبيق",
                            progress: detailCenter.progress,
                            status: detailCenter.statusText.isEmpty ? "جاري التجهيز" : detailCenter.statusText,
                            accent: detailCenter.activeKind == .duplicate ? StoreTheme.accent : Color(red: 0.04, green: 0.65, blue: 0.59)
                        )
                    } else {
                        genericDetailRow
                    }
                }

                ForEach(installOperations) { operation in
                    transferRow(
                        app: operation.app,
                        kind: installKind(operation.state.phase),
                        progress: normalizedInstallProgress(operation.state),
                        status: operation.state.message ?? installKind(operation.state.phase),
                        accent: StoreTheme.accent
                    )
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    private func transferRow(
        app: StoreApp,
        kind: String,
        progress: Double,
        status: String,
        accent: Color
    ) -> some View {
        let value = max(0, min(1, progress))
        return VStack(spacing: 10) {
            HStack(spacing: 11) {
                AppIconView(app: app, size: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(AppFont.black(13.5))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(kind)
                        .font(AppFont.bold(10))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(status.storeForcedRTL)
                        .font(AppFont.regular(10))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("\(Int(value * 100))%")
                    .font(AppFont.black(17))
                    .foregroundStyle(accent)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(StoreTheme.field)
                    Capsule().fill(accent)
                        .frame(width: max(5, proxy.size.width * value))
                }
            }
            .frame(height: 8)
        }
        .padding(13)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(accent.opacity(0.38), lineWidth: 0.8)
        }
    }

    private var genericDetailRow: some View {
        let value = max(0, min(1, detailCenter.progress))
        return VStack(spacing: 10) {
            HStack {
                Text(detailCenter.activeKind == .duplicate ? "تكرار التطبيق" : "دمج ديلب مع التطبيق")
                    .font(AppFont.black(13))
                    .foregroundStyle(StoreTheme.textPrimary)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(AppFont.black(17))
                    .foregroundStyle(StoreTheme.accent)
            }
            ProgressView(value: value)
                .tint(StoreTheme.accent)
        }
        .padding(13)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
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
}
