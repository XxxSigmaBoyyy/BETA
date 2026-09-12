import Foundation
import UIKit
import Display

// AorusGram local badge system.
//
// Badge assignments come only from a signed license response. They remain local
// presentation state and are never sent to Telegram.
//
// Three kinds:
//   - verified  → handled natively: TelegramCore's `isVerified` is patched to
//                 return true for these channels/chats, so the genuine Telegram
//                 checkmark is shown (NOT rendered here).
//   - dev       → a hollow rounded-rect "DEV" tag (blue outline + blue text).
//   - meme      → a custom easter-egg cat icon for one friend-admin.
//
// `verified` rides Telegram's native verified presentation path; DEV and meme are
// rendered by this module.

public enum AorusBadgeKind: Equatable {
    case dev
    case meme
}

public enum AorusBadge {
    private static let badgeRegistryKey = "aorusgram_server_badges_v1"
    private static let selfBadgeRegistryKey = "aorusgram_server_self_badges_v2"
    private static let verifiedRegistryKey = "aorusgram_server_verified_v1"
    private static let snapshotRevisionKey = "aorusgram_server_badges_revision_v1"
    private static let registryLock = NSLock()

    // Replace, never merge, the signed assignment for one account. This ensures a
    // server-side revoke disappears on the next successful license response.
    public static func replaceServerBadges(forPeerRawId id: Int64,
                                           badges: [(String, Int64?)],
                                           serverNow: Int64?) {
        guard id != 0 else { return }
        let now = serverNow ?? Int64(Date().timeIntervalSince1970)
        let sanitized = sanitize(badges, now: now)

        registryLock.lock()
        let defaults = UserDefaults.standard
        var registry = defaults.dictionary(forKey: selfBadgeRegistryKey) ?? [:]
        registry[String(id)] = sanitized
        defaults.set(registry, forKey: selfBadgeRegistryKey)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        notifyChanged()
    }

    // Replace the complete signed roster in one critical section. The current
    // account's /check or /bootstrap assignment lives in a separate overlay and
    // therefore remains authoritative even when a snapshot arrives concurrently.
    @discardableResult
    public static func replaceServerBadgeSnapshot(
        _ badges: [Int64: [(String, Int64?)]],
        serverNow: Int64,
        revision: Int64
    ) -> Bool {
        guard serverNow > 0, revision >= 0 else { return false }
        var snapshot: [String: Any] = [:]
        snapshot.reserveCapacity(badges.count)
        for (peerId, assignments) in badges where peerId > 0 {
            let sanitized = sanitize(assignments, now: serverNow)
            if !sanitized.isEmpty {
                snapshot[String(peerId)] = sanitized
            }
        }

        registryLock.lock()
        let defaults = UserDefaults.standard
        if let storedRevision = defaults.object(forKey: snapshotRevisionKey) as? NSNumber,
           revision < storedRevision.int64Value {
            registryLock.unlock()
            return false
        }
        defaults.set(snapshot, forKey: badgeRegistryKey)
        defaults.set(NSNumber(value: revision), forKey: snapshotRevisionKey)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        notifyChanged()
        return true
    }

    public static func clearServerBadgeSnapshot() {
        registryLock.lock()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: badgeRegistryKey)
        defaults.removeObject(forKey: snapshotRevisionKey)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        notifyChanged()
    }

    private static func sanitize(_ badges: [(String, Int64?)], now: Int64) -> [String: Int64] {
        var sanitized: [String: Int64] = [:]
        for (rawId, until) in badges {
            let normalized = rawId == "head_admin_cat" ? "meme" : rawId
            guard normalized == "dev" || normalized == "meme" || normalized == "verified" else {
                continue
            }
            if let until, until <= now { continue }
            // Zero is the property-list-safe representation of no expiry.
            sanitized[normalized] = until ?? 0
        }
        return sanitized
    }

    /// Publish the derived registries once at launch.
    ///
    /// `verified` is not rendered by this module: TelegramCore's `isVerified` reads the
    /// derived registry key directly, and that key is only ever written as a side effect
    /// of a badge write. On a launch where no badge write happens — a fresh install, or
    /// any launch before the first signed response lands — the key is absent and every
    /// checkmark is missing. Called from the bootstrap so the registries exist before the
    /// first row is drawn.
    public static func bootstrapRegistries() {
        registryLock.lock()
        rebuildVerifiedRegistry(defaults: UserDefaults.standard)
        registryLock.unlock()
        notifyChanged()
    }

    private static func rebuildVerifiedRegistry(defaults: UserDefaults) {
        let snapshot = defaults.dictionary(forKey: badgeRegistryKey) ?? [:]
        let own = defaults.dictionary(forKey: selfBadgeRegistryKey) ?? [:]
        var verified: [String: Any] = [:]

        for (peerId, rawAssignments) in snapshot {
            if let assignments = rawAssignments as? [String: Any],
               let until = assignments["verified"] as? NSNumber {
                verified[peerId] = until
            }
        }
        // A present self entry, including an empty one, overrides the roster.
        for (peerId, rawAssignments) in own {
            verified.removeValue(forKey: peerId)
            if let assignments = rawAssignments as? [String: Any],
               let until = assignments["verified"] as? NSNumber {
                verified[peerId] = until
            }
        }
        defaults.set(verified, forKey: verifiedRegistryKey)
    }

    private static func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("aorusgram.serverBadgesChanged"), object: nil
            )
        }
    }

    private static func activeAssignments(for id: Int64) -> [String: Any] {
        registryLock.lock()
        defer { registryLock.unlock() }
        let defaults = UserDefaults.standard
        if let own = defaults.dictionary(forKey: selfBadgeRegistryKey),
           let assignments = own[String(id)] as? [String: Any] {
            return assignments
        }
        if let roster = defaults.dictionary(forKey: badgeRegistryKey)?[String(id)] as? [String: Any] {
            return roster
        }
        return [:]
    }

    private static func isActive(_ value: Any?, now: Int64) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let until = number.int64Value
        return until == 0 || now < until
    }

    public static func kind(forPeerRawId id: Int64) -> AorusBadgeKind? {
        let assignments = activeAssignments(for: id)
        let now = Int64(Date().timeIntervalSince1970)
        if isActive(assignments["meme"], now: now) { return .meme }
        if isActive(assignments["dev"], now: now) { return .dev }
        return nil
    }

    // Toast text shown when the badge is tapped. Follows the in-app Telegram language
    // via the shared "aorusgram_lang_code" key written by AppDelegate.
    //
    // These two strings are resolved here rather than through AorusGramUI's shared
    // helper: AorusBadge is a leaf module that Display-level code links against, and
    // depending on AorusGramUI to translate two labels would drag the settings UI in behind
    // it. The lookup key is the same one AppDelegate publishes.
    private static func localized(_ table: [String: String], _ fallback: String) -> String {
        let code = (UserDefaults.standard.string(forKey: "aorusgram_lang_code")
            ?? UserDefaults.standard.string(forKey: "aorusgram_lang")
            ?? Locale.preferredLanguages.first
            ?? "en").lowercased()
        // Full code first, then the base: Telegram ships Chinese as two packs, "zh-hans" and
        // "zh-hant", and truncating at the separator would show one of them the wrong script.
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if let exact = table[normalized] {
            return exact
        }
        let base = String(normalized.prefix(while: { $0 != "-" }))
        return table[base] ?? fallback
    }

    public static func toastText(forPeerRawId id: Int64, peerName _: String) -> String? {
        guard let kind = kind(forPeerRawId: id) else { return nil }
        switch kind {
        case .dev:
            return localized([
                "ru": "Разработчик AorusGram",
                "uk": "Розробник AorusGram",
                "es": "Desarrollador de AorusGram",
                "pt": "Desenvolvedor do AorusGram",
                "de": "AorusGram-Entwickler",
                "fr": "Développeur d’AorusGram",
                "tr": "AorusGram geliştiricisi",
                "it": "Sviluppatore di AorusGram",
                "pl": "Deweloper AorusGram",
                "nl": "AorusGram-ontwikkelaar",
                "id": "Pengembang AorusGram",
                "ms": "Pembangun AorusGram",
                "ca": "Desenvolupador d’AorusGram",
                "be": "Распрацоўшчык AorusGram",
                "uz": "AorusGram dasturchisi",
                "ko": "AorusGram 개발자",
                "ar": "مطوّر AorusGram",
                "fa": "توسعه‌دهنده AorusGram",
                "kk": "AorusGram әзірлеушісі",
                "ja": "AorusGram 開発者",
                "fi": "AorusGramin kehittäjä",
                "he": "מפתח AorusGram",
                "zh-hans": "AorusGram 开发者",
                "zh-hant": "AorusGram 開發者",
                "hr": "Programer AorusGrama",
                "sr": "Програмер AorusGrama",
                "cs": "Vývojář AorusGramu",
                "sk": "Vývojár AorusGramu",
                "ro": "Dezvoltator AorusGram",
                "hu": "AorusGram fejlesztője",
                "nb": "AorusGram-utvikler",
                "sv": "AorusGram-utvecklare",
                "vi": "Nhà phát triển AorusGram",
            ], "AorusGram Developer")
        case .meme:
            return localized([
                "ru": "Гл. Администратор AorusGram",
                "uk": "Гол. Адміністратор AorusGram",
                "es": "Administrador principal de AorusGram",
                "pt": "Administrador principal do AorusGram",
                "de": "Hauptadministrator von AorusGram",
                "fr": "Administrateur principal d’AorusGram",
                "tr": "AorusGram baş yöneticisi",
                "it": "Amministratore principale di AorusGram",
                "pl": "Główny administrator AorusGram",
                "nl": "Hoofdbeheerder van AorusGram",
                "id": "Administrator utama AorusGram",
                "ms": "Pentadbir utama AorusGram",
                "ca": "Administrador principal d’AorusGram",
                "be": "Гал. Адміністратар AorusGram",
                "uz": "AorusGram bosh administratori",
                "ko": "AorusGram 수석 관리자",
                "ar": "المسؤول الرئيسي في AorusGram",
                "fa": "سرپرست اصلی AorusGram",
                "kk": "AorusGram бас әкімшісі",
                "ja": "AorusGram 主管理者",
                "fi": "AorusGramin pääylläpitäjä",
                "he": "מנהל ראשי של AorusGram",
                "zh-hans": "AorusGram 主管理员",
                "zh-hant": "AorusGram 主管理員",
                "hr": "Glavni administrator AorusGrama",
                "sr": "Главни администратор AorusGrama",
                "cs": "Hlavní administrátor AorusGramu",
                "sk": "Hlavný administrátor AorusGramu",
                "ro": "Administrator principal AorusGram",
                "hu": "AorusGram főadminisztrátora",
                "nb": "Hovedadministrator for AorusGram",
                "sv": "Huvudadministratör för AorusGram",
                "vi": "Quản trị viên chính của AorusGram",
            ], "AorusGram Head Administrator")
        }
    }

    // Badge image sized to `height` points (square box; DEV is wider than tall).
    // Rendered at screen scale. Returns nil if the peer has no custom badge.
    public static func image(forPeerRawId id: Int64, height: CGFloat, accent: UIColor) -> UIImage? {
        guard let kind = kind(forPeerRawId: id) else { return nil }
        switch kind {
        case .meme:
            return catImage(height: height)
        case .dev:
            return devImage(height: height, accent: accent)
        }
    }

    // Meme cat scaled to `height` points (preserving aspect). The source asset is a
    // large square PNG; without this it would render at its native size and dwarf the
    // surrounding row. Other surfaces (chat list, profile) historically aspect-fit it
    // into a fixed box, but the dedicated badge views use the image size directly, so
    // the scaling must happen here to stay consistent everywhere.
    private static func catImage(height: CGFloat) -> UIImage? {
        guard let cat = AorusBadgeAssets.cat else { return nil }
        let h = max(12.0, height)
        let aspect = cat.size.width / max(1.0, cat.size.height)
        let size = CGSize(width: floor(h * aspect), height: h)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.preferred()
            f.opaque = false
            return f
        }())
        return renderer.image { _ in
            cat.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // Hollow "DEV" tag: rounded-rect border (no fill) + "DEV" text, both in the
    // light-blue accent. The tag occupies ~70% of the slot height (transparent
    // padding above/below) and uses a medium (non-bold) weight so it reads as a
    // neat, understated label rather than grabbing attention.
    private static func devImage(height: CGFloat, accent: UIColor) -> UIImage? {
        let h = max(12.0, height)
        let tagH = floor(h * 0.9)
        let fontSize = floor(tagH * 0.62)
        let font = Font.medium(fontSize)
        let text = "DEV" as NSString
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent, .kern: 0.3]
        let textSize = text.size(withAttributes: textAttrs)
        let hInset = floor(tagH * 0.3)
        let lineWidth = max(1.0, h * 0.06)
        let tagW = ceil(textSize.width + hInset * 2.0)
        let size = CGSize(width: tagW, height: h)

        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.preferred()
            f.opaque = false
            return f
        }())
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let tagY = floor((h - tagH) / 2.0)
            let rect = CGRect(x: lineWidth / 2.0, y: tagY + lineWidth / 2.0, width: tagW - lineWidth, height: tagH - lineWidth)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: tagH * 0.3)
            cg.setStrokeColor(accent.cgColor)
            cg.setLineWidth(lineWidth)
            path.stroke()
            let textOrigin = CGPoint(x: (tagW - textSize.width) / 2.0, y: tagY + (tagH - textSize.height) / 2.0)
            text.draw(at: textOrigin, withAttributes: textAttrs)
        }
    }
}
