import SlipKit
import SwiftUI

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

/// Rounded device glyph used across the UI.
struct DeviceIcon: View {
    let type: DeviceType
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: type.symbolName)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.slipGreen.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct DeviceRow: View {
    let peer: DiscoveredPeer

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(type: peer.info.deviceType ?? .desktop)
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
