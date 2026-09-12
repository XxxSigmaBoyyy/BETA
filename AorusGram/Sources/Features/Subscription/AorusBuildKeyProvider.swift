import Foundation

// Separate per-build signing key. It is injected only in CI from
// AORUS_BUILD_KEY_HEX and is never committed in plaintext.
enum AorusBuildKeyProvider {
    static let build = "1"

    private static let pad: [UInt8] = [
        0x8D, 0x31, 0xE7, 0x54, 0xA2, 0x0B, 0x69, 0xCF,
        0x17, 0xB8, 0x43, 0xF1, 0x5C, 0x96, 0x2E, 0x7A
    ]

    private static let obfuscated: [UInt8] = [
        /*__AORUS_BUILD_POLICY_KEY_OBFUSCATED__*/
    ]

    static var isProvisioned: Bool { !obfuscated.isEmpty }

    static func withKey<Result>(_ body: (Data) -> Result) -> Result? {
        guard !obfuscated.isEmpty else { return nil }
        var bytes = obfuscated.enumerated().map { index, byte in
            byte ^ pad[index % pad.count]
        }
        var data = Data(bytes)
        defer {
            _ = data.withUnsafeMutableBytes { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
            }
            _ = bytes.withUnsafeMutableBytes { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        return body(data)
    }

    /// Whether the build-policy headers are put on the wire.
    ///
    /// The License API runs with `legacy_allowed = true` and does not expect them yet.
    /// Sending them is not neutral: a build signature the server does not accept is
    /// answered with 426 `client_outdated`, and on `/license/badges/snapshot` that means
    /// the roster never arrives and nobody has a badge. The key is still provisioned and
    /// the signature is still computed and tested by the same code path, so turning this
    /// on is a one-line change the day the server's build policy is switched on.
    static let sendsBuildHeaders = false

    @discardableResult
    static func applyHeaders(to request: inout URLRequest,
                             timestamp: String,
                             nonce: String,
                             device: String) -> Bool {
        guard sendsBuildHeaders else {
            // Nothing to add, and that is a success: the request is complete without them.
            return true
        }
        let normalizedDevice = device.lowercased()
        let message = "\(timestamp)\n\(nonce)\n\(normalizedDevice)\n\(build)"
        guard let signature = withKey({ key in
            LicenseCrypto.hmacSHA256Hex(message: Data(message.utf8), keyBytes: key).lowercased()
        }) else {
            return false
        }
        request.setValue(build, forHTTPHeaderField: "X-Aorus-Build")
        request.setValue(signature, forHTTPHeaderField: "X-Aorus-Build-Sign")
        return true
    }
}
