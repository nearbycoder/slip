import Crypto
import Foundation
import X509

/// Persistent device identity: a P-256 key, a self-signed certificate (CN=Slip, 20 years)
/// and the random fingerprint used in HTTP mode.
public struct SlipIdentity: Sendable, Codable, Equatable {
    /// PKCS#8 PEM of the private key.
    public let privateKeyPEM: String
    /// DER of the self-signed certificate.
    public let certificateDER: Data
    /// Random 32-char hex string advertised as fingerprint when HTTPS is off.
    public let httpFingerprint: String

    /// Lowercase hex SHA-256 of the certificate DER.
    public var certificateFingerprint: String { Self.sha256Hex(certificateDER) }

    public func fingerprint(for transport: TransportProtocol) -> String {
        transport == .https ? certificateFingerprint : httpFingerprint
    }

    public static func generate(commonName: String = "Slip") throws -> SlipIdentity {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Slip")
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(20 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        let der = Data(try cert.serializeAsPEM().derBytes)
        return SlipIdentity(privateKeyPEM: key.pemRepresentation, certificateDER: der,
                            httpFingerprint: randomHex(byteCount: 16))
    }

    /// Loads the identity stored at `url`, generating and saving a new one if needed.
    public static func loadOrCreate(at url: URL) throws -> SlipIdentity {
        if let data = try? Data(contentsOf: url),
           let identity = try? JSONDecoder().decode(SlipIdentity.self, from: data),
           !identity.certificateDER.isEmpty {
            return identity
        }
        let identity = try generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: url, options: [.atomic])
        #if os(macOS) || os(iOS)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
        return identity
    }

    /// Default location: Application Support/Slip/identity.json.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Slip", isDirectory: true).appendingPathComponent("identity.json")
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(byteCount: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

/// Default `deviceModel` / `deviceType` for this OS.
public enum DeviceDefaults {
    public static var deviceType: DeviceType {
        #if os(iOS)
        return .mobile
        #else
        return .desktop
        #endif
    }

    public static var deviceModel: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        let machine: String = {
            if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.machine", &buf, &size, nil, 0)
            return String(cString: buf)
        }()
        return machine.hasPrefix("iPad") ? "iPad" : "iPhone"
        #else
        return "Apple"
        #endif
    }
}
