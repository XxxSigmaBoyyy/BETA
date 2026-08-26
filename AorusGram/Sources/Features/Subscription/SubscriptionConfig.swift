import Foundation

// All subscription / license configuration in one isolated place.
//
// This whole layer is deliberately self-contained: it talks ONLY to the license
// API over a private URLSession and never touches MTProto, getProxy, the proxy
// secret logic or any Telegram networking.
enum SubscriptionConfig {
    // MARK: License API
    static let baseURLString = "https://license.aorusgram.com"
    static let keyVersion = "1"                       // X-Aorus-Kv
    static let userAgent = "AorusGram/1.0.0 (iOS)"

    // MARK: Purchase bot
    static let purchaseBotUsername = "AorusGram_bot"
    // The app's own deep-link scheme (aorusgram://). The build sets
    // app_specific_url_scheme = "aorusgram" to match Info.plist, so this resolves the
    // bot chat INSIDE AorusGram (no Safari, no real-Telegram hop).
    static let purchaseBotScheme = "aorusgram://resolve?domain=AorusGram_bot&start=buy"
    // Resolved by Telegram's own internal resolver (openExternalUrl, forceExternal:
    // false) for the over-lock flow and as an in-app fallback. Never the browser.
    static let purchaseBotLink = "https://t.me/AorusGram_bot?start=buy"

    // MARK: Networking
    static let requestTimeout: TimeInterval = 15

    // Re-check throttle: on foreground only re-hit the API if the last successful
    // check is older than this. active_until still governs real validity.
    static let recheckInterval: TimeInterval = 60 * 30   // 30 minutes

    // MARK: - Hardening (anti fake-server / MITM)
    //
    // SAFE DEFAULTS: everything below is inert until provisioned, so the current
    // build behaves exactly as before. Activate ONLY in lock-step with the server.

    // Ed25519 PUBLIC key (raw 32 bytes, lowercase hex = 64 chars) the server uses to
    // sign every license response. Empty → response verification is inert. Its leak
    // is harmless: the matching PRIVATE key lives only on the server.
    static let responseSigningPublicKeyHex = "ae648741a012a36c991fdf4680742c68bdf1722c1693b3781c4daa08a8c49196"

    // When true, a response that is unsigned OR badly-signed is rejected (treated as
    // a network failure → no access granted). Keep FALSE until the server signs every
    // response, otherwise every user would be locked out.
    static let requireSignedResponse = true

    // Max clock skew (seconds) tolerated for the signed response timestamp.
    static let responseMaxSkew: TimeInterval = 300

    // TLS SPKI pins (base64 of SHA256 over DER SubjectPublicKeyInfo). Both protected
    // API hosts currently use the same verified Let's Encrypt chain. The leaf pin is
    // the strict match; the CA pins keep routine certificate renewal from taking the
    // client offline. Standard hostname and trust validation still runs first.
    //
    // IMPORTANT: rotate these only after checking the live chain. Never replace this
    // map with a wildcard host: banner/media services have independent lifecycles.
    static let pinnedSPKIHashesByHost: [String: [String]] = [
        "license.aorusgram.com": protectedAPISPKIPins,
        "api.aorusgram.com": protectedAPISPKIPins,
        "ai.aorusgram.com": aiAPISPKIPins
    ]

    // ai.aorusgram.com has its own leaf key, while using the same verified
    // Let's Encrypt chain as the other protected Aorus endpoints.
    private static let aiAPISPKIPins: [String] = [
        "Z/Olfhfs1OaJN2JjMhd4P2+AzcWrz5oY3PUQbx+RUno=",
        "s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y=",
        "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w="
    ]

    private static let protectedAPISPKIPins: [String] = [
        "3q/xrGVq1Nunte2iV/hnis5DNCAPkT5RwJsRej6w4s0=", // aorusgram.com leaf
        "s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y=", // Let's Encrypt YE2
        "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w="  // ISRG Root YE
    ]
}
