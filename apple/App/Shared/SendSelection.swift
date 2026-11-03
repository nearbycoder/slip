import Foundation
import Observation
import SlipKit

/// The Send tab's selection tray.
@MainActor
@Observable
final class SendSelection {
    var items: [SendItem] = []
    var lastError: String?

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty }

    func add(urls: [URL]) {
        do {
            let new = try SendItem.items(for: urls)
            items.append(contentsOf: new.filter { n in !items.contains { $0.source == n.source && $0.fileName == n.fileName } })
        } catch {
            lastError = error.localizedDescription
        }
    }

    func add(_ item: SendItem) { items.append(item) }

    func addText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(.text(text))
    }

    func remove(_ item: SendItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    /// Fresh ids so the same selection can be sent to several devices.
    func itemsForSending() -> [SendItem] {
        items.map {
            SendItem(fileName: $0.fileName, size: $0.size, mimeType: $0.mimeType, modified: $0.modified,
                     source: $0.source, preview: $0.preview)
        }
    }
}

extension SendItem {
    var displayName: String { preview.map { "“\($0.prefix(40))”" } ?? fileName }
    var symbolName: String {
        if preview != nil { return "text.bubble" }
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if fileName.contains("/") { return "folder" }
        return "doc"
    }
}
