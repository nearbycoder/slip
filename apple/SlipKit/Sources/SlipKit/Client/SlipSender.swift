import Crypto
import Foundation
import UniformTypeIdentifiers

/// One thing to send.
public struct SendItem: Sendable, Identifiable, Hashable {
    public enum Source: Sendable, Hashable {
        case file(URL)
        case data(Data)
    }

    public let id: String
    /// Name on the receiver, may contain `/` for folder sends (`Photos/2024/a.jpg`).
    public var fileName: String
    public var size: Int64
    public var mimeType: String
    public var modified: Date?
    public var source: Source
    /// Set for text messages.
    public var preview: String?

    public init(id: String = UUID().uuidString, fileName: String, size: Int64, mimeType: String,
                modified: Date? = nil, source: Source, preview: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.mimeType = mimeType
        self.modified = modified
        self.source = source
        self.preview = preview
    }

    /// A single file on disk.
    public static func file(_ url: URL, name: String? = nil) throws -> SendItem {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileName = name ?? url.lastPathComponent
        return SendItem(fileName: fileName, size: Int64(values.fileSize ?? 0),
                        mimeType: mimeType(forFileName: fileName), modified: values.contentModificationDate,
                        source: .file(url))
    }

    /// In-memory data (e.g. from a photo picker).
    public static func data(_ data: Data, fileName: String, mimeType: String? = nil) -> SendItem {
        SendItem(fileName: fileName, size: Int64(data.count), mimeType: mimeType ?? Self.mimeType(forFileName: fileName),
                 modified: Date(), source: .data(data))
    }

    /// A text message: `<uuid>.txt`, `text/plain`, preview = the text.
    public static func text(_ text: String) -> SendItem {
        let data = Data(text.utf8)
        return SendItem(fileName: "\(UUID().uuidString).txt", size: Int64(data.count), mimeType: "text/plain",
                        source: .data(data), preview: text)
    }

    /// Files and folders (recursively, `fileName` = relative path including the folder name).
    public static func items(for urls: [URL]) throws -> [SendItem] {
        var result: [SendItem] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            if !isDir.boolValue {
                result.append(try .file(url))
                continue
            }
            let root = url.standardizedFileURL.resolvingSymlinksInPath()
            let folderName = root.lastPathComponent
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let child as URL in e {
                guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let full = child.standardizedFileURL.resolvingSymlinksInPath().path
                let rel = String(full.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                result.append(try .file(child, name: folderName + "/" + rel))
            }
        }
        return result
    }

    public static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    func dto(sha256: String?) -> FileDto {
        FileDto(id: id, fileName: fileName, size: size, fileType: mimeType, sha256: sha256, preview: preview,
                metadata: preview == nil ? FileMetadata(modified: modified, accessed: nil) : nil)
    }
}

public enum SendOutcome: Sendable, Equatable {
    case completed
    /// 204 — e.g. a text message; nothing uploaded.
    case delivered
    case pinRequired
    case declined
    case busy
    case tooManyRequests
    case cancelled
    case failed(String)

    public var message: String {
        switch self {
        case .completed: return "Sent"
        case .delivered: return "Delivered"
        case .pinRequired: return "PIN required"
        case .declined: return "Declined"
        case .busy: return "Receiver is busy"
        case .tooManyRequests: return "Too many requests"
        case .cancelled: return "Cancelled"
        case .failed(let s): return s
        }
    }
}

public enum SendEvent: Sendable {
    case waitingForAcceptance
    case accepted(sessionId: String, fileIds: Set<String>)
    case fileProgress(fileId: String, sent: Int64, total: Int64)
    case fileFinished(fileId: String)
    case fileFailed(fileId: String, reason: String)
}

/// Runs a full send: prepare-upload → parallel uploads → done/cancel.
public struct SlipSender: Sendable {
    public var client: SlipClient
    public var maxParallelUploads = 3
    /// Compute and send sha256 for files (costs a full read before sending).
    public var includeSHA256 = false

    public init(client: SlipClient = SlipClient()) { self.client = client }

    public func send(_ items: [SendItem], to peer: PeerAddress, as info: DeviceInfo, pin: String? = nil,
                     events: @escaping @Sendable (SendEvent) -> Void = { _ in }) async -> SendOutcome {
        guard !items.isEmpty else { return .failed("Nothing to send") }
        var files: [String: FileDto] = [:]
        for item in items {
            let sha = includeSHA256 ? (try? Self.sha256(of: item)) : nil
            files[item.id] = item.dto(sha256: sha)
        }
        events(.waitingForAcceptance)
        let result: PrepareUploadResult
        do {
            result = try await client.prepareUpload(at: peer, request: PrepareUploadRequest(info: info, files: files), pin: pin)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .failed(error.localizedDescription)
        }
        let response: PrepareUploadResponse
        switch result {
        case .accepted(let r): response = r
        case .finished: return .delivered
        case .pinRequired: return .pinRequired
        case .declined: return .declined
        case .busy: return .busy
        case .tooManyRequests: return .tooManyRequests
        case .failed(let status): return .failed("Receiver answered HTTP \(status)")
        }

        let accepted = items.filter { response.files[$0.id] != nil }
        events(.accepted(sessionId: response.sessionId, fileIds: Set(accepted.map(\.id))))
        if accepted.isEmpty { return .completed }

        let client = self.client
        let parallel = max(1, maxParallelUploads)
        let failures: [String] = await withTaskGroup(of: String?.self) { group in
            var iterator = accepted.makeIterator()
            func addNext() -> Bool {
                guard let item = iterator.next(), let token = response.files[item.id] else { return false }
                group.addTask {
                    let progress: @Sendable (Int64) -> Void = { sent in
                        events(.fileProgress(fileId: item.id, sent: sent, total: item.size))
                    }
                    do {
                        switch item.source {
                        case .file(let url):
                            try await client.upload(at: peer, sessionId: response.sessionId, fileId: item.id,
                                                    token: token, fileURL: url, progress: progress)
                        case .data(let data):
                            try await client.upload(at: peer, sessionId: response.sessionId, fileId: item.id,
                                                    token: token, data: data, progress: progress)
                        }
                        events(.fileProgress(fileId: item.id, sent: item.size, total: item.size))
                        events(.fileFinished(fileId: item.id))
                        return nil
                    } catch {
                        let reason = Task.isCancelled ? "Cancelled" : error.localizedDescription
                        events(.fileFailed(fileId: item.id, reason: reason))
                        return reason
                    }
                }
                return true
            }
            for _ in 0..<parallel { if !addNext() { break } }
            var failures: [String] = []
            while let r = await group.next() {
                if let r { failures.append(r) }
                if !Task.isCancelled { _ = addNext() }
            }
            return failures
        }

        if Task.isCancelled {
            await Task.detached { await client.cancel(at: peer, sessionId: response.sessionId) }.value
            return .cancelled
        }
        if failures.isEmpty { return .completed }
        return .failed(failures.count == accepted.count ? failures[0] : "\(failures.count) of \(accepted.count) files failed")
    }

    static func sha256(of item: SendItem) throws -> String {
        var hasher = SHA256()
        switch item.source {
        case .data(let d):
            hasher.update(data: d)
        case .file(let url):
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
