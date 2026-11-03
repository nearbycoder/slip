import SlipKit
import SwiftUI

/// Incoming transfer: sender, file list (deselectable), total size, Accept / Decline.
struct IncomingRequestView: View {
    @Environment(SlipController.self) private var controller
    let request: IncomingRequest
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 16) {
            DeviceIcon(type: request.sender.deviceType ?? .desktop, size: 56)
            VStack(spacing: 4) {
                Text(request.sender.alias).font(.title2.weight(.semibold))
                Text("wants to send you \(request.files.count) file\(request.files.count == 1 ? "" : "s") · \(Format.bytes(selectedSize))")
                    .foregroundStyle(.secondary)
                if let model = request.sender.deviceModel {
                    Text("\(model) · \(request.senderIP)").font(.caption).foregroundStyle(.secondary)
                }
            }
            List(request.files) { file in
                Toggle(isOn: Binding(get: { selected.contains(file.id) },
                                     set: { on in if on { selected.insert(file.id) } else { selected.remove(file.id) } })) {
                    HStack {
                        Text(file.fileName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.bytes(file.size)).foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .frame(minHeight: 120, idealHeight: 220)
            HStack {
                Button(role: .destructive) { controller.decline() } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button { controller.accept(fileIds: selected) } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.slipGreen)
                .disabled(selected.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 380, idealWidth: 440)
        .onAppear { selected = Set(request.files.map(\.id)) }
        .interactiveDismissDisabled()
    }

    private var selectedSize: Int64 { request.files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
}

struct MessageView: View {
    let message: ReceivedMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minWidth: 360, minHeight: 160)
            .navigationTitle("Message from \(message.senderAlias)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        Platform.copy(message.text)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PinPromptView: View {
    @Environment(SlipController.self) private var controller
    let prompt: PinPrompt
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Text(prompt.wasWrong ? "Wrong PIN. Try again." : "\(prompt.peerAlias) requires a PIN.")
                SecureField("PIN", text: $pin)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onSubmit(submit)
            }
            .formStyle(.grouped)
            .frame(minWidth: 320)
            .navigationTitle("PIN required")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { controller.dismissPinPrompt() } }
                ToolbarItem(placement: .confirmationAction) { Button("Send", action: submit).disabled(pin.isEmpty) }
            }
        }
    }

    private func submit() { controller.submitPin(pin, for: prompt) }
}

/// Attaches the global sheets (incoming request, message, PIN) to the root view.
struct SlipSheets: ViewModifier {
    @Environment(SlipController.self) private var controller

    func body(content: Content) -> some View {
        @Bindable var controller = controller
        content
            .sheet(item: Binding(get: { controller.pendingRequest }, set: { if $0 == nil && controller.pendingRequest != nil { controller.decline() } })) { request in
                IncomingRequestView(request: request)
                    .environment(controller)
            }
            .sheet(item: $controller.presentedMessage) { MessageView(message: $0) }
            .sheet(item: Binding(get: { controller.pinPrompt }, set: { if $0 == nil { controller.pinPrompt = nil } })) { prompt in
                PinPromptView(prompt: prompt).environment(controller)
            }
            .preferredColorScheme(controller.settings.theme.colorScheme)
            .tint(Color.slipGreen)
    }
}

extension View {
    func slipSheets() -> some View { modifier(SlipSheets()) }
}
