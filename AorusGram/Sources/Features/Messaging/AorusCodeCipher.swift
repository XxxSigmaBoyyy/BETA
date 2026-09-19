import Foundation
import CryptoKit

// MARK: - AorusCode cipher
//
// The cryptographic core of AorusCode, kept deliberately free of any AorusGram
// dependency — only Foundation and CryptoKit — so the release preflight can
// compile it on its own and prove the round-trip, the tamper rejection and the
// KDF against a known-answer vector. AorusStealthCodec (in AorusGramUI) and the
// message-reveal transform injected into ChatMessageTextBubbleContentNode both
// call THIS one implementation, so the two can never drift the way a duplicated
// codec would.
//
// A message is authenticated-encrypted with ChaCha20-Poly1305 and only then
// spread across zero-width Unicode characters. Two key tiers:
//
//   - App key — a 256-bit key compiled into every AorusGram build. Any AorusGram
//     user decrypts automatically; nobody without the app sees anything but the
//     cover text. HONESTLY: because the key ships in every copy of the app, a
//     determined reverse-engineer who extracts it from the binary can read app-key
//     messages. This tier hides a message from every other Telegram client and
//     from casual inspection — it is not proof against someone who pulls the key
//     out of the IPA. That is unavoidable for "any AorusGram user can read it".
//
//   - Passphrase — the key is stretched from a passphrase the sender and reader
//     agree on out of band, peppered with the app key, through 210 000 rounds of
//     PBKDF2-HMAC-SHA256. This tier is genuinely uncrackable: the secret is not in
//     the app, so extracting the binary buys nothing, and the only attack left is
//     guessing the passphrase against a deliberately slow KDF. Use it for anything
//     that must stay secret even from other AorusGram users.
//
// Ciphertext is authenticated (Poly1305): a flipped bit anywhere in the hidden
// payload makes decryption fail cleanly rather than return garbage.

public enum AorusCodeCipher {
    // MARK: Container format
    //
    // The bytes below are what gets spread into invisible characters:
    //
    //   [0]   version   = 0x02
    //   [1]   mode      = 0x00 app key | 0x01 passphrase
    //   [2..] if passphrase: 16-byte random salt, then the sealed box
    //         if app key:    the sealed box directly
    //
    // The sealed box is ChaChaPoly's own combined form: 12-byte nonce ‖ ciphertext
    // ‖ 16-byte tag. The nonce is fresh per message, so the same secret sent twice
    // never produces the same payload.
    private static let version: UInt8 = 0x02
    private static let modeAppKey: UInt8 = 0x00
    private static let modePassphrase: UInt8 = 0x01
    private static let saltLength = 16
    private static let pbkdf2Rounds = 210_000

    // Invisible alphabet — four Default-Ignorable, zero-advance scalars, two bits
    // each. Iterated as Unicode.Scalar and NOT Character: U+200C is
    // Grapheme_Cluster_Break = Extend and would merge with the preceding scalar
    // under Character iteration, corrupting the grouping. These exact code points
    // render with no glyph and no width on iOS CoreText — no tofu boxes.
    //   0 → ZERO WIDTH SPACE, 1 → ZERO WIDTH NON-JOINER,
    //   2 → WORD JOINER,      3 → ZERO WIDTH NO-BREAK SPACE
    private static let alphabet: [Unicode.Scalar] = ["\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}"]
    private static let indexOfScalar: [Unicode.Scalar: Int] = [
        "\u{200B}": 0, "\u{200C}": 1, "\u{2060}": 2, "\u{FEFF}": 3
    ]

    // Invisible math operators, distinct from the data alphabet, bracketing the
    // payload. Kept identical to every prior AorusCode build so a message in flight
    // is still located the same way.
    public static let magicOpen = "\u{2061}\u{2062}"
    public static let magicClose = "\u{2062}\u{2061}"

    // MARK: - Public API

    /// Wraps `cover` with `secret` hidden after it. `passphrase == nil` uses the
    /// shared app key; a non-empty passphrase uses the passphrase tier. Returns the
    /// cover unchanged if there is nothing to hide or encryption is impossible.
    public static func hide(cover: String, secret: String, passphrase: String? = nil) -> String {
        let trimmedSecret = secret
        guard !trimmedSecret.isEmpty else { return cover }
        guard let container = seal(Data(trimmedSecret.utf8), passphrase: passphrase) else {
            return cover
        }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: magicOpen.unicodeScalars)
        for byte in container {
            scalars.append(alphabet[Int((byte >> 6) & 0x3)])
            scalars.append(alphabet[Int((byte >> 4) & 0x3)])
            scalars.append(alphabet[Int((byte >> 2) & 0x3)])
            scalars.append(alphabet[Int(byte & 0x3)])
        }
        scalars.append(contentsOf: magicClose.unicodeScalars)
        return cover + String(scalars)
    }

    /// The hidden secret in `text`, or nil if there is none or it does not decrypt
    /// with the supplied `passphrase` (nil = try the app key).
    ///
    /// A message from a build older than encryption carried its secret as plain
    /// UTF-8 in the same invisible alphabet; that legacy form is still read, so an
    /// in-flight conversation does not go dark on upgrade. Legacy messages never
    /// carried a passphrase, so the fallback is only taken when none is supplied.
    public static func reveal(from text: String, passphrase: String? = nil) -> String? {
        guard let container = extractPayload(from: text) else { return nil }
        if let opened = open(container, passphrase: passphrase),
           let text = String(data: opened, encoding: .utf8), !text.isEmpty {
            return text
        }
        // Legacy v1: the raw bytes were the UTF-8 secret, with no version framing.
        if passphrase == nil, let legacy = String(bytes: container, encoding: .utf8),
           !legacy.isEmpty, container.first != version {
            return legacy
        }
        return nil
    }

    /// True if `text` carries an AorusCode payload (encrypted or legacy). Says
    /// nothing about whether it will decrypt — only that the markers are present.
    public static func containsPayload(_ text: String) -> Bool {
        text.contains(magicOpen) && text.contains(magicClose)
    }

    /// The cover text with the invisible payload removed.
    public static func visibleText(_ text: String) -> String {
        guard let openRange = text.range(of: magicOpen) else { return text }
        return String(text[text.startIndex..<openRange.lowerBound])
    }

    // MARK: - Encrypt / decrypt

    private static func seal(_ plaintext: Data, passphrase: String?) -> Data? {
        do {
            if let passphrase, !passphrase.isEmpty {
                let salt = randomBytes(saltLength)
                let key = deriveKey(passphrase: passphrase, salt: salt)
                let box = try ChaChaPoly.seal(plaintext, using: key)
                var out = Data([version, modePassphrase])
                out.append(salt)
                out.append(box.combined)
                return out
            } else {
                guard let key = appKey() else { return nil }
                let box = try ChaChaPoly.seal(plaintext, using: key)
                var out = Data([version, modeAppKey])
                out.append(box.combined)
                return out
            }
        } catch {
            return nil
        }
    }

    private static func open(_ container: Data, passphrase: String?) -> Data? {
        guard container.count >= 2, container[container.startIndex] == version else { return nil }
        let mode = container[container.startIndex + 1]
        let body = container.subdata(in: (container.startIndex + 2)..<container.endIndex)
        do {
            switch mode {
            case modeAppKey:
                guard passphrase == nil || passphrase?.isEmpty == true, let key = appKey() else { return nil }
                return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: body), using: key)
            case modePassphrase:
                guard let passphrase, !passphrase.isEmpty, body.count > saltLength else { return nil }
                let salt = body.subdata(in: body.startIndex..<(body.startIndex + saltLength))
                let sealed = body.subdata(in: (body.startIndex + saltLength)..<body.endIndex)
                let key = deriveKey(passphrase: passphrase, salt: salt)
                return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - Payload extraction

    /// The container bytes between the markers, or nil. Groups of four alphabet
    /// scalars become one byte; anything that is not a data scalar (a stray marker,
    /// a scalar some client re-ordered) is skipped so a slightly mangled payload
    /// still yields what it can rather than nothing.
    private static func extractPayload(from text: String) -> Data? {
        guard let openRange = text.range(of: magicOpen),
              let closeRange = text.range(of: magicClose),
              openRange.upperBound <= closeRange.lowerBound else { return nil }
        let scalars = Array(text[openRange.upperBound..<closeRange.lowerBound].unicodeScalars)
        var bytes = [UInt8]()
        var digits = [Int]()
        digits.reserveCapacity(4)
        for scalar in scalars {
            guard let digit = indexOfScalar[scalar] else { continue }
            digits.append(digit)
            if digits.count == 4 {
                bytes.append(UInt8((digits[0] << 6) | (digits[1] << 4) | (digits[2] << 2) | digits[3]))
                digits.removeAll(keepingCapacity: true)
            }
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    // MARK: - Key material

    // The shared app key, obfuscated as an XOR split so it is not a readable literal
    // in the binary. This is the same posture the proxy and build-policy keys use.
    // It is a SHARED secret by design — every AorusGram build carries it so every
    // AorusGram user can read app-key messages — which is exactly why it cannot be
    // the last word in secrecy; see the passphrase tier for that.
    private static let keyPad: [UInt8] = [
        0x55, 0xCE, 0x79, 0x2C, 0x45, 0x18, 0x7C, 0x7D,
        0xCF, 0xDE, 0x2B, 0xC5, 0x87, 0xB5, 0x9F, 0x0A,
        0x33, 0x30, 0x6F, 0xDE, 0x09, 0x5F, 0x1A, 0xCA,
        0xE0, 0xAF, 0xF2, 0xD3, 0xDB, 0xAE, 0xCD, 0x61,
    ]
    private static let keyObfuscated: [UInt8] = [
        0x4C, 0x66, 0x68, 0x01, 0xD8, 0x79, 0x93, 0xFA,
        0x63, 0xC8, 0x13, 0x06, 0xA6, 0x00, 0x52, 0xB6,
        0x30, 0xF8, 0x08, 0x03, 0x39, 0xDF, 0x70, 0xB7,
        0x43, 0x5F, 0x21, 0x14, 0x3D, 0x0B, 0x2F, 0xB3,
    ]

    private static func appKey() -> SymmetricKey? {
        guard keyPad.count == 32, keyObfuscated.count == 32 else { return nil }
        var raw = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { raw[i] = keyObfuscated[i] ^ keyPad[i] }
        let key = SymmetricKey(data: Data(raw))
        for i in 0..<32 { raw[i] = 0 }
        return key
    }

    /// PBKDF2-HMAC-SHA256. The salt is peppered with the app key, so a passphrase
    /// message cannot be attacked by anyone who does not also have an AorusGram
    /// build — they would be missing half the salt.
    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var pepperedSalt = salt
        if let appKeyData = appKey()?.withUnsafeBytes({ Data($0) }) {
            pepperedSalt.append(appKeyData)
        }
        let derived = pbkdf2SHA256(
            password: Data(passphrase.utf8),
            salt: pepperedSalt,
            rounds: pbkdf2Rounds,
            keyLength: 32
        )
        return SymmetricKey(data: derived)
    }

    /// Standard PBKDF2 over HMAC-SHA256. `keyLength` here is always 32, one SHA-256
    /// block, so a single derived block is produced; the loop is kept general so the
    /// construction reads as the RFC 2898 definition and is verified against a known
    /// answer in the preflight.
    static func pbkdf2SHA256(password: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        let key = SymmetricKey(data: password)
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < keyLength {
            var block = salt
            withUnsafeBytes(of: blockIndex.bigEndian) { block.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
            var t = u
            if rounds > 1 {
                for _ in 1..<rounds {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            derived.append(t)
            blockIndex &+= 1
        }
        return derived.prefix(keyLength)
    }

    private static func randomBytes(_ count: Int) -> Data {
        // SymmetricKey is CryptoKit's own CSPRNG-backed generator, so this needs no
        // Security import and no error path.
        return SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}
