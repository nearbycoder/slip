import Foundation

/// An incoming `prepare-upload` awaiting the user's decision.
public struct IncomingRequest: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let sender: DeviceInfo
    public let senderIP: String
    public let files: [FileDto]

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum ReceiveDecision: Sendable, Equatable {
    /// Accept the given file ids (nil = all).
    case accept(Set<String>?)
    case decline
}

/// Snapshot of an accepted receive session.
public struct ReceiveSessionInfo: Sendable, Hashable {
    public let sessionId: String
    public let requestId: UUID
    public let sender: DeviceInfo
    public let senderIP: String
    /// Accepted files only.
    public let files: [FileDto]
    public let saveDirectory: URL
}

public enum ReceiverEvent: Sendable {
    /// A peer registered with us (POST /register).
    case peerRegistered(DeviceInfo, ip: String)
    /// A text message arrived (we answered 204).
    case textMessage(String, from: DeviceInfo, ip: String)
    /// A pending request disappeared (timeout, sender cancel or disconnect) before a decision.
    case requestWithdrawn(UUID)
    case sessionStarted(ReceiveSessionInfo)
    case fileProgress(sessionId: String, fileId: String, received: Int64, total: Int64)
    case fileFinished(sessionId: String, fileId: String, url: URL)
    case fileFailed(sessionId: String, fileId: String, reason: String)
    case sessionFinished(sessionId: String, cancelled: Bool)
}

public struct ReceiverConfiguration: Sendable, Equatable {
    public var port: Int
    public var transport: TransportProtocol
    public var saveDirectory: URL
    public var pin: String?
    public var autoAccept: Bool
    public var decisionTimeout: TimeInterval
    /// Accepted sessions with no upload activity for this long are discarded (so a sender
    /// that never uploads can't block us forever).
    public var staleSessionTimeout: TimeInterval
    public var bindHost: String

    public init(port: Int = SlipConstants.defaultPort, transport: TransportProtocol = .https,
                saveDirectory: URL, pin: String? = nil, autoAccept: Bool = false,
                decisionTimeout: TimeInterval = 60, staleSessionTimeout: TimeInterval = 120,
                bindHost: String = "0.0.0.0") {
        self.port = port
        self.transport = transport
        self.saveDirectory = saveDirectory
        self.pin = pin
        self.autoAccept = autoAccept
        self.decisionTimeout = decisionTimeout
        self.staleSessionTimeout = staleSessionTimeout
        self.bindHost = bindHost
    }
}
