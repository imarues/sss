import SwiftUI
import UniformTypeIdentifiers
import Zip

private enum DylibChoiceMode {
    case none
    case local
    case ready
}

private struct DylibZipEntry: Identifiable, Hashable {
    let url: URL
    let pathInArchive: String
    var id: String { url.path }
    // Display the relative folder as well, so same-named dylibs stay distinct.
    var name: String { pathInArchive }
}

private enum ReadyDylibOutcome {
    case direct
    case zip
}

@MainActor
private final class AppDylibMergeModel: ObservableObject {
    let app: StoreApp

    @Published var mode: DylibChoiceMode = .none
    @Published var localDylibs: [URL] = []
    @Published var readyDylib: URL?
    @Published var selectedReadyItem: StoreApp?
    @Published var catalog: [StoreApp] = []
    @Published var loadingCatalog = false
    @Published var inspectingAsset = false
    @Published var assetProgress: Double = 0
    @Published var zipEntries: [DylibZipEntry] = []
    @Published var selectedZipIDs: Set<String> = []
    @Published var errorText: String?

    private let downloader = DylibAssetDownloader()

    init(app: StoreApp) {
        self.app = app
    }

    var selectedDylibs: [URL] {
        switch mode {
        case .none:
            return []
        case .local:
            return localDylibs
        case .ready:
            if let readyDylib { return [readyDylib] }
            return zipEntries.filter { selectedZipIDs.contains($0.id) }.map(\.url)
        }
    }

    var canSubmit: Bool {
        mode == .none || !selectedDylibs.isEmpty
    }

    var selectedSummary: String? {
        switch mode {
        case .none:
            return nil
        case .local:
            guard !localDylibs.isEmpty else { return nil }
            return localDylibs.count == 1 ? localDylibs[0].lastPathComponent : "\(localDylibs.count) ملفات Dylib"
        case .ready:
            guard let item = selectedReadyItem else { return nil }
            if readyDylib != nil { return item.name }
            if !selectedZipIDs.isEmpty { return "\(item.name) · \(selectedZipIDs.count) ملف" }
            return item.name
        }
    }

    func chooseNone() {
        mode = .none
        localDylibs = []
        readyDylib = nil
        selectedReadyItem = nil
        zipEntries = []
        selectedZipIDs = []
        errorText = nil
    }

    func chooseLocal() {
        mode = .local
        readyDylib = nil
        selectedReadyItem = nil
        zipEntries = []
        selectedZipIDs = []
        errorText = nil
    }

    func chooseReady() {
        mode = .ready
        localDylibs = []
        errorText = nil
        Task { await loadCatalogIfNeeded() }
    }

    func importLocal(_ urls: [URL]) {
        chooseLocal()
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
                    self.localDylibs = stored
                    self.errorText = nil
                }
            } catch {
                DispatchQueue.main.async { self.errorText = error.localizedDescription }
            }
        }
    }

    func loadCatalogIfNeeded() async {
        guard catalog.isEmpty, !loadingCatalog else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            let all = try await KiraSourceSearchService.shared.catalog(force: false)
            catalog = all
                .filter { $0.isDylibAsset && $0.effectiveDownloadURL != nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorText = "تعذر تحميل قائمة الديلب: \(error.localizedDescription)"
        }
    }

    func inspectReady(_ item: StoreApp, completion: @escaping (ReadyDylibOutcome) -> Void) {
        guard !inspectingAsset,
              let raw = item.effectiveDownloadURL,
              let url = URL(string: raw) else { return }

        mode = .ready
        selectedReadyItem = item
        readyDylib = nil
        zipEntries = []
        selectedZipIDs = []
        inspectingAsset = true
        assetProgress = 0
        errorText = nil

        downloader.start(
            url: url,
            progress: { [weak self] fraction in
                DispatchQueue.main.async { self?.assetProgress = fraction }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.inspectingAsset = false
                        self.errorText = error.localizedDescription
                    case .success(let downloaded):
                        self.assetProgress = 1
                        // ZIP extraction runs off the main queue so large archives
                        // never freeze the picker while their contents are scanned.
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            let inspected = Result {
                                try DylibArchiveInspector.inspect(downloaded, preferredName: item.name)
                            }
                            DispatchQueue.main.async {
                                guard let self else { return }
                                self.inspectingAsset = false
                                switch inspected {
                                case .failure(let error):
                                    self.errorText = error.localizedDescription
                                case .success(.direct(let file)):
                                    self.readyDylib = file
                                    self.zipEntries = []
                                    self.selectedZipIDs = []
                                    completion(.direct)
                                case .success(.zip(let entries)):
                                    self.readyDylib = nil
                                    self.zipEntries = entries
                                    self.selectedZipIDs = []
                                    completion(.zip)
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    func toggleZip(_ entry: DylibZipEntry) {
        if selectedZipIDs.contains(entry.id) {
            selectedZipIDs.remove(entry.id)
        } else {
            selectedZipIDs.insert(entry.id)
        }
    }

}

// Prepared archives are inspected away from the UI actor. The download's
// suggested filename is not trusted: CDNs often return application/octet-stream
// as asset.bin, but Zip 2.x requires a .zip path to extract it.
private enum DylibPreparedAsset {
    case direct(URL)
    case zip([DylibZipEntry])
}

private enum DylibArchiveInspector {
    private static let fm = FileManager.default

    static func inspect(_ source: URL, preferredName: String) throws -> DylibPreparedAsset {
        let handle = try FileHandle(forReadingFrom: source)
        let signature = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        let bytes = Array(signature)
        let isArchive = bytes.count == 4 &&
            bytes[0] == 0x50 && bytes[1] == 0x4b &&
            ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
             (bytes[2] == 0x05 && bytes[3] == 0x06) ||
             (bytes[2] == 0x07 && bytes[3] == 0x08))

        if isArchive {
            let workFolder = fm.temporaryDirectory
                .appendingPathComponent("DylibZip-\(UUID().uuidString)", isDirectory: true)
            let extractedFolder = workFolder.appendingPathComponent("contents", isDirectory: true)
            try fm.createDirectory(at: extractedFolder, withIntermediateDirectories: true)
            // Always give Zip a genuine .zip extension, regardless of the
            // download response's suggested filename or URL query parameters.
            let archiveURL = workFolder.appendingPathComponent("download.zip")
            try fm.copyItem(at: source, to: archiveURL)
            do {
                try Zip.unzipFile(archiveURL, destination: extractedFolder,
                                  overwrite: true, password: nil, progress: nil)
            } catch {
                throw SideloadSigningError.unsupportedDylib("تعذر فك ضغط ZIP: \(error.localizedDescription)")
            }

            guard let enumerator = fm.enumerator(
                at: extractedFolder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else {
                throw SideloadSigningError.unsupportedDylib("تعذر فحص محتويات ZIP")
            }
            var found: [DylibZipEntry] = []
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "dylib" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(file.path.dropFirst(extractedFolder.path.count + 1))
                found.append(DylibZipEntry(url: file, pathInArchive: relative))
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !found.isEmpty else {
                throw SideloadSigningError.unsupportedDylib("لا يوجد ملف Dylib داخل ZIP أو مجلداته")
            }
            return .zip(found)
        }

        if source.pathExtension.lowercased() == "zip" {
            throw SideloadSigningError.unsupportedDylib("الملف ليس أرشيف ZIP صالح")
        }
        if source.pathExtension.lowercased() == "dylib" { return .direct(source) }

        let folder = fm.temporaryDirectory
            .appendingPathComponent("ReadyDylib-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = preferredName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let destination = folder.appendingPathComponent((safe.isEmpty ? "Injected" : safe) + ".dylib")
        try fm.copyItem(at: source, to: destination)
        return .direct(destination)
    }
}

private final class DylibAssetDownloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    typealias Progress = (Double) -> Void
    typealias Completion = (Result<URL, Error>) -> Void

    private var progress: Progress?
    private var completion: Completion?
    private var resultURL: URL?
    private var resultError: Error?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func start(url: URL, progress: @escaping Progress, completion: @escaping Completion) {
        session.getAllTasks { $0.forEach { $0.cancel() } }
        self.progress = progress
        self.completion = completion
        resultURL = nil
        resultError = nil

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("application/octet-stream,*/*;q=0.9", forHTTPHeaderField: "Accept")
        session.downloadTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = max(totalBytesExpectedToWrite, 0)
        progress?(expected > 0 ? min(1, Double(totalBytesWritten) / Double(expected)) : 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            resultError = SideloadSigningError.httpStatus(http.statusCode)
            return
        }

        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("DylibAsset-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suggested = downloadTask.response?.suggestedFilename
            let name = suggested?.isEmpty == false ? suggested! : "asset.bin"
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: location, to: destination)
            resultURL = destination
        } catch {
            resultError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = completion
        completion = nil
        if let error {
            callback?(.failure(error))
        } else if let resultError {
            callback?(.failure(resultError))
        } else if let resultURL {
            callback?(.success(resultURL))
        } else {
            callback?(.failure(SideloadSigningError.downloadFailed))
        }
    }
}

struct AppDylibMergeSheet: View {
    let app: StoreApp

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AppDylibMergeModel
    @ObservedObject private var center = DetailPreparationCenter.shared
    @State private var pickingLocal = false
    @State private var showReadyPicker = false

    private let accent = Color(red: 0.04, green: 0.65, blue: 0.59)

    init(app: StoreApp) {
        self.app = app
        _model = StateObject(wrappedValue: AppDylibMergeModel(app: app))
    }

    private var isBusy: Bool {
        center.isActive(appID: app.id, kind: .dylib)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                dragIndicator
                header
                intro
                options

                if let summary = model.selectedSummary {
                    selectedCard(summary)
                }

                if isBusy {
                    progressCard
                }

                if let error = model.errorText ?? center.errorText, !error.isEmpty {
                    errorCard(error)
                }

                Button {
                    if model.mode == .none {
                        if SigningAssetProvider.hasCredentials {
                            StoreInstallCoordinator.shared.start(app)
                        } else {
                            SigningSetupCoordinator.shared.request(for: app)
                        }
                        dismiss()
                    } else {
                        center.beginDylib(app: app, dylibs: model.selectedDylibs)
                    }
                } label: {
                    HStack(spacing: 9) {
                        if isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: model.mode == .none ? "arrow.down.app.fill" : "puzzlepiece.extension.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                        Text(isBusy ? "جاري الدمج" : (model.mode == .none ? "تثبيت بلا ديلب" : "دمج وتثبيت"))
                            .font(AppFont.black(17))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(model.canSubmit ? accent : StoreTheme.textSecondary.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSubmit || isBusy)

                if isBusy {
                    Text("تقدر تسكر هذه الصفحة أو تطلع من التطبيق. التحميل والدمج يستمران بالخلفية وتظهر الحالة في الجزيرة الديناميكية.")
                        .font(AppFont.regular(11.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .padding(.horizontal, 16)
                }

                Button("إلغاء") { dismiss() }
                    .font(AppFont.bold(14))
                    .foregroundStyle(StoreTheme.textSecondary)

                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .background(StoreTheme.background.ignoresSafeArea())
        
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
        .sheet(isPresented: $pickingLocal) {
            SigningFilePicker(allowedContentTypes: [.sideloadDylib], allowsMultipleSelection: true) { urls in
                pickingLocal = false
                if !urls.isEmpty { model.importLocal(urls) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showReadyPicker) {
            ReadyDylibPickerSheet(model: model, accent: accent)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: DetailPreparationCenter.completedNotification)) { note in
            guard let appID = note.userInfo?["appID"] as? String,
                  let kind = note.userInfo?["kind"] as? String,
                  appID == app.id,
                  kind == DetailPreparationKind.dylib.rawValue else { return }
            dismiss()
        }
    }

    private var dragIndicator: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 48, height: 5)
            .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIconView(app: app, size: 72)
            VStack(alignment: .trailing, spacing: 6) {
                Text("دمج ديلب")
                    .font(AppFont.black(24))
                    .foregroundStyle(StoreTheme.textPrimary)
                Text(app.name)
                    .font(AppFont.regular(13))
                    .foregroundStyle(StoreTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }

    private var intro: some View {
        Text("اختر مكتبة أو أكثر تُحقن داخل التطبيق أثناء توقيعه، أو ثبّت النسخة الأصلية بلا حقن.")
            .font(AppFont.regular(13.5))
            .foregroundStyle(StoreTheme.textSecondary)
            .lineSpacing(7)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var options: some View {
        VStack(spacing: 11) {
            optionRow(
                title: "بلا حقن",
                subtitle: "النسخة الأصلية كما هي",
                icon: "nosign",
                selected: model.mode == .none
            ) {
                model.chooseNone()
            }

            optionRow(
                title: "اختيار ملف Dylib",
                subtitle: "اختر ملفًا أو أكثر من جهازك",
                icon: "doc.badge.plus",
                selected: model.mode == .local
            ) {
                model.chooseLocal()
                pickingLocal = true
            }

            optionRow(
                title: "Dylib جاهز",
                subtitle: "من مكتبة الديلبات في المتجر",
                icon: "shippingbox.fill",
                selected: model.mode == .ready
            ) {
                model.chooseReady()
                showReadyPicker = true
            }
        }
    }

    private func optionRow(
        title: String,
        subtitle: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(selected ? accent.opacity(0.20) : StoreTheme.field)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selected ? accent : StoreTheme.textSecondary)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(title)
                        .font(AppFont.black(16))
                        .foregroundStyle(StoreTheme.textPrimary)
                    Text(subtitle)
                        .font(AppFont.regular(11.5))
                        .foregroundStyle(StoreTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? accent : StoreTheme.tabInactive)
            }
            .padding(.horizontal, 14)
            .frame(height: 82)
            .background(selected ? accent.opacity(0.08) : StoreTheme.surface.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(selected ? accent.opacity(0.85) : StoreTheme.surfaceBorder.opacity(0.85), lineWidth: selected ? 1.3 : 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectedCard(_ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(accent)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(title)
                    .font(AppFont.bold(13))
                    .foregroundStyle(StoreTheme.textPrimary)
                    .lineLimit(1)
                Text("جاهز للدمج")
                    .font(AppFont.regular(10.5))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 15)
        .frame(height: 64)
        .background(StoreTheme.surface.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private var progressCard: some View {
        VStack(spacing: 10) {
            ProgressView(value: center.progress)
                .tint(accent)
            HStack {
                Text("\(Int(center.progress * 100))%")
                    .font(AppFont.bold(11))
                    .foregroundStyle(accent)
                Spacer()
                Text(center.statusText.isEmpty ? "جاري التجهيز" : center.statusText)
                    .font(AppFont.medium(12))
                    .foregroundStyle(StoreTheme.textSecondary)
            }
        }
        .padding(15)
        .background(StoreTheme.surface.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func errorCard(_ text: String) -> some View {
        Text(text)
            .font(AppFont.medium(11.5))
            .foregroundStyle(Color.red)
            .multilineTextAlignment(.center)
            .padding(13)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReadyDylibPickerSheet: View {
    @ObservedObject var model: AppDylibMergeModel
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showZipPicker = false
    @State private var zipChoiceConfirmed = false

    private var filtered: [StoreApp] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.catalog }
        return model.catalog.filter {
            [$0.name, $0.version ?? ""]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 11) {
                    if model.loadingCatalog {
                        ProgressView().tint(accent).padding(.top, 60)
                    } else {
                        ForEach(filtered) { item in
                            Button {
                                model.inspectReady(item) { outcome in
                                    switch outcome {
                                    case .direct:
                                        dismiss()
                                    case .zip:
                                        showZipPicker = true
                                    }
                                }
                            } label: {
                                HStack(spacing: 13) {
                                    AppIconView(app: item, size: 58)

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name)
                                            .font(AppFont.black(15))
                                            .foregroundStyle(StoreTheme.textPrimary)
                                            .lineLimit(1)
                                        Text("v\(item.version ?? "—")")
                                            .font(AppFont.regular(11.5))
                                            .foregroundStyle(StoreTheme.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Image(systemName: model.selectedReadyItem?.id == item.id ? "checkmark.circle.fill" : "chevron.right")
                                        .foregroundStyle(model.selectedReadyItem?.id == item.id ? accent : StoreTheme.textSecondary)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 82)
                                .background(StoreTheme.surface.opacity(0.90))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(model.selectedReadyItem?.id == item.id ? accent.opacity(0.75) : StoreTheme.surfaceBorder.opacity(0.75), lineWidth: 0.8)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.inspectingAsset)
                        }
                    }
                    Color.clear.frame(height: 70)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .navigationTitle("Dylib جاهز")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "بحث")
            .overlay(alignment: .bottom) {
                if model.inspectingAsset {
                    VStack(spacing: 8) {
                        ProgressView(value: model.assetProgress)
                            .tint(accent)
                        Text("جاري تحميل الملف · \(Int(model.assetProgress * 100))%")
                            .font(AppFont.medium(11.5))
                            .foregroundStyle(StoreTheme.textSecondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(16)
                }
            }
            .task { await model.loadCatalogIfNeeded() }
        }
        .sheet(isPresented: $showZipPicker, onDismiss: {
            if zipChoiceConfirmed {
                dismiss()
            }
        }) {
            ZipDylibPickerSheet(model: model, accent: accent) {
                zipChoiceConfirmed = true
                showZipPicker = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }
}

private struct ZipDylibPickerSheet: View {
    @ObservedObject var model: AppDylibMergeModel
    let accent: Color
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 12) {
                    Text("اختر ملفات Dylib من الحزمة")
                        .font(AppFont.black(20))
                        .foregroundStyle(StoreTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Text("لن يتم حقن أي ملف تلقائياً. حدد ملفًا واحدًا أو أكثر ثم اضغط اعتماد الاختيار.")
                        .font(AppFont.regular(12))
                        .foregroundStyle(StoreTheme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineSpacing(5)

                    ForEach(model.zipEntries) { entry in
                        Button {
                            model.toggleZip(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.selectedZipIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(model.selectedZipIDs.contains(entry.id) ? accent : StoreTheme.tabInactive)
                                Spacer()
                                Text(entry.name)
                                    .font(AppFont.medium(13))
                                    .foregroundStyle(StoreTheme.textPrimary)
                                    .lineLimit(1)
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundStyle(accent)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 58)
                            .background(StoreTheme.surface.opacity(0.90))
                            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onConfirm()
                    } label: {
                        Text("اعتماد الاختيار (\(model.selectedZipIDs.count))")
                            .font(AppFont.black(15))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(model.selectedZipIDs.isEmpty ? StoreTheme.textSecondary.opacity(0.42) : accent)
                            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selectedZipIDs.isEmpty)
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .background(StoreTheme.background.ignoresSafeArea())
            .navigationTitle("محتويات ZIP")
            .navigationBarTitleDisplayMode(.inline)
        }
        
         .environment(\.layoutDirection, StoreLanguage.isEnglish ? .leftToRight : .rightToLeft)
    }
}
