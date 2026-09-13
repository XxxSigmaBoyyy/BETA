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
    private static let snapshotServerNowKey = "aorusgram_server_badges_server_now_v1"
    private static let snapshotStoredAtKey = "aorusgram_server_badges_stored_at_v1"
    /// A roster this old stops being honoured. A revoke must not be defeatable by
    /// keeping the device off the network; the roster is cosmetic, so losing it while
    /// genuinely offline for a week costs nothing and it returns on the next fetch.
    private static let maximumSnapshotAge: TimeInterval = 7 * 24 * 60 * 60
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
        let changed = !plistEqual(registry[String(id)], sanitized)
        registry[String(id)] = sanitized
        defaults.set(registry, forKey: selfBadgeRegistryKey)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        if changed {
            notifyChanged()
        }
    }

    /// Compare two property-list values the way UserDefaults round-trips them.
    ///
    /// A value read back is bridged — `Int64` returns as `NSNumber` — so comparing the
    /// Swift values directly reports a difference that is not there. Both sides go
    /// through the Foundation types, where `NSNumber` compares by numeric value and a
    /// dictionary compares element by element. They are wrapped in a one-element
    /// `NSArray` rather than compared directly, because that gives both sides a single
    /// concrete Foundation type with no bridging left to infer.
    private static func plistEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let left = lhs else { return rhs == nil }
        guard let right = rhs else { return false }
        return NSArray(array: [left]).isEqual(to: [right])
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
        // Ordering is by the SERVER CLOCK first, and `revision` only breaks a tie within
        // the same second.
        //
        // Revision alone used to decide this, and that was a trap with no way out: the
        // stored revision only ever rises, so a server whose revision falls — which is
        // what happens when the newest badge row is the one deleted, and the manifest
        // revision is derived from the rows — is refused for good. The roster freezes,
        // every later fetch is thrown away, and a revoked badge stays on screen until
        // the app is reinstalled. `server_now` cannot fall that way.
        //
        // Nothing is lost by relaxing it: a replayed older response is already
        // impossible, because LicenseResponseVerifier binds the server's signature to
        // the random nonce of THIS request and to a timestamp inside a freshness window.
        // A stored revision with no stored server clock is the old format, and it is
        // accepted unconditionally — that is what releases anyone already frozen.
        if let storedServerNow = (defaults.object(forKey: snapshotServerNowKey) as? NSNumber)?.int64Value {
            if serverNow < storedServerNow {
                registryLock.unlock()
                return false
            }
            if serverNow == storedServerNow,
               let storedRevision = (defaults.object(forKey: snapshotRevisionKey) as? NSNumber)?.int64Value,
               revision < storedRevision {
                registryLock.unlock()
                return false
            }
        }
        // Every successful fetch lands here, and most carry the roster unchanged. The
        // notification re-runs the presentation pipeline, so posting it on an identical
        // roster would rebuild the theme on every foreground for nothing.
        let changed = !plistEqual(defaults.dictionary(forKey: badgeRegistryKey), snapshot)
        defaults.set(snapshot, forKey: badgeRegistryKey)
        defaults.set(NSNumber(value: revision), forKey: snapshotRevisionKey)
        defaults.set(NSNumber(value: serverNow), forKey: snapshotServerNowKey)
        defaults.set(Date().timeIntervalSince1970, forKey: snapshotStoredAtKey)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        if changed {
            notifyChanged()
        }
        return true
    }

    public static func clearServerBadgeSnapshot() {
        registryLock.lock()
        let defaults = UserDefaults.standard
        discardSnapshot(defaults: defaults)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        notifyChanged()
    }

    private static func discardSnapshot(defaults: UserDefaults) {
        defaults.removeObject(forKey: badgeRegistryKey)
        defaults.removeObject(forKey: snapshotRevisionKey)
        defaults.removeObject(forKey: snapshotServerNowKey)
        defaults.removeObject(forKey: snapshotStoredAtKey)
    }

    /// Drops a roster that has not been refreshed inside `maximumSnapshotAge`.
    ///
    /// A roster written by a build that did not record the time is stamped now rather
    /// than thrown away, so upgrading does not blank everyone's badges; the age is then
    /// measured from the upgrade. A stamp far in the future is a clock that has been
    /// moved, and is treated as stale rather than trusted indefinitely.
    private static func expireStaleSnapshot(defaults: UserDefaults) -> Bool {
        guard defaults.dictionary(forKey: badgeRegistryKey) != nil else { return false }
        let now = Date().timeIntervalSince1970
        guard let storedAt = defaults.object(forKey: snapshotStoredAtKey) as? NSNumber else {
            defaults.set(now, forKey: snapshotStoredAtKey)
            return false
        }
        guard abs(now - storedAt.doubleValue) > maximumSnapshotAge else { return false }
        discardSnapshot(defaults: defaults)
        return true
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
        let defaults = UserDefaults.standard
        let discarded = expireStaleSnapshot(defaults: defaults)
        rebuildVerifiedRegistry(defaults: defaults)
        registryLock.unlock()
        // Launch: the derived registry is published before anything draws, so there is
        // nothing on screen to invalidate unless a stale roster was just thrown away.
        if discarded {
            notifyChanged()
        }
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
