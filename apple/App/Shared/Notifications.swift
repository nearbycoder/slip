import Foundation
import SlipKit
import UserNotifications

/// Local notifications for incoming requests, messages and finished transfers.
@MainActor
final class SlipNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SlipNotifications()
    private var authorized = false

    /// Installs the hooks. The permission prompt waits until after the first-run welcome.
    func setUp(controller: SlipController) {
        UNUserNotificationCenter.current().delegate = self
        if !Welcome.isNeeded { requestAuthorization() }
        controller.onIncomingRequest = { [weak controller] request in
            guard controller?.settings.notificationsEnabled == true else { return }
            SlipNotifications.shared.post(title: "\(request.sender.alias) wants to send files",
                                          body: "\(request.files.count) file(s) · \(ByteCountFormatter.string(fromByteCount: request.totalSize, countStyle: .file))",
                                          id: request.id.uuidString)
        }
        controller.onMessage = { [weak controller] message in
            guard controller?.settings.notificationsEnabled == true else { return }
            SlipNotifications.shared.post(title: "Message from \(message.senderAlias)", body: message.text, id: message.id.uuidString)
        }
        controller.onTransferFinished = { [weak controller] transfer in
            guard controller?.settings.notificationsEnabled == true, transfer.direction == .incoming else { return }
            let names = transfer.files.filter { $0.status == .completed }.map(\.name)
            SlipNotifications.shared.post(title: "Received from \(transfer.peerAlias)",
                                          body: names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : ""),
                                          id: transfer.id.uuidString)
        }
        SendFeedback.shared.attach(to: controller)
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in SlipNotifications.shared.authorized = granted }
        }
    }

    func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app shows its own sheet when in the foreground; still show a banner on macOS
        // in case the window is hidden behind others.
        #if os(macOS)
        completionHandler([.banner, .sound])
        #else
        completionHandler([])
        #endif
    }
}
