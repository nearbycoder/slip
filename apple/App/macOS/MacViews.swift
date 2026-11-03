import AppKit
import SlipKit
import SwiftUI

// MARK: - Receive

/// Receive pane: a glass "radar" hero over System Settings-style grouped sections.
struct MacReceiveView: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
            } header: {
                ReceiveHero()
            }

            Section("This Mac") {
                LabeledContent("Name", value: controller.settings.alias)
                LabeledContent("Address") {
                    Text(controller.localAddresses.isEmpty ? "Not connected" : controller.localAddresses.joined(separator: ", "))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("Port") {
                    Text(verbatim: "\(controller.deviceInfo.port)").monospacedDigit()
                }
                LabeledContent("Encryption") {
                    Label(controller.settings.useHTTPS ? "HTTPS" : "Off (HTTP)",
                          systemImage: controller.settings.useHTTPS ? "lock.fill" : "lock.open")
                }
            }

            Section("Receiving") {
                Toggle(isOn: $controller.settings.discoverable) {
                    Text("Discoverable")
                    Text("Let nearby devices see this Mac.")
                }
                Toggle(isOn: $controller.settings.quickSave) {
                    Text("Quick Save")
                    Text("Accept incoming files without asking.")
                }
                LabeledContent("Save to") {
                    Button {
                        Platform.reveal(controller.saveDirectory)
                    } label: {
                        Label(controller.saveDirectory.lastPathComponent, systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }
            }

            if let error = controller.serverError ?? controller.discoveryError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.serverError != nil ? .red : .secondary)
                }
            }

            if !controller.messages.isEmpty {
                Section("Messages") {
                    ForEach(controller.messages) { m in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "text.bubble.fill").foregroundStyle(Color.slipGreen)
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
                                .help("Copy")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Receive")
        .navigationSubtitle(statusLine)
        .toolbar {
            ToolbarItem {
                Button("Show Downloads", systemImage: "folder") { Platform.reveal(controller.saveDirectory) }
                    .help("Show received files in Finder")
            }
        }
    }

    private var statusLine: String {
        if controller.serverError != nil { return "Not receiving" }
        if !controller.isRunning { return "Starting…" }
        return controller.settings.discoverable ? "Ready to receive" : "Hidden from nearby devices"
    }
}

/// App icon on a glass disc with radar pulses while the receiver is live.
private struct ReceiveHero: View {
    @Environment(SlipController.self) private var controller
    @State private var pulse = false

    private var live: Bool { controller.isRunning && controller.serverError == nil && controller.settings.discoverable }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.slipGreen.opacity(0.35), lineWidth: 1)
                        .frame(width: 112, height: 112)
                        .scaleEffect(pulse ? 2.1 : 1)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 3).repeatForever(autoreverses: false).delay(Double(i)),
                                   value: pulse)
                        .opacity(live ? 1 : 0)
                }
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .frame(width: 112, height: 112)
                    .slipGlass(in: Circle(), tint: Color.slipGreen.opacity(0.18))
                    .saturation(live ? 1 : 0)
            }
            .frame(height: 190)

            VStack(spacing: 6) {
                Text(controller.settings.alias)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)
                HStack(spacing: 7) {
                    Circle()
                        .fill(live ? Color.slipGreen : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(live ? "Visible to nearby devices" : (controller.isRunning ? "Not visible" : "Starting…"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .slipGlass(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .textCase(nil)
        .onAppear { pulse = true }
    }
}

// MARK: - Send

/// Send pane: native device list with a floating glass selection tray.
struct MacSendView: View {
    @Environment(SlipController.self) private var controller
    @Environment(SendSelection.self) private var selection
    @State private var showingText = false
    @State private var showingManual = false
    @State private var alert: String?
    @State private var dropTargeted = false

    var body: some View {
        List {
            Section {
                ForEach(controller.peers) { peer in
                    MacDeviceRow(peer: peer, canSend: !selection.isEmpty) { send(to: peer) } onDrop: { urls in
                        send(urls: urls, to: peer)
                    }
                }
            } header: {
                if !controller.peers.isEmpty { Text("Nearby Devices") }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .overlay {
            if controller.peers.isEmpty {
                ContentUnavailableView {
                    Label(controller.isScanning ? "Looking for Devices…" : "No Devices Nearby",
                          systemImage: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative, isActive: controller.isScanning)
                } description: {
                    Text("Open Slip or LocalSend on another device on the same Wi-Fi network.")
                } actions: {
                    Button("Send to IP Address…") { showingManual = true }
                        .slipGlassButton()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SelectionTray(showingText: $showingText, targeted: dropTargeted, pickFiles: pickFiles)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            selection.add(urls: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Send")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button("Add Files", systemImage: "plus") { pickFiles() }
                    .help("Add files or folders (⌘O)")
                Button("Add Text", systemImage: "text.bubble") { showingText = true }
                    .help("Send a message or link")
                Button("Paste", systemImage: "doc.on.clipboard") { Platform.paste(into: selection) }
                    .help("Add what's on the clipboard")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }
            ToolbarItemGroup {
                Button("Send to IP Address", systemImage: "network") { showingManual = true }
                    .help("Connect to a device by IP address")
                Button("Refresh", systemImage: "arrow.clockwise") { controller.refresh() }
                    .disabled(controller.isScanning)
                    .help("Look for devices again (⌘R)")
            }
        }
        .sheet(isPresented: $showingText) { TextComposer { selection.addText($0) } }
        .sheet(isPresented: $showingManual) { ManualPeerView() }
        .alert("Slip", isPresented: Binding(get: { alert != nil || selection.lastError != nil },
                                             set: { if !$0 { alert = nil; selection.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? selection.lastError ?? "")
        }
    }

    private var subtitle: String {
        let n = controller.peers.count
        if n == 0 { return controller.isScanning ? "Searching…" : "No devices" }
        return "\(n) device\(n == 1 ? "" : "s") nearby"
    }

    private func send(to peer: DiscoveredPeer) {
        guard !selection.isEmpty else {
            alert = "Add files, a folder or some text first, or drop files straight onto a device."
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

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { selection.add(urls: panel.urls) }
    }
}

private struct MacDeviceRow: View {
    let peer: DiscoveredPeer
    let canSend: Bool
    let onSend: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: (peer.info.deviceType ?? .desktop).symbolName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.slipGreen)
                .frame(width: 44, height: 44)
                .slipGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                           tint: Color.slipGreen.opacity(targeted ? 0.35 : 0.08))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.info.alias).font(.headline)
                HStack(spacing: 6) {
                    Text([peer.info.deviceModel, peer.ip].compactMap { $0 }.joined(separator: " · "))
                    if peer.info.protocol == .http {
                        Image(systemName: "lock.open").help("Unencrypted (HTTP)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if targeted {
                Label("Drop to send", systemImage: "arrow.down.doc")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.slipGreen)
            } else if canSend {
                Button("Send", systemImage: "paperplane.fill", action: onSend)
                    .slipGlassProminentButton()
                    .controlSize(.large)
            } else if hovering {
                Text("Drop files to send")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.snappy, value: targeted)
        .animation(.snappy, value: canSend)
    }
}

/// Floating glass tray showing what's about to be sent.
private struct SelectionTray: View {
    @Environment(SendSelection.self) private var selection
    @Binding var showingText: Bool
    let targeted: Bool
    let pickFiles: () -> Void

    var body: some View {
        SlipGlassContainer(spacing: 10) {
            HStack(spacing: 12) {
                if selection.isEmpty {
                    Image(systemName: targeted ? "arrow.down.doc.fill" : "tray.and.arrow.up")
                        .font(.title2)
                        .foregroundStyle(targeted ? Color.slipGreen : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(targeted ? "Drop to add" : "Nothing selected").font(.headline)
                        Text("Drag files here, or add files, text or the clipboard.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Add Files…", systemImage: "plus", action: pickFiles)
                        .slipGlassProminentButton()
                        .controlSize(.large)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(selection.items) { item in
                                SelectionChip(item: item) { withAnimation(.snappy) { selection.remove(item) } }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollClipDisabled()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(selection.items.count) item\(selection.items.count == 1 ? "" : "s")").font(.headline)
                        Text(Format.bytes(selection.totalSize)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .fixedSize()
                    Button("Clear", systemImage: "xmark") { withAnimation(.snappy) { selection.clear() } }
                        .labelStyle(.iconOnly)
                        .slipGlassButton()
                        .controlSize(.large)
                        .help("Clear selection")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .slipGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                       tint: targeted ? Color.slipGreen.opacity(0.25) : nil)
        }
        .animation(.snappy, value: selection.items.count)
        .animation(.snappy, value: targeted)
    }
}

private struct SelectionChip: View {
    let item: SendItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbolName).foregroundStyle(Color.slipGreen)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                Text(Format.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .slipGlass(in: Capsule(), interactive: true)
    }
}

// MARK: - Sidebar footer

/// "This Mac" status pinned to the bottom of the sidebar.
struct SidebarStatus: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.settings.alias).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(controller.isRunning && controller.serverError == nil ? Color.slipGreen : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(controller.localAddresses.first ?? "Offline")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
        }
        .padding(10)
        .slipGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(10)
    }
}
