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

    // MARK: - Self-describing envelope
    //
    // `bind` falls back to returning the plaintext unchanged when no Secure Enclave key
    // can be had, and the caller cannot tell that apart from ciphertext. That is a data
    // loss waiting to happen, and it happened: a save made while the key was unavailable
    // — a background launch before the device's first unlock, where a key with
    // `AfterFirstUnlockThisDeviceOnly` can neither be read nor created — wrote plaintext
    // that the next launch tried to decrypt. Decryption failed, a key existed by then, so
    // the blob was judged corrupt and the user's imported servers were dropped on the
    // floor. Permanently: nothing rewrote it.
    //
    // The envelope says which of the two it is, so no reader has to guess.

    private static let tagEncrypted: UInt8 = 0x01
    private static let tagPlaintext: UInt8 = 0x02

    /// Wraps `plaintext` in an envelope that records how it was protected.
    static func protect(_ plaintext: Data) -> Data {
        var envelope = Data()
        if let sealed = seal(plaintext) {
            envelope.append(tagEncrypted)
            envelope.append(sealed)
        } else {
            envelope.append(tagPlaintext)
            envelope.append(plaintext)
        }
        return envelope
    }

    /// Unwraps an envelope written by `protect`. nil only when the envelope is not one of
    /// ours, or when it really is ciphertext this installation cannot open.
    static func open(_ envelope: Data) -> Data? {
        guard let tag = envelope.first else { return nil }
        let body = Data(envelope.dropFirst())
        switch tag {
        case tagEncrypted:
            return unbind(body)
        case tagPlaintext:
            return body
        default:
            return nil
        }
    }

    /// The encrypting half of `bind`, separated so `protect` can tell "there is no key" from
    /// "here is your ciphertext" instead of both arriving as a `Data`.
    private static func seal(_ plaintext: Data) -> Data? {
        guard let privKey = seKey() ?? createSeKey(),
              let pubKey = SecKeyCopyPublicKey(privKey) else { return nil }
        let algo = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(pubKey, .encrypt, algo),
              let ct = SecKeyCreateEncryptedData(pubKey, algo, plaintext as CFData, nil) else {
            return nil
        }
        return ct as Data
    }

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

    /// Whether this installation already owns the private key used by `unbind`.
    /// Callers use this to distinguish a legitimate legacy plaintext migration
    /// from ciphertext that failed authentication while a key is present.
    static var hasDeviceKey: Bool {
        return seKey() != nil
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
        // Checked by type id, not by `as?`: Swift rejects a conditional downcast to a
        // CoreFoundation type outright ("will always succeed") and points at this instead.
        // The query asks for a key and the keychain answers with one, but a bare forced
        // cast turns any deviation from that into a crash on a path whose every other
        // failure mode already returns nil.
        guard let ref, CFGetTypeID(ref) == SecKeyGetTypeID() else { return nil }
        return (ref as! SecKey)
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
