import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// A held-open prepare-upload: resolved exactly once by the user, a timeout, or a cancel.
final class PendingDecision: @unchecked Sendable {
    enum Outcome: Sendable { case decided(ReceiveDecision), timedOut, withdrawn }

    let request: IncomingRequest
    private let lock = NIOLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var result: Outcome?

    init(request: IncomingRequest) { self.request = request }

    func wait() async -> Outcome {
        await withCheckedContinuation { cont in
            lock.withLock {
                if let result { cont.resume(returning: result) } else { continuation = cont }
            }
        }
    }

    /// Returns false if already resolved.
    @discardableResult
    func resolve(_ outcome: Outcome) -> Bool {
        var cont: CheckedContinuation<Outcome, Never>?
        let ok: Bool = lock.withLock {
            guard result == nil else { return false }
            result = outcome
            cont = continuation
            continuation = nil
            return true
        }
        cont?.resume(returning: outcome)
        return ok
    }

    var isResolved: Bool { lock.withLock { result != nil } }
}

/// Accepted session state. All mutation goes through `ReceiveStore`'s lock.
final class ReceiveSession: @unchecked Sendable {
    enum FileState { case waiting, receiving, done, failed }

    let info: ReceiveSessionInfo
    let tokens: [String: String]
    var fileStates: [String: FileState]
    var lastActivity = Date()
    var activeChannels: [ObjectIdentifier: Channel] = [:]

    init(info: ReceiveSessionInfo, tokens: [String: String]) {
        self.info = info
        self.tokens = tokens
        self.fileStates = Dictionary(uniqueKeysWithValues: tokens.keys.map { ($0, .waiting) })
    }

    var isComplete: Bool { fileStates.values.allSatisfy { $0 == .done || $0 == .failed } }
}

struct UploadTicket: Sendable {
    let sessionId: String
    let file: FileDto
    let saveDirectory: URL
}

/// The single-session state machine behind the server.
final class ReceiveStore: @unchecked Sendable {
    enum State {
        case idle
        case pending(PendingDecision)
        case active(ReceiveSession)
    }

    private let lock = NIOLock()
    private var state: State = .idle

    /// Claims the receiver for a new request. Returns nil if busy (409).
    func beginPending(_ request: IncomingRequest, staleAfter: TimeInterval) -> PendingDecision? {
        lock.withLock {
            switch state {
            case .idle:
                break
            case .pending(let p):
                if !p.isResolved { return nil }
            case .active(let s):
                // Drop stale sessions where the sender never uploaded.
                let busy = !s.activeChannels.isEmpty || Date().timeIntervalSince(s.lastActivity) < staleAfter
                if busy { return nil }
            }
            let p = PendingDecision(request: request)
            state = .pending(p)
            return p
        }
    }

    /// Clears a pending request (declined / timed out).
    func clearPending(_ p: PendingDecision) {
        lock.withLock {
            if case .pending(let cur) = state, cur === p { state = .idle }
        }
    }

    /// Promotes a pending request to an active session.
    func activate(_ p: PendingDecision, session: ReceiveSession) -> Bool {
        lock.withLock {
            guard case .pending(let cur) = state, cur === p else { return false }
            state = .active(session)
            return true
        }
    }

    enum UploadCheck { case ok(UploadTicket), forbidden, conflict }

    func beginUpload(sessionId: String, fileId: String, token: String, ip: String, channel: Channel) -> UploadCheck {
        lock.withLock {
            guard case .active(let s) = state, s.info.sessionId == sessionId else { return .forbidden }
            guard s.info.senderIP == ip, let expected = s.tokens[fileId], expected == token,
                  let file = s.info.files.first(where: { $0.id == fileId }) else { return .forbidden }
            switch s.fileStates[fileId] {
            case .receiving: return .conflict
            case .done: return .conflict
            default: break
            }
            s.fileStates[fileId] = .receiving
            s.lastActivity = Date()
            s.activeChannels[ObjectIdentifier(channel)] = channel
            return .ok(UploadTicket(sessionId: sessionId, file: file, saveDirectory: s.info.saveDirectory))
        }
    }

    func touch(sessionId: String) {
        lock.withLock {
            if case .active(let s) = state, s.info.sessionId == sessionId { s.lastActivity = Date() }
        }
    }

    /// Marks an upload finished. Returns whether the session is now complete (and was ended).
    func finishUpload(_ ticket: UploadTicket, success: Bool, channel: Channel) -> (sessionEnded: Bool, stillActive: Bool) {
        lock.withLock {
            guard case .active(let s) = state, s.info.sessionId == ticket.sessionId else { return (false, false) }
            s.fileStates[ticket.file.id] = success ? .done : .failed
            s.activeChannels[ObjectIdentifier(channel)] = nil
            s.lastActivity = Date()
            if s.isComplete {
                state = .idle
                return (true, true)
            }
            return (false, true)
        }
    }

    /// Resolves the final file location atomically w.r.t. other uploads in this process.
    func withFinalizeLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    enum CancelResult { case none, pending(PendingDecision), session(ReceiveSession) }

    /// Cancels the matching pending request or session.
    func cancel(sessionId: String?, ip: String) -> CancelResult {
        lock.withLock {
            switch state {
            case .idle:
                return .none
            case .pending(let p):
                guard p.request.senderIP == ip else { return .none }
                state = .idle
                return .pending(p)
            case .active(let s):
                if let sessionId, sessionId != s.info.sessionId { return .none }
                if sessionId == nil && s.info.senderIP != ip { return .none }
                state = .idle
                return .session(s)
            }
        }
    }

    /// Ends the active session from the receiver side (user cancel).
    func cancelActive(sessionId: String) -> ReceiveSession? {
        lock.withLock {
            guard case .active(let s) = state, s.info.sessionId == sessionId else { return nil }
            state = .idle
            return s
        }
    }

    func isSessionActive(_ sessionId: String) -> Bool {
        lock.withLock {
            if case .active(let s) = state { return s.info.sessionId == sessionId }
            return false
        }
    }
}
