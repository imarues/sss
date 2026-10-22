import SwiftUI
import UniformTypeIdentifiers

enum DetailPackageActionMode {
    case duplicate
    case dylib
}

final class DetailPackageActionModel: ObservableObject {
    @Published var copyVariant: SideloadCopyVariant = .one
    @Published var dylibs: [URL] = []
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var errorMessage: String?

    private let downloader = SideloadURLDownloader()

    func importDylibs(_ urls: [URL]) {
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var imported: [URL] = []
                for url in urls {
                    guard url.pathExtension.lowercased() == "dylib" else {
                        throw SideloadSigningError.unsupportedDylib(url.lastPathComponent)
                    }
                    imported.append(try SideloadFileVault.importPickedFile(url, allowedExtensions: ["dylib"]))
                }
                DispatchQueue.main.async {
                    self.dylibs.append(contentsOf: imported)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func removeDylib(_ url: URL) {
        dylibs.removeAll { $0 == url }
    }

    func run(app: StoreApp, mode: DetailPackageActionMode, completion: @escaping () -> Void) {
        guard !busy else { return }
        guard let raw = app.effectiveDownloadURL,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = "رابط IPA غير متوفر لهذا التطبيق."
            return
        }

        if mode == .dylib && dylibs.isEmpty {
            errorMessage = "اختر ملف Dylib واحدًا على الأقل."
            return
        }

        busy = true
        progress = 0
        status = "جاري تحميل التطبيق"
        errorMessage = nil

        downloader.start(
            url: url,
            progress: { fraction, _, _ in
                DispatchQueue.main.async {
                    self.progress = fraction * 0.42
                    self.status = "جاري تحميل التطبيق"
                }
            },
            completion: { result in
                switch result {
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.busy = false
                        self.status = ""
                        self.errorMessage = error.localizedDescription
                    }
                case .success(let localURL):
                    self.prepare(localURL: localURL, app: app, sourceURL: raw, mode: mode, completion: completion)
                }
            }
        )
    }

    func cancel() {
        downloader.cancel()
        busy = false
        status = ""
    }

    private func prepare(localURL: URL, app: StoreApp, sourceURL: String, mode: DetailPackageActionMode, completion: @escaping () -> Void) {
        let variant: SideloadCopyVariant = mode == .duplicate ? copyVariant : .original
        let selectedDylibs = mode == .dylib ? dylibs : []

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try SideloadPackagePreparer.prepare(
                    sourceIPA: localURL,
                    knownMetadata: nil,
                    copyVariant: variant,
                    dylibURLs: selectedDylibs,
                    sourceKind: .updates,
                    sourceURL: sourceURL,
                    progress: { value, text in
                        DispatchQueue.main.async {
                            self.progress = 0.42 + (value * 0.58)
                            self.status = text
                        }
                    }
                )

                DispatchQueue.main.async {
                    self.busy = false
                    self.progress = 1
                    self.status = "جاهز للتوقيع والتثبيت"
                    if SigningAssetProvider.hasCredentials {
                        StoreInstallCoordinator.shared.start(result.app)
                    } else {
                        SigningSetupCoordinator.shared.request(for: result.app)
                    }
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct DetailPackageActionSheet: View {
    let app: StoreApp
    let mode: DetailPackageActionMode

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DetailPackageActionModel()
    @State private var pickingDylib = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 46, height: 5)
                        .padding(.top, 6)

                    HStack(spacing: 13) {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(mode == .duplicate ? "تكرار \(app.name)" : "دمج ديلب")
                                .font(AppFont.black(22))
                                .foregroundStyle(StoreTheme.textPrimary)
                                .lineLimit(1)
                            Text(app.name)
                                .font(AppFont.regular(12))
                                .foregroundStyle(StoreTheme.textSecondary)
                                .lineLimit(1)
                        }
                        AppIconView(app: app, size: 62)
                    }

                    if mode == .duplicate {
                        duplicateOptions
                    } else {
                        dylibOptions
                    }

                    if model.busy {
                        VStack(spacing: 8) {
                            ProgressView(value: model.progress)
                                .tint(StoreTheme.accent)
                            Text(model.status)
                                .font(AppFont.regular(11))
                                .foregroundStyle(StoreTheme.textSecondary)
                        }
                        .padding(14)
                        .storeCard(radius: 16)
                    }

                    if let error = model.errorMessage {
                        Text(error)
                            .font(AppFont.regular(11.5))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(14)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }

                    Button {
                        model.run(app: app, mode: mode) {
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if model.busy {
                                ProgressView().tint(StoreTheme.onAccent)
                            } else {
                                Image(systemName: mode == .duplicate ? "plus.square.on.square" : "puzzlepiece.extension.fill")
                            }
                            Text(mode == .duplicate ? "تكرار وتثبيت" : "دمج وتثبيت")
                                .font(AppFont.black(16))
                        }
                        .foregroundStyle(StoreTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(StoreTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy || (mode == .dylib && model.dylibs.isEmpty))
                    .opacity((model.busy || (mode == .dylib && model.dylibs.isEmpty)) ? 0.48 : 1)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 18)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: $pickingDylib) {
            SigningFilePicker(allowedContentTypes: [.sideloadDylib], allowsMultipleSelection: true) { urls in
                pickingDylib = false
                guard !urls.isEmpty else { return }
                model.importDylibs(urls)
            }
            .ignoresSafeArea()
        }
    }

    private var duplicateOptions: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text("اختر رقم النسخة")
                .font(AppFont.black(17))
                .foregroundStyle(StoreTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 9) {
                ForEach(SideloadCopyVariant.allCases.filter { $0 != .original }) { item in
                    Button {
                        model.copyVariant = item
                    } label: {
                        Text(item.title)
                            .font(AppFont.black(16))
                            .foregroundStyle(model.copyVariant == item ? StoreTheme.onAccent : StoreTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(model.copyVariant == item ? StoreTheme.accent : StoreTheme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let bundle = app.bundleId, !bundle.isEmpty {
                Text(bundle + String(model.copyVariant.rawValue))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(StoreTheme.field.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(16)
        .storeCard(radius: 20)
    }

    private var dylibOptions: some View {
        VStack(spacing: 12) {
            Button {
                pickingDylib = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(StoreTheme.accent)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("اختيار ملف Dylib")
                            .font(AppFont.black(16))
                            .foregroundStyle(StoreTheme.textPrimary)
                        Text("يمكن اختيار أكثر من ملف")
                            .font(AppFont.regular(11))
                            .foregroundStyle(StoreTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 72)
                .background(StoreTheme.field.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(StoreTheme.surfaceBorder, style: StrokeStyle(lineWidth: 1, dash: [7, 5]))
                }
            }
            .buttonStyle(.plain)

            ForEach(model.dylibs, id: \.path) { url in
                HStack(spacing: 10) {
                    Button {
                        model.removeDylib(url)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(StoreTheme.textSecondary)
                    }
                    Spacer()
                    Text(url.lastPathComponent)
                        .font(AppFont.medium(12))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(StoreTheme.accent)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .storeCard(radius: 15)
            }
        }
    }
}
