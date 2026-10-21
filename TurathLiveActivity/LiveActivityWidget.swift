import ActivityKit
import WidgetKit
import SwiftUI

@main
struct TurathLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TurathInstallLiveActivity()
    }
}

struct TurathInstallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InstallActivityAttributes.self) { context in
            HStack(spacing: 12) {
                phaseIcon(context.state.phase)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.appName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(stageTitle(context.state.phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: max(0, min(1, context.state.progress)))
                        .tint(.accentColor)
                }

                Text(percent(context.state.progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    phaseIcon(context.state.phase)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state.progress))
                        .font(.caption.bold().monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.attributes.appName)
                            .font(.caption.bold())
                            .lineLimit(1)
                        HStack {
                            Text(stageTitle(context.state.phase))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let speed = context.state.speed, context.state.phase == .downloading {
                                Text(speed)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: max(0, min(1, context.state.progress)))
                            .tint(.accentColor)
                    }
                }
            } compactLeading: {
                Image(systemName: compactIcon(context.state.phase))
                    .foregroundStyle(compactColor(context.state.phase))
            } compactTrailing: {
                Text(percent(context.state.progress))
                    .font(.caption2.bold().monospacedDigit())
            } minimal: {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, context.state.progress)))
                        .stroke(compactColor(context.state.phase), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: compactIcon(context.state.phase))
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(2)
            }
            .keylineTint(.accentColor)
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: InstallActivityAttributes.Phase) -> some View {
        ZStack {
            Circle().fill(compactColor(phase).opacity(0.18))
            Image(systemName: compactIcon(phase))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(compactColor(phase))
        }
    }

    private func compactIcon(_ phase: InstallActivityAttributes.Phase) -> String {
        switch phase {
        case .downloading: return "arrow.down"
        case .signing: return "signature"
        case .installing: return "square.and.arrow.down"
        case .complete: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private func compactColor(_ phase: InstallActivityAttributes.Phase) -> Color {
        switch phase {
        case .complete: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    private func stageTitle(_ phase: InstallActivityAttributes.Phase) -> String {
        switch phase {
        case .downloading: return "جاري تحميل التطبيق"
        case .signing: return "جاري توقيع التطبيق"
        case .installing: return "جاري تجهيز التثبيت"
        case .complete: return "جاهز للتثبيت"
        case .failed: return "تعذر إكمال العملية"
        }
    }

    private func percent(_ progress: Double) -> String {
        "\(Int(max(0, min(1, progress)) * 100))%"
    }
}
