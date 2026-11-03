import SlipKit
import SwiftUI

/// Incoming transfer: sender, file list (deselectable), total size, Accept / Decline.
struct IncomingRequestView: View {
    @Environment(SlipController.self) private var controller
    let request: IncomingRequest
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                DeviceAvatar(info: request.sender, size: 64)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Text(request.sender.alias)
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text([request.sender.deviceModel, request.senderIP].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            HStack {
                Text("\(selected.count) of \(request.files.count) selected · \(Format.bytes(selectedSize))")
                    .monospacedDigit()
                Spacer()
                Button(allSelected ? "Select None" : "Select All") {
                    selected = allSelected ? [] : Set(request.files.map(\.id))
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(request.files) { file in
                        FileChoiceRow(file: file, isOn: selected.contains(file.id)) {
                            if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(minHeight: 120, idealHeight: CGFloat(min(request.files.count, 6)) * 46 + 12, maxHeight: 300)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 20)

            Label("Saves to \(saveLocation)", systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            HStack(spacing: 10) {
                Button(role: .cancel) { controller.decline() } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .slipGlassButton()
                Button { controller.accept(fileIds: selected) } label: {
                    Text(allSelected ? "Accept" : "Accept \(selected.count)").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .slipGlassProminentButton()
                .tint(Color.slipGreen)
                .disabled(selected.isEmpty)
            }
            .controlSize(.large)
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440)
        #else
        .presentationDetents([.fraction(0.8), .large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear { selected = Set(request.files.map(\.id)) }
        .interactiveDismissDisabled()
    }

    private var allSelected: Bool { selected.count == request.files.count }
    private var selectedSize: Int64 { request.files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    private var summary: String {
        let n = request.files.count
        return "wants to send you \(n == 1 ? "a file" : "\(n) files") (\(Format.bytes(request.totalSize)))"
    }

    private var saveLocation: String {
        #if os(macOS)
        controller.saveDirectory.lastPathComponent
        #else
        "Files › Slip"
        #endif
    }
}

private struct FileChoiceRow: View {
    let file: FileDto
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isOn ? Color.white : Color.secondary, isOn ? Color.slipGreen : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                FileGlyph(fileName: file.fileName, mimeType: file.fileType, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.fileName as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let folder = (file.fileName as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(Format.bytes(file.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
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
