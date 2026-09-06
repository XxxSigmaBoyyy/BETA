import Foundation
import CryptoKit
import Security

struct AorusRealityCredential: Decodable, Equatable {
    let uuid: String
    let flow: String

    var isValid: Bool {
        guard let value = UUID(uuidString: uuid),
              value.uuidString.lowercased() == uuid.lowercased(),
              flow == "xtls-rprx-vision" else {
            return false
        }
        let canonical = value.uuidString.lowercased()
        let versionIndex = canonical.index(canonical.startIndex, offsetBy: 14)
        return canonical[versionIndex] == "4"
    }
}

/// uTLS ClientHello shapes Xray can imitate. Kept as a list rather than a single pinned
/// value so the masquerade can be changed from the signed profile when a censor starts
/// recognising one of them — the alternative is shipping a new build for every such move.
private let aorusAllowedFingerprints: Set<String> = [
    "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"
]

struct AorusRealityEndpoint: Decodable, Equatable {
    let address: String
    let port: Int
    let region: String?
    let serverName: String
    let publicKey: String
    let shortId: String
    let spiderX: String
    let fingerprint: String
    let priority: Int
    /// Stable identity from the control plane (`de_direct`, `fi_via_moscow`, …). The UI keys
    /// its card off this rather than off priority or address, both of which move.
    let id: String?
    let country: String?
    let routeType: String?
    let via: String?

    enum CodingKeys: String, CodingKey {
        case address, port, region, priority, fingerprint, id, country, via
        case serverName = "server_name"
        case publicKey = "public_key"
        case shortId = "short_id"
        case spiderX = "spider_x"
        case routeType = "route_type"
    }

    /// Human-readable reason this endpoint was dropped, or nil when it is usable.
    ///
    /// Returned instead of a bare Bool so a rejected endpoint can say why in the diagnostic
    /// log. Silently dropping one and leaving an empty server list was the previous
    /// behaviour, and it made a server-side typo indistinguishable from an outage.
    var invalidReason: String? {
        let normalizedAddress = address.lowercased()
        if address.isEmpty || address.count > 255 { return "address_length" }
        if normalizedAddress == "0.0.0.0" || normalizedAddress == "::" || normalizedAddress == "::0" { return "address_unspecified" }
        if normalizedAddress == "localhost" || normalizedAddress.hasPrefix("127.") { return "address_loopback" }
        if !(1 ... 65_535).contains(port) { return "port_range" }
        if !(1 ... 100).contains(priority) { return "priority_range" }
        if !(40 ... 64).contains(publicKey.count) || !publicKey.utf8.allSatisfy(Self.isBase64URLByte) { return "public_key" }
        if shortId.count > 16 || !shortId.count.isMultiple(of: 2) { return "short_id_length" }
        if shortId != shortId.lowercased() || !shortId.allSatisfy({ $0.isHexDigit }) { return "short_id_charset" }
        if !Self.isValidHostname(serverName) { return "server_name" }
        if !spiderX.hasPrefix("/") || spiderX.count > 128 { return "spider_x" }
        if !aorusAllowedFingerprints.contains(fingerprint) { return "fingerprint" }
        if let region, region.isEmpty || region.count > 32 || !region.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) || byte == 0x20 || byte == 0x2d
        }) { return "region_charset" }
        // Accepts both an IPv4 literal and a DNS hostname: the control plane now issues
        // hostnames so the dial target can move without a client release, and NAT64 networks
        // need a name to synthesise from.
        if !address.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d || byte == 0x2e || byte == 0x3a
        }) { return "address_charset" }
        return nil
    }

    var isValid: Bool { return invalidReason == nil }

    /// Identity used by the UI and by failover bookkeeping. Falls back to address:port for
    /// profiles issued before the control plane carried an id.
    var stableId: String {
        if let id, !id.isEmpty { return id }
        return "\(address):\(port)"
    }

    private var legacyIsValid: Bool {
        let normalizedAddress = address.lowercased()
        guard !address.isEmpty, address.count <= 255,
              normalizedAddress != "0.0.0.0",
              normalizedAddress != "::",
              normalizedAddress != "::0",
              normalizedAddress != "localhost",
              !normalizedAddress.hasPrefix("127."),
              (1 ... 65_535).contains(port),
              (1 ... 100).contains(priority),
              (40 ... 64).contains(publicKey.count),
              publicKey.utf8.allSatisfy(Self.isBase64URLByte),
              shortId.count <= 16, shortId.count.isMultiple(of: 2),
              shortId == shortId.lowercased(),
              shortId.allSatisfy({ $0.isHexDigit }),
              Self.isValidHostname(serverName),
              spiderX.hasPrefix("/"), spiderX.count <= 128,
              fingerprint == "chrome" else {
            return false
        }
        if let region {
            guard !region.isEmpty, region.count <= 32,
                  region.utf8.allSatisfy({ byte in
                      (byte >= 0x30 && byte <= 0x39) ||
                      (byte >= 0x41 && byte <= 0x5a) ||
                      (byte >= 0x61 && byte <= 0x7a) ||
                      byte == 0x20 || byte == 0x2d
                  }) else {
                return false
            }
        }
        return address.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) ||
            byte == 0x2d || byte == 0x2e || byte == 0x3a
        }
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        byte == 0x2d || byte == 0x5f
    }

    private static func isValidHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) ||
                ($0 >= 0x41 && $0 <= 0x5a) ||
                ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d
            }
        }
    }
}

struct AorusRealityProfile: Decodable, Equatable {
    let schema: Int
    let deviceHash: String
    let issuedAt: Int64
    let expiresAt: Int64
    let activeUntil: Int64
    let credential: AorusRealityCredential
    let endpoints: [AorusRealityEndpoint]

    /// The endpoints that survived validation, in the order the control plane sent them.
    var validEndpoints: [AorusRealityEndpoint] {
        return endpoints.filter { $0.isValid }
    }

    /// Why each rejected endpoint was rejected, for the diagnostic log.
    var rejectedEndpoints: [(id: String, reason: String)] {
        return endpoints.compactMap { endpoint in
            guard let reason = endpoint.invalidReason else { return nil }
            return (endpoint.stableId, reason)
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, credential, endpoints
        case deviceHash = "device_hash"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case activeUntil = "active_until"
    }

    func isValid(for expectedDeviceHash: String, now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        guard schema == 1,
              deviceHash == expectedDeviceHash,
              deviceHash.count == 64,
              deviceHash == deviceHash.lowercased(),
              deviceHash.allSatisfy({ $0.isHexDigit }),
              issuedAt <= now + 300,
              expiresAt > now,
              activeUntil >= expiresAt,
              credential.isValid,
              (1 ... 8).contains(endpoints.count),
              // One malformed endpoint used to reject the whole profile, which turned a
              // single server-side typo into a client with no servers at all. Now the bad
              // ones are dropped and the rest still connect.
              !validEndpoints.isEmpty else {
            return false
        }
        let dialTargets = validEndpoints.map { "\($0.address):\($0.port)" }
        return Set(dialTargets).count == validEndpoints.count &&
            Set(validEndpoints.map(\.priority)).count == validEndpoints.count
    }
}

struct AorusRealityEnvelope: Decodable {
    let payload: String
    let timestamp: String
    let signature: String
    let requestNonce: String
}

enum AorusRealityEnvelopeVerifier {
    // requestNonce is the Worker's nonce for its signed request to License API.
    // The client request nonce is independently verified inside the P-256 device
    // proof before License API issues this device-bound payload.
    static func decode(
        _ envelope: AorusRealityEnvelope,
        expectedDeviceHash: String
    ) -> AorusRealityProfile? {
        guard let timestamp = Int64(envelope.timestamp),
              abs(Int64(Date().timeIntervalSince1970) - timestamp) <= 300,
              envelope.requestNonce.count == 32,
              envelope.requestNonce == envelope.requestNonce.lowercased(),
              envelope.requestNonce.allSatisfy({ $0.isHexDigit }),
              let payload = Data(aorusBase64URL: envelope.payload),
              payload.count <= 65_536,
              let signature = Data(aorusHex: envelope.signature), signature.count == 64,
              let keyData = Data(aorusHex: SubscriptionConfig.responseSigningPublicKeyHex), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return nil
        }

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let message = Data("\(envelope.timestamp)\n\(envelope.requestNonce)\n\(digest)".utf8)
        guard key.isValidSignature(signature, for: message),
              let profile = try? JSONDecoder().decode(AorusRealityProfile.self, from: payload),
              profile.isValid(for: expectedDeviceHash) else {
            return nil
        }
        return profile
    }
}

enum AorusRealityDeviceIdentity {
    struct Proof {
        let publicKey: String
        let signature: String
    }

    private static let tag = Data("com.aorusgram.reality.device-key.v1".utf8)
    private static let lock = NSLock()

    static func proof(timestamp: String, nonce: String, deviceHash: String) -> Proof? {
        guard timestamp.allSatisfy({ $0.isNumber }),
              nonce.count == 32, nonce.allSatisfy({ $0.isHexDigit }),
              deviceHash.count == 64, deviceHash.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard let privateKey = loadKey() ?? createKey(),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              publicData.count == 65, publicData.first == 0x04 else {
            return nil
        }
        let message = Data("aorus-reality-profile-v1\n\(timestamp)\n\(nonce)\n\(deviceHash)".utf8)
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, .ecdsaSignatureMessageX962SHA256),
              let signature = SecKeyCreateSignature(
                privateKey,
                .ecdsaSignatureMessageX962SHA256,
                message as CFData,
                nil
              ) as Data? else {
            return nil
        }
        return Proof(publicKey: publicData.aorusBase64URL, signature: signature.aorusBase64URL)
    }

    private static func loadKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        // Checked by type id, not by `as?`: Swift rejects a conditional downcast to a
        // CoreFoundation type outright. Every other way this lookup can fail returns nil,
        // and a keychain that answered with something other than a key should not be the
        // one path that crashes.
        guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else { return nil }
        return (item as! SecKey)
    }

    private static func createKey() -> SecKey? {
        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let base: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes
        ]
        return SecKeyCreateRandomKey(base as CFDictionary, nil)
    }
}

private extension Data {
    init?(aorusHex value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            guard let next = value.index(index, offsetBy: 2, limitedBy: value.endIndex),
                  let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    init?(aorusBase64URL value: String) {
        guard !value.isEmpty,
              value.utf8.allSatisfy({
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) ||
                ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f
              }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        self = decoded
    }

    var aorusBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
