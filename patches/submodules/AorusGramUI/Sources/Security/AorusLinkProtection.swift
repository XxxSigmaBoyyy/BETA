import Foundation
import UIKit
import AorusGram

public enum AorusLinkProtection {
    private static let enabledKey = "aorusgram_link_protection_enabled"
    private static let redirectsKey = "aorusgram_link_protection_redirects"
    private static let blockFilesKey = "aorusgram_link_protection_block_files"
    private static var allowedOnce = Set<String>()

    // ru/en are templates, not finished text. The scheme, TLD, brand or extension is
    // substituted into %@ after translation, so the English string stays a stable key in
    // AorusL10nTable instead of differing on every link.
    private struct Risk {
        let ru: String
        let en: String
        var value: String? = nil
        let blocking: Bool
    }

    private struct Report {
        let normalizedURL: String
        let risks: [Risk]

        var shouldBlock: Bool {
            return risks.contains(where: { $0.blocking })
        }
    }

    public static var isEnabled: Bool {
        if !AorusLicenseAccess.isAllowed {
            return false
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    public static var checksRedirects: Bool {
        if UserDefaults.standard.object(forKey: redirectsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: redirectsKey)
    }

    public static var blocksDangerousFiles: Bool {
        if UserDefaults.standard.object(forKey: blockFilesKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: blockFilesKey)
    }

    public static func setEnabled(_ value: Bool) {
        let effectiveValue = AorusLicenseAccess.isAllowed ? value : false
        UserDefaults.standard.set(effectiveValue, forKey: enabledKey)
    }

    public static func setChecksRedirects(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: redirectsKey)
    }

    public static func setBlocksDangerousFiles(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: blockFilesKey)
    }

    public static func consumeAllowed(_ raw: String) -> Bool {
        let key = canonicalKey(raw)
        if allowedOnce.contains(key) {
            allowedOnce.remove(key)
            return true
        }
        return false
    }

    public static func allowOnce(_ raw: String) {
        allowedOnce.insert(canonicalKey(raw))
    }

    public static func shouldIntercept(_ raw: String) -> Bool {
        guard isEnabled else {
            return false
        }
        return !analyze(raw).risks.isEmpty
    }

    public static func presentWarning(url raw: String, languageCode: String?, openAnyway: @escaping () -> Void) {
        let report = analyze(raw)
        guard !report.risks.isEmpty else {
            openAnyway()
            return
        }

        let title = report.shouldBlock
            ? (aorusL("Опасная ссылка заблокирована", "Dangerous Link Blocked"))
            : (aorusL("Подозрительная ссылка", "Suspicious Link"))
        let riskText = report.risks.prefix(6).map { risk in
            let template = aorusL(risk.ru, risk.en)
            let text = risk.value.map { template.replacingOccurrences(of: "%@", with: $0) } ?? template
            return text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: "\n")
        let message = report.normalizedURL + "\n\n" + riskText

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: aorusL("Отмена", "Cancel"), style: .cancel))
        if !report.shouldBlock {
            alert.addAction(UIAlertAction(title: aorusL("Открыть всё равно", "Open Anyway"), style: .destructive, handler: { _ in
                openAnyway()
            }))
        } else {
            alert.addAction(UIAlertAction(title: "OK", style: .default))
        }
        topController()?.present(alert, animated: true)
    }

    /// The scheme this text declares, by the rule the URI syntax actually uses: letters,
    /// digits, `+`, `-` and `.` after a leading letter, then a colon. No authority
    /// required — that is what distinguishes `javascript:…` from `https://…`, and it is
    /// the distinction that matters here.
    ///
    /// nil when the text names no scheme at all, which is when a default may be assumed.
    static func declaredScheme(_ value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = value[value.startIndex ..< colon]
        guard let first = candidate.first, first.isLetter, first.isASCII else { return nil }
        guard candidate.allSatisfy({ character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "+" || character == "-" || character == "."
        }) else {
            return nil
        }
        // A bare "example.com:8080/path" is a host and a port, not a scheme and a body.
        // Both halves of the test are needed: the digits alone would also reject `tel:123`,
        // which IS a scheme, and a dot alone would reject nothing useful — a real scheme
        // may contain one but a numeric body after a dotted name is a port every time.
        let rest = value[value.index(after: colon)...]
        let upToDelimiter = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if candidate.contains("."), !upToDelimiter.isEmpty,
           upToDelimiter.allSatisfy({ $0.isNumber && $0.isASCII }) {
            return nil
        }
        return String(candidate).lowercased()
    }

    private static func analyze(_ raw: String) -> Report {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whether a scheme is present is a question of URI syntax, not of whether the text
        // happens to contain "://". `javascript:alert(1)`, `data:text/plain,x` and `tel:123`
        // are all schemes with an OPAQUE body and no authority — so the old test said "no
        // scheme", prefixed `https://`, and every one of them was then analysed as an
        // ordinary https link whose scheme was `https`. The three schemes this analyser
        // exists to catch were exactly the three it could not see.
        let declared = declaredScheme(trimmed)
        let parseSource = declared == nil ? "https://\(trimmed)" : trimmed
        let url = URL(string: parseSource)
        let components = URLComponents(string: parseSource)
        let scheme = (declared ?? components?.scheme ?? url?.scheme ?? "").lowercased()
        let host = (components?.host ?? url?.host ?? "").lowercased()
        // Decoded, so that `.%6dobileconfig` is examined as `.mobileconfig`. Percent
        // encoding is the sender's choice and iOS decodes it before acting on it; reading
        // the encoded form meant the extension list could be stepped around by spelling
        // one letter differently.
        let encodedPath = components?.percentEncodedPath ?? url?.path ?? ""
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        var risks: [Risk] = []

        if !scheme.isEmpty && riskySchemes.contains(scheme) {
            risks.append(Risk(
                ru: "опасная схема ссылки: %@",
                en: "dangerous URL scheme: %@",
                value: scheme,
                blocking: scheme == "javascript" || scheme == "data" || scheme == "file" || scheme == "itms-services"
            ))
        }

        if scheme == "tg", !isAllowedTelegramSchemeHost(host) {
            risks.append(Risk(
                ru: "ссылка запускает внутреннее действие Telegram",
                en: "link starts an internal Telegram action",
                blocking: false
            ))
        }

        if host.contains("xn--") {
            risks.append(Risk(
                ru: "домен использует Punycode и может скрывать подмену символов",
                en: "domain uses Punycode and may hide character spoofing",
                blocking: false
            ))
        }

        if containsNonASCII(host) {
            risks.append(Risk(
                ru: "домен содержит не ASCII-символы",
                en: "domain contains non-ASCII characters",
                blocking: false
            ))
        }

        if containsMixedLatinCyrillic(host) {
            risks.append(Risk(
                ru: "в домене смешаны латиница и кириллица",
                en: "domain mixes Latin and Cyrillic characters",
                blocking: false
            ))
        }

        if hasCredentials(raw: trimmed, host: host) {
            risks.append(Risk(
                ru: "в ссылке есть скрытая часть перед доменом",
                en: "link contains a hidden credential part before the domain",
                blocking: false
            ))
        }

        if isIPAddress(host) {
            risks.append(Risk(
                ru: "ссылка ведёт на IP-адрес вместо понятного домена",
                en: "link points to an IP address instead of a readable domain",
                blocking: false
            ))
        }

        if isShortener(host) {
            risks.append(Risk(
                ru: "используется сокращатель ссылок",
                en: "link uses a URL shortener",
                blocking: false
            ))
        }

        if checksRedirects && containsRedirectParameter(components: components, raw: trimmed) {
            risks.append(Risk(
                ru: "ссылка содержит параметр редиректа на другой адрес",
                en: "link contains a redirect parameter to another address",
                blocking: false
            ))
        }

        if let tld = host.split(separator: ".").last.map(String.init), suspiciousTLDs.contains(tld) {
            risks.append(Risk(
                ru: "подозрительная доменная зона: .%@",
                en: "suspicious domain zone: .%@",
                value: tld,
                blocking: false
            ))
        }

        if let brandRisk = brandImpersonationRisk(host: host) {
            risks.append(brandRisk)
        }

        let fileExtension = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        if dangerousExtensions.contains(fileExtension) {
            risks.append(Risk(
                ru: "ссылка ведёт на потенциально опасный файл .%@",
                en: "link points to a potentially dangerous .%@ file",
                value: fileExtension,
                blocking: blocksDangerousFiles
            ))
        }

        return Report(normalizedURL: trimmed, risks: deduplicate(risks))
    }

    private static func canonicalKey(_ raw: String) -> String {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func topController() -> UIViewController? {
        var window: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first
            if window != nil {
                break
            }
        }
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private static let riskySchemes: Set<String> = [
        "javascript", "data", "file", "itms-services", "facetime", "facetime-audio", "tel", "sms"
    ]

    private static let dangerousExtensions: Set<String> = [
        "apk", "ipa", "mobileconfig", "dmg", "pkg", "exe", "msi", "bat", "cmd", "scr", "ps1", "vbs", "js", "jar", "zip", "rar", "7z"
    ]

    private static let suspiciousTLDs: Set<String> = [
        "zip", "mov", "click", "rest", "quest", "top", "xyz", "icu", "cyou", "cam", "work", "gq", "tk", "ml", "cf"
    ]

    private static let shorteners: Set<String> = [
        "bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd", "buff.ly", "cutt.ly", "s.id", "clck.ru", "vk.cc", "lnkd.in", "rebrand.ly", "shorturl.at", "rb.gy"
    ]

    private static let trustedTelegramHosts: Set<String> = [
        "t.me", "telegram.me", "telegram.org", "core.telegram.org", "desktop.telegram.org", "macos.telegram.org", "web.telegram.org"
    ]

    private static func isAllowedTelegramSchemeHost(_ host: String) -> Bool {
        return host == "resolve" || host == "join" || host == "addstickers" || host == "share" || host == "msg" || host == "proxy" || host == "socks"
    }

    private static func containsNonASCII(_ value: String) -> Bool {
        return value.unicodeScalars.contains { $0.value > 127 }
    }

    private static func containsMixedLatinCyrillic(_ value: String) -> Bool {
        var hasLatin = false
        var hasCyrillic = false
        for scalar in value.unicodeScalars {
            if (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) {
                hasLatin = true
            } else if (0x0400...0x052F).contains(Int(scalar.value)) {
                hasCyrillic = true
            }
        }
        return hasLatin && hasCyrillic
    }

    private static func hasCredentials(raw: String, host: String) -> Bool {
        guard !host.isEmpty, let schemeRange = raw.range(of: "://") else {
            return false
        }
        let afterScheme = raw[schemeRange.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else {
            return afterScheme.contains("@")
        }
        return afterScheme[..<slash].contains("@")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else {
            return false
        }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else {
                return false
            }
            return true
        }
    }

    private static func isShortener(_ host: String) -> Bool {
        return shorteners.contains(host) || shorteners.contains(host.replacingOccurrences(of: "www.", with: ""))
    }

    private static func containsRedirectParameter(components: URLComponents?, raw: String) -> Bool {
        let redirectNames: Set<String> = ["url", "u", "to", "target", "redirect", "redirect_url", "next", "return", "return_to", "continue", "dest", "destination"]
        if let items = components?.queryItems {
            for item in items {
                if redirectNames.contains(item.name.lowercased()), let value = item.value?.lowercased() {
                    if value.contains("://") || value.contains("%3a%2f%2f") {
                        return true
                    }
                }
            }
        }
        let lower = raw.lowercased()
        return lower.contains("redirect=http") || lower.contains("url=http") || lower.contains("target=http")
    }

    private static func brandImpersonationRisk(host: String) -> Risk? {
        guard !host.isEmpty else {
            return nil
        }
        if trustedTelegramHosts.contains(host) || host.hasSuffix(".telegram.org") {
            return nil
        }
        let folded = confusableFold(host)
        let labels = folded.split(separator: ".").map(String.init)
        let brands = ["telegram", "ton", "fragment", "apple", "google", "binance", "bybit", "metamask", "trustwallet", "paypal", "sberbank", "tinkoff", "avito", "ozon", "wildberries"]
        for label in labels {
            for brand in brands {
                if label.contains(brand), !isTrustedBrandHost(host, brand: brand) {
                    return Risk(
                        ru: "домен похож на известный сервис: %@",
                        en: "domain looks similar to a known service: %@",
                        value: brand,
                        blocking: false
                    )
                }
            }
        }
        return nil
    }

    private static func isTrustedBrandHost(_ host: String, brand: String) -> Bool {
        let trusted: [String: [String]] = [
            "telegram": Array(trustedTelegramHosts),
            "ton": ["ton.org"],
            "fragment": ["fragment.com"],
            "apple": ["apple.com"],
            "google": ["google.com", "google.ru"],
            "binance": ["binance.com"],
            "bybit": ["bybit.com"],
            "metamask": ["metamask.io"],
            "trustwallet": ["trustwallet.com"],
            "paypal": ["paypal.com"],
            "sberbank": ["sberbank.ru", "sber.ru"],
            "tinkoff": ["tinkoff.ru", "tbank.ru"],
            "avito": ["avito.ru"],
            "ozon": ["ozon.ru"],
            "wildberries": ["wildberries.ru"]
        ]
        guard let hosts = trusted[brand] else {
            return false
        }
        return hosts.contains { trustedHost in
            host == trustedHost || host.hasSuffix(".\(trustedHost)")
        }
    }

    private static func confusableFold(_ value: String) -> String {
        let map: [Character: Character] = [
            "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x",
            "к": "k", "м": "m", "т": "t", "в": "b", "н": "h", "і": "i", "ӏ": "l",
            "α": "a", "β": "b", "ε": "e", "ζ": "z", "η": "h", "ι": "i", "κ": "k",
            "μ": "m", "ν": "n", "ο": "o", "ρ": "p", "τ": "t", "χ": "x", "υ": "y"
        ]
        var result = ""
        result.reserveCapacity(value.count)
        for character in value.lowercased() {
            result.append(map[character] ?? character)
        }
        return result
    }

    private static func deduplicate(_ risks: [Risk]) -> [Risk] {
        var seen = Set<String>()
        var result: [Risk] = []
        for risk in risks {
            let key = risk.ru + risk.en + (risk.value ?? "")
            if seen.insert(key).inserted {
                result.append(risk)
            }
        }
        return result
    }
}
