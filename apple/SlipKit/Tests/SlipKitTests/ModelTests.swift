import Foundation
@testable import SlipKit
import XCTest

final class ModelTests: XCTestCase {
    func testDeviceInfoRoundTrip() throws {
        let info = DeviceInfo(alias: "Nice Orange", deviceModel: "macOS", deviceType: .desktop,
                              fingerprint: "abc", port: 53320, protocol: .http, download: false)
        let data = try SlipJSON.encode(info)
        let back = try SlipJSON.decode(DeviceInfo.self, from: data)
        XCTAssertEqual(back, info)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["version"] as? String, "2.1")
        XCTAssertEqual(obj["protocol"] as? String, "http")
        XCTAssertEqual(obj["port"] as? Int, 53320)
    }

    func testDeviceInfoLenientDefaults() throws {
        let json = #"{"alias":"Secret Banana","version":"2.0","fingerprint":"f","deviceModel":null,"extra":{"x":1}}"#
        let info = try SlipJSON.decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.alias, "Secret Banana")
        XCTAssertNil(info.deviceModel)
        XCTAssertNil(info.deviceType)
        XCTAssertEqual(info.port, 53317)
        XCTAssertEqual(info.protocol, .https)
        XCTAssertFalse(info.download)
    }

    func testUnknownDeviceTypeFallsBackToDesktop() throws {
        let json = #"{"alias":"A","version":"2.0","fingerprint":"f","deviceType":"toaster","port":"1234","protocol":"weird","download":1}"#
        let info = try SlipJSON.decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.deviceType, .desktop)
        XCTAssertEqual(info.port, 1234)
        XCTAssertEqual(info.protocol, .https)
        XCTAssertTrue(info.download)
    }

    func testMulticastPacketAcceptsLegacyAnnouncementKey() throws {
        let legacy = #"{"alias":"A","fingerprint":"f","announcement":true}"#
        XCTAssertTrue(try SlipJSON.decode(MulticastPacket.self, from: Data(legacy.utf8)).announce)
        let modern = #"{"alias":"A","fingerprint":"f","announce":false,"announcement":true}"#
        XCTAssertFalse(try SlipJSON.decode(MulticastPacket.self, from: Data(modern.utf8)).announce)
        let none = #"{"alias":"A","fingerprint":"f"}"#
        XCTAssertFalse(try SlipJSON.decode(MulticastPacket.self, from: Data(none.utf8)).announce)
    }

    func testMulticastPacketEncodesBothKeys() throws {
        let p = MulticastPacket(info: DeviceInfo(alias: "A", deviceModel: nil, deviceType: .mobile, fingerprint: "f"), announce: true)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: SlipJSON.encode(p)) as? [String: Any])
        XCTAssertEqual(obj["announce"] as? Bool, true)
        XCTAssertEqual(obj["announcement"] as? Bool, true)
        XCTAssertEqual(obj["alias"] as? String, "A")
        XCTAssertEqual(obj["deviceType"] as? String, "mobile")
        XCTAssertTrue(obj.keys.contains("deviceModel"))
    }

    func testFileDtoRoundTripAndLenient() throws {
        let date = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01T12:00:00Z
        let f = FileDto(id: "1", fileName: "a.png", size: 123, fileType: "image/png",
                        metadata: FileMetadata(modified: date))
        let data = try SlipJSON.encode(f)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("2024-01-01T12:00:00Z"))
        XCTAssertEqual(try SlipJSON.decode(FileDto.self, from: data), f)

        let minimal = #"{"id":"x","fileName":"b.jpg","size":5.0,"fileType":"image/jpeg","metadata":{"modified":"2021-01-01T12:34:56.789Z","accessed":null},"legacy":true}"#
        let m = try SlipJSON.decode(FileDto.self, from: Data(minimal.utf8))
        XCTAssertEqual(m.size, 5)
        XCTAssertNil(m.sha256)
        XCTAssertNil(m.preview)
        XCTAssertNotNil(m.metadata?.modified)
        XCTAssertNil(m.metadata?.accessed)
    }

    func testPrepareUploadRequestDecodingAndTextDetection() throws {
        let json = #"""
        {"info":{"alias":"Nice Orange","version":"2.0","deviceModel":"Samsung","deviceType":"mobile","fingerprint":"r","port":53317,"protocol":"https","download":true},
         "files":{"id1":{"id":"id1","fileName":"m.txt","size":5,"fileType":"text/plain","sha256":null,"preview":"hello"}}}
        """#
        let req = try SlipJSON.decode(PrepareUploadRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.info.deviceType, .mobile)
        XCTAssertTrue(req.isTextMessage)
        var notText = req
        notText.files["id2"] = FileDto(id: "id2", fileName: "x.bin", size: 1, fileType: "application/octet-stream")
        XCTAssertFalse(notText.isTextMessage)
    }

    func testPrepareUploadResponseRoundTrip() throws {
        let r = PrepareUploadResponse(sessionId: "s", files: ["a": "t1", "b": "t2"])
        XCTAssertEqual(try SlipJSON.decode(PrepareUploadResponse.self, from: SlipJSON.encode(r)), r)
    }

    func testTextSendItem() {
        let item = SendItem.text("héllo")
        XCTAssertEqual(item.mimeType, "text/plain")
        XCTAssertEqual(item.size, 6)
        XCTAssertTrue(item.fileName.hasSuffix(".txt"))
        XCTAssertEqual(item.preview, "héllo")
    }

    func testAliasGenerator() {
        for _ in 0..<50 {
            let alias = AliasGenerator.random()
            let parts = alias.split(separator: " ").map(String.init)
            XCTAssertEqual(parts.count, 2)
            XCTAssertTrue(AliasGenerator.adjectives.contains(parts[0]))
            XCTAssertTrue(AliasGenerator.fruits.contains(parts[1]))
        }
        XCTAssertEqual(AliasGenerator.adjectives.count, 38)
        XCTAssertEqual(AliasGenerator.fruits.count, 26)
    }

    func testPeerAddressParsing() {
        XCTAssertEqual(PeerAddress(parsing: "10.0.0.2:53320", transport: .http),
                       PeerAddress(host: "10.0.0.2", port: 53320, transport: .http))
        XCTAssertEqual(PeerAddress(parsing: "10.0.0.2", transport: .https)?.port, 53317)
        XCTAssertNil(PeerAddress(parsing: "10.0.0.2:abc", transport: .https))
    }

    func testSubnetScanHosts() {
        let iface = IPv4Interface(name: "en0", address: "192.168.1.10", netmask: "255.255.255.0",
                                  addressValue: 0xC0A8_010A, netmaskValue: 0xFFFF_FF00, supportsMulticast: true)
        let hosts = iface.scanHosts()
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("192.168.1.10"))
        XCTAssertFalse(hosts.contains("192.168.1.0"))
        XCTAssertFalse(hosts.contains("192.168.1.255"))
        let wide = IPv4Interface(name: "en0", address: "10.1.2.3", netmask: "255.255.0.0",
                                 addressValue: 0x0A01_0203, netmaskValue: 0xFFFF_0000, supportsMulticast: true)
        XCTAssertEqual(wide.scanHosts().count, 253) // clamped to the /24
    }
}

final class PathSanitizerTests: XCTestCase {
    func testSegments() {
        XCTAssertEqual(PathSanitizer.segments(of: "a.png"), ["a.png"])
        XCTAssertEqual(PathSanitizer.segments(of: "Photos/2024/a.jpg"), ["Photos", "2024", "a.jpg"])
        XCTAssertEqual(PathSanitizer.segments(of: "/etc/passwd"), ["etc", "passwd"])
        XCTAssertEqual(PathSanitizer.segments(of: "../../x/../y.txt"), ["x", "y.txt"])
        XCTAssertEqual(PathSanitizer.segments(of: "./a/./b"), ["a", "b"])
        XCTAssertEqual(PathSanitizer.segments(of: "a\\..\\b.txt"), ["a_.._b.txt"])
        XCTAssertEqual(PathSanitizer.segments(of: "we:ird\u{0}.txt"), ["we_ird_.txt"])
        XCTAssertEqual(PathSanitizer.segments(of: ".."), ["file"])
        XCTAssertEqual(PathSanitizer.segments(of: ""), ["file"])
        XCTAssertEqual(PathSanitizer.segments(of: "//a//b"), ["a", "b"])
    }

    func testUniqueDestination() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slip-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try PathSanitizer.uniqueDestination(for: "../sub/a.txt", in: dir)
        XCTAssertEqual(first.path, dir.appendingPathComponent("sub/a.txt").path)
        try Data("1".utf8).write(to: first)
        let second = try PathSanitizer.uniqueDestination(for: "sub/a.txt", in: dir)
        XCTAssertEqual(second.lastPathComponent, "a (1).txt")
        try Data("2".utf8).write(to: second)
        XCTAssertEqual(try PathSanitizer.uniqueDestination(for: "sub/a.txt", in: dir).lastPathComponent, "a (2).txt")

        let noExt = try PathSanitizer.uniqueDestination(for: "README", in: dir)
        try Data().write(to: noExt)
        XCTAssertEqual(try PathSanitizer.uniqueDestination(for: "README", in: dir).lastPathComponent, "README (1)")

        let hidden = try PathSanitizer.uniqueDestination(for: ".env", in: dir)
        try Data().write(to: hidden)
        XCTAssertEqual(try PathSanitizer.uniqueDestination(for: ".env", in: dir).lastPathComponent, ".env (1)")
        // Never escapes the directory.
        XCTAssertTrue(try PathSanitizer.uniqueDestination(for: "/../../../tmp/x", in: dir).path.hasPrefix(dir.path))
    }
}
