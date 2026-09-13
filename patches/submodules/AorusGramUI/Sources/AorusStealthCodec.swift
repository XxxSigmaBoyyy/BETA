import Foundation
import AorusGram

// MARK: - AorusCode — encrypted Unicode steganography
//
// The public face of AorusCode used by the composer and sender. Every message is
// authenticated-encrypted before it is spread across zero-width Unicode characters,
// so another Telegram client sees only the cover text and cannot read the secret,
// while an AorusGram reader decrypts it automatically. The cryptography itself —
// ChaCha20-Poly1305 under a shared app key, or PBKDF2-stretched from a passphrase —
// lives in `AorusCodeCipher`, which the message-reveal path shares, so there is one
// implementation and the encode and decode sides cannot drift apart.

public final class AorusStealthCodec {
    public static let shared = AorusStealthCodec()
    private init() {}

    public var isEnabled: Bool {
        get {
            if !AorusLicenseAccess.isAllowed {
                return false
            }
            return UserDefaults.standard.bool(forKey: "aorusgram_aorus_code_enabled")
        }
        set {
            let effectiveValue = AorusLicenseAccess.isAllowed ? newValue : false
            UserDefaults.standard.set(effectiveValue, forKey: "aorusgram_aorus_code_enabled")
        }
    }

    // MARK: - Encode

    /// Wraps `cover` with an encrypted, hidden `secret`. A non-empty `passphrase`
    /// makes the message readable only by someone who also knows it — even another
    /// AorusGram user cannot open it without the passphrase; the default (nil) uses
    /// the shared AorusGram key so any AorusGram reader decrypts it automatically.
    /// Pass empty `cover` for a purely invisible message.
    public func encode(cover: String, secret: String, passphrase: String? = nil) -> String {
        return AorusCodeCipher.hide(cover: cover, secret: secret, passphrase: passphrase)
    }

    // MARK: - Decode

    /// The decrypted secret if `text` carries an AorusCode payload this reader can
    /// open, else nil.
    public func decode(_ text: String, passphrase: String? = nil) -> String? {
        return AorusCodeCipher.reveal(from: text, passphrase: passphrase)
    }

    // MARK: - Display helpers

    /// True if the text carries an AorusCode payload (says nothing about whether it
    /// will decrypt for this reader).
    public func hasHiddenMessage(_ text: String) -> Bool {
        return AorusCodeCipher.containsPayload(text)
    }

    /// Strips the invisible AorusCode payload, leaving only the visible cover text.
    public func visibleText(_ text: String) -> String {
        return AorusCodeCipher.visibleText(text)
    }

    /// Display pair for a received message: the cover, and the secret if it opened.
    public func split(_ text: String, passphrase: String? = nil) -> (visible: String, secret: String?) {
        if hasHiddenMessage(text) {
            return (visibleText(text), decode(text, passphrase: passphrase))
        }
        return (text, nil)
    }
}

// MARK: - Notification for UI layer

extension Notification.Name {
    static let aorusCodeMessageReceived = Notification.Name("aorusgram_aorus_code_received")
}
