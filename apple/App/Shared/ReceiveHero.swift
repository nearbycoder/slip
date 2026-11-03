import SlipKit
import SwiftUI

/// The Slip app icon drawn in SwiftUI (matches assets/icon.svg), so it stays crisp at any size.
struct SlipLogo: View {
    var size: CGFloat = 76

    var body: some View {
        Canvas { ctx, canvas in
            let s = canvas.width / 1024
            let rect = CGRect(origin: .zero, size: canvas)
            let squircle = Path(roundedRect: rect, cornerRadius: 232 * s, style: .continuous)
            ctx.fill(squircle, with: .linearGradient(
                Gradient(stops: [.init(color: Color(hex: 0x3EE08A), location: 0),
                                 .init(color: Color(hex: 0x17A74C), location: 0.55),
                                 .init(color: Color(hex: 0x0B7A39), location: 1)]),
                startPoint: CGPoint(x: canvas.width * 0.15, y: 0), endPoint: CGPoint(x: canvas.width * 0.85, y: canvas.height)))
            ctx.fill(squircle, with: .radialGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0)]),
                                                      center: CGPoint(x: canvas.width * 0.28, y: canvas.height * 0.18),
                                                      startRadius: 0, endRadius: canvas.width * 0.75))
            let style = StrokeStyle(lineWidth: 120 * s, lineCap: .round, lineJoin: .round)
            var top = Path()
            top.move(to: CGPoint(x: 606 * s, y: 296 * s))
            top.addLine(to: CGPoint(x: 410 * s, y: 296 * s))
            top.addArc(center: CGPoint(x: 410 * s, y: 404 * s), radius: 108 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            top.addLine(to: CGPoint(x: 440 * s, y: 512 * s))
            ctx.stroke(top, with: .color(.white.opacity(0.55)), style: style)
            var bottom = Path()
            bottom.move(to: CGPoint(x: 584 * s, y: 512 * s))
            bottom.addLine(to: CGPoint(x: 614 * s, y: 512 * s))
            bottom.addArc(center: CGPoint(x: 614 * s, y: 620 * s), radius: 108 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            bottom.addLine(to: CGPoint(x: 418 * s, y: 728 * s))
            var shadowCtx = ctx
            shadowCtx.addFilter(.shadow(color: .black.opacity(0.25), radius: 14 * s, y: 14 * s))
            shadowCtx.stroke(bottom, with: .color(.white), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Glass disc with the Slip logo and radar pulses while this device is visible.
struct ReceiveHero: View {
    @Environment(SlipController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: Bool { controller.isRunning && controller.serverError == nil && controller.settings.discoverable }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if live && !reduceMotion {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        ZStack {
                            ForEach(0..<3, id: \.self) { i in
                                let phase = (t / 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                                Circle()
                                    .stroke(Color.slipGreen.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                                    .frame(width: 112, height: 112)
                                    .scaleEffect(1 + phase * 1.15)
                            }
                        }
                    }
                }
                Circle()
                    .fill(Color.slipGreen.opacity(live ? 0.22 : 0.06))
                    .frame(width: 150, height: 150)
                    .blur(radius: 30)
                SlipLogo(size: 72)
                    .frame(width: 112, height: 112)
                    .slipGlass(in: Circle(), tint: Color.slipGreen.opacity(live ? 0.2 : 0.04))
                    .saturation(live ? 1 : 0)
            }
            .frame(height: 200)

            VStack(spacing: 8) {
                Text(controller.settings.alias)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 7) {
                    Circle()
                        .fill(live ? Color.slipGreen : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(live ? "Visible to nearby devices" : (controller.isRunning ? "Hidden from nearby devices" : "Starting…"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .slipGlass(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .textCase(nil)
        .animation(.smooth, value: live)
    }
}

/// The last few files received, with quick Open / Show in Finder (macOS) or Share (iOS).
struct RecentlyReceived: View {
    @Environment(SlipController.self) private var controller
    var open: (URL) -> Void = { _ in }

    private var files: [(file: TransferFile, from: String)] {
        controller.transfers
            .filter { $0.direction == .incoming }
            .flatMap { t in t.files.filter { $0.status == .completed }.map { ($0, t.peerAlias) } }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        if !files.isEmpty {
            Section("Recently Received") {
                ForEach(files, id: \.file.id) { entry in
                    HStack(spacing: 10) {
                        FileGlyph(fileName: entry.file.name, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((entry.file.name as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text("From \(entry.from) · \(Format.bytes(entry.file.size))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = entry.file.url {
                            #if os(macOS)
                            Button("Open") { open(url) }
                            Button("Show in Finder", systemImage: "magnifyingglass") { Platform.reveal(url) }
                                .labelStyle(.iconOnly)
                                .help("Show in Finder")
                            #else
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            #endif
                        }
                    }
                    .buttonStyle(.borderless)
                    #if os(iOS)
                    .contentShape(Rectangle())
                    .onTapGesture { if let url = entry.file.url { open(url) } }
                    #endif
                }
            }
        }
    }
}

/// Received text messages with Copy.
struct MessagesSection: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        if !controller.messages.isEmpty {
            Section("Messages") {
                ForEach(controller.messages) { m in
                    HStack(alignment: .top, spacing: 12) {
                        DeviceAvatar(alias: m.senderAlias, type: .mobile, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.text).textSelection(.enabled)
                            Text("\(m.senderAlias) · \(m.date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { Platform.copy(m.text) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
