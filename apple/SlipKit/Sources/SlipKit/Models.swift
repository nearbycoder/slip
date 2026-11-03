import Foundation

/// Protocol-wide constants (see protocol/IMPLEMENTATION.md).
public enum SlipConstants {
    public static let protocolVersion = "2.1"
    public static let defaultPort = 53317
    public static let multicastGroup = "224.0.0.167"
    public static let multicastPort = 53317
    public static let apiPrefix = "/api/localsend/v2"
}

/// `deviceType`. Unknown values fall back to `.desktop`.
public enum DeviceType: String, Codable, Sendable, CaseIterable {
    case mobile, desktop, web, headless, server

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = DeviceType(rawValue: raw) ?? .desktop
    }
}

/// `protocol` (`http` | `https`). Unknown values fall back to `.https`.
public enum TransportProtocol: String, Codable, Sendable {
    case http, https

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = TransportProtocol(rawValue: raw) ?? .https
    }
}

/// The `DeviceInfo` shape used in announce, register, prepare-upload `info` and `/info`.
public struct DeviceInfo: Codable, Sendable, Hashable {
    public var alias: String
    public var version: String
    public var deviceModel: String?
    public var deviceType: DeviceType?
    public var fingerprint: String
    public var port: Int
    public var `protocol`: TransportProtocol
    public var download: Bool

    public init(alias: String, version: String = SlipConstants.protocolVersion, deviceModel: String?,
                deviceType: DeviceType?, fingerprint: String, port: Int = SlipConstants.defaultPort,
                protocol: TransportProtocol = .https, download: Bool = false) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.protocol = `protocol`
        self.download = download
    }

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, `protocol`, download
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = (try? c.decodeIfPresent(String.self, forKey: .alias)) ?? "Unknown"
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? "1.0"
        deviceModel = try? c.decodeIfPresent(String.self, forKey: .deviceModel)
        if c.contains(.deviceType), !((try? c.decodeNil(forKey: .deviceType)) ?? true) {
            deviceType = try? c.decode(DeviceType.self, forKey: .deviceType)
        } else {
            deviceType = nil
        }
        fingerprint = (try? c.decodeIfPresent(String.self, forKey: .fingerprint)) ?? ""
        port = Lenient.int(c, .port) ?? SlipConstants.defaultPort
        `protocol` = (try? c.decodeIfPresent(TransportProtocol.self, forKey: .protocol)) ?? .https
        download = Lenient.bool(c, .download) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alias, forKey: .alias)
        try c.encode(version, forKey: .version)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(deviceType, forKey: .deviceType)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(port, forKey: .port)
        try c.encode(`protocol`, forKey: .protocol)
        try c.encode(download, forKey: .download)
    }
}

/// Multicast packet: `DeviceInfo` + `announce` (+ legacy `announcement`).
public struct MulticastPacket: Codable, Sendable, Hashable {
    public var info: DeviceInfo
    public var announce: Bool

    public init(info: DeviceInfo, announce: Bool) {
        self.info = info
        self.announce = announce
    }

    enum CodingKeys: String, CodingKey { case announce, announcement }

    public init(from decoder: Decoder) throws {
        info = try DeviceInfo(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        announce = Lenient.bool(c, .announce) ?? Lenient.bool(c, .announcement) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try info.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(announce, forKey: .announce)
        try c.encode(announce, forKey: .announcement)
    }
}

public struct FileMetadata: Codable, Sendable, Hashable {
    public var modified: Date?
    public var accessed: Date?

    public init(modified: Date? = nil, accessed: Date? = nil) {
        self.modified = modified
        self.accessed = accessed
    }

    enum CodingKeys: String, CodingKey { case modified, accessed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modified = ISODate.parse((try? c.decodeIfPresent(String.self, forKey: .modified)) ?? nil)
        accessed = ISODate.parse((try? c.decodeIfPresent(String.self, forKey: .accessed)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modified.map(ISODate.format), forKey: .modified)
        try c.encode(accessed.map(ISODate.format), forKey: .accessed)
    }
}

public struct FileDto: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var fileType: String
    public var sha256: String?
    public var preview: String?
    public var metadata: FileMetadata?

    public init(id: String = UUID().uuidString, fileName: String, size: Int64, fileType: String,
                sha256: String? = nil, preview: String? = nil, metadata: FileMetadata? = nil) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.fileType = fileType
        self.sha256 = sha256
        self.preview = preview
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey { case id, fileName, size, fileType, sha256, preview, metadata }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = (try? c.decodeIfPresent(String.self, forKey: .fileName)) ?? id
        size = Lenient.int64(c, .size) ?? 0
        fileType = (try? c.decodeIfPresent(String.self, forKey: .fileType)) ?? "application/octet-stream"
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        metadata = try? c.decodeIfPresent(FileMetadata.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(size, forKey: .size)
        try c.encode(fileType, forKey: .fileType)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(preview, forKey: .preview)
        try c.encode(metadata, forKey: .metadata)
    }

    /// True if this file is part of a text message (`text/*` with a preview).
    public var isTextMessage: Bool { fileType.lowercased().hasPrefix("text/") && preview != nil }
}

public struct PrepareUploadRequest: Codable, Sendable {
    public var info: DeviceInfo
    public var files: [String: FileDto]

    public init(info: DeviceInfo, files: [String: FileDto]) {
        self.info = info
        self.files = files
    }

    /// Every file is `text/*` with a non-null preview → it's a message, answer 204.
    public var isTextMessage: Bool { !files.isEmpty && files.values.allSatisfy(\.isTextMessage) }
}

public struct PrepareUploadResponse: Codable, Sendable, Hashable {
    public var sessionId: String
    public var files: [String: String]

    public init(sessionId: String, files: [String: String]) {
        self.sessionId = sessionId
        self.files = files
    }
}

// MARK: - JSON helpers

public enum SlipJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

enum Lenient {
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decodeIfPresent(String.self, forKey: key) { return Int(v) }
        return nil
    }

    static func int64<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int64(v) }
        if let v = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(v) }
        return nil
    }

    static func bool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let v = try? c.decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        if let v = try? c.decodeIfPresent(String.self, forKey: key) { return ["true", "1", "yes"].contains(v.lowercased()) }
        return nil
    }
}

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let d = plain.date(from: string) ?? withFraction.date(from: string) { return d }
        // Dart's DateTime.toIso8601String() omits the zone for local times.
        let local = ISO8601DateFormatter()
        local.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        local.timeZone = .current
        local.formatOptions.remove(.withTimeZone)
        return local.date(from: string)
    }

    static func format(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return plain.string(from: date)
    }
}
