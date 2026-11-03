import AppKit
import SlipKit
import SwiftUI

@MainActor
enum AppModel {
    static let controller = SlipController()
    static let selection = SendSelection()
    static var openMainWindow: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            Task { await controller.start() }
        }
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
    @AppStorage(MenuBarKey.showExtra) private var showMenuBarExtra = true

    var body: some Scene {
        Window("Slip", id: "main") {
            MacRootView()
                .slipSheets()
                .environment(controller)
                .environment(selection)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 960, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { NotificationCenter.default.post(name: .slipAddFiles, object: nil) }
                    .keyboardShortcut("o")
                Button("Refresh Devices") { controller.refresh() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsWindow().environment(controller)
        }

        // Scene bodies read no controller state (that re-evaluates every scene while a window is
        // being built); the root view mirrors the setting into this key instead.
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent().environment(controller).environment(selection)
        } label: {
            MenuBarLabel().environment(controller)
        }
    }
}

private struct SettingsWindow: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        SettingsView()
            .frame(width: 520, height: 600)
            .preferredColorScheme(controller.settings.theme.colorScheme)
            .tint(Color.slipGreen)
    }
}

private struct MenuBarLabel: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        Image(systemName: controller.activeTransfers.isEmpty ? "paperplane" : "paperplane.fill")
    }
}

enum MenuBarKey {
    static let showExtra = "slip.menuBarExtra.shown"
}

extension Notification.Name {
    static let slipAddFiles = Notification.Name("SlipAddFiles")
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
    // `-SlipTab send` opens a specific pane (developer override, like `-SlipPort`).
    @State private var item: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "SlipTab") ?? "") ?? .receive
    @AppStorage(MenuBarKey.showExtra) private var showMenuBarExtra = true

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
                        Label(peer.info.alias, systemImage: (peer.info.deviceType ?? .desktop).symbolName)
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
            switch item ?? .receive {
            case .receive: MacReceiveView()
            case .send: MacSendView()
            case .transfers: TransfersView()
            }
        }
        .onAppear {
            AppModel.openMainWindow = { [openWindow] in openWindow(id: "main") }
            showMenuBarExtra = controller.settings.showMenuBarExtra
        }
        .onChange(of: controller.settings.showMenuBarExtra) { _, shown in showMenuBarExtra = shown }
        .onChange(of: showMenuBarExtra) { _, shown in
            if controller.settings.showMenuBarExtra != shown { controller.settings.showMenuBarExtra = shown }
        }
        .task { await controller.start() }
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

struct MenuBarContent: View {
    @Environment(SlipController.self) private var controller
    @Environment(SendSelection.self) private var selection
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(controller.settings.alias) — \(controller.isRunning ? "receiving" : "offline")")
        if let ip = controller.localAddresses.first { Text("\(ip):\(String(controller.deviceInfo.port))") }
        Divider()
        if !controller.activeTransfers.isEmpty {
            ForEach(controller.activeTransfers) { t in
                Text("\(t.direction == .incoming ? "↓" : "↑") \(t.peerAlias) \(Int(t.fraction * 100))%")
            }
            Divider()
        }
        Menu("Send Files To") {
            if controller.peers.isEmpty { Text("No devices found") }
            ForEach(controller.peers) { peer in
                Button(peer.info.alias) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    NSApp.activate()
                    if panel.runModal() == .OK, let items = try? SendItem.items(for: panel.urls) {
                        controller.send(items, to: peer)
                    }
                }
            }
        }
        Button("Refresh Devices") { controller.refresh() }
        Toggle("Quick Save", isOn: Binding(get: { controller.settings.quickSave }, set: { controller.settings.quickSave = $0 }))
        Divider()
        Button("Open Slip") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Show Downloads") { Platform.reveal(controller.saveDirectory) }
        Divider()
        Button("Quit Slip") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
