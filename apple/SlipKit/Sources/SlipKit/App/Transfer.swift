import Foundation
import Observation

public enum TransferDirection: String, Sendable {
    case incoming, outgoing
}

public enum TransferStatus: Equatable, Sendable {
    case waiting
    case inProgress
    case completed
    case cancelled
    case declined
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .waiting, .inProgress: return false
        default: return true
        }
    }

    public var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .inProgress: return "Transferring"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .declined: return "Declined"
        case .failed(let s): return s
        }
    }
}

@Observable
public final class TransferFile: Identifiable {
    public let id: String
    public let name: String
    public let size: Int64
    public var transferred: Int64 = 0
    public var status: TransferStatus = .waiting
    /// Final location for received files / source for sent files.
    public var url: URL?

    public init(id: String, name: String, size: Int64, url: URL? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.url = url
    }

    public var fraction: Double { size > 0 ? min(1, Double(transferred) / Double(size)) : (status == .completed ? 1 : 0) }
}

@Observable
public final class Transfer: Identifiable {
    public let id = UUID()
    public let direction: TransferDirection
    public let peerAlias: String
    public let peerDeviceType: DeviceType
    public let peerModel: String?
    public var files: [TransferFile]
    public var status: TransferStatus
    public var sessionId: String?
    public let startedAt = Date()
    public var finishedAt: Date?
    public var saveDirectory: URL?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var peerAddress: PeerAddress?
    @ObservationIgnored var items: [SendItem] = []

    init(direction: TransferDirection, peer: DeviceInfo, files: [TransferFile], status: TransferStatus) {
        self.direction = direction
        self.peerAlias = peer.alias
        self.peerDeviceType = peer.deviceType ?? .desktop
        self.peerModel = peer.deviceModel
        self.files = files
        self.status = status
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var transferredBytes: Int64 { files.reduce(0) { $0 + min($1.transferred, $1.size) } }
    public var fraction: Double { totalBytes > 0 ? Double(transferredBytes) / Double(totalBytes) : (status == .completed ? 1 : 0) }

    /// Average speed in bytes/second.
    public var bytesPerSecond: Double {
        let end = finishedAt ?? Date()
        let t = end.timeIntervalSince(startedAt)
        return t > 0.2 ? Double(transferredBytes) / t : 0
    }

    func file(_ id: String) -> TransferFile? { files.first { $0.id == id } }

    func finish(_ status: TransferStatus) {
        guard !self.status.isFinished else { return }
        self.status = status
        finishedAt = Date()
        for f in files where !f.status.isFinished {
            f.status = status == .completed ? .completed : status
        }
    }
}

public struct ReceivedMessage: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let text: String
    public let senderAlias: String
    public let date = Date()
}

public struct PinPrompt: Identifiable, Sendable {
    public let id = UUID()
    public let transferId: UUID
    public let peerAlias: String
    public let wasWrong: Bool
}
