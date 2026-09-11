import Foundation
import UIKit
import LocalAuthentication
import AorusGram

// AorusGram: account-scoped Chat Protection.
//
// Persistent state is separated by Telegram account id. Unlock timestamps remain memory-only,
// so terminating the app always restores protection.
public final class AorusChatLock {
    public static let shared = AorusChatLock()

    private static let legacyEnabledKey = "aorusgram_chat_lock_enabled"
    private static let legacyPeersKey = "aorusgram_chat_lock_peers"
    private static let migrationKey = "aorusgram_chat_lock_account_scope_migrated"

    public static let changedNotification = Notification.Name("aorusgram_chat_lock_changed")
    public static let gracePeriod: TimeInterval = 10 * 60

    private static var lastUnlock: [Int64: TimeInterval] = [:]
    private static var promptingAccounts = Set<Int64>()
    private static var cachedEnabled: [Int64: Bool] = [:]
    private static var cachedIds: [Int64: Set<Int64>] = [:]
    private static var expiryGeneration: [Int64: Int] = [:]
    private static let stateLock = NSRecursiveLock()

    private init() {}

    private static func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private static func enabledKey(accountId: Int64) -> String {
        return "\(legacyEnabledKey)_\(accountId)"
    }

    private static func peersKey(accountId: Int64) -> String {
        return "\(legacyPeersKey)_\(accountId)"
    }

    /// Move pre-account-scoping state to the first account that opens it. Removing the legacy
    /// keys prevents the same protected-peer list from leaking into every other account.
    private static func migrateLegacyIfNeeded(accountId: Int64) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        let scopedEnabledKey = enabledKey(accountId: accountId)
        let scopedPeersKey = peersKey(accountId: accountId)
        if defaults.object(forKey: scopedEnabledKey) == nil,
           let enabled = defaults.object(forKey: legacyEnabledKey) as? Bool {
            defaults.set(enabled, forKey: scopedEnabledKey)
        }
        if defaults.object(forKey: scopedPeersKey) == nil,
           let peers = defaults.array(forKey: legacyPeersKey) {
            defaults.set(peers, forKey: scopedPeersKey)
        }
        defaults.removeObject(forKey: legacyEnabledKey)
        defaults.removeObject(forKey: legacyPeersKey)
        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - State

    public static func isEnabled(accountId: Int64) -> Bool {
        guard AorusLicenseAccess.isAllowed else { return false }
        return withStateLock {
            migrateLegacyIfNeeded(accountId: accountId)
            if let cached = cachedEnabled[accountId] {
                return cached
            }
            let value = UserDefaults.standard.bool(forKey: enabledKey(accountId: accountId))
            cachedEnabled[accountId] = value
            return value
        }
    }

    public static func setEnabled(_ value: Bool, accountId: Int64) {
        let effectiveValue = AorusLicenseAccess.isAllowed ? value : false
        withStateLock {
            migrateLegacyIfNeeded(accountId: accountId)
            UserDefaults.standard.set(effectiveValue, forKey: enabledKey(accountId: accountId))
            cachedEnabled[accountId] = effectiveValue
            if effectiveValue {
                markUnlocked(accountId: accountId)
            } else {
                resetGracePeriod(accountId: accountId)
            }
            notifyChanged(accountId: accountId)
        }
    }

    public static func lockedPeerIds(accountId: Int64) -> [Int64] {
        return withStateLock {
            migrateLegacyIfNeeded(accountId: accountId)
            guard let raw = UserDefaults.standard.array(forKey: peersKey(accountId: accountId)) as? [NSNumber] else {
                return []
            }
            return raw.map(\.int64Value)
        }
    }

    private static func setLockedPeerIds(_ ids: [Int64], accountId: Int64) {
        UserDefaults.standard.set(ids.map { NSNumber(value: $0) }, forKey: peersKey(accountId: accountId))
        cachedIds[accountId] = Set(ids)
    }

    private static func lockedIdSet(accountId: Int64) -> Set<Int64> {
        return withStateLock {
            if let cached = cachedIds[accountId] {
                return cached
            }
            let set = Set(lockedPeerIds(accountId: accountId))
            cachedIds[accountId] = set
            return set
        }
    }

    public static func add(accountId: Int64, peerId: Int64) {
        withStateLock {
            var ids = lockedPeerIds(accountId: accountId)
            guard !ids.contains(peerId) else { return }
            ids.append(peerId)
            setLockedPeerIds(ids, accountId: accountId)
            resetGracePeriod(accountId: accountId)
            notifyChanged(accountId: accountId)
        }
    }

    public static func remove(accountId: Int64, peerId: Int64) {
        withStateLock {
            var ids = lockedPeerIds(accountId: accountId)
            ids.removeAll { $0 == peerId }
            setLockedPeerIds(ids, accountId: accountId)
            notifyChanged(accountId: accountId)
        }
    }

    public static func isProtected(accountId: Int64, peerId: Int64) -> Bool {
        return withStateLock {
            guard isEnabled(accountId: accountId) else { return false }
            return lockedIdSet(accountId: accountId).contains(peerId)
        }
    }

    // MARK: - Grace period

    private static func now() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    public static func isWithinGracePeriod(accountId: Int64) -> Bool {
        return withStateLock {
            now() - (lastUnlock[accountId] ?? -.greatestFiniteMagnitude) < gracePeriod
        }
    }

    public static func markUnlocked(accountId: Int64) {
        withStateLock {
            lastUnlock[accountId] = now()
            scheduleExpiryNotification(accountId: accountId)
            notifyChanged(accountId: accountId)
        }
    }

    private static func scheduleExpiryNotification(accountId: Int64) {
        let generation = withStateLock { () -> Int in
            let value = (expiryGeneration[accountId] ?? 0) &+ 1
            expiryGeneration[accountId] = value
            return value
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gracePeriod + 0.5) {
            let isCurrent = withStateLock {
                expiryGeneration[accountId] == generation
            }
            guard isCurrent else { return }
            guard !isWithinGracePeriod(accountId: accountId) else { return }
            notifyChanged(accountId: accountId)
        }
    }

    private static func notifyChanged(accountId: Int64) {
        NotificationCenter.default.post(
            name: changedNotification,
            object: NSNumber(value: accountId)
        )
    }

    public static func resetGracePeriod(accountId: Int64) {
        withStateLock {
            lastUnlock[accountId] = -.greatestFiniteMagnitude
            expiryGeneration[accountId] = (expiryGeneration[accountId] ?? 0) &+ 1
        }
    }

    public static func requiresAuth(accountId: Int64, peerId: Int64) -> Bool {
        return withStateLock {
            guard isProtected(accountId: accountId, peerId: peerId) else { return false }
            return !isWithinGracePeriod(accountId: accountId)
        }
    }

    public static func settingsRequireAuth(accountId: Int64) -> Bool {
        return withStateLock {
            guard isEnabled(accountId: accountId) else { return false }
            return !isWithinGracePeriod(accountId: accountId)
        }
    }

    // MARK: - Authentication

    public static func isBiometryAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public static func authenticate(
        accountId: Int64,
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        if isWithinGracePeriod(accountId: accountId) {
            DispatchQueue.main.async { completion(true) }
            return
        }
        let isAlreadyPrompting = withStateLock {
            promptingAccounts.contains(accountId)
        }
        if isAlreadyPrompting {
            DispatchQueue.main.async { completion(false) }
            return
        }

        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // A protection feature must never silently open protected data when the device
            // cannot authenticate its owner.
            DispatchQueue.main.async { completion(false) }
            return
        }

        let didBeginPrompt = withStateLock { () -> Bool in
            guard !promptingAccounts.contains(accountId) else { return false }
            promptingAccounts.insert(accountId)
            return true
        }
        guard didBeginPrompt else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                withStateLock {
                    promptingAccounts.remove(accountId)
                }
                if success {
                    markUnlocked(accountId: accountId)
                }
                completion(success)
            }
        }
    }
}

// MARK: - Bridges for patched stock sources

public func aorusChatLockIsProtected(_ accountId: Int64, _ peerId: Int64) -> Bool {
    return AorusChatLock.isProtected(accountId: accountId, peerId: peerId)
}

public func aorusChatLockRequiresAuth(_ accountId: Int64, _ peerId: Int64) -> Bool {
    return AorusChatLock.requiresAuth(accountId: accountId, peerId: peerId)
}

public func aorusChatLockHiddenMessageText(_ languageCode: String) -> String {
    return aorusL("Сообщение скрыто", "Message hidden", AorusLang.resolve(languageCode))
}

public func aorusChatLockAuthenticate(_ accountId: Int64, _ completion: @escaping (Bool) -> Void) {
    // Follows the language selected in Telegram; the device language is only used
    // before Telegram has one at all.
    AorusChatLock.authenticate(
        accountId: accountId,
        reason: aorusL("Разблокируйте, чтобы открыть чат", "Unlock to open this chat"),
        completion: completion
    )
}
