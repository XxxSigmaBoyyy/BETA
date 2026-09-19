import Foundation
import CryptoKit

// Verifies that a license API response really came from OUR server and was not
// produced by a fake server or a man-in-the-middle. The server signs every
// response with an Ed25519 PRIVATE key; the client holds only the matching
// PUBLIC key (whose leak is harmless — you cannot forge a signature with it).
//
// The signed message binds:
//   - the client's request nonce  → a captured "paid_active" cannot be replayed
//     against a different request / device,
//   - a server timestamp          → stale captures are rejected (freshness window).
//
// ROLLOUT SAFETY (this is critical): with no public key provisioned
// (SubscriptionConfig.responseSigningPublicKeyHex == "") verification is INERT —
// it returns `.unsigned` and the caller keeps the current behavior, so nothing
// breaks before the server starts signing. Once the key is baked in and the
// server signs every response, forged / unsigned responses are rejected.
//
// SECURITY: never log the body, the signature, or the key material.
enum LicenseResponseVerifier {
    enum Verdict { case ok, unsigned, invalid }

    // Header names — keep verbatim in sync with the server.
    private static let hSign = "X-Aorus-Resp-Sign"   // hex Ed25519 signature (64 bytes → 128 hex)
    private static let hTs   = "X-Aorus-Resp-Ts"     // unix seconds (string)

    /// `bodyData`     — the exact response bytes received.
    /// `headers`      — HTTPURLResponse.allHeaderFields (case-insensitive lookup).
    /// `requestNonce` — the nonce the client sent in X-Aorus-Nonce for THIS request.
    static func verify(bodyData: Data,
                       headers: [AnyHashable: Any],
                       requestNonce: String) -> Verdict {
        let pubHex = SubscriptionConfig.responseSigningPublicKeyHex
        guard !pubHex.isEmpty else { return .unsigned }   // not provisioned yet

        guard let sigHex = header(headers, hSign), !sigHex.isEmpty,
              let tsStr  = header(headers, hTs),
              let ts     = TimeInterval(tsStr) else {
            return .unsigned                              // server did not sign
        }

        // Freshness: reject responses outside the allowed clock-skew window.
        if abs(Date().timeIntervalSince1970 - ts) > SubscriptionConfig.responseMaxSkew {
            return .invalid
        }

        // message = ts \n requestNonce \n sha256Hex(body)
        let bodySha = LicenseCrypto.sha256Hex(bodyData)
        let message = Data((tsStr + "\n" + requestNonce + "\n" + bodySha).utf8)
        let keyData = LicenseCrypto.hexDecode(pubHex)
        let sigData = LicenseCrypto.hexDecode(sigHex)

        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return .invalid
        }
        return pub.isValidSignature(sigData, for: message) ? .ok : .invalid
    }

    // HTTP header names are case-insensitive; allHeaderFields preserves server casing.
    private static func header(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        if let v = headers[name] as? String { return v }
        for (k, val) in headers {
            if let ks = k as? String, ks.caseInsensitiveCompare(name) == .orderedSame {
                return val as? String
            }
        }
        return nil
    }
}
