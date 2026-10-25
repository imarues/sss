import SwiftUI

/// Description text comes from the matching app ID in freeapps/IPA-AR.json
/// and freeapps/IPA-EN.json. No Apple Translation language downloads.
struct AppNotesTranslationSection: View {
    let appID: String
    let originalText: String
    let heading: String

    @AppStorage("store.language") private var language = "ar"

    @State private var showOppositeLanguage = false
    @State private var englishDescription: String?
    @State private var arabicDescription: String?
    @State private var englishLoading = true
    @State private var englishFailed = false

    private var interfaceIsEnglish: Bool { language == "en" }
    private var displayEnglish: Bool { interfaceIsEnglish != showOppositeLanguage }
    private var displayedArabic: String {
        let candidate = arabicDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate?.isEmpty == false ? candidate! : originalText
    }

    private var translationButtonTitle: String {
        if interfaceIsEnglish {
            return displayEnglish ? "ترجمة • عربية" : "English • EN"
        }
        return displayEnglish ? "العربي الأصلي" : "Translate • EN"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    showOppositeLanguage.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 12, weight: .semibold))
                        Text(translationButtonTitle)
                            .font(AppFont.bold(11.5))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(StoreTheme.accent)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(StoreTheme.accent.opacity(0.11), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(StoreTheme.accent.opacity(0.25), lineWidth: 0.8)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(StoreGlassPressStyle())
                .accessibilityIdentifier("description.translation.toggle")

                Spacer(minLength: 8)

                Text(StoreLanguage.localized(heading))
                    .font(AppFont.black(20))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .environment(\.layoutDirection, .leftToRight)

            if displayEnglish {
                englishTextView
            } else {
                RTLDescriptionText(text: displayedArabic, fontSize: 14, lineSpacing: 9)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .task(id: appID) {
            englishDescription = nil
            arabicDescription = nil
            englishLoading = true
            englishFailed = false

            // Fetch both JSON indexes in parallel, once per cache interval.
            // The source AR notes remain readable while either index downloads.
            async let fetchedEnglish = AppNotesJSONCatalog.shared.description(
                appID: appID, language: .english
            )
            async let fetchedArabic = AppNotesJSONCatalog.shared.description(
                appID: appID, language: .arabic
            )

            let en = try? await fetchedEnglish
            guard !Task.isCancelled else { return }
            let cleanedEnglish = en?.trimmingCharacters(in: .whitespacesAndNewlines)
            englishDescription = cleanedEnglish?.isEmpty == false ? cleanedEnglish : nil
            englishFailed = englishDescription == nil
            englishLoading = false

            let ar = try? await fetchedArabic
            guard !Task.isCancelled else { return }
            let cleanedArabic = ar?.trimmingCharacters(in: .whitespacesAndNewlines)
            arabicDescription = cleanedArabic?.isEmpty == false ? cleanedArabic : nil
        }
        .onChange(of: language) { _ in
            // The default visible language always tracks the app's setting.
            showOppositeLanguage = false
        }
    }

    @ViewBuilder
    private var englishTextView: some View {
        if let text = englishDescription, !text.isEmpty {
            Text(text)
                .font(AppFont.regular(14))
                .foregroundStyle(StoreTheme.textSecondary)
                .lineSpacing(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .leftToRight)
                .textSelection(.enabled)
        } else if englishLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(StoreTheme.accent)
                    .scaleEffect(0.8)
                Text("Loading English description…")
                    .font(AppFont.medium(12))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
        } else if englishFailed {
            Text(interfaceIsEnglish
                 ? "English description unavailable. Tap ترجمة • عربية to view the original."
                 : "الوصف الإنكليزي غير متوفر حالياً. اضغط العربي الأصلي للرجوع.")
                .font(AppFont.medium(12))
                .foregroundStyle(StoreTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
