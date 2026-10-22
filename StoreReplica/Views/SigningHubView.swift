import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static var sideloadIPA: UTType {
        UTType(filenameExtension: "ipa", conformingTo: .zip) ?? .data
    }

    static var sideloadDylib: UTType {
        UTType(filenameExtension: "dylib", conformingTo: .data) ?? .data
    }
}

enum SigningHubTab: String, CaseIterable, Identifiable {
    case file = "رفع ملف"
    case link = "عبر رابط"
    case apps = "تطبيقاتي"

    var id: String { rawValue }
}

final class SigningHubViewModel: ObservableObject {
    @Published var selectedTab: SigningHubTab = .file
    @Published var copyVariant: SideloadCopyVariant = .original
    @Published var selectedIPA: URL?
    @Published var selectedIPAName: String?
    @Published var metadata: SideloadIPAMetadata?
    @Published var dylibs: [URL] = []
    @Published var linkText = ""
    @Published var busy = false
    @Published var inspecting = false
    @Published var downloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var expectedBytes: Int64 = 0
    @Published var workProgress: Double = 0
    @Published var statusText = ""
    @Published var errorText: String?
    @Published var preparedApp: StoreApp?
    @Published var libraryItems: [SideloadLibraryItem] = []

    private let downloader = SideloadURLDownloader()

    func selectIPA(_ url: URL) {
        inspecting = true
        errorText = nil
        metadata = nil
        selectedIPAName = url.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stored = try SideloadFileVault.importPickedFile(url, allowedExtensions: ["ipa"])
                let info = try SideloadIPAInspector.inspect(stored)
                DispatchQueue.main.async {
                    self.selectedIPA = stored
                    self.selectedIPAName = url.lastPathComponent
                    self.metadata = info
                    self.inspecting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.inspecting = false
                    self.errorText = error.localizedDescription
                    self.selectedIPA = nil
                    self.metadata = nil
                }
            }
        }
    }

    func selectDylibs(_ urls: [URL]) {
        errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var stored: [URL] = []
                for url in urls {
                    guard url.pathExtension.lowercased() == "dylib" else {
                        throw SideloadSigningError.unsupportedDylib(url.lastPathComponent)
                    }
                    stored.append(try SideloadFileVault.importPickedFile(url, allowedExtensions: ["dylib"]))
                }
                DispatchQueue.main.async {
                    self.dylibs.append(contentsOf: stored)
                }
            } catch {
                DispatchQueue.main.async { self.errorText = error.localizedDescription }
            }
        }
    }

    func removeDylib(_ url: URL) {
        dylibs.removeAll { $0 == url }
    }

    func resetFile() {
        selectedIPA = nil
        selectedIPAName = nil
        metadata = nil
        copyVariant = .original
        errorText = nil
    }

    func signSelectedFile() {
        guard let selectedIPA else {
            errorText = "اختر ملف IPA أولاً."
            return
        }
        prepareAndInstall(
            sourceIPA: selectedIPA,
            knownMetadata: metadata,
            sourceKind: .file,
            sourceURL: nil
        )
    }

    func signFromLink() {
        let raw = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorText = SideloadSigningError.invalidURL.localizedDescription
            return
        }

        errorText = nil
        busy = true
        downloading = true
        downloadProgress = 0
        downloadedBytes = 0
        expectedBytes = 0
        workProgress = 0
        metadata = nil
        preparedApp = nil
        statusText = "جاري تحميل IPA"

        downloader.start(
            url: url,
            progress: { fraction, written, expected in
                DispatchQueue.main.async {
                    self.downloadProgress = fraction
                    self.downloadedBytes = written
                    self.expectedBytes = expected
                    self.statusText = expected > 0 ? "جاري التحميل" : "جاري التحميل…"
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    self.downloading = false
                    switch result {
                    case .success(let localURL):
                        self.downloadProgress = 1
                        self.statusText = "تم التحميل، جاري قراءة التطبيق"
                        self.prepareAndInstall(
                            sourceIPA: localURL,
                            knownMetadata: nil,
                            sourceKind: .link,
                            sourceURL: raw,
                            alreadyBusy: true
                        )
                    case .failure(let error):
                        self.busy = false
                        self.errorText = error.localizedDescription
                        self.statusText = ""
                    }
                }
            }
        )
    }

    func cancelDownload() {
        downloader.cancel()
        busy = false
        downloading = false
        statusText = ""
    }

    func refreshLibrary() {
        DispatchQueue.global(qos: .utility).async {
            let items = SideloadLibraryStore.items()
            DispatchQueue.main.async { self.libraryItems = items }
        }
    }

    private func prepareAndInstall(
        sourceIPA: URL,
        knownMetadata: SideloadIPAMetadata?,
        sourceKind: SideloadSourceKind,
        sourceURL: String?,
        alreadyBusy: Bool = false
    ) {
        if !alreadyBusy {
            guard !busy else { return }
            busy = true
        }
        errorText = nil
        workProgress = 0
        statusText = "جاري تجهيز التطبيق"
        preparedApp = nil

        let variant = copyVariant
        let selectedDylibs = dylibs

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try SideloadPackagePreparer.prepare(
                    sourceIPA: sourceIPA,
                    knownMetadata: knownMetadata,
                    copyVariant: variant,
                    dylibURLs: selectedDylibs,
                    sourceKind: sourceKind,
                    sourceURL: sourceURL,
                    progress: { fraction, text in
                        DispatchQueue.main.async {
                            self.workProgress = fraction
                            self.statusText = text
                        }
                    },
                    metadataReady: { info in
                        DispatchQueue.main.async {
                            self.metadata = info
                        }
                    }
                )

                DispatchQueue.main.async {
                    self.busy = false
                    self.workProgress = 1
                    self.preparedApp = result.app
                    self.metadata = result.metadata
                    self.statusText = "جاهز للتوقيع والتثبيت"
                    self.refreshLibrary()

                    if SigningAssetProvider.hasCredentials {
                        StoreInstallCoordinator.shared.start(result.app)
                    } else {
                        SigningSetupCoordinator.shared.request(for: result.app)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.errorText = error.localizedDescription
                    self.statusText = ""
                }
            }
        }
    }
}

struct SigningHubView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SigningHubViewModel()
    @ObservedObject private var installer = StoreInstallCoordinator.shared
    @State private var pickingIPA = false
    @State private var pickingDylib = false
    @State private var showDylibSection = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    titleBlock
                    tabStrip

                    Group {
                        switch model.selectedTab {
                        case .file: fileSection
                        case .link: linkSection
                        case .apps: myAppsSection
                        }
                    }

                    if let error = model.errorText {
                        errorCard(error)
                    }

                    Color.clear.frame(height: 34)
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
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: $pickingIPA) {
            SigningFilePicker(allowedContentTypes: [.data]) { urls in
                pickingIPA = false
                guard let url = urls.first else { return }
                model.selectIPA(url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $pickingDylib) {
            SigningFilePicker(
                allowedContentTypes: [.sideloadDylib],
                allowsMultipleSelection: true
            ) { urls in
                pickingDylib = false
                guard !urls.isEmpty else { return }
                model.selectDylibs(urls)
            }
            .ignoresSafeArea()
        }
        .onAppear { model.refreshLibrary() }
        .onChange(of: model.selectedTab) { tab in
            if tab == .apps { model.refreshLibrary() }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 5) {
            Text("توقيع تطبيق")
                .font(AppFont.black(25))
                .foregroundStyle(StoreTheme.textPrimary)
            Text("ثبّت IPA من جهازك أو عبر رابط")
                .font(AppFont.regular(12))
                .foregroundStyle(StoreTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(SigningHubTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(AppFont.bold(12))
                        .foregroundStyle(model.selectedTab == tab ? StoreTheme.onAccent : StoreTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(model.selectedTab == tab ? StoreTheme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(StoreTheme.surfaceBorder.opacity(0.8), lineWidth: 0.8)
        }
    }

    private var fileSection: some View {
        VStack(spacing: 14) {
            if let info = model.metadata, model.selectedIPA != nil {
                selectedAppCard(info: info, fileName: model.selectedIPAName)
            } else {
                uploadCard
            }

            if model.selectedIPA != nil {
                copySelector
                dylibSection
                primaryButton(
                    title: installButtonTitle,
                    icon: "checkmark.shield.fill",
                    disabled: model.busy || model.inspecting
                ) {
                    model.signSelectedFile()
                }
            }

            if model.inspecting {
                workingCard(progress: nil, title: "جاري قراءة معلومات التطبيق")
            }

            installStateCard
            noteCard("اختر IPA من ملفاتك. عند اختيار نسخة من 1 إلى 5 يضاف الرقم إلى اسم التطبيق وإلى نهاية Bundle ID تلقائياً.")
        }
    }

    private var uploadCard: some View {
        Button { pickingIPA = true } label: {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(StoreTheme.accent.opacity(0.13))
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(StoreTheme.accent)
                }
                .frame(width: 62, height: 62)

                VStack(spacing: 4) {
                    Text("اختر ملف IPA")
                        .font(AppFont.black(17))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("اختر تطبيقاً من تطبيق الملفات")
                        .font(AppFont.regular(11))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(StoreTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(StoreTheme.surfaceBorder, style: StrokeStyle(lineWidth: 1, dash: [7, 5]))
            }
        }
        .buttonStyle(.plain)
    }

    private func selectedAppCard(info: SideloadIPAMetadata, fileName: String?) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                localIcon(data: info.iconData, url: nil, size: 62)

                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                        Text(info.name)
                            .font(AppFont.black(15))
                            .foregroundStyle(StoreTheme.textPrimary)
                            .lineLimit(1)
                    }
                    Text(info.bundleID)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .lineLimit(1)
                    Text("v\(info.version) • \(formatBytes(info.size))")
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let fileName {
                Text(fileName)
                    .font(AppFont.regular(10))
                    .foregroundStyle(StoreTheme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Button {
                model.resetFile()
                pickingIPA = true
            } label: {
                Text("اختر ملفاً آخر")
                    .font(AppFont.bold(12))
                    .foregroundStyle(StoreTheme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 37)
                    .background(StoreTheme.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.green.opacity(0.48), lineWidth: 1)
        }
    }

    private var linkSection: some View {
        VStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 8) {
                Text("رابط IPA")
                    .font(AppFont.bold(12))
                    .foregroundStyle(StoreTheme.textPrimary)
                TextField("https://example.com/app.ipa", text: $model.linkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .multilineTextAlignment(.left)
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.horizontal, 14)
                    .frame(height: 49)
                    .background(StoreTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(StoreTheme.surfaceBorder.opacity(0.75), lineWidth: 0.8)
                    }
            }
            .padding(15)
            .background(StoreTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            copySelector
            dylibSection

            if model.downloading {
                downloadProgressCard
            } else if model.busy {
                workingCard(progress: model.workProgress, title: model.statusText.isEmpty ? "جاري تجهيز التطبيق" : model.statusText)
            } else if let info = model.metadata, model.preparedApp != nil {
                selectedAppCard(info: info, fileName: nil)
            }

            primaryButton(
                title: model.downloading ? "إلغاء التحميل" : installButtonTitle,
                icon: model.downloading ? "xmark" : "arrow.down.app.fill",
                disabled: model.busy && !model.downloading
            ) {
                if model.downloading { model.cancelDownload() }
                else { model.signFromLink() }
            }

            installStateCard
            noteCard("ضع رابط IPA، اختر النسخة والديلب، ثم اضغط وقّع وثبّت. بعد اكتمال التحميل يبدأ التجهيز والتوقيع تلقائياً.")
        }
    }

    private var downloadProgressCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(guessedLinkName)
                        .font(AppFont.bold(13))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .lineLimit(1)
                    Text(model.metadata?.bundleID ?? "جاري محاولة قراءة بيانات التطبيق…")
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(StoreTheme.field)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(StoreTheme.accent)
                }
                .frame(width: 52, height: 52)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(downloadSizeText)
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
                Spacer()
                Text("\(Int(model.downloadProgress * 100))%")
                    .font(AppFont.black(36))
                    .foregroundStyle(StoreTheme.textPrimary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(StoreTheme.field)
                    Capsule().fill(StoreTheme.accent)
                        .frame(width: max(5, proxy.size.width * model.downloadProgress))
                }
            }
            .frame(height: 12)
        }
        .padding(16)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var guessedLinkName: String {
        if let name = model.metadata?.name { return name }
        guard let url = URL(string: model.linkText), !url.lastPathComponent.isEmpty else { return "IPA" }
        let value = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return value.isEmpty ? "IPA" : value
    }

    private var downloadSizeText: String {
        if model.expectedBytes > 0 {
            return "\(formatBytes(model.downloadedBytes)) / \(formatBytes(model.expectedBytes))"
        }
        return formatBytes(model.downloadedBytes)
    }

    private var copySelector: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack {
                Text("يضاف الرقم للاسم والباندل")
                    .font(AppFont.regular(10))
                    .foregroundStyle(StoreTheme.textSecondary)
                Spacer()
                Text("النسخة")
                    .font(AppFont.black(14))
                    .foregroundStyle(StoreTheme.textPrimary)
            }

            HStack(spacing: 6) {
                ForEach(SideloadCopyVariant.allCases) { variant in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { model.copyVariant = variant }
                    } label: {
                        Text(variant.title)
                            .font(AppFont.bold(11.5))
                            .foregroundStyle(model.copyVariant == variant ? StoreTheme.onAccent : StoreTheme.textSecondary)
                            .frame(width: variant == .original ? 76 : 42, height: 36)
                            .background(model.copyVariant == variant ? StoreTheme.accent : StoreTheme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .padding(14)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var dylibSection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showDylibSection.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: showDylibSection ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StoreTheme.textSecondary)
                    if !model.dylibs.isEmpty {
                        Text("\(model.dylibs.count)")
                            .font(AppFont.bold(10))
                            .foregroundStyle(StoreTheme.onAccent)
                            .frame(width: 25, height: 25)
                            .background(StoreTheme.accent)
                            .clipShape(Circle())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("دمج ديلب")
                            .font(AppFont.black(14))
                            .foregroundStyle(StoreTheme.textPrimary)
                        Text("يدعم .dylib فقط")
                            .font(AppFont.regular(10))
                            .foregroundStyle(StoreTheme.textSecondary)
                    }
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StoreTheme.accent)
                }
            }
            .buttonStyle(.plain)

            if showDylibSection {
                Divider().overlay(StoreTheme.surfaceBorder)

                ForEach(model.dylibs, id: \.path) { dylib in
                    HStack(spacing: 8) {
                        Button { model.removeDylib(dylib) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.red.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(dylib.lastPathComponent)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(StoreTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                    }
                }

                Button { pickingDylib = true } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Spacer()
                        Text("رفع ديلب من جهازك")
                    }
                    .font(AppFont.bold(12))
                    .foregroundStyle(StoreTheme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(StoreTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("مسار الحقن: @executable_path/اسم.dylib")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(14)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StoreTheme.surfaceBorder.opacity(0.75), lineWidth: 0.8)
        }
    }

    private var installButtonTitle: String {
        if model.busy { return model.statusText.isEmpty ? "جاري التجهيز…" : model.statusText }
        if model.dylibs.isEmpty { return "وقّع وثبّت" }
        return "ادمج \(model.dylibs.count) ديلب ووقّع وثبّت"
    }

    private func primaryButton(title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if model.busy && !model.downloading {
                    ProgressView().tint(StoreTheme.onAccent)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                }
                Text(title)
                    .font(AppFont.black(14))
                    .lineLimit(1)
            }
            .foregroundStyle(StoreTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(StoreTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.58 : 1)
    }

    @ViewBuilder
    private var installStateCard: some View {
        if let app = model.preparedApp {
            let state = installer.state(for: app)
            if state.phase != .idle && state.phase != .complete {
                workingCard(
                    progress: state.progress > 0 ? state.progress : nil,
                    title: state.message ?? installPhaseTitle(state.phase)
                )
            }
        }
    }

    private func installPhaseTitle(_ phase: StoreInstallPhase) -> String {
        switch phase {
        case .idle: return ""
        case .downloading: return "جاري التحميل"
        case .ready: return "جاهز"
        case .signing: return "جاري التوقيع"
        case .installing: return "جاري فتح المثبت"
        case .complete: return "تم"
        case .failed: return "تعذر التثبيت"
        }
    }

    private func workingCard(progress: Double?, title: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().tint(StoreTheme.accent)
                Text(title)
                    .font(AppFont.bold(12))
                    .foregroundStyle(StoreTheme.textPrimary)
                Spacer()
            }
            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StoreTheme.field)
                        Capsule().fill(StoreTheme.accent)
                            .frame(width: max(4, proxy.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 7)
            }
        }
        .padding(14)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var myAppsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Button { model.refreshLibrary() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(StoreTheme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("تطبيقاتي")
                        .font(AppFont.black(19))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("التطبيقات المحمّلة من الروابط والتحديثات")
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
            }

            if model.libraryItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(StoreTheme.textSecondary)
                    Text("ماكو تطبيقات محفوظة بعد")
                        .font(AppFont.bold(13))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text("أي IPA تحمله من رابط أو من قسم التحديثات يطلع هنا تلقائياً.")
                        .font(AppFont.regular(10.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 38)
                .background(StoreTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.libraryItems) { item in
                        libraryRow(item)
                    }
                }
            }
        }
    }

    private func libraryRow(_ item: SideloadLibraryItem) -> some View {
        HStack(spacing: 11) {
            VStack(spacing: 8) {
                ShareLink(item: item.ipaURL) {
                    Label("مشاركة", systemImage: "square.and.arrow.up")
                        .font(AppFont.bold(10.5))
                        .foregroundStyle(StoreTheme.accent)
                        .frame(width: 82, height: 31)
                        .background(StoreTheme.accent.opacity(0.10))
                        .clipShape(Capsule())
                }
                InstallPill(title: "تثبيت", app: item.storeApp)
                    .frame(width: 82)
            }

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

            localIcon(data: nil, url: item.iconURL, size: 58)
        }
        .padding(13)
        .background(StoreTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StoreTheme.surfaceBorder.opacity(0.70), lineWidth: 0.8)
        }
    }

    private func localIcon(data: Data?, url: URL?, size: CGFloat) -> some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [StoreTheme.field, StoreTheme.surfaceBorder], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(StoreTheme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
        }
    }

    private func noteCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(text)
                .font(AppFont.regular(10.5))
                .foregroundStyle(StoreTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "info.circle.fill")
                .foregroundStyle(StoreTheme.accent)
        }
        .padding(13)
        .background(StoreTheme.accent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(text)
                .font(AppFont.medium(10.5))
                .foregroundStyle(Color.red.opacity(0.95))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
        }
        .padding(13)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
