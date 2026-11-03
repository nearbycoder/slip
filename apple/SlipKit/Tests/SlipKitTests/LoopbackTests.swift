import Crypto
import Foundation
@testable import SlipKit
import XCTest

/// Collects receiver events thread-safely.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ReceiverEvent] = []
    func add(_ e: ReceiverEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [ReceiverEvent] { lock.lock(); defer { lock.unlock() }; return events }

    var texts: [String] { all.compactMap { if case .textMessage(let t, _, _) = $0 { return t } else { return nil } } }
    var finishedURLs: [URL] { all.compactMap { if case .fileFinished(_, _, let u) = $0 { return u } else { return nil } } }
    var sessionsFinished: Int { all.filter { if case .sessionFinished = $0 { return true } else { return false } }.count }
}

/// A user decision the test controls.
final class DecisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<ReceiveDecision, Never>?
    private var waiting: [CheckedContinuation<IncomingRequest, Never>] = []
    private var lastRequest: IncomingRequest?

    func decide(_ r: IncomingRequest) async -> ReceiveDecision {
        await withCheckedContinuation { c in
            lock.lock()
            cont = c
            lastRequest = r
            let w = waiting
            waiting = []
            lock.unlock()
            w.forEach { $0.resume(returning: r) }
        }
    }

    func requestArrived() async -> IncomingRequest {
        await withCheckedContinuation { c in
            lock.lock()
            if let r = lastRequest, cont != nil { lock.unlock(); c.resume(returning: r); return }
            waiting.append(c)
            lock.unlock()
        }
    }

    func resolve(_ d: ReceiveDecision) {
        lock.lock()
        let c = cont
        cont = nil
        lastRequest = nil
        lock.unlock()
        c?.resume(returning: d)
    }
}

final class LoopbackTests: XCTestCase {
    var tempDirs: [URL] = []

    override func tearDown() {
        tempDirs.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func makeDir(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("slip-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func makeServer(transport: TransportProtocol, saveDir: URL, pin: String? = nil, autoAccept: Bool = true,
                    gate: DecisionGate? = nil, log: EventLog, timeout: TimeInterval = 60) async throws -> (SlipServer, PeerAddress) {
        let identity = try SlipIdentity.generate()
        let info = DeviceInfo(alias: "Receiver", deviceModel: "Test", deviceType: .headless,
                              fingerprint: identity.fingerprint(for: transport), protocol: transport)
        let config = ReceiverConfiguration(port: 0, transport: transport, saveDirectory: saveDir, pin: pin,
                                           autoAccept: autoAccept, decisionTimeout: timeout, bindHost: "127.0.0.1")
        let server = SlipServer(identity: identity, deviceInfo: info, configuration: config,
                                decide: { req in await gate?.decide(req) ?? .decline },
                                events: { log.add($0) })
        let port = try await server.start()
        return (server, PeerAddress(host: "127.0.0.1", port: port, transport: transport))
    }

    func senderInfo() -> DeviceInfo {
        DeviceInfo(alias: "Sender", deviceModel: "Test", deviceType: .desktop, fingerprint: UUID().uuidString)
    }

    func makeSourceFiles() throws -> (URL, [URL]) {
        let src = try makeDir("src")
        let big = src.appendingPathComponent("big.bin")
        var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024 + 17)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: big)
        let folder = src.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("2024/two.txt"))
        let empty = src.appendingPathComponent("empty.dat")
        try Data().write(to: empty)
        return (src, [big, folder, empty])
    }

    func assertTransfer(_ transport: TransportProtocol, sha256: Bool) async throws {
        let save = try makeDir("save")
        let log = EventLog()
        let (server, addr) = try await makeServer(transport: transport, saveDir: save, log: log)
        defer { Task { await server.stop() } }

        let (src, inputs) = try makeSourceFiles()
        let items = try SendItem.items(for: inputs)
        XCTAssertEqual(Set(items.map(\.fileName)), ["big.bin", "Album/one.txt", "Album/2024/two.txt", "empty.dat"])
        var sender = SlipSender()
        sender.includeSHA256 = sha256
        let progress = EventCounter()
        let outcome = await sender.send(items, to: addr, as: senderInfo()) { e in
            if case .fileProgress = e { progress.increment() }
        }
        XCTAssertEqual(outcome, .completed)
        XCTAssertGreaterThan(progress.value, 0)
        for rel in ["big.bin", "Album/one.txt", "Album/2024/two.txt", "empty.dat"] {
            let a = try Data(contentsOf: src.appendingPathComponent(rel))
            let b = try Data(contentsOf: save.appendingPathComponent(rel))
            XCTAssertEqual(a, b, "\(rel) differs")
        }
        // No partial files left behind.
        let leftovers = FileManager.default.enumerator(atPath: save.path)?.compactMap { $0 as? String }
            .filter { $0.contains(".slip-partial-") } ?? []
        XCTAssertEqual(leftovers, [])
        try await waitUntil { log.sessionsFinished == 1 }

        // Second send of the same name gets " (1)".
        let again = await sender.send(try SendItem.items(for: [inputs[2]]), to: addr, as: senderInfo())
        XCTAssertEqual(again, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: save.appendingPathComponent("empty (1).dat").path))
    }

    func testHTTPSTransfer() async throws { try await assertTransfer(.https, sha256: false) }
    func testHTTPTransfer() async throws { try await assertTransfer(.http, sha256: true) }

    func testInfoRegisterAndUnknownRoutes() async throws {
        let log = EventLog()
        let (server, addr) = try await makeServer(transport: .https, saveDir: try makeDir("save"), log: log)
        defer { Task { await server.stop() } }
        let client = SlipClient()
        let info = try await client.info(at: addr)
        XCTAssertEqual(info.alias, "Receiver")
        XCTAssertEqual(info.fingerprint, server.identity.certificateFingerprint)
        XCTAssertEqual(info.port, addr.port)

        let me = senderInfo()
        let reg = try await client.register(at: addr, info: me)
        XCTAssertEqual(reg.alias, "Receiver")
        try await waitUntil {
            log.all.contains { if case .peerRegistered(let p, "127.0.0.1") = $0 { return p.alias == "Sender" } else { return false } }
        }

        var r = URLRequest(url: URL(string: "https://127.0.0.1:\(addr.port)/api/localsend/v1/info")!)
        r.httpMethod = "GET"
        let (_, resp) = try await RawClient.shared.session.data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
    }

    func testPinRequired() async throws {
        let save = try makeDir("save")
        let (server, addr) = try await makeServer(transport: .https, saveDir: save, pin: "123456", log: EventLog())
        defer { Task { await server.stop() } }
        let (_, inputs) = try makeSourceFiles()
        let items = try SendItem.items(for: [inputs[2]])
        let sender = SlipSender()
        let none = await sender.send(items, to: addr, as: senderInfo())
        XCTAssertEqual(none, .pinRequired)
        let wrong = await sender.send(items, to: addr, as: senderInfo(), pin: "000000")
        XCTAssertEqual(wrong, .pinRequired)
        let right = await sender.send(items, to: addr, as: senderInfo(), pin: "123456")
        XCTAssertEqual(right, .completed)
    }

    func testDeclineAndBusy() async throws {
        let gate = DecisionGate()
        let log = EventLog()
        let (server, addr) = try await makeServer(transport: .https, saveDir: try makeDir("save"), autoAccept: false,
                                                  gate: gate, log: log)
        defer { Task { await server.stop() } }
        let (_, inputs) = try makeSourceFiles()
        let items = try SendItem.items(for: inputs)
        let sender = SlipSender()
        let info = senderInfo()

        let first = Task { await sender.send(items, to: addr, as: info) }
        let request = await gate.requestArrived()
        XCTAssertEqual(request.files.count, 4)
        XCTAssertEqual(request.sender.alias, "Sender")
        XCTAssertEqual(request.senderIP, "127.0.0.1")

        // Another sender while the first request is held open → 409.
        let busy = await sender.send(items, to: addr, as: senderInfo())
        XCTAssertEqual(busy, .busy)

        gate.resolve(.decline)
        let declined = await first.value
        XCTAssertEqual(declined, .declined)

        // After declining the receiver is free again; accept only a subset.
        let second = Task { await sender.send(items, to: addr, as: info) }
        let req2 = await gate.requestArrived()
        let big = try XCTUnwrap(req2.files.first { $0.fileName == "big.bin" })
        gate.resolve(.accept([big.id]))
        let partial = await second.value
        XCTAssertEqual(partial, .completed)
        try await waitUntil { log.finishedURLs.count == 1 }
        XCTAssertEqual(log.finishedURLs.first?.lastPathComponent, "big.bin")
    }

    func testDecisionTimeoutGives403() async throws {
        let gate = DecisionGate()
        let log = EventLog()
        let (server, addr) = try await makeServer(transport: .http, saveDir: try makeDir("save"), autoAccept: false,
                                                  gate: gate, log: log, timeout: 0.5)
        defer { Task { await server.stop() } }
        let outcome = await SlipSender().send([.data(Data("x".utf8), fileName: "x.bin")], to: addr, as: senderInfo())
        XCTAssertEqual(outcome, .declined)
        XCTAssertTrue(log.all.contains { if case .requestWithdrawn = $0 { return true } else { return false } })
        gate.resolve(.decline)
    }

    func testTextMessageReturns204() async throws {
        let log = EventLog()
        let gate = DecisionGate()
        let (server, addr) = try await makeServer(transport: .https, saveDir: try makeDir("save"), autoAccept: false,
                                                  gate: gate, log: log)
        defer { Task { await server.stop() } }
        let result = try await SlipClient().prepareUpload(
            at: addr, request: PrepareUploadRequest(info: senderInfo(), files: ["t": SendItem.text("Hi there").dto(sha256: nil)].mapKeys(\.id)))
        XCTAssertEqual(result, .finished)
        let outcome = await SlipSender().send([.text("Second")], to: addr, as: senderInfo())
        XCTAssertEqual(outcome, .delivered)
        try await waitUntil { log.texts == ["Hi there", "Second"] }
    }

    func testUploadValidation() async throws {
        let save = try makeDir("save")
        let log = EventLog()
        let (server, addr) = try await makeServer(transport: .http, saveDir: save, log: log)
        defer { Task { await server.stop() } }
        let client = SlipClient()
        let payload = Data("payload bytes".utf8)
        let good = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let files = [
            "ok": FileDto(id: "ok", fileName: "ok.txt", size: Int64(payload.count), fileType: "application/octet-stream", sha256: good),
            "bad": FileDto(id: "bad", fileName: "bad.txt", size: Int64(payload.count), fileType: "application/octet-stream",
                           sha256: String(repeating: "0", count: 64)),
            "evil": FileDto(id: "evil", fileName: "../../evil.txt", size: Int64(payload.count), fileType: "application/octet-stream"),
        ]
        guard case .accepted(let resp) = try await client.prepareUpload(at: addr, request: PrepareUploadRequest(info: senderInfo(), files: files)) else {
            return XCTFail("not accepted")
        }
        XCTAssertEqual(Set(resp.files.keys), ["ok", "bad", "evil"])

        // Missing params → 400, bad token → 403, wrong session → 403.
        let s1 = try await RawClient.post(addr, "upload?sessionId=\(resp.sessionId)", body: payload)
        XCTAssertEqual(s1, 400)
        let s2 = try await RawClient.post(addr, "upload?sessionId=\(resp.sessionId)&fileId=ok&token=nope", body: payload)
        XCTAssertEqual(s2, 403)
        let s3 = try await RawClient.post(addr, "upload?sessionId=x&fileId=ok&token=\(resp.files["ok"]!)", body: payload)
        XCTAssertEqual(s3, 403)

        // Checksum mismatch → 422 and nothing kept.
        do {
            try await client.upload(at: addr, sessionId: resp.sessionId, fileId: "bad", token: resp.files["bad"]!, data: payload) { _ in }
            XCTFail("expected 422")
        } catch let SlipClientError.httpStatus(code) {
            XCTAssertEqual(code, 422)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: save.appendingPathComponent("bad.txt").path))

        try await client.upload(at: addr, sessionId: resp.sessionId, fileId: "ok", token: resp.files["ok"]!, data: payload) { _ in }
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("ok.txt")), payload)
        // Re-uploading a finished file is rejected.
        let s4 = try await RawClient.post(addr, "upload?sessionId=\(resp.sessionId)&fileId=ok&token=\(resp.files["ok"]!)", body: payload)
        XCTAssertEqual(s4, 409)

        // Path traversal is sanitised into the save dir.
        try await client.upload(at: addr, sessionId: resp.sessionId, fileId: "evil", token: resp.files["evil"]!, data: payload) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: save.appendingPathComponent("evil.txt").path))
        try await waitUntil { log.sessionsFinished == 1 }

        // Session is over: further uploads are forbidden.
        let s5 = try await RawClient.post(addr, "upload?sessionId=\(resp.sessionId)&fileId=ok&token=\(resp.files["ok"]!)", body: payload)
        XCTAssertEqual(s5, 403)
    }

    func testSenderCancel() async throws {
        let log = EventLog()
        let (server, addr) = try await makeServer(transport: .http, saveDir: try makeDir("save"), log: log)
        defer { Task { await server.stop() } }
        let client = SlipClient()
        let files = ["a": FileDto(id: "a", fileName: "a.bin", size: 10, fileType: "application/octet-stream")]
        guard case .accepted(let resp) = try await client.prepareUpload(at: addr, request: PrepareUploadRequest(info: senderInfo(), files: files)) else {
            return XCTFail("not accepted")
        }
        // Busy while the session is active.
        let busy = try await client.prepareUpload(at: addr, request: PrepareUploadRequest(info: senderInfo(), files: files))
        XCTAssertEqual(busy, .busy)
        await client.cancel(at: addr, sessionId: resp.sessionId)
        try await waitUntil {
            log.all.contains { if case .sessionFinished(_, true) = $0 { return true } else { return false } }
        }
        let again = try await client.prepareUpload(at: addr, request: PrepareUploadRequest(info: senderInfo(), files: files))
        if case .accepted = again {} else { XCTFail("expected accepted after cancel, got \(again)") }
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Plain URLSession that trusts self-signed certs, for raw status-code checks.
final class RawClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = RawClient()
    lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.useCredential, challenge.protectionSpace.serverTrust.map(URLCredential.init(trust:)))
    }

    static func post(_ addr: PeerAddress, _ pathAndQuery: String, body: Data) async throws -> Int {
        var r = URLRequest(url: URL(string: "\(addr.transport.rawValue)://\(addr.host):\(addr.port)\(SlipConstants.apiPrefix)/\(pathAndQuery)")!)
        r.httpMethod = "POST"
        r.httpBody = body
        let (_, resp) = try await shared.session.data(for: r)
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }
}

extension Dictionary where Key == String, Value == FileDto {
    func mapKeys(_ key: KeyPath<FileDto, String>) -> [String: FileDto] {
        Dictionary(uniqueKeysWithValues: values.map { ($0[keyPath: key], $0) })
    }
}
