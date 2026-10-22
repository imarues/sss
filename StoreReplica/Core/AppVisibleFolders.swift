import Foundation

enum AppVisibleFolders {
    private static let fm = FileManager.default

    static var root: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var apps: URL { root.appendingPathComponent("Apps", isDirectory: true) }
    static var games: URL { root.appendingPathComponent("Games", isDirectory: true) }
    static var dylib: URL { root.appendingPathComponent("Dyilb", isDirectory: true) }

    static func ensure() {
        for folder in [apps, games, dylib] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: folder.path
            )
        }
    }

    static func appFolder(isGame: Bool) -> URL {
        ensure()
        return isGame ? games : apps
    }

    @discardableResult
    static func mirrorFile(from source: URL, to folder: URL, fileName: String) -> URL? {
        ensure()
        let safeName = sanitize(fileName)
        let destination = folder.appendingPathComponent(safeName, isDirectory: false)

        if fm.fileExists(atPath: destination.path) {
            let sourceSize = ((try? fm.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value
            let destinationSize = ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value
            if sourceSize != nil, sourceSize == destinationSize { return destination }
            try? fm.removeItem(at: destination)
        }

        do {
            try fm.linkItem(at: source, to: destination)
        } catch {
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                return nil
            }
        }

        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = value
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "download" }
        return String(cleaned.prefix(180))
    }
}
