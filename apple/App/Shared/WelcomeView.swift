import SlipKit
import SwiftUI

enum Welcome {
    static let key = "slip.welcomed"

    /// First launch shows the welcome before networking starts (which triggers the
    /// system's local network prompt). Demo mode skips it.
    static var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: key) && UserDefaults.standard.string(forKey: "SlipDemo") == nil
    }
}

/// First-run welcome: what Slip does, the device name, and a heads-up about the permission prompt.
struct WelcomeView: View {
    @Environment(SlipController.self) private var controller
    let onContinue: () -> Void
    @State private var alias = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 16) {
                    SlipLogo(size: 96)
                        .shadow(color: Color.slipGreen.opacity(0.45), radius: 22, y: 10)
                    VStack(spacing: 6) {
                        Text("Welcome to Slip")
                            .font(.largeTitle.weight(.bold))
                        Text("Send files, photos and text to anything nearby.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 18) {
                    FeatureRow(symbol: "dot.radiowaves.left.and.right", tint: .slipGreen,
                               title: "Finds devices on your Wi-Fi",
                               text: "Devices running Slip appear automatically. No accounts, no pairing.")
                    FeatureRow(symbol: "lock.fill", tint: .blue,
                               title: "Private by design",
                               text: "Files go straight to the other device, encrypted. Nothing is uploaded anywhere.")
                    FeatureRow(symbol: "arrow.left.arrow.right", tint: .orange,
                               title: "Works with LocalSend",
                               text: "Send to Slip and LocalSend on Mac, iPhone, Android, Windows and Linux.")
                }
                .frame(maxWidth: 420, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Nearby devices will see you as")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        DeviceAvatar(alias: alias, type: deviceType, model: model, size: 40)
                        TextField("Device name", text: $alias)
                            .font(.headline)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .onSubmit(finish)
                        Button("Shuffle", systemImage: "shuffle") {
                            withAnimation(.snappy) { alias = AliasGenerator.random() }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Pick a random name")
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Button(action: finish) {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity)
                }
                .slipGlassProminentButton()
                .tint(Color.slipGreen)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Label("Next, \(platformName) asks to let Slip find devices on your local network. Choose Allow.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onAppear { alias = controller.settings.alias }
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
    }

    private func finish() {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != controller.settings.alias { controller.settings.alias = trimmed }
        UserDefaults.standard.set(true, forKey: Welcome.key)
        SlipNotifications.shared.requestAuthorization()
        onContinue()
    }

    private var platformName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    private var deviceType: DeviceType {
        #if os(macOS)
        .desktop
        #else
        .mobile
        #endif
    }

    private var model: String {
        #if os(macOS)
        "macOS"
        #else
        "iPhone"
        #endif
    }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
