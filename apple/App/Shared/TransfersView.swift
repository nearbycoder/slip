import SlipKit
import SwiftUI
#if os(iOS)
import QuickLook
#endif

/// Transfers/History: progress per file, speed, open / reveal.
struct TransfersView: View {
    @Environment(SlipController.self) private var controller
    #if os(iOS)
    @State private var previewURL: URL?
    #endif

    var body: some View {
        Group {
            if controller.transfers.isEmpty {
                ContentUnavailableView("No transfers yet", systemImage: "arrow.up.arrow.down",
                                       description: Text("Files you send and receive show up here."))
            } else {
                List {
                    ForEach(controller.transfers) { transfer in
                        Section {
                            TransferHeader(transfer: transfer)
                            ForEach(transfer.files) { file in
                                FileRow(file: file, direction: transfer.direction) { url in open(url) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItem {
                Button("Clear finished") { controller.clearFinishedTransfers() }
                    .disabled(!controller.transfers.contains { $0.status.isFinished })
            }
        }
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
    }

    private func open(_ url: URL) {
        #if os(macOS)
        Platform.open(url)
        #else
        previewURL = url
        #endif
    }
}

private struct TransferHeader: View {
    @Environment(SlipController.self) private var controller
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DeviceIcon(type: transfer.peerDeviceType, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(transfer.direction == .incoming ? "From" : "To") \(transfer.peerAlias)").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Label(transfer.status.label, systemImage: transfer.status.symbolName)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(transfer.status.tint)
                    .help(transfer.status.label)
                if !transfer.status.isFinished {
                    Button("Cancel", role: .destructive) { controller.cancel(transfer) }
                        .buttonStyle(.borderless)
                }
                #if os(macOS)
                if transfer.direction == .incoming, transfer.status.isFinished, let dir = transfer.saveDirectory {
                    Button { Platform.reveal(transfer.files.compactMap(\.url).first ?? dir) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                #endif
            }
            if !transfer.status.isFinished {
                ProgressView(value: transfer.fraction).tint(Color.slipGreen)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = ["\(transfer.files.count) file\(transfer.files.count == 1 ? "" : "s")",
                     "\(Format.bytes(transfer.transferredBytes)) of \(Format.bytes(transfer.totalBytes))"]
        if transfer.status == .inProgress || transfer.status == .completed, transfer.bytesPerSecond > 0 {
            parts.append(Format.speed(transfer.bytesPerSecond))
        }
        if transfer.status.isFinished { parts.append(transfer.status.label) }
        return parts.joined(separator: " · ")
    }
}

private struct FileRow: View {
    let file: TransferFile
    let direction: TransferDirection
    let open: (URL) -> Void

    var body: some View {
        HStack {
            Image(systemName: file.status.symbolName).foregroundStyle(file.status.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                if file.status == .inProgress {
                    ProgressView(value: file.fraction).tint(Color.slipGreen)
                } else if case .failed(let reason) = file.status {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Text(Format.bytes(file.size)).font(.caption).foregroundStyle(.secondary)
            if direction == .incoming, file.status == .completed, let url = file.url {
                Button { open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Open")
                #if os(macOS)
                Button { Platform.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                #else
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                #endif
            }
        }
        .font(.callout)
    }
}
