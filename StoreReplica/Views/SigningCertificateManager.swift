import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SigningCertificateManagerView: View {
    @ObservedObject private var vault = SigningCertificateVault.shared
    @Environment(\.dismiss) private var dismiss
    @State private var p12URL: URL?
    @State private var provisionURL: URL?
    @State private var password = ""
    @State private var showP12Picker = false
    @State private var showProvisionPicker = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 17) {
                    VStack(alignment: .trailing, spacing: 12) {
                        Text("إدارة الشهادات")
                            .font(AppFont.black(22))
                            .foregroundStyle(StoreTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        HStack(spacing: 10) {
                            pickerTile(icon: "doc.badge.plus", title: "إضافة MobileProvision",
                                       filename: provisionURL?.lastPathComponent) { showProvisionPicker = true }
                            pickerTile(icon: "key.fill", title: "إضافة P12",
                                       filename: p12URL?.lastPathComponent) { showP12Picker = true }
                        }
                        HStack(spacing: 8) {
                            SecureField("رمز الشهادة P12", text: $password)
                                .textContentType(.password)
                                .font(AppFont.medium(14))
                                .foregroundStyle(StoreTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Image(systemName: "lock.shield.fill").foregroundStyle(StoreTheme.accent)
                        }
                        .padding(15)
                        .background(StoreTheme.field, in: RoundedRectangle(cornerRadius: 15))

                        Button { addCertificate() } label: {
                            HStack(spacing: 8) {
                                if working { ProgressView().tint(.white) }
                                Text(StoreLanguage.localized(working ? "جاري فحص الشهادة..." : "إدراج الشهادة"))
                                    .font(AppFont.bold(15))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(StoreTheme.accent, in: RoundedRectangle(cornerRadius: 15))
                        }
                        .disabled(working || p12URL == nil || provisionURL == nil || password.isEmpty)
                        .opacity(working || p12URL == nil || provisionURL == nil || password.isEmpty ? 0.5 : 1)

                        if let message {
                            Text(StoreLanguage.localized(message))
                                .font(AppFont.medium(12))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(16)
                    .storeCard()

                    ForEach(vault.certificates) { certificate in
                        certificateCard(certificate)
                    }

                    if vault.certificates.isEmpty {
                        Text("ماكو شهادات محفوظة حالياً. اختَر ملف P12 وملف MobileProvision وأدخل الرمز.")
                            .font(AppFont.medium(12))
                            .foregroundStyle(StoreTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(20)
                    }
                }
                .padding(16)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .navigationTitle("إدارة الشهادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("إغلاق") { dismiss() } }
            }
        }
        
        .task { await vault.refresh() }
        .sheet(isPresented: $showP12Picker) {
            SigningFilePicker(allowedContentTypes: [.signingP12]) { urls in
                showP12Picker = false
                if let url = urls.first { p12URL = url }
            }
        }
        .sheet(isPresented: $showProvisionPicker) {
            SigningFilePicker(allowedContentTypes: [.signingMobileProvision]) { urls in
                showProvisionPicker = false
                if let url = urls.first { provisionURL = url }
            }
        }
    }

    private func pickerTile(icon: String, title: String, filename: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: filename == nil ? icon : "checkmark.seal.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(StoreTheme.accent)
                Text(StoreLanguage.localized(filename ?? title))
                    .font(AppFont.medium(11))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .padding(.horizontal, 5)
            .background(StoreTheme.field, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func certificateCard(_ certificate: StoredSigningCertificate) -> some View {
        VStack(alignment: .trailing, spacing: 13) {
            HStack(spacing: 8) {
                if vault.activeID == certificate.id {
                    Label("النشطة", systemImage: "checkmark.circle.fill")
                        .font(AppFont.medium(11))
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(certificate.displayName)
                        .font(AppFont.bold(16))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    Text("UDID: " + certificate.udidLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.57))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(.white)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule()
                        .fill(certificate.isValid ? Color.green : Color.red)
                        .frame(width: geometry.size.width * certificate.progress)
                }
            }
            .frame(height: 8)

            HStack {
                Text(certificate.expiresAt, format: .dateTime.year().month().day())
                    .font(AppFont.medium(12))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(certificate.isValid ? "\(certificate.daysRemaining) " + StoreLanguage.localized("يوم متبقي") : StoreLanguage.localized("منتهية الصلاحية"))
                    .font(AppFont.bold(12))
                    .foregroundStyle(certificate.isValid ? Color.green : Color.red)
            }
            HStack {
                Button(role: .destructive) { vault.delete(certificate) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                        .frame(width: 40, height: 36)
                }
                Spacer()
                if vault.activeID != certificate.id {
                    Button("استخدام للشهادة والتوقيع") { activate(certificate) }
                        .font(AppFont.bold(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).frame(height: 36)
                        .background(StoreTheme.accent, in: Capsule())
                        .disabled(!certificate.isValid || working)
                }
            }
        }
        .padding(17)
        .background(
            LinearGradient(colors: [Color(red: 0.26, green: 0.36, blue: 0.65),
                                    Color(red: 0.10, green: 0.15, blue: 0.31)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 23)
        )
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: StoreTheme.accent.opacity(0.14), radius: 10, y: 5)
    }

    private func addCertificate() {
        guard let p12URL, let provisionURL else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await vault.add(p12URL: p12URL, profileURL: provisionURL, password: password)
                self.p12URL = nil
                self.provisionURL = nil
                password = ""
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func activate(_ certificate: StoredSigningCertificate) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do { try await vault.activate(certificate) }
            catch { message = error.localizedDescription }
        }
    }
}
