import SlipKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings per IMPLEMENTATION.md: alias · port · HTTPS · save dir · Quick Save · PIN ·
/// discoverable · theme.
struct SettingsView: View {
    @Environment(SlipController.self) private var controller
    @State private var portText = ""
    @State private var aliasText = ""

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section("Device") {
                TextField("Device name", text: $aliasText)
                    .onSubmit(commitAlias)
                    .autocorrectionDisabled()
                Button("Random name") {
                    aliasText = AliasGenerator.random()
                    commitAlias()
                }
                Toggle("Discoverable", isOn: $controller.settings.discoverable)
            }

            Section("Receiving") {
                Toggle("Quick Save (accept automatically)", isOn: $controller.settings.quickSave)
                Toggle("Require PIN", isOn: $controller.settings.requirePin)
                if controller.settings.requirePin {
                    TextField("PIN", text: $controller.settings.pin)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                #if os(macOS)
                LabeledContent("Save to") {
                    HStack {
                        Text(controller.saveDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        if controller.settings.saveDirectoryPath != nil {
                            Button("Reset") { controller.setSaveDirectory(nil) }
                        }
                    }
                }
                #else
                LabeledContent("Save to", value: "Slip folder in Files")
                #endif
                Toggle("Notifications", isOn: $controller.settings.notificationsEnabled)
            }

            Section("Network") {
                TextField("Port", text: $portText)
                    .onSubmit(commitPort)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Toggle("Encryption (HTTPS)", isOn: $controller.settings.useHTTPS)
                LabeledContent("Fingerprint") {
                    Text(controller.deviceInfo.fingerprint.prefix(24) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $controller.settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                #if os(macOS)
                Toggle("Show in menu bar", isOn: $controller.settings.showMenuBarExtra)
                #endif
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Protocol", value: "LocalSend v\(SlipConstants.protocolVersion)")
            } footer: {
                Text("Slip is compatible with LocalSend on every platform.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            portText = "\(controller.settings.port)"
            aliasText = controller.settings.alias
        }
        .onDisappear {
            commitAlias()
            commitPort()
        }
    }

    private func commitAlias() {
        let trimmed = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != controller.settings.alias { controller.settings.alias = trimmed }
    }

    private func commitPort() {
        if let p = Int(portText), (1...65535).contains(p) {
            if p != controller.settings.port { controller.settings.port = p }
        } else {
            portText = "\(controller.settings.port)"
        }
    }

    #if os(macOS)
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = controller.saveDirectory
        if panel.runModal() == .OK, let url = panel.url { controller.setSaveDirectory(url) }
    }
    #endif
}
