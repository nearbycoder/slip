import SlipKit
import SwiftUI
#if os(iOS)
import QuickLook
import UIKit

/// iOS Receive tab: glass radar hero over grouped sections.
struct ReceiveView: View {
    @Environment(SlipController.self) private var controller
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var controller = controller
        List {
            Section {
                ReceiveHero()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .listSectionSpacing(0)

            Section("This \(UIDevice.current.model)") {
                LabeledContent("Address") {
                    Text(controller.localAddresses.isEmpty ? "Not connected" : controller.localAddresses.joined(separator: ", "))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                LabeledContent("Port") { Text(verbatim: "\(controller.deviceInfo.port)").monospacedDigit() }
                LabeledContent("Encryption") {
                    Label(controller.settings.useHTTPS ? "HTTPS" : "Off", systemImage: controller.settings.useHTTPS ? "lock.fill" : "lock.open")
                }
            }

            Section {
                Toggle(isOn: $controller.settings.discoverable) {
                    Text("Discoverable")
                    Text("Let nearby devices see this \(UIDevice.current.model).")
                }
                Toggle(isOn: $controller.settings.quickSave) {
                    Text("Quick Save")
                    Text("Accept incoming files without asking.")
                }
            } footer: {
                Text("Received files are saved to Files › On My \(UIDevice.current.model) › Slip. Keep Slip open to receive.")
            }

            if let error = controller.serverError ?? controller.discoveryError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(controller.serverError != nil ? .red : .secondary)
                        .font(.callout)
                }
            }

            RecentlyReceived { previewURL = $0 }
            MessagesSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
    }
}
#endif
