import AppKit
import SlipKit
import SwiftUI

/// Draws transfer progress on the Dock icon and badges a waiting request.
@MainActor
enum DockTile {
    private static let progressView = DockProgressView()

    static func update(fraction: Double?, badge: String?) {
        let tile = NSApp.dockTile
        tile.badgeLabel = badge
        if let fraction {
            progressView.fraction = fraction
            progressView.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = progressView
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let inset = bounds.width * 0.16
        let height = max(8, bounds.height * 0.085)
        let track = NSRect(x: inset, y: bounds.height * 0.13, width: bounds.width - inset * 2, height: height)
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2).fill()
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var filled = track
        filled.size.width = max(height, track.width * min(1, max(0, fraction)))
        NSColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 1).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// Invisible view that keeps the Dock tile in sync with the controller.
struct DockTileSync: View {
    @Environment(SlipController.self) private var controller

    private var state: DockState {
        let active = controller.activeTransfers
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = active.reduce(Int64(0)) { $0 + $1.transferredBytes }
        return DockState(fraction: active.isEmpty ? nil : (total > 0 ? (Double(done) / Double(total) * 50).rounded() / 50 : 0),
                         badge: controller.pendingRequest != nil ? "1" : nil)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: state, initial: true) { _, s in DockTile.update(fraction: s.fraction, badge: s.badge) }
    }

    private struct DockState: Equatable {
        var fraction: Double?
        var badge: String?
    }
}
