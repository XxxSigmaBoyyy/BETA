import Foundation
import CryptoKit

// Compiles AorusCodeCipher.swift on its own and exercises the whole of AorusCode:
// the KDF against a published known-answer vector, the encrypt→decrypt round-trip,
// invisibility, authentication (tamper rejection), the passphrase tier, and the
// legacy-message fallback. Run by the release preflight, so a regression in the
// cipher fails the build in seconds rather than shipping unreadable messages.

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusCodeCipher test failed: \(message)\n", stderr)
        exit(1)
    }
}

// The four zero-width data scalars and the two invisible markers. Nothing AorusCode
// appends may fall outside this set, or it would show as a visible character.
private let zeroWidth: Set<Unicode.Scalar> = [
    "\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}", "\u{2061}", "\u{2062}"
]

// PBKDF2-HMAC-SHA256, the construction verified as its own step because everything
// in the passphrase tier rests on it. Vectors are the widely published ones for
// P="password", S="salt".
private func verifiesTheKdf() {
    let oneRound = AorusCodeCipher.pbkdf2SHA256(
        password: Data("password".utf8), salt: Data("salt".utf8), rounds: 1, keyLength: 32
    )
    require(oneRound.map { String(format: "%02x", $0) }.joined()
            == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
            "PBKDF2-HMAC-SHA256 c=1 matches the known-answer vector")

    let twoRounds = AorusCodeCipher.pbkdf2SHA256(
        password: Data("password".utf8), salt: Data("salt".utf8), rounds: 2, keyLength: 32
    )
    require(twoRounds.map { String(format: "%02x", $0) }.joined()
            == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
            "PBKDF2-HMAC-SHA256 c=2 matches the known-answer vector")

    require(oneRound != twoRounds, "iteration count changes the derived key")
}

private func hidesAndRevealsUnderTheAppKey() {
    let cover = "Погода сегодня хорошая"
    let secret = "координаты 55.75, 37.61 — приходи один"
    let wrapped = AorusCodeCipher.hide(cover: cover, secret: secret)

    require(wrapped != cover, "something was appended")
    require(wrapped.hasPrefix(cover), "the cover text is untouched at the front")
    require(AorusCodeCipher.visibleText(wrapped) == cover, "only the cover is visible")
    require(AorusCodeCipher.containsPayload(wrapped), "the payload is detected")
    require(AorusCodeCipher.reveal(from: wrapped) == secret, "the secret round-trips")
}

private func addsOnlyInvisibleCharacters() {
    let cover = "hi"
    let wrapped = AorusCodeCipher.hide(cover: cover, secret: "a longer secret message ✅ с юникодом")
    let appended = wrapped.unicodeScalars.dropFirst(cover.unicodeScalars.count)
    for scalar in appended {
        require(zeroWidth.contains(scalar),
                "every appended scalar is zero-width (offender U+\(String(scalar.value, radix: 16)))")
    }
}

private func neverRepeatsAPayload() {
    // A fresh nonce per message means the same secret never encodes the same way,
    // so an observer cannot even tell two identical secrets apart.
    let a = AorusCodeCipher.hide(cover: "", secret: "same")
    let b = AorusCodeCipher.hide(cover: "", secret: "same")
    require(a != b, "two encryptions of one secret differ")
    require(AorusCodeCipher.reveal(from: a) == "same" && AorusCodeCipher.reveal(from: b) == "same",
            "both still decrypt to the secret")
}

private func rejectsTampering() {
    let wrapped = AorusCodeCipher.hide(cover: "x", secret: "authenticated")
    var scalars = Array(wrapped.unicodeScalars)
    // Flip the last data scalar to a different one. Poly1305 must reject it.
    let dataSet: [Unicode.Scalar] = ["\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}"]
    var flipped = false
    for i in stride(from: scalars.count - 1, through: 0, by: -1) {
        if let idx = dataSet.firstIndex(of: scalars[i]) {
            scalars[i] = dataSet[(idx + 1) % dataSet.count]
            flipped = true
            break
        }
    }
    require(flipped, "the payload contained a data scalar to flip")
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    require(AorusCodeCipher.reveal(from: String(view)) == nil, "a tampered payload does not decrypt")
}

private func passphraseIsExclusive() {
    let secret = "только для того, кто знает фразу"
    let wrapped = AorusCodeCipher.hide(cover: "cover", secret: secret, passphrase: "correct horse")

    require(AorusCodeCipher.reveal(from: wrapped) == nil,
            "a passphrase message does not open with the app key")
    require(AorusCodeCipher.reveal(from: wrapped, passphrase: "wrong") == nil,
            "the wrong passphrase does not open it")
    require(AorusCodeCipher.reveal(from: wrapped, passphrase: "correct horse") == secret,
            "the right passphrase opens it")
    require(AorusCodeCipher.visibleText(wrapped) == "cover", "the cover is still only the cover")

    // An app-key message is not opened by supplying a passphrase — the two tiers
    // are distinct, and the auto-reveal path only ever supplies nil.
    let appKeyMessage = AorusCodeCipher.hide(cover: "", secret: "shared")
    require(AorusCodeCipher.reveal(from: appKeyMessage, passphrase: "anything") == nil,
            "a passphrase does not open an app-key message")
    require(AorusCodeCipher.reveal(from: appKeyMessage) == "shared", "but nil opens it")
}

private func readsLegacyMessages() {
    // The pre-encryption format: the markers around base-4 of the raw UTF-8 bytes,
    // with no version framing. A build from before encryption produced this, and a
    // conversation in flight must not go dark on upgrade.
    let dataScalars: [Unicode.Scalar] = ["\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}"]
    let secret = "legacy plaintext"
    var view = String.UnicodeScalarView()
    view.append(contentsOf: "\u{2061}\u{2062}".unicodeScalars)
    for byte in secret.utf8 {
        view.append(dataScalars[Int((byte >> 6) & 0x3)])
        view.append(dataScalars[Int((byte >> 4) & 0x3)])
        view.append(dataScalars[Int((byte >> 2) & 0x3)])
        view.append(dataScalars[Int(byte & 0x3)])
    }
    view.append(contentsOf: "\u{2062}\u{2061}".unicodeScalars)
    let legacy = "cover" + String(view)
    require(AorusCodeCipher.reveal(from: legacy) == secret, "a legacy plaintext message still reads")
}

private func ignoresTextWithNoPayload() {
    require(AorusCodeCipher.reveal(from: "just a normal message") == nil, "plain text has no secret")
    require(!AorusCodeCipher.containsPayload("just a normal message"), "plain text has no payload")
    require(AorusCodeCipher.visibleText("just a normal message") == "just a normal message",
            "plain text is its own visible text")
    require(AorusCodeCipher.hide(cover: "keep", secret: "") == "keep", "an empty secret hides nothing")
}

@main
private enum AorusCodeCipherTests {
    static func main() {
        verifiesTheKdf()
        hidesAndRevealsUnderTheAppKey()
        addsOnlyInvisibleCharacters()
        neverRepeatsAPayload()
        rejectsTampering()
        passphraseIsExclusive()
        readsLegacyMessages()
        ignoresTextWithNoPayload()
        print("AorusCodeCipher tests: OK")
    }
}
