import Foundation

/// Where a peer's HTTP(S) server lives.
public struct PeerAddress: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var transport: TransportProtocol

    public init(host: String, port: Int = SlipConstants.defaultPort, transport: TransportProtocol = .https) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    public var description: String { "\(transport.rawValue)://\(host):\(port)" }

    func url(_ route: String, query: [String: String] = [:]) -> URL {
        var c = URLComponents()
        c.scheme = transport.rawValue
        c.host = host
        c.port = port
        c.path = SlipConstants.apiPrefix + "/" + route
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url!
    }

    /// Parses `host:port` (port defaults to 53317).
    public init?(parsing string: String, transport: TransportProtocol) {
        let parts = string.split(separator: ":")
        guard let host = parts.first, !host.isEmpty, parts.count <= 2 else { return nil }
        let port = parts.count == 2 ? Int(parts[1]) : SlipConstants.defaultPort
        guard let port else { return nil }
        self.init(host: String(host), port: port, transport: transport)
    }
}

public enum PrepareUploadResult: Sendable, Equatable {
    case accepted(PrepareUploadResponse)
    /// 204: nothing to upload (text message delivered).
    case finished
    case pinRequired
    case declined
    case busy
    case tooManyRequests
    case failed(status: Int)
}

public enum SlipClientError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let s): return "Receiver answered HTTP \(s)"
        case .invalidResponse: return "Invalid response from receiver"
        }
    }
}

/// HTTP(S) client for the LocalSend v2 API. Accepts the self-signed certificates
/// LocalSend peers use (for these endpoints only — this session is never used for
/// anything else).
public final class SlipClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(requestTimeout: TimeInterval = 15) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func jsonRequest(_ url: URL, method: String = "POST", body: Data?, timeout: TimeInterval?) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let timeout { r.timeoutInterval = timeout }
        return r
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SlipClientError.invalidResponse }
        return (data, http.statusCode)
    }

    public func info(at peer: PeerAddress, timeout: TimeInterval? = nil) async throws -> DeviceInfo {
        let (data, status) = try await perform(jsonRequest(peer.url("info"), method: "GET", body: nil, timeout: timeout))
        guard status == 200 else { throw SlipClientError.httpStatus(status) }
        return try SlipJSON.decode(DeviceInfo.self, from: data)
    }

    /// POST /register with our info; returns the peer's info.
    public func register(at peer: PeerAddress, info: DeviceInfo, timeout: TimeInterval? = nil) async throws -> DeviceInfo {
        let body = try SlipJSON.encode(info)
        let (data, status) = try await perform(jsonRequest(peer.url("register"), body: body, timeout: timeout))
        guard status == 200 else { throw SlipClientError.httpStatus(status) }
        var peerInfo = try SlipJSON.decode(DeviceInfo.self, from: data)
        // The register response may omit port/protocol: we reached it on this address.
        if !Self.hasKey("port", in: data) { peerInfo.port = peer.port }
        if !Self.hasKey("protocol", in: data) { peerInfo.protocol = peer.transport }
        return peerInfo
    }

    static func hasKey(_ key: String, in data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[key] != nil
    }

    /// POST /prepare-upload. Held open by the receiver until the user decides.
    public func prepareUpload(at peer: PeerAddress, request: PrepareUploadRequest, pin: String? = nil,
                              timeout: TimeInterval = 120) async throws -> PrepareUploadResult {
        let body = try SlipJSON.encode(request)
        let url = peer.url("prepare-upload", query: pin.map { ["pin": $0] } ?? [:])
        let (data, status) = try await perform(jsonRequest(url, body: body, timeout: timeout))
        switch status {
        case 200:
            return .accepted(try SlipJSON.decode(PrepareUploadResponse.self, from: data))
        case 204: return .finished
        case 401: return .pinRequired
        case 403: return .declined
        case 409: return .busy
        case 429: return .tooManyRequests
        default: return .failed(status: status)
        }
    }

    /// Streams `fileURL` to the receiver. `progress` gets total bytes sent so far.
    public func upload(at peer: PeerAddress, sessionId: String, fileId: String, token: String,
                       fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let request = uploadRequest(peer, sessionId: sessionId, fileId: fileId, token: token)
        let delegate = UploadProgressDelegate(progress: progress)
        let (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        try Self.check(response)
    }

    public func upload(at peer: PeerAddress, sessionId: String, fileId: String, token: String,
                       data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let request = uploadRequest(peer, sessionId: sessionId, fileId: fileId, token: token)
        let delegate = UploadProgressDelegate(progress: progress)
        let (_, response) = try await session.upload(for: request, from: data, delegate: delegate)
        try Self.check(response)
    }

    private func uploadRequest(_ peer: PeerAddress, sessionId: String, fileId: String, token: String) -> URLRequest {
        var r = URLRequest(url: peer.url("upload", query: ["sessionId": sessionId, "fileId": fileId, "token": token]))
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 60
        return r
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SlipClientError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 204 else { throw SlipClientError.httpStatus(http.statusCode) }
    }

    /// POST /cancel. Errors are ignored.
    public func cancel(at peer: PeerAddress, sessionId: String) async {
        let r = jsonRequest(peer.url("cancel", query: ["sessionId": sessionId]), body: nil, timeout: 5)
        _ = try? await perform(r)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}
