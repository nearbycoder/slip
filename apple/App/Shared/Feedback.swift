import Observation
import SlipKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sounds, haptics and the brief "Sent" confirmation on device rows.
@MainActor
@Observable
final class SendFeedback {
    static let shared = SendFeedback()

    /// Peer aliases that just received something from us, cleared after a moment.
    private(set) var justSent: Set<String> = []

    func attach(to controller: SlipController) {
        let previous = controller.onTransferFinished
        controller.onTransferFinished = { [weak self] transfer in
            previous?(transfer)
            self?.transferFinished(transfer)
        }
        let previousRequest = controller.onIncomingRequest
        controller.onIncomingRequest = { request in
            previousRequest?(request)
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
        }
    }

    func didSend(to alias: String) {
        withAnimation(.snappy) { _ = justSent.insert(alias) }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.snappy) { _ = justSent.remove(alias) }
        }
    }

    private func transferFinished(_ transfer: Transfer) {
        switch transfer.status {
        case .completed:
            if transfer.direction == .outgoing { didSend(to: transfer.peerAlias) }
            play(.success, direction: transfer.direction)
        case .failed, .declined:
            play(.failure, direction: transfer.direction)
        default:
            break
        }
    }

    private enum Outcome { case success, failure }

    private func play(_ outcome: Outcome, direction: TransferDirection) {
        #if os(macOS)
        let name: NSSound.Name = outcome == .failure ? "Basso" : (direction == .incoming ? "Glass" : "Pop")
        NSSound(named: name)?.play()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(outcome == .success ? .success : .error)
        #endif
    }
}
