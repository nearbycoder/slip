import SlipKit
import SwiftUI
#if os(iOS)
import QuickLook
#endif

/// Transfers/History: one card per transfer with progress, speed, time left and file actions.
struct TransfersView: View {
    @Environment(SlipController.self) private var controller
    #if os(iOS)
    @State private var previewURL: URL?
    #endif

    var body: some View {
        Group {
            if controller.transfers.isEmpty {
                ContentUnavailableView {
                    Label("No Transfers Yet", systemImage: "arrow.up.arrow.down")
                } description: {
                    Text("Files you send and receive will appear here.")
                }
            } else {
                Form {
                    ForEach(controller.transfers) { transfer in
                        TransferSection(transfer: transfer, open: open)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Transfers")
        #if os(macOS)
        .navigationSubtitle(subtitle)
        #endif
        .toolbar {
            ToolbarItem {
                Button("Clear Finished", systemImage: "trash") { withAnimation { controller.clearFinishedTransfers() } }
                    .disabled(!controller.transfers.contains { $0.status.isFinished })
                    .help("Remove finished transfers from the list")
            }
        }
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
    }

    private var subtitle: String {
        let active = controller.activeTransfers.count
        if active > 0 { return "\(active) in progress" }
        return controller.transfers.isEmpty ? "" : "\(controller.transfers.count) recent"
    }

    private func open(_ url: URL) {
        #if os(macOS)
        Platform.open(url)
        #else
        previewURL = url
        #endif
    }
}

private struct TransferSection: View {
    @Environment(SlipController.self) private var controller
    let transfer: Transfer
    let open: (URL) -> Void
    @State private var expanded: Bool?

    private var active: Bool { !transfer.status.isFinished }
    private var showFiles: Bool { expanded ?? active }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(transfer.status.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    actions
                }
                if active {
                    ProgressView(value: transfer.fraction)
                        .tint(Color.slipGreen)
                        .animation(.linear(duration: 0.25), value: transfer.fraction)
                }
            }
            .padding(.vertical, 4)

            Button {
                withAnimation(.snappy) { expanded = !showFiles }
            } label: {
                HStack {
                    Text("\(transfer.files.count) file\(transfer.files.count == 1 ? "" : "s") · \(Format.bytes(transfer.totalBytes))")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showFiles ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showFiles ? "Hide files" : "Show files")

            if showFiles {
                ForEach(transfer.files) { file in
                    FileRow(file: file, direction: transfer.direction, open: open)
                }
            }
        }
    }

    private var avatar: some View {
        DeviceAvatar(alias: transfer.peerAlias, type: transfer.peerDeviceType, model: transfer.peerModel, size: 42)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: transfer.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, transfer.status.isFailure ? Color.red : Color.slipGreen)
                    .background(Circle().fill(.background).padding(-1.5))
                    .offset(x: 3, y: 3)
            }
    }

    @ViewBuilder
    private var actions: some View {
        if active {
            Button("Cancel", role: .cancel) { controller.cancel(transfer) }
                .buttonStyle(.bordered)
                .help("Cancel transfer")
        } else {
            #if os(macOS)
            if transfer.direction == .incoming, transfer.status == .completed, let dir = transfer.saveDirectory {
                Button("Show in Finder") {
                    Platform.reveal(transfer.files.compactMap(\.url).first ?? dir)
                }
                .buttonStyle(.bordered)
            } else {
                statusBadge
            }
            #else
            statusBadge
            #endif
        }
    }

    private var statusBadge: some View {
        Image(systemName: transfer.status.symbolName)
            .font(.title3)
            .foregroundStyle(transfer.status.tint)
            .help(transfer.status.label)
            .accessibilityLabel(transfer.status.label)
    }

    private var title: String {
        let name = transfer.peerAlias
        switch (transfer.direction, transfer.status) {
        case (.outgoing, .waiting): return "Waiting for \(name)"
        case (.outgoing, .inProgress): return "Sending to \(name)"
        case (.outgoing, .completed): return "Sent to \(name)"
        case (.outgoing, .declined): return "\(name) declined"
        case (.incoming, .completed): return "Received from \(name)"
        case (.incoming, _) where !transfer.status.isFinished: return "Receiving from \(name)"
        case (.incoming, _): return "From \(name)"
        case (.outgoing, _): return "To \(name)"
        }
    }

    private var subtitle: String {
        switch transfer.status {
        case .waiting:
            return "Waiting for \(transfer.peerAlias) to accept…"
        case .inProgress:
            var parts = ["\(Int(transfer.fraction * 100))%",
                         "\(Format.bytes(transfer.transferredBytes)) of \(Format.bytes(transfer.totalBytes))"]
            if transfer.bytesPerSecond > 0 {
                parts.append(Format.speed(transfer.bytesPerSecond))
                if let left = Format.remaining(bytes: transfer.totalBytes - transfer.transferredBytes, speed: transfer.bytesPerSecond) {
                    parts.append(left)
                }
            }
            return parts.joined(separator: " · ")
        case .completed:
            var parts = [Format.relative(transfer.finishedAt ?? transfer.startedAt)]
            if transfer.bytesPerSecond > 0 { parts.append(Format.speed(transfer.bytesPerSecond)) }
            return parts.joined(separator: " · ")
        case .failed(let reason):
            return reason
        case .declined, .cancelled:
            return "\(transfer.status.label) · \(Format.relative(transfer.finishedAt ?? transfer.startedAt))"
        }
    }
}

private struct FileRow: View {
    let file: TransferFile
    let direction: TransferDirection
    let open: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            FileThumbnail(url: file.url, fileName: file.name, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text((file.name as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                if file.status == .inProgress {
                    ProgressView(value: file.fraction).tint(Color.slipGreen).controlSize(.small)
                } else if case .failed(let reason) = file.status {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            Text(file.status == .inProgress ? "\(Format.bytes(file.transferred)) of \(Format.bytes(file.size))" : Format.bytes(file.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if direction == .incoming, file.status == .completed, let url = file.url {
                Button("Open", systemImage: "arrow.up.forward.app") { open(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open")
                #if os(macOS)
                Button("Show in Finder", systemImage: "magnifyingglass") { Platform.reveal(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                #else
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                #endif
            } else {
                Image(systemName: file.status.symbolName)
                    .foregroundStyle(file.status == .waiting ? .secondary : file.status.tint)
                    .frame(width: 18)
                    .help(file.status.label)
            }
        }
        .font(.callout)
    }
}

extension TransferStatus {
    var isFailure: Bool {
        switch self {
        case .failed, .declined: return true
        default: return false
        }
    }
}
