import SlipKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Small platform shims used by the shared views.
@MainActor
enum Platform {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Adds whatever is on the clipboard (files, image or text) to the selection.
    static func paste(into selection: SendSelection) {
        #if os(macOS)
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            selection.add(urls: urls)
        } else if let image = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            selection.add(.data(image, fileName: "Pasted Image.png", mimeType: "image/png"))
        } else if let s = pb.string(forType: .string) {
            selection.addText(s)
        }
        #else
        let pb = UIPasteboard.general
        if let image = pb.image, let png = image.pngData() {
            selection.add(.data(png, fileName: "Pasted Image.png", mimeType: "image/png"))
        } else if let url = pb.url, url.isFileURL {
            selection.add(urls: [url])
        } else if let s = pb.string {
            selection.addText(s)
        }
        #endif
    }

    #if os(macOS)
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    #endif
}
