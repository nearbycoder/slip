import SlipKit
import SwiftUI
import UIKit

@main
struct SlipiOSApp: App {
    @State private var controller = SlipController()
    @State private var selection = SendSelection()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .slipSheets()
                .environment(controller)
                .environment(selection)
                .task {
                    SlipNotifications.shared.setUp(controller: controller)
                    await controller.start()
                }
                .onOpenURL { url in
                    // Files opened in Slip from other apps ("Open in…") go to the selection tray.
                    selection.add(urls: [url])
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
                // Ask for a little extra time so in-flight transfers can finish.
                if !controller.activeTransfers.isEmpty, backgroundTask == .invalid {
                    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Slip transfer") {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                        backgroundTask = .invalid
                    }
                }
            case .active:
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
                // Sockets may have been reclaimed while suspended: restart and re-announce.
                if wasBackgrounded, controller.activeTransfers.isEmpty {
                    wasBackgrounded = false
                    Task { await controller.restart() }
                }
            default:
                break
            }
        }
    }
}

struct IOSRootView: View {
    @Environment(SlipController.self) private var controller
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ReceiveView() }
                .tabItem { Label("Receive", systemImage: "arrow.down.circle") }
                .tag(0)
            NavigationStack { SendView() }
                .tabItem { Label("Send", systemImage: "paperplane") }
                .tag(1)
            NavigationStack { TransfersView() }
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                .badge(controller.activeTransfers.count)
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
    }
}
