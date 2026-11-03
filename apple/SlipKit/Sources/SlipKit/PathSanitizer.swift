import Foundation

/// Turns a peer-supplied `fileName` (which may contain `/` for folder sends) into a safe
/// relative path below the save directory.
public enum PathSanitizer {
    /// Sanitised path segments. Never empty, never contains `.`/`..`, never absolute.
    public static func segments(of fileName: String) -> [String] {
        let illegal = CharacterSet(charactersIn: "\\:\0").union(.controlCharacters)
        var result: [String] = []
        for raw in fileName.split(separator: "/", omittingEmptySubsequences: true) {
            var segment = String(String.UnicodeScalarView(raw.unicodeScalars.map { illegal.contains($0) ? "_" : $0 }))
            segment = segment.trimmingCharacters(in: .whitespaces)
            if segment.isEmpty || segment == "." || segment == ".." { continue }
            // Keep each segment within the usual 255-byte limit.
            while segment.utf8.count > 255 { segment.removeFirst() }
            result.append(segment)
        }
        if result.isEmpty { result = ["file"] }
        return result
    }

    public static func relativePath(of fileName: String) -> String {
        segments(of: fileName).joined(separator: "/")
    }

    /// Resolves a destination URL inside `directory` for `fileName`, creating intermediate
    /// directories and appending ` (1)`, ` (2)`, … before the extension if the target exists.
    public static func uniqueDestination(for fileName: String, in directory: URL,
                                         fileManager: FileManager = .default) throws -> URL {
        let segs = segments(of: fileName)
        var parent = directory
        for dir in segs.dropLast() { parent.appendPathComponent(dir, isDirectory: true) }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        return uniqueFile(named: segs.last!, in: parent, fileManager: fileManager)
    }

    public static func uniqueFile(named name: String, in parent: URL, fileManager: FileManager = .default) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || (name as NSString).deletingPathExtension.isEmpty
            ? name : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : ".\(ext)"
        var n = 1
        repeat {
            candidate = parent.appendingPathComponent("\(stem) (\(n))\(suffix)", isDirectory: false)
            n += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}
