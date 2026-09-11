import Foundation
import AorusGram

// MARK: - AorusCode — Unicode Steganography
//
// Encodes a secret message into truly zero-width Unicode characters appended
// to a cover text. Other Telegram clients see only the cover text; AorusGram
// recipients automatically decode and reveal the real message.
//
// Alphabet rationale: every code point used here is a Unicode "Default
// Ignorable" character that CoreText renders with NO glyph and ZERO advance
// on iOS — so nothing ever shows up as a tofu box. We deliberately avoid
// code points that look invisible on paper but render as boxes on iOS
// (e.g. U+206A–U+206F, U+FFA0, the Mongolian U+180B–U+180F range).
//
// Encoding: the UTF-8 bytes of the secret are written in base-4. Each byte
// becomes four base-4 digits (most-significant first); each digit maps to one
// of four invisible characters. A magic header/footer (two further invisible
// characters, distinct from the data alphabet) brackets the payload.

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

    // Four data code points — all guaranteed zero-width / no-glyph on iOS.
    // NOTE: typed as Unicode.Scalar (code points), NOT Character (grapheme
    // clusters): U+200C has Grapheme_Cluster_Break = Extend and would merge
    // with the preceding code point under Character iteration, corrupting the
    // 4-symbol grouping. Scalar iteration is immune to that.
    //   index 0 → ZERO WIDTH SPACE
    //   index 1 → ZERO WIDTH NON-JOINER
    //   index 2 → WORD JOINER
    //   index 3 → ZERO WIDTH NO-BREAK SPACE
    private let alphabet: [Unicode.Scalar] = ["\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}"]

    // Magic markers — invisible math operators, distinct from the data alphabet.
    private let magicOpen:  String = "\u{2061}\u{2062}"   // FUNCTION APPLICATION + INVISIBLE TIMES
    private let magicClose: String = "\u{2062}\u{2061}"   // INVISIBLE TIMES + FUNCTION APPLICATION

    // MARK: - Encode

    /// Wraps `cover` text with a hidden `secret` encoded as invisible Unicode.
    /// Pass empty string for `cover` to send a purely invisible message.
    public func encode(cover: String, secret: String) -> String {
        guard !secret.isEmpty else { return cover }
        var hidden = String.UnicodeScalarView()
        hidden.append(contentsOf: magicOpen.unicodeScalars)
        for byte in secret.utf8 {
            hidden.append(alphabet[Int((byte >> 6) & 0x3)])
            hidden.append(alphabet[Int((byte >> 4) & 0x3)])
            hidden.append(alphabet[Int((byte >> 2) & 0x3)])
            hidden.append(alphabet[Int(byte & 0x3)])
        }
        hidden.append(contentsOf: magicClose.unicodeScalars)
        return cover + String(hidden)
    }

    // MARK: - Decode

    /// Returns the decoded secret if the text contains an AorusCode payload, else nil.
    public func decode(_ text: String) -> String? {
        guard let openRange = text.range(of: magicOpen),
              let closeRange = text.range(of: magicClose),
              openRange.upperBound <= closeRange.lowerBound else { return nil }

        let payload = Array(text[openRange.upperBound..<closeRange.lowerBound].unicodeScalars)
        var bytes: [UInt8] = []
        var i = 0
        while i + 3 < payload.count {
            guard let d0 = alphabet.firstIndex(of: payload[i]),
                  let d1 = alphabet.firstIndex(of: payload[i + 1]),
                  let d2 = alphabet.firstIndex(of: payload[i + 2]),
                  let d3 = alphabet.firstIndex(of: payload[i + 3]) else { i += 1; continue }
            bytes.append(UInt8((d0 << 6) | (d1 << 4) | (d2 << 2) | d3))
            i += 4
        }
        return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - Display helpers

    /// True if the text carries an AorusCode payload.
    public func hasHiddenMessage(_ text: String) -> Bool {
        text.contains(magicOpen) && text.contains(magicClose)
    }

    /// Strips the invisible AorusCode payload, leaving only the visible cover text.
    public func visibleText(_ text: String) -> String {
        guard let openRange = text.range(of: magicOpen) else { return text }
        return String(text[text.startIndex..<openRange.lowerBound])
    }

    /// Returns display pair: (coverText, secretText?) for a received message.
    public func split(_ text: String) -> (visible: String, secret: String?) {
        if hasHiddenMessage(text) {
            return (visibleText(text), decode(text))
        }
        return (text, nil)
    }
}

// MARK: - Notification for UI layer

extension Notification.Name {
    static let aorusCodeMessageReceived = Notification.Name("aorusgram_aorus_code_received")
}
