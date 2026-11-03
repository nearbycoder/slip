import Crypto
import Foundation
import NIOSSL
@testable import SlipKit
import X509
import XCTest

final class IdentityTests: XCTestCase {
    func testFingerprintIsSHA256OfDER() throws {
        let id = try SlipIdentity.generate()
        let expected = SHA256.hash(data: id.certificateDER).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(id.certificateFingerprint, expected)
        XCTAssertEqual(id.certificateFingerprint.count, 64)
        XCTAssertEqual(id.certificateFingerprint, id.certificateFingerprint.lowercased())
        XCTAssertEqual(id.fingerprint(for: .https), id.certificateFingerprint)
        XCTAssertEqual(id.fingerprint(for: .http), id.httpFingerprint)
        XCTAssertEqual(id.httpFingerprint.count, 32)
        XCTAssertNotEqual(try SlipIdentity.generate().certificateFingerprint, id.certificateFingerprint)
    }

    func testCertificateContents() throws {
        let id = try SlipIdentity.generate()
        let cert = try Certificate(derEncoded: [UInt8](id.certificateDER))
        XCTAssertTrue(cert.subject.description.contains("CN=Slip"))
        XCTAssertEqual(cert.subject, cert.issuer)
        XCTAssertGreaterThan(cert.notValidAfter.timeIntervalSince(cert.notValidBefore), 10 * 365 * 86_400)
        // Loadable by NIOSSL (what the server uses).
        _ = try NIOSSLCertificate(bytes: [UInt8](id.certificateDER), format: .der)
        _ = try NIOSSLPrivateKey(bytes: [UInt8](id.privateKeyPEM.utf8), format: .pem)
    }

    func testPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slip-id-\(UUID().uuidString)/identity.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = try SlipIdentity.loadOrCreate(at: url)
        let b = try SlipIdentity.loadOrCreate(at: url)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.certificateFingerprint, b.certificateFingerprint)
    }
}
