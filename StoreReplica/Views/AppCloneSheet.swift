import SwiftUI

struct AppCloneSheet: View {
    let app: StoreApp

    @Environment(\.dismiss) private var dismiss
    @State private var selectedNumber = 1
    @State private var useCustom = false
    @State private var customText = "15"

    private var effectiveNumber: Int {
        if useCustom, let value = Int(customText), (1...99).contains(value) { return value }
        return selectedNumber
    }

    private var customIsValid: Bool {
        guard useCustom else { return true }
        guard let value = Int(customText) else { return false }
        return (1...99).contains(value)
    }

    private var bundleBase: String {
        app.bundleId?.isEmpty == false ? app.bundleId! : app.id
    }

    private var duplicateApp: StoreApp {
        let number = effectiveNumber
        return StoreApp(
            id: app.id + "-duplicate-" + String(number),
            name: app.name + " " + String(number),
            bundleId: bundleBase + String(number),
            version: app.version,
            buildNumber: app.buildNumber,
            minIosVersion: app.minIosVersion,
            fileSize: app.fileSize,
            notes: app.notes,
            iconUrl: app.iconUrl,
            featured: app.featured,
            categories: app.categories,
            installs: app.installs,
            updatedAt: app.updatedAt,
            addedAt: app.addedAt,
            versionUpdatedAt: app.versionUpdatedAt,
            feedKind: app.feedKind,
            downloadUrl: app.downloadUrl,
            downloadURL: app.downloadURL
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 48, height: 5).padding(.top, 2)
                header
                intro
                numberCard

                Button(action: startDuplicate) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.square.on.square").font(.system(size: 18, weight: .bold))
                        Text("تكرار وتثبيت").font(AppFont.black(17))
                    }
                    .foregroundStyle(StoreTheme.onAccent)
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .background(StoreTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!customIsValid)
                .opacity(customIsValid ? 1 : 0.62)

                Text("يتم تنزيل IPA بالطريقة الطبيعية أولاً، ثم يغيّر BatSign الباندل أثناء نفس مرحلة التوقيع. لا يتم تعديل ملف التحميل المؤقت.")
                    .font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(5).padding(.horizontal, 20)

                Button("إلغاء") { dismiss() }
                    .font(AppFont.bold(14)).foregroundStyle(StoreTheme.textSecondary).padding(.top, 2)
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 18).padding(.top, 8)
        }
        .background(StoreTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func startDuplicate() {
        guard customIsValid else { return }
        let number = effectiveNumber
        dismiss()

        // Use the durable original-IPA preparation flow shared with injection.
        // The prepared clone is staged before signing, and an existing valid
        // certificate is reused instead of asking for it on every duplicate.
        DetailPreparationCenter.shared.beginDuplicate(app: app, number: number)
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIconView(app: app, size: 72)
            VStack(alignment: .trailing, spacing: 6) {
                Text("تكرار \(app.name)").font(AppFont.black(24)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.72)
                Text(app.name).font(AppFont.regular(13)).foregroundStyle(StoreTheme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var intro: some View {
        Text("نسخة ثانية مستقلة تعمل بجانب الأصلية على الجهاز نفسه — مناسبة لحساب آخر مثلاً.")
            .font(AppFont.regular(13.5)).foregroundStyle(StoreTheme.textSecondary)
            .multilineTextAlignment(.trailing).lineSpacing(7)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .environment(\.layoutDirection, .rightToLeft)
    }

    private var numberCard: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Text("اختر رقم النسخة").font(AppFont.black(20)).foregroundStyle(StoreTheme.textPrimary).frame(maxWidth: .infinity, alignment: .trailing)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 5), spacing: 10) {
                ForEach(1...10, id: \.self) { number in
                    Button {
                        selectedNumber = number
                        useCustom = false
                    } label: {
                        Text("\(number)")
                            .font(AppFont.black(18))
                            .foregroundStyle(!useCustom && selectedNumber == number ? StoreTheme.onAccent : StoreTheme.textPrimary)
                            .frame(maxWidth: .infinity).frame(height: 57)
                            .background(!useCustom && selectedNumber == number ? StoreTheme.accent : StoreTheme.field.opacity(0.92))
                            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)

            Button {
                useCustom = true
                if customText.isEmpty { customText = String(selectedNumber) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "number.circle.fill").font(.system(size: 20, weight: .bold))
                    Text("رقم مخصص").font(AppFont.black(16))
                    Spacer()
                    Image(systemName: useCustom ? "checkmark.circle.fill" : "chevron.left").font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(useCustom ? StoreTheme.accent : StoreTheme.textSecondary)
                .padding(.horizontal, 16).frame(height: 56)
                .background(useCustom ? StoreTheme.accent.opacity(0.14) : StoreTheme.field.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            .buttonStyle(.plain)

            if useCustom {
                HStack(spacing: 12) {
                    Text("من 1 إلى 99").font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary)
                    TextField("15", text: $customText)
                        .keyboardType(.numberPad).multilineTextAlignment(.center)
                        .font(AppFont.black(18)).foregroundStyle(StoreTheme.textPrimary)
                        .frame(width: 100, height: 50).background(StoreTheme.background.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(StoreTheme.surfaceBorder.opacity(0.75)).frame(height: 1).padding(.vertical, 2)

            VStack(alignment: .trailing, spacing: 9) {
                Text("معرّف النسخة الجديدة").font(AppFont.bold(12.5)).foregroundStyle(StoreTheme.textSecondary).frame(maxWidth: .infinity, alignment: .trailing)
                HStack(spacing: 0) {
                    Text(bundleBase).foregroundStyle(StoreTheme.textSecondary)
                    Text("\(effectiveNumber)").foregroundStyle(StoreTheme.accent).fontWeight(.bold)
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Color.green).font(.system(size: 16, weight: .bold))
                Text("لن تُحذف النسخة الأصلية ولا بياناتها. كل نسخة تُسجّل دخولها وتُحدّث وحدها.")
                    .font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(17)
        .background(StoreTheme.surface.opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(StoreTheme.surfaceBorder.opacity(0.85), lineWidth: 0.8) }
    }
}
