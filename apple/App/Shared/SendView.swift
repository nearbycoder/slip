import SlipKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#else
import AppKit
#endif

#if os(iOS)
/// iOS Send tab: nearby devices with a floating glass selection tray.
struct SendView: View {
    @Environment(SlipController.self) private var controller
    @Environment(SendSelection.self) private var selection
    @State private var showingText = false
    @State private var showingManual = false
    @State private var alert: String?
    @State private var showingImporter = false
    @State private var importFolders = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var nudge = 0

    var body: some View {
        List {
            Section {
                if controller.peers.isEmpty {
                    ContentUnavailableView {
                        Label(controller.isScanning ? "Looking for Devices…" : "No Devices Nearby",
                              systemImage: "dot.radiowaves.left.and.right")
                            .symbolEffect(.variableColor.iterative, isActive: controller.isScanning)
                    } description: {
                        Text("Open Slip or LocalSend on another device on the same Wi-Fi network.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(controller.peers) { peer in
                    IOSDeviceRow(peer: peer, canSend: !selection.isEmpty) { send(to: peer) }
                }
            } header: {
                if !controller.peers.isEmpty { Text("Nearby") }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await controller.scan() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tray
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .navigationTitle("Send")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Send to IP Address", systemImage: "network") { showingManual = true }
                Button("Refresh", systemImage: "arrow.clockwise") { controller.refresh() }
                    .disabled(controller.isScanning)
            }
        }
        .sheet(isPresented: $showingText) { TextComposer { selection.addText($0) } }
        .sheet(isPresented: $showingManual) { ManualPeerView().presentationDetents([.medium]) }
        .alert("Slip", isPresented: Binding(get: { alert != nil || selection.lastError != nil },
                                             set: { if !$0 { alert = nil; selection.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? selection.lastError ?? "")
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importFolders ? [.folder] : [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addImported(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .sensoryFeedback(.warning, trigger: nudge)
    }

    // MARK: Tray

    @ViewBuilder
    private var tray: some View {
        if selection.isEmpty {
            SlipGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                        SourceButtonLabel(title: loadingPhotos ? "Loading…" : "Photos", symbol: "photo.on.rectangle")
                    }
                    Menu {
                        Button("Files", systemImage: "doc") { importFolders = false; showingImporter = true }
                        Button("Folder", systemImage: "folder") { importFolders = true; showingImporter = true }
                    } label: {
                        SourceButtonLabel(title: "Files", symbol: "doc")
                    }
                    Button { showingText = true } label: { SourceButtonLabel(title: "Text", symbol: "text.bubble") }
                    Button { Platform.paste(into: selection) } label: { SourceButtonLabel(title: "Paste", symbol: "doc.on.clipboard") }
                }
                .buttonStyle(.plain)
            }
            .phaseAnimator([false, true], trigger: nudge) { content, up in
                content.offset(y: up ? -6 : 0)
            } animation: { _ in .bouncy(duration: 0.25) }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selection.items) { item in
                            IOSSelectionChip(item: item) { withAnimation(.snappy) { selection.remove(item) } }
                        }
                    }
                }
                HStack {
                    Text("\(selection.items.count) item\(selection.items.count == 1 ? "" : "s") · \(Format.bytes(selection.totalSize))")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    Spacer()
                    Menu {
                        PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        Button("Files", systemImage: "doc") { importFolders = false; showingImporter = true }
                        Button("Folder", systemImage: "folder") { importFolders = true; showingImporter = true }
                        Button("Text", systemImage: "text.bubble") { showingText = true }
                        Button("Paste", systemImage: "doc.on.clipboard") { Platform.paste(into: selection) }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Button("Clear", systemImage: "xmark") { withAnimation(.snappy) { selection.clear() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                }
            }
            .padding(14)
            .slipGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    // MARK: Actions

    private func send(to peer: DiscoveredPeer) {
        guard !selection.isEmpty else {
            nudge += 1
            return
        }
        controller.send(selection.itemsForSending(), to: peer)
    }

    /// Copies security-scoped picks into a temporary outbox so they stay readable.
    private func addImported(_ urls: [URL]) {
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("Outbox/\(UUID().uuidString)", isDirectory: true)
        var copies: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
                let dest = outbox.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                copies.append(dest)
            } catch {
                alert = error.localizedDescription
            }
        }
        selection.add(urls: copies)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        loadingPhotos = true
        defer {
            loadingPhotos = false
            photoItems = []
        }
        for item in items {
            if let file = try? await item.loadTransferable(type: PickedFile.self) {
                selection.add(urls: [file.url])
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                selection.add(.data(data, fileName: "Photo-\(UUID().uuidString.prefix(8)).\(ext)"))
            }
        }
    }
}

private struct SourceButtonLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.slipGreen)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
        .slipGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
    }
}

private struct IOSDeviceRow: View {
    let peer: DiscoveredPeer
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        Button(action: onSend) {
            HStack(spacing: 14) {
                DeviceAvatar(peer: peer, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.info.alias).font(.headline).foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        Text(peer.info.deviceModel ?? peer.ip)
                        if peer.info.protocol == .http { Image(systemName: "lock.open") }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if SendFeedback.shared.justSent.contains(peer.info.alias) {
                    Label("Sent", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.slipGreen)
                        .transition(.scale.combined(with: .opacity))
                } else if canSend {
                    Text("Send")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.slipGreen, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: canSend)
        .accessibilityHint(canSend ? "Sends your selection to \(peer.info.alias)" : "Choose something to send first")
    }
}

private struct IOSSelectionChip: View {
    let item: SendItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if item.preview != nil {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.slipGreen)
            } else {
                FileThumbnail(item: item, size: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName).font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .leading)
                Text(Format.bytes(item.size)).font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.displayName)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}
#endif

#if os(iOS)
/// A photo/video exported to a temporary file (avoids loading videos into memory).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Outbox/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}
#endif

struct TextComposer: View {
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Type a message or paste a link", text: $text, axis: .vertical)
                    .lineLimit(5...12)
                    .font(.body)
                    .focused($focused)
                    .padding(14)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Message")
                HStack {
                    Button("Paste", systemImage: "doc.on.clipboard") { pasteClipboard() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                Text("Text arrives as a message on the other device. LocalSend shows it too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(20)
            #if os(macOS)
            .frame(width: 440, height: 300)
            #endif
            .navigationTitle("Send Text")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(text)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func pasteClipboard() {
        #if os(macOS)
        if let s = NSPasteboard.general.string(forType: .string) { text += s }
        #else
        if let s = UIPasteboard.general.string { text += s }
        #endif
    }
}

struct ManualPeerView: View {
    @Environment(SlipController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("IP address", text: $host)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("Port", text: $port, prompt: Text(verbatim: "\(controller.settings.port)"))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320)
            .navigationTitle("Send to IP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Connecting…" : "Add device") { connect() }
                        .disabled(host.isEmpty || busy)
                }
            }
        }
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await controller.addPeer(host: host.trimmingCharacters(in: .whitespaces), port: Int(port), transport: nil)
                dismiss()
            } catch {
                self.error = "Could not reach \(host): \(error.localizedDescription)"
            }
        }
    }
}
