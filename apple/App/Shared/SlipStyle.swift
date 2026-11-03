import SlipKit
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// Brand green #16a34a.
    static let slipGreen = Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255)
}

extension DeviceType {
    var symbolName: String {
        switch self {
        case .mobile: return "iphone"
        case .desktop: return "desktopcomputer"
        case .web: return "globe"
        case .headless: return "terminal"
        case .server: return "server.rack"
        }
    }
}

/// The most specific SF Symbol for a peer, using its model string when it names a platform.
enum DeviceSymbol {
    static func name(type: DeviceType, model: String?) -> String {
        let m = (model ?? "").lowercased()
        if m.contains("ipad") { return "ipad" }
        if m.contains("iphone") || m.contains("ios") { return "iphone" }
        if m.contains("mac") { return "laptopcomputer" }
        if m.contains("windows") { return "pc" }
        if m.contains("linux") || m.contains("ubuntu") || m.contains("fedora") { return "desktopcomputer" }
        if type == .mobile { return "smartphone" }
        return type.symbolName
    }
}

/// A stable avatar colour per device: aliases end in a fruit or vegetable, so use its colour.
enum AliasColor {
    private static let produce: [String: (Color, Color)] = [
        "apple": (.init(hex: 0xF87171), .init(hex: 0xDC2626)),
        "avocado": (.init(hex: 0xA3E635), .init(hex: 0x4D7C0F)),
        "banana": (.init(hex: 0xFDE047), .init(hex: 0xEAB308)),
        "blackberry": (.init(hex: 0x818CF8), .init(hex: 0x3730A3)),
        "blueberry": (.init(hex: 0x60A5FA), .init(hex: 0x1D4ED8)),
        "broccoli": (.init(hex: 0x4ADE80), .init(hex: 0x15803D)),
        "carrot": (.init(hex: 0xFDBA74), .init(hex: 0xEA580C)),
        "cherry": (.init(hex: 0xFB7185), .init(hex: 0xBE123C)),
        "coconut": (.init(hex: 0xD6B48A), .init(hex: 0x8B5E34)),
        "grape": (.init(hex: 0xC084FC), .init(hex: 0x7E22CE)),
        "lemon": (.init(hex: 0xFDE68A), .init(hex: 0xF59E0B)),
        "lettuce": (.init(hex: 0xBEF264), .init(hex: 0x65A30D)),
        "mango": (.init(hex: 0xFCD34D), .init(hex: 0xF97316)),
        "melon": (.init(hex: 0x86EFAC), .init(hex: 0x16A34A)),
        "mushroom": (.init(hex: 0xD6D3D1), .init(hex: 0x78716C)),
        "onion": (.init(hex: 0xF0ABFC), .init(hex: 0xA21CAF)),
        "orange": (.init(hex: 0xFDBA74), .init(hex: 0xF97316)),
        "papaya": (.init(hex: 0xFDBA74), .init(hex: 0xE11D48)),
        "peach": (.init(hex: 0xFECACA), .init(hex: 0xFB7185)),
        "pear": (.init(hex: 0xD9F99D), .init(hex: 0x84CC16)),
        "pineapple": (.init(hex: 0xFDE047), .init(hex: 0xCA8A04)),
        "potato": (.init(hex: 0xE7C9A0), .init(hex: 0xA16207)),
        "pumpkin": (.init(hex: 0xFDBA74), .init(hex: 0xC2410C)),
        "raspberry": (.init(hex: 0xF9A8D4), .init(hex: 0xDB2777)),
        "strawberry": (.init(hex: 0xFCA5A5), .init(hex: 0xE11D48)),
        "tomato": (.init(hex: 0xFCA5A5), .init(hex: 0xDC2626)),
    ]
    private static let fallback: [(Color, Color)] = [
        (.init(hex: 0x86EFAC), .init(hex: 0x16A34A)), (.init(hex: 0x93C5FD), .init(hex: 0x2563EB)),
        (.init(hex: 0xFDBA74), .init(hex: 0xEA580C)), (.init(hex: 0xC4B5FD), .init(hex: 0x7C3AED)),
        (.init(hex: 0xF9A8D4), .init(hex: 0xDB2777)), (.init(hex: 0x67E8F9), .init(hex: 0x0891B2)),
    ]

    static func gradient(for alias: String) -> LinearGradient {
        let word = alias.split(separator: " ").last.map { $0.lowercased() } ?? ""
        let pair = produce[word] ?? fallback[Int(alias.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) % fallback.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Round avatar for a device: its alias colour with the device's symbol.
struct DeviceAvatar: View {
    let alias: String
    let type: DeviceType
    var model: String?
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(AliasColor.gradient(for: alias))
            .overlay {
                Image(systemName: DeviceSymbol.name(type: type, model: model))
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension DeviceAvatar {
    init(peer: DiscoveredPeer, size: CGFloat = 40) {
        self.init(alias: peer.info.alias, type: peer.info.deviceType ?? .desktop, model: peer.info.deviceModel, size: size)
    }

    init(info: DeviceInfo, size: CGFloat = 40) {
        self.init(alias: info.alias, type: info.deviceType ?? .desktop, model: info.deviceModel, size: size)
    }
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func speed(_ bps: Double) -> String { bytes(Int64(bps)) + "/s" }

    /// "About 2 min left", or nil when there isn't enough data yet.
    static func remaining(bytes: Int64, speed: Double) -> String? {
        guard speed > 1, bytes > 0 else { return nil }
        let seconds = Double(bytes) / speed
        if seconds < 5 { return "Almost done" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        f.maximumUnitCount = 2
        return f.string(from: seconds).map { "About \($0) left" }
    }

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// SF Symbol and tint for a file, from its name / MIME type.
enum FileKind {
    static func symbol(fileName: String, mimeType: String? = nil) -> String {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
            ?? mimeType.flatMap { UTType(mimeType: $0) }
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    static func tint(fileName: String, mimeType: String? = nil) -> Color {
        switch symbol(fileName: fileName, mimeType: mimeType) {
        case "photo": return .orange
        case "film": return .purple
        case "waveform": return .pink
        case "doc.richtext": return .red
        case "tablecells": return .green
        case "rectangle.on.rectangle.angled": return .orange
        case "doc.zipper": return .brown
        case "chevron.left.forwardslash.chevron.right": return .indigo
        default: return .blue
        }
    }
}

/// Small rounded tile with a file's type symbol.
struct FileGlyph: View {
    let fileName: String
    var mimeType: String?
    var size: CGFloat = 28

    var body: some View {
        let tint = FileKind.tint(fileName: fileName, mimeType: mimeType)
        Image(systemName: FileKind.symbol(fileName: fileName, mimeType: mimeType))
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension TransferStatus {
    var tint: Color {
        switch self {
        case .completed: return .slipGreen
        case .failed, .declined: return .red
        case .cancelled: return .secondary
        case .waiting, .inProgress: return .accentColor
        }
    }

    var symbolName: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .declined: return "hand.raised.fill"
        case .cancelled: return "xmark.circle.fill"
        case .waiting: return "hourglass"
        case .inProgress: return "arrow.up.arrow.down.circle"
        }
    }
}

struct DeviceRow: View {
    let peer: DiscoveredPeer

    var body: some View {
        HStack(spacing: 12) {
            DeviceAvatar(peer: peer)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.info.alias).font(.headline)
                Text([peer.info.deviceModel, peer.ip].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if peer.info.protocol == .http {
                Image(systemName: "lock.open").foregroundStyle(.secondary).help("Unencrypted (HTTP)")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
