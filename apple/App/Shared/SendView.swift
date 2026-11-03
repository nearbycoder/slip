import SlipKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif

/// Send tab: selection tray + nearby devices.
struct SendView: View {
    @Environment(SlipController.self) private var controller
    @Environment(SendSelection.self) private var selection
    @State private var showingText = false
    @State private var showingManual = false
    @State private var alert: String?
    #if os(iOS)
    @State private var showingImporter = false
    @State private var importFolders = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    #endif

    var body: some View {
        List {
            Section {
                selectionButtons
                ForEach(selection.items) { item in
                    HStack {
                        Image(systemName: item.symbolName).foregroundStyle(Color.slipGreen).frame(width: 24)
                        Text(item.displayName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.bytes(item.size)).foregroundStyle(.secondary).font(.caption)
                        #if os(macOS)
                        Button { selection.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                }
                .onDelete { idx in idx.map { selection.items[$0] }.forEach(selection.remove) }
            } header: {
                HStack {
                    Text("Selection")
                    Spacer()
                    if !selection.isEmpty {
                        Text("\(selection.items.count) · \(Format.bytes(selection.totalSize))")
                        Button("Clear") { selection.clear() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }

            Section {
                if controller.peers.isEmpty {
                    HStack {
                        if controller.isScanning { ProgressView().controlSize(.small) }
                        Text(controller.isScanning ? "Looking for devices…" : "No devices found yet")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(controller.peers) { peer in
                    Button { send(to: peer) } label: { DeviceRow(peer: peer) }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .dropDestination(for: URL.self) { urls, _ in
                            send(urls: urls, to: peer)
                            return true
                        }
                        .help("Click to send the selection, or drop files here")
                        #endif
                }
                Button {
                    showingManual = true
                } label: {
                    Label("Send to IP address…", systemImage: "network")
                }
            } header: {
                HStack {
                    Text("Nearby devices")
                    Spacer()
                    Button {
                        controller.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.isScanning)
                }
            }
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            selection.add(urls: urls)
            return true
        }
        #endif
        .navigationTitle("Send")
        .sheet(isPresented: $showingText) {
            TextComposer { selection.addText($0) }
        }
        .sheet(isPresented: $showingManual) {
            ManualPeerView()
        }
        .alert("Slip", isPresented: Binding(get: { alert != nil || selection.lastError != nil },
                                             set: { if !$0 { alert = nil; selection.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? selection.lastError ?? "")
        }
        #if os(iOS)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importFolders ? [.folder] : [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addImported(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        #endif
    }

    @ViewBuilder
    private var selectionButtons: some View {
        #if os(macOS)
        HStack {
            Button { pickFiles() } label: { Label("Files or Folders…", systemImage: "doc.badge.plus") }
            Button { showingText = true } label: { Label("Text", systemImage: "text.bubble") }
            Button { Platform.paste(into: selection) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        }
        .buttonStyle(.bordered)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                    Label(loadingPhotos ? "Loading…" : "Photos", systemImage: "photo.on.rectangle")
                }
                Button { importFolders = false; showingImporter = true } label: { Label("Files", systemImage: "doc") }
                Button { importFolders = true; showingImporter = true } label: { Label("Folder", systemImage: "folder") }
                Button { showingText = true } label: { Label("Text", systemImage: "text.bubble") }
                Button { Platform.paste(into: selection) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            }
            .buttonStyle(.bordered)
        }
        #endif
    }

    private func send(to peer: DiscoveredPeer) {
        guard !selection.isEmpty else {
            alert = "Choose files, a folder or some text to send first."
            return
        }
        controller.send(selection.itemsForSending(), to: peer)
    }

    private func send(urls: [URL], to peer: DiscoveredPeer) {
        do {
            controller.send(try SendItem.items(for: urls), to: peer)
        } catch {
            alert = error.localizedDescription
        }
    }

    #if os(macOS)
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { selection.add(urls: panel.urls) }
    }
    #endif

    #if os(iOS)
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
    #endif
}

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

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
                .frame(minWidth: 360, minHeight: 200)
                .navigationTitle("Send text")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            onAdd(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
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
