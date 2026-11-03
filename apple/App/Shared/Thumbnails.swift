import QuickLookThumbnailing
import SlipKit
import SwiftUI

/// QuickLook thumbnail for a local file, falling back to its type glyph while loading
/// or when the file has no visual representation.
struct FileThumbnail: View {
    let url: URL?
    let fileName: String
    var mimeType: String?
    var size: CGFloat = 28
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if FileKind.symbol(fileName: fileName, mimeType: mimeType) == "film" {
                            Image(systemName: "play.fill")
                                .font(.system(size: size * 0.22, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 1)
                                .padding(size * 0.1)
                        }
                    }
                    .transition(.opacity)
            } else {
                FileGlyph(fileName: fileName, mimeType: mimeType, size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let url, ThumbnailCache.isVisual(fileName: fileName, mimeType: mimeType) else { return }
        let pixels = CGSize(width: size, height: size)
        if let cached = ThumbnailCache.shared.image(for: url, size: size) {
            image = cached
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: pixels, scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
        ThumbnailCache.shared.store(rep.cgImage, for: url, size: size)
        withAnimation(.easeOut(duration: 0.2)) { image = rep.cgImage }
    }
}

extension FileThumbnail {
    init(item: SendItem, size: CGFloat = 28) {
        if case .file(let url) = item.source {
            self.init(url: url, fileName: item.fileName, mimeType: item.mimeType, size: size)
        } else {
            self.init(url: nil, fileName: item.fileName, mimeType: item.mimeType, size: size)
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    func image(for url: URL, size: CGFloat) -> CGImage? { cache.object(forKey: key(url, size)) }
    func store(_ image: CGImage, for url: URL, size: CGFloat) { cache.setObject(image, forKey: key(url, size)) }
    private func key(_ url: URL, _ size: CGFloat) -> NSString { "\(url.path)#\(Int(size))" as NSString }

    static func isVisual(fileName: String, mimeType: String?) -> Bool {
        ["photo", "film", "doc.richtext", "rectangle.on.rectangle.angled"].contains(FileKind.symbol(fileName: fileName, mimeType: mimeType))
    }
}
