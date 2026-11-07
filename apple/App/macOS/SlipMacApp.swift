import AppKit
import SlipKit
import SwiftUI

@MainActor
enum AppModel {
    static let controller = SlipController()
    static let selection = SendSelection()
    static let menuBar = MenuBarVisibility(isInserted: controller.settings.showMenuBarExtra)
    static var openMainWindow: (() -> Void)?

    static func queueForSending(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        selection.add(urls: urls)
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) { openMainWindow?() }
        NotificationCenter.default.post(name: .slipSelectPane, object: SidebarItem.send.rawValue)
        NSApp.activate()
    }
}

/// Handles Finder › Services › Send with Slip.
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    @objc func sendFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        MainActor.assumeIsolated { AppModel.queueForSending(urls) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
        MainActor.assumeIsolated {
            let controller = AppModel.controller
            SlipNotifications.shared.setUp(controller: controller)
            let notify = controller.onIncomingRequest
            controller.onIncomingRequest = { request in
                notify?(request)
                // Bring the window forward so the Accept/Decline sheet is visible.
                if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
                    AppModel.openMainWindow?()
                }
                NSApp.activate()
                NSApp.requestUserAttention(.informationalRequest)
            }
            if !Welcome.isNeeded { Task { await controller.start() } }
        }
    }

    /// Files dropped on the Dock icon or opened with Slip go to the Send tray.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.queueForSending(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep receiving from the menu bar if it's enabled.
        MainActor.assumeIsolated { !AppModel.controller.settings.showMenuBarExtra }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            let c = AppModel.controller
            Task { await c.stop() }
        }
    }
}

@main
struct SlipMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = AppModel.controller
    @State private var selection = AppModel.selection
    @State private var menuBar = AppModel.menuBar

    var body: some Scene {
        Window("Slip", id: "main") {
            MacRootView()
                .slipSheets()
                .environment(controller)
                .environment(selection)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { NotificationCenter.default.post(name: .slipAddFiles, object: nil) }
                    .keyboardShortcut("o")
                Button("Add Text…") { NotificationCenter.default.post(name: .slipAddText, object: nil) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Devices") { controller.refresh() }
                    .keyboardShortcut("r")
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, pane in
                    Button(pane.title) { NotificationCenter.default.post(name: .slipSelectPane, object: pane.rawValue) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
            }
        }

        Settings {
            SettingsWindow().environment(controller)
        }

        // Scene bodies read no controller state (that re-evaluates every scene while a window is
        // being built), only this one value.
        MenuBarExtra(isInserted: menuBar.binding) {
            MenuBarContent().environment(controller).environment(selection)
        } label: {
            MenuBarLabel().environment(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct SettingsWindow: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        MacSettingsView()
            .preferredColorScheme(controller.settings.theme.colorScheme)
            .tint(Color.slipGreen)
    }
}

private struct MenuBarLabel: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        Image(controller.activeTransfers.isEmpty ? "MenuBarIcon" : "MenuBarIconActive")
    }
}

/// Whether the menu bar extra is inserted, mirrored into `settings.showMenuBarExtra`.
///
/// Not `@AppStorage`: that re-runs the scene on every UserDefaults write, and inserting the
/// extra makes AppKit write its status item visibility to UserDefaults, which re-inserts the
/// extra, and so on. On a fresh install that loop froze the app at launch.
@MainActor
@Observable
final class MenuBarVisibility {
    private(set) var isInserted: Bool

    init(isInserted: Bool) { self.isInserted = isInserted }

    /// Ignores writes of the current value, which SwiftUI makes while updating the scene.
    func set(_ inserted: Bool) {
        guard inserted != isInserted else { return }
        isInserted = inserted
        if AppModel.controller.settings.showMenuBarExtra != inserted {
            AppModel.controller.settings.showMenuBarExtra = inserted
        }
    }

    var binding: Binding<Bool> {
        Binding(get: { self.isInserted }, set: { self.set($0) })
    }
}

extension Notification.Name {
    static let slipAddFiles = Notification.Name("SlipAddFiles")
    static let slipAddText = Notification.Name("SlipAddText")
    static let slipSelectPane = Notification.Name("SlipSelectPane")
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case receive, send, transfers
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .receive: return "arrow.down.circle"
        case .send: return "paperplane"
        case .transfers: return "arrow.up.arrow.down"
        }
    }
}

struct MacRootView: View {
    @Environment(SlipController.self) private var controller
    @Environment(SendSelection.self) private var selection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    // `-SlipTab send` opens a specific pane (developer override, like `-SlipPort`).
    @State private var item: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "SlipTab") ?? "") ?? .receive
    @State private var showingWelcome = Welcome.isNeeded

    @ViewBuilder
    private var detail: some View {
        switch item ?? .receive {
        case .receive: MacReceiveView()
        case .send: MacSendView()
        case .transfers: TransfersView()
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $item) {
                Section {
                    ForEach(SidebarItem.allCases) { i in
                        Label(i.title, systemImage: i.symbol)
                            .badge(i == .transfers ? controller.activeTransfers.count : 0)
                            .tag(i)
                    }
                }
                Section("Nearby") {
                    if controller.peers.isEmpty {
                        Label(controller.isScanning ? "Searching…" : "No devices", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(controller.peers) { peer in
                        Label(peer.info.alias, systemImage: DeviceSymbol.name(type: peer.info.deviceType ?? .desktop, model: peer.info.deviceModel))
                            .selectionDisabled()
                            .dropDestination(for: URL.self) { urls, _ in
                                if let items = try? SendItem.items(for: urls) { controller.send(items, to: peer) }
                                item = .transfers
                                return true
                            }
                            .help("Drop files to send to \(peer.info.alias)")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "SlipPreview") == "request", let request = controller.pendingRequest {
                // Design review: the incoming-request sheet rendered in place.
                IncomingRequestView(request: request).frame(width: 440).fixedSize(horizontal: false, vertical: true)
            } else if UserDefaults.standard.string(forKey: "SlipPreview") == "welcome" {
                WelcomeView {}
            } else if UserDefaults.standard.string(forKey: "SlipPreview") == "menubar" {
                MenuBarContent().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else {
                detail
            }
            #else
            detail
            #endif
        }
        .onAppear {
            AppModel.openMainWindow = { [openWindow] in openWindow(id: "main") }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "SlipOpenSettings") { openSettings() }
            #endif
        }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "SlipDemoSelection"), selection.isEmpty {
                selection.add(.data(Data(count: 4_404_019), fileName: "IMG_3001.heic", mimeType: "image/heic"))
                selection.add(.data(Data(count: 92_274_688), fileName: "Tram 28.mov", mimeType: "video/quicktime"))
                selection.add(.data(Data(count: 812_000), fileName: "Restaurants.pdf", mimeType: "application/pdf"))
                selection.addText("See you at the tram stop at 6!")
            }
            #endif
            if !showingWelcome { await controller.start() }
        }
        .sheet(isPresented: $showingWelcome) {
            WelcomeView {
                showingWelcome = false
                Task { await controller.start() }
            }
            .environment(controller)
        }
        .background { DockTileSync() }
        .onReceive(NotificationCenter.default.publisher(for: .slipSelectPane)) { note in
            if let raw = note.object as? String, let pane = SidebarItem(rawValue: raw) { item = pane }
        }
        .onReceive(NotificationCenter.default.publisher(for: .slipAddText)) { _ in item = .send }
        .onReceive(NotificationCenter.default.publisher(for: .slipAddFiles)) { _ in
            item = .send
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { selection.add(urls: panel.urls) }
        }
    }
}

/// The menu bar panel: status, live transfers and one-click sending to nearby devices.
struct MenuBarContent: View {
    @Environment(SlipController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.settings.alias).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(live ? Color.slipGreen : Color.secondary).frame(width: 6, height: 6)
                        Text(live ? (controller.localAddresses.first ?? "Receiving") : "Not receiving")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Quick Save", isOn: $controller.settings.quickSave)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .help("Accept incoming files without asking")
            }

            if !controller.activeTransfers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.activeTransfers) { t in
                        HStack(spacing: 8) {
                            DeviceAvatar(alias: t.peerAlias, type: t.peerDeviceType, model: t.peerModel, size: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(t.direction == .incoming ? "From" : "To") \(t.peerAlias)").font(.callout)
                                    Spacer()
                                    Text("\(Int(t.fraction * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                ProgressView(value: t.fraction).tint(Color.slipGreen).controlSize(.small)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Nearby").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if controller.peers.isEmpty {
                    Text(controller.isScanning ? "Looking for devices…" : "No devices found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], spacing: 6) {
                        ForEach(controller.peers) { peer in
                            MenuBarPeer(peer: peer)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Open Slip") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Downloads", systemImage: "folder") { Platform.reveal(controller.saveDirectory) }
                    .labelStyle(.iconOnly)
                    .help("Show received files")
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .help("Quit Slip")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var live: Bool { controller.isRunning && controller.serverError == nil }
}

private struct MenuBarPeer: View {
    @Environment(SlipController.self) private var controller
    let peer: DiscoveredPeer
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        Button(action: pickAndSend) {
            VStack(spacing: 5) {
                DeviceAvatar(peer: peer, size: 38)
                    .scaleEffect(targeted ? 1.1 : 1)
                Text(peer.info.alias)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(targeted ? Color.slipGreen.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Send files to \(peer.info.alias), or drop them here")
        .dropDestination(for: URL.self) { urls, _ in
            if let items = try? SendItem.items(for: urls) { controller.send(items, to: peer) }
            return true
        } isTargeted: { targeted = $0 }
        .animation(.snappy(duration: 0.2), value: targeted)
    }

    private func pickAndSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = "Choose files or folders to send to \(peer.info.alias)"
        NSApp.activate()
        if panel.runModal() == .OK, let items = try? SendItem.items(for: panel.urls) {
            controller.send(items, to: peer)
        }
    }
}
