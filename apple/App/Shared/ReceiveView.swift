import SlipKit
import SwiftUI

/// Receive tab: the big "ready to receive" card.
struct ReceiveView: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        ScrollView {
            VStack(spacing: 20) {
                card
                if !controller.messages.isEmpty { messages }
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Receive")
    }

    private var card: some View {
        @Bindable var controller = controller
        return VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.slipGreen.opacity(0.12)).frame(width: 132, height: 132)
                Circle().fill(Color.slipGreen.opacity(0.22)).frame(width: 100, height: 100)
                Image(systemName: controller.isRunning && controller.serverError == nil ? "wifi" : "wifi.slash")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.slipGreen)
            }
            .padding(.top, 8)

            Text(controller.settings.alias)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("IP").foregroundStyle(.secondary)
                    Text(controller.localAddresses.isEmpty ? "—" : controller.localAddresses.joined(separator: ", "))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    Text(verbatim: "\(controller.deviceInfo.port)")
                }
                GridRow {
                    Text("Protocol").foregroundStyle(.secondary)
                    Text(controller.settings.useHTTPS ? "HTTPS (encrypted)" : "HTTP")
                }
            }
            .font(.callout.monospacedDigit())

            Divider()

            Toggle("Discoverable", isOn: $controller.settings.discoverable)
            Toggle("Quick Save (accept automatically)", isOn: $controller.settings.quickSave)

            if let error = controller.serverError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if let error = controller.discoveryError {
                Label(error, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(24)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var statusLine: String {
        if controller.serverError != nil { return "Not receiving" }
        if !controller.isRunning { return "Starting…" }
        return controller.settings.discoverable ? "Ready to receive — visible to nearby devices" : "Ready to receive — hidden"
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Messages").font(.headline)
            ForEach(controller.messages) { m in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.text).textSelection(.enabled)
                        Text("\(m.senderAlias) · \(m.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Platform.copy(m.text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
