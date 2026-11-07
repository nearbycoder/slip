import AppKit
import SlipKit
import SwiftUI

/// The Settings window (⌘,): a tab per area, like the system's own apps.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ReceivingSettings().tabItem { Label("Receiving", systemImage: "tray.and.arrow.down") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
        }
        .scenePadding()
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(SlipController.self) private var controller
    @State private var aliasText = ""

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                HStack(spacing: 14) {
                    DeviceAvatar(alias: aliasText.isEmpty ? controller.settings.alias : aliasText, type: .desktop, model: "macOS", size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Device name", text: $aliasText, prompt: Text("Device name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitAlias)
                        Text("This is how other devices see your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Shuffle", systemImage: "shuffle") {
                        aliasText = AliasGenerator.random()
                        commitAlias()
                    }
                    .labelStyle(.iconOnly)
                    .help("Pick a random name")
                }
            }
            Section {
                Toggle(isOn: $controller.settings.discoverable) {
                    Text("Discoverable")
                    Text("Nearby devices can see this Mac and send to it.")
                }
                Toggle(isOn: $controller.settings.notificationsEnabled) {
                    Text("Notifications")
                    Text("Alert me about incoming files and finished transfers.")
                }
            }
            Section {
                Picker("Appearance", selection: $controller.settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: AppModel.menuBar.binding) {
                    Text("Show in menu bar")
                    Text("Keep receiving after the window is closed.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { aliasText = controller.settings.alias }
        .onDisappear(perform: commitAlias)
    }

    private func commitAlias() {
        let trimmed = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != controller.settings.alias { controller.settings.alias = trimmed }
    }
}

private struct ReceivingSettings: View {
    @Environment(SlipController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                Toggle(isOn: $controller.settings.quickSave) {
                    Text("Quick Save")
                    Text("Accept incoming files without asking.")
                }
                Toggle(isOn: $controller.settings.requirePin) {
                    Text("Require a PIN")
                    Text("Senders must enter this PIN before they can send you anything.")
                }
                if controller.settings.requirePin {
                    TextField("PIN", text: $controller.settings.pin, prompt: Text("e.g. 4815"))
                }
            }
            Section {
                LabeledContent("Save files to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: controller.saveDirectory.path(percentEncoded: false)))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(controller.saveDirectory.lastPathComponent)
                        Menu {
                            Button("Choose Folder…", action: chooseFolder)
                            Button("Show in Finder") { Platform.reveal(controller.saveDirectory) }
                            if controller.settings.saveDirectoryPath != nil {
                                Divider()
                                Button("Use Downloads") { controller.setSaveDirectory(nil) }
                            }
                        } label: {
                            Text("Change")
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = controller.saveDirectory
        if panel.runModal() == .OK, let url = panel.url { controller.setSaveDirectory(url) }
    }
}

private struct NetworkSettings: View {
    @Environment(SlipController.self) private var controller
    @State private var portText = ""

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                Toggle(isOn: $controller.settings.useHTTPS) {
                    Text("Encrypt transfers (HTTPS)")
                    Text("Turn off only for very old LocalSend devices.")
                }
                LabeledContent("Port") {
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(commitPort)
                }
                LabeledContent("Address", value: controller.localAddresses.first ?? "Not connected")
            } footer: {
                Text("Every device on your network must use the same port. The default is 53317.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Fingerprint") {
                    Text(controller.deviceInfo.fingerprint.prefix(16) + "…")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Protocol", value: "LocalSend v\(SlipConstants.protocolVersion)")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            } footer: {
                Text("Slip works with LocalSend on every platform.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = "\(controller.settings.port)" }
        .onDisappear(perform: commitPort)
    }

    private func commitPort() {
        if let p = Int(portText), (1...65535).contains(p) {
            if p != controller.settings.port { controller.settings.port = p }
        } else {
            portText = "\(controller.settings.port)"
        }
    }
}
