import Foundation
import Security
import AorusBadge

// Persistent license cache.
//
// The authoritative snapshot is Secure-Enclave wrapped and lives in a this-device-only
// Keychain item. A light, non-sensitive mirror is kept in UserDefaults for fast UI
// reads. The SERVER is the source of truth; this cache exists for UX and a bounded offline grace based on
// server_now / active_until — never raw local time alone.
final class LicenseStore {
    static let shared = LicenseStore()
    private init() {}

    private let lock = NSLock()
    private let kcService = "com.aorusgram.license"
    private let kcAccount = "cache_v1"
    private let udTelegramKey = "aorusgram_lic_tg_uid"   // non-sensitive UI/id mirror

    struct Snapshot: Codable {
        var statusRaw: String
        var plan: String?
        var activeUntil: Int64?
        var serverNow: Int64?
        var daysLeft: Int?
        var lastCheckWall: Double      // Date().timeIntervalSince1970 at the check
        var telegramUserId: Int64?
        // Tamper / theft protection (optional → old blobs decode and are re-signed).
        var deviceHash: String?        // device this cache belongs to
        var sig: String?               // HMAC over the fields above (key = license key)
    }

    private var snapshotValue: Snapshot?

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }

    func load() {
        guard let stored = readKeychain() else {
            lock.lock()
            snapshotValue = nil
            lock.unlock()
            return
        }
        let s = stored.snapshot
        // Integrity + device binding: a tampered blob, or one lifted from another
        // device, is ignored. This only forces a fresh online check — it can never
        // lock out a legitimate user (the server verdict restores access).
        if s.sig == sign(s), s.deviceHash == DeviceFingerprint.deviceHash() {
            lock.lock()
            snapshotValue = s
            lock.unlock()
            if stored.needsMigration {
                writeKeychain(s)
            }
        } else {
            lock.lock()
            snapshotValue = nil
            lock.unlock()
        }
    }

    func save(response: LicenseResponse, telegramUserId: Int64?) {
        lock.lock()
        let snap = Snapshot(
            statusRaw: response.status.rawValue,
            plan: response.plan,
            activeUntil: response.activeUntil,
            serverNow: response.serverNow,
            daysLeft: response.daysLeft,
            lastCheckWall: Date().timeIntervalSince1970,
            telegramUserId: telegramUserId ?? snapshotValue?.telegramUserId
        )
        snapshotValue = snap
        // Keep the persisted blob in the same order as the in-memory snapshot. A
        // concurrent account-id update must not be overwritten by an older write.
        writeKeychain(snap)
        lock.unlock()

        // UI mirror — non-sensitive only.
        let ud = UserDefaults.standard
        ud.set(snap.statusRaw, forKey: "aorusgram_lic_status")
        ud.set(snap.daysLeft ?? -1, forKey: "aorusgram_lic_days_left")

        if let peerId = telegramUserId ?? snap.telegramUserId, peerId != 0 {
            AorusBadge.replaceServerBadges(
                forPeerRawId: peerId,
                badges: response.badges.map { ($0.id.rawValue, $0.until) },
                serverNow: response.serverNow
            )
        }
        if response.status.allowsAppAccess {
            BadgeSnapshotService.shared.licenseDidBecomeActive()
        } else {
            BadgeSnapshotService.shared.licenseDidBecomeInactive()
            AorusBadge.clearServerBadgeSnapshot()
        }
    }

    func clear() {
        lock.lock()
        let clearedPeerId = snapshotValue?.telegramUserId
        snapshotValue = nil
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
        ]
        SecItemDelete(base as CFDictionary)
        lock.unlock()
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "aorusgram_lic_status")
        ud.removeObject(forKey: "aorusgram_lic_days_left")
        if let clearedPeerId, clearedPeerId != 0 {
            AorusBadge.replaceServerBadges(
                forPeerRawId: clearedPeerId, badges: [], serverNow: nil
            )
        }
        BadgeSnapshotService.shared.licenseDidBecomeInactive()
        AorusBadge.clearServerBadgeSnapshot()
    }

    // Prefer the id captured with the last license snapshot; fall back to the
    // standalone mirror set right after Telegram login (before any license check).
    var telegramUserId: Int64? {
        if let id = snapshot?.telegramUserId, id != 0 { return id }
        let v = UserDefaults.standard.object(forKey: udTelegramKey) as? NSNumber
        return v.map { $0.int64Value }
    }
    var daysLeft: Int? { snapshot?.daysLeft }

    // Persist the Telegram account id independently of the license snapshot, so the
    // first /license/check, /bootstrap and /activate after login carry the real id.
    func setTelegramUserId(_ id: Int64) {
        guard id != 0 else { return }
        UserDefaults.standard.set(NSNumber(value: id), forKey: udTelegramKey)
        lock.lock()
        var snap = snapshotValue
        if snap != nil {
            snap?.telegramUserId = id
            snapshotValue = snap
        }
        if let snap {
            writeKeychain(snap)
        }
        lock.unlock()
    }

    // Estimated current server time = server anchor + elapsed wall clock since the
    // last check. If the clock moved backwards we do NOT extend validity.
    private func estimatedServerNow(_ snap: Snapshot) -> Int64? {
        guard let serverNow = snap.serverNow else { return nil }
        let elapsed = Date().timeIntervalSince1970 - snap.lastCheckWall
        // A wall-clock rollback is not elapsed time. Returning the old anchor here
        // froze the licence at the last successful check and could extend offline
        // access indefinitely. Fail closed and require a fresh signed verdict.
        guard elapsed >= 0, elapsed < Double(Int64.max) else { return nil }
        let estimate = serverNow.addingReportingOverflow(Int64(elapsed))
        return estimate.overflow ? nil : estimate.partialValue
    }

    // Offline effective status: an active cache is trusted only while active_until
    // has not passed (server-anchored estimate); otherwise it is treated expired.
    func effectiveOfflineStatus() -> LicenseStatus {
        guard let snap = snapshot else { return .notStarted }
        let cached = LicenseStatus.parse(snap.statusRaw)
        switch cached {
        case .trialActive, .paidActive:
            guard let until = snap.activeUntil, let now = estimatedServerNow(snap) else {
                return .expired
            }
            return now < until ? cached : .expired
        default:
            return cached
        }
    }

    func needsRecheck(interval: TimeInterval) -> Bool {
        guard let last = snapshot?.lastCheckWall else { return true }
        let elapsed = Date().timeIntervalSince1970 - last
        return elapsed < 0 || elapsed > interval
    }

    // MARK: - Integrity

    // Canonical, deterministic representation of the signed fields (excludes `sig`).
    private func canonicalString(_ s: Snapshot) -> String {
        var parts: [String] = []
        parts.append(s.statusRaw)
        parts.append(s.plan ?? "")
        parts.append(s.activeUntil.map { String($0) } ?? "")
        parts.append(s.serverNow.map { String($0) } ?? "")
        parts.append(s.daysLeft.map { String($0) } ?? "")
        parts.append(String(format: "%.0f", s.lastCheckWall))
        parts.append(s.telegramUserId.map { String($0) } ?? "")
        parts.append(s.deviceHash ?? "")
        return parts.joined(separator: "|")
    }

    // HMAC-SHA256 with the embedded license key. Never logged.
    private func sign(_ s: Snapshot) -> String {
        return LicenseKeyProvider.withLicenseHmacKey { key in
            LicenseCrypto.hmacSHA256Hex(message: Data(canonicalString(s).utf8), keyBytes: key)
        } ?? ""
    }

    // MARK: - Keychain (JSON blob)

    private func writeKeychain(_ snap: Snapshot) {
        var s = snap
        s.deviceHash = DeviceFingerprint.deviceHash()
        s.sig = nil
        s.sig = sign(s)            // sign over the canonical fields (incl. deviceHash)
        guard let data = try? JSONEncoder().encode(s) else { return }
        // The self-describing envelope, for the same reason the VPN store uses it: `bind`
        // returns plaintext when no Secure Enclave key can be had and the reader cannot
        // tell, so a cache written before the device's first unlock became unreadable for
        // good — and an unreadable licence cache is a user losing their offline grace.
        let protectedData = AorusSeKeyBinder.protect(data)
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = protectedData
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    private func readKeychain() -> (snapshot: Snapshot, needsMigration: Bool)? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }

        // The current format says how it was protected, so no guessing is involved.
        if let opened = AorusSeKeyBinder.open(data),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: opened) {
            return (snapshot, false)
        }

        // Written by a build that wrapped with `bind`: ciphertext, or the plaintext its
        // fallback produced. Both are read here and rewritten in the current format.
        if let unbound = AorusSeKeyBinder.unbind(data),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: unbound) {
            return (snapshot, true)
        }

        // Older still: no wrapping at all. Accepting it is safe because the snapshot
        // carries its own signature over the device hash — a blob that was tampered with
        // fails that check whatever wrapper it arrived in.
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return (snapshot, true)
        }
        return nil
    }
}
