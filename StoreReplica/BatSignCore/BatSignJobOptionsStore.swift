import Foundation

/// Persistent signing options modeled after BatSign's SignJob snapshot.
/// Dylibs are copied into Application Support before the IPA download/sign job starts,
/// so no security-scoped or URLSession temporary URL survives into signing.
enum BatSignJobOptionsStore {
    private struct Record: Codable {
        let appID: String
        let dylibPaths: [String]
    }

    private static let fm = FileManager.default
    private static let lock = NSLock()

    private static var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BatSignJobs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func safeID(_ appID: String) -> String {
        Data(appID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func directory(for appID: String) -> URL {
        root.appendingPathComponent(safeID(appID), isDirectory: true)
    }

    private static func recordURL(for appID: String) -> URL {
        directory(for: appID).appendingPathComponent("options.json")
    }

    static func stageDylibs(_ urls: [URL], for appID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let dir = directory(for: appID)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var paths: [String] = []
        var used = Set<String>()
        for source in urls {
            guard source.pathExtension.lowercased() == "dylib" else {
                throw SideloadSigningError.unsupportedDylib(source.lastPathComponent)
            }
            var name = source.lastPathComponent
            if used.contains(name.lowercased()) {
                name = String(UUID().uuidString.prefix(6)) + "-" + name
            }
            used.insert(name.lowercased())
            let target = dir.appendingPathComponent(name)

            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                try fm.copyItem(at: source, to: target)
            } catch {
                let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                try data.write(to: target, options: .atomic)
            }
            paths.append(target.path)
        }

        let record = Record(appID: appID, dylibPaths: paths)
        let data = try JSONEncoder().encode(record)
        try data.write(to: recordURL(for: appID), options: .atomic)
    }

    static func dylibs(for appID: String) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: recordURL(for: appID)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return [] }
        return record.dylibPaths
            .map(URL.init(fileURLWithPath:))
            .filter { fm.fileExists(atPath: $0.path) }
    }

    static func clear(for appID: String) {
        lock.lock()
        defer { lock.unlock() }
        try? fm.removeItem(at: directory(for: appID))
    }
}
