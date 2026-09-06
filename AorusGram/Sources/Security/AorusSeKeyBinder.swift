import Foundation
import Security

// MARK: - AorusSeKeyBinder
//
// Wraps/unwraps Data with a persistent Secure Enclave P-256 key pair so that
// sensitive blobs stored in Keychain cannot be used even if extracted from the
// device — decryption requires the SE private key to be present.
//
// Falls back to identity (plaintext pass-through) when the SE is unavailable
// (simulator, devices without SE, or first-generation hardware). The caller's
// Keychain item accessibility attribute still enforces device-binding in those
// cases.

enum AorusSeKeyBinder {

    // MARK: - Public API

    /// Encrypts `plaintext` with the SE public key.
    /// Returns `plaintext` unchanged if SE is not available.
    static func bind(_ plaintext: Data) -> Data {
        guard let privKey = seKey() ?? createSeKey(),
              let pubKey = SecKeyCopyPublicKey(privKey) else { return plaintext }
        let algo = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(pubKey, .encrypt, algo),
              let ct = SecKeyCreateEncryptedData(pubKey, algo, plaintext as CFData, nil) else {
            return plaintext
        }
        return ct as Data
    }

    /// Decrypts `ciphertext` with the SE private key.
    /// Returns `nil` if SE key is absent (key lost, device erased) or decryption fails.
    static func unbind(_ ciphertext: Data) -> Data? {
        guard let privKey = seKey() else { return nil }
        let algo = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(privKey, .decrypt, algo),
              let pt = SecKeyCreateDecryptedData(privKey, algo, ciphertext as CFData, nil) else {
            return nil
        }
        return pt as Data
    }

    // MARK: - Key management

    // Application tag stored as raw bytes — XOR so no plaintext literal in binary.
    private static var keyTag: Data {
        let b: [UInt8] = [0x72,0x4D,0x5E,0x6A,0x34,0x09,0x05,0xFD,0xEA,0xCD,0xC9,0xAD,0xB0,0xC0,0x8F,0x63,0x4D,0x1D,0x36,0x35,0x36,0x41]
        let m: [UInt8] = [0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF,0x11,0x22,0x33,0x44,0x55,0x66,0x77]
        return Data(zip(b, m).map { $0 ^ $1 })
    }

    private static func seKey() -> SecKey? {
        let q: [String: Any] = [
            kSecClass as String:                kSecClassKey,
            kSecAttrApplicationTag as String:   keyTag,
            kSecAttrKeyType as String:          kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String:            true,
        ]
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess else { return nil }
        // Conditional, not forced: the query asks for a key and the keychain answers with
        // one, but a forced cast turns any deviation from that into a crash on a path whose
        // every other failure mode already returns nil.
        guard let key = ref as? SecKey else { return nil }
        return key
    }

    private static func createSeKey() -> SecKey? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            nil
        ) else { return nil }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String:       kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String:      true,
                kSecAttrApplicationTag as String:   keyTag,
                kSecAttrAccessControl as String:    access,
            ],
        ]
        return SecKeyCreateRandomKey(attrs as CFDictionary, nil)
        #endif
    }
}
