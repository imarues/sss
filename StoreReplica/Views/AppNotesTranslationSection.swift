import SwiftUI
import Foundation
#if canImport(Translation)
import Translation
#endif

/// IPA-AR provides Arabic notes. Always keep that original untouched.
/// In English UI show an English translation when iOS provides it; the user
/// can toggle to the original Arabic using the control beside the heading.
struct AppNotesTranslationSection: View {
    let appID: String
    let originalText: String
    let heading: String

    @AppStorage("store.language") private var language = "ar"

    var body: some View {
        Group {
            #if canImport(Translation)
            if #available(iOS 18.0, *) {
                NativeNotesTranslation(
                    appID: appID,
                    originalText: originalText,
                    heading: heading,
                    englishInterface: language == "en"
                )
                .id(appID + "|" + language + "|" + String(originalText.hashValue))
            } else {
                olderSystemSection
            }
            #else
            olderSystemSection
            #endif
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private var olderSystemSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(isEnglishVisible: false, translating: false) {}
            arabicOriginal
        }
        .alert("الترجمة غير متاحة", isPresented: $showOlderSystemNotice) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text("الترجمة داخل الوصف تحتاج iOS 18 أو أحدث. الوصف العربي الأصلي محفوظ ومعروض بدون تغيير.")
        }
    }

    @State private var showOlderSystemNotice = false

    private var arabicOriginal: some View {
        RTLDescriptionText(text: originalText, fontSize: 14, lineSpacing: 9)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, .rightToLeft)
    }

    private func header(
        isEnglishVisible: Bool,
        translating: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: {
                showOlderSystemNotice = true
                action()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 12, weight: .semibold))
                    Text(language == "en" ? "Translate · AR" : "ترجمة · EN")
                        .font(AppFont.bold(11.5))
                }
                .foregroundStyle(StoreTheme.accent)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(StoreTheme.accent.opacity(0.11), in: Capsule())
                .overlay(Capsule().stroke(StoreTheme.accent.opacity(0.25), lineWidth: 0.8))
            }
            .buttonStyle(StoreGlassPressStyle())

            Spacer(minLength: 8)

            Text(StoreLanguage.localized(heading))
                .font(AppFont.black(20))
                .foregroundStyle(StoreTheme.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private enum NotesTranslationMemory {
    static let english = NSCache<NSString, NSString>()
}

@available(iOS 18.0, *)
private struct NativeNotesTranslation: View {
    let appID: String
    let originalText: String
    let heading: String
    let englishInterface: Bool

    @State private var showEnglish: Bool
    @State private var englishText: String?
    @State private var isTranslating = false
    @State private var errorText: String?
    @State private var translationConfiguration: TranslationSession.Configuration?

    init(appID: String, originalText: String, heading: String, englishInterface: Bool) {
        self.appID = appID
        self.originalText = originalText
        self.heading = heading
        self.englishInterface = englishInterface
        _showEnglish = State(initialValue: englishInterface)
    }

    private var cacheKey: NSString {
        "\(appID)|\(originalText.hashValue)" as NSString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    showEnglish.toggle()
                    if showEnglish { requestEnglishTranslation() }
                } label: {
                    HStack(spacing: 6) {
                        if isTranslating && showEnglish {
                            ProgressView().tint(StoreTheme.accent).scaleEffect(0.73)
                        } else {
                            Image(systemName: "character.bubble")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(englishInterface
                             ? (showEnglish ? "Translate · AR" : "Translate · EN")
                             : (showEnglish ? "الأصل العربي" : "ترجمة · EN"))
                            .font(AppFont.bold(11.5))
                            .lineLimit(1)
                    }
                    .foregroundStyle(StoreTheme.accent)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(StoreTheme.accent.opacity(0.11), in: Capsule())
                    .overlay(Capsule().stroke(StoreTheme.accent.opacity(0.25), lineWidth: 0.8))
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

            if showEnglish, let englishText, !englishText.isEmpty {
                Text(englishText)
                    .font(AppFont.regular(14))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .lineSpacing(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
            } else {
                // Display the real Arabic notes while Apple prepares or downloads
                // its English translation models. Never fabricate English copy.
                RTLDescriptionText(text: originalText, fontSize: 14, lineSpacing: 9)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, .rightToLeft)
            }

            if isTranslating && showEnglish && englishText == nil {
                Text(englishInterface ? "Translating description…" : "جاري ترجمة الوصف…")
                    .font(AppFont.medium(11))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorText, showEnglish && englishText == nil {
                Text(errorText)
                    .font(AppFont.medium(11))
                    .foregroundStyle(StoreTheme.badgeUpdated)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .translationTask(translationConfiguration) { session in
            do {
                let translated = try await session.translate(originalText)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    NotesTranslationMemory.english.setObject(
                        translated.targetText as NSString, forKey: cacheKey
                    )
                    englishText = translated.targetText
                    isTranslating = false
                    errorText = nil
                }
            } catch {
                await MainActor.run {
                    isTranslating = false
                    errorText = englishInterface
                        ? "English translation is unavailable. Showing the original Arabic."
                        : "تعذرت الترجمة حالياً. الوصف العربي الأصلي ما زال متاحاً."
                }
            }
        }
        .onAppear {
            if showEnglish { requestEnglishTranslation() }
        }
        .onChange(of: englishInterface) { isEnglish in
            showEnglish = isEnglish
            if isEnglish { requestEnglishTranslation() }
        }
    }

    private func requestEnglishTranslation() {
        if let saved = NotesTranslationMemory.english.object(forKey: cacheKey) {
            englishText = saved as String
            isTranslating = false
            errorText = nil
            return
        }
        guard !isTranslating else { return }
        isTranslating = true
        errorText = nil
        if translationConfiguration == nil {
            translationConfiguration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "ar"),
                target: Locale.Language(identifier: "en")
            )
        } else {
            translationConfiguration?.invalidate()
        }
    }
}
#endif
