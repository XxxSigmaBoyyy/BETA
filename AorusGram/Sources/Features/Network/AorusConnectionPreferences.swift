import Foundation
import Security

/// The two AorusGram switches on Telegram's Proxy screen, kept where reinstalling cannot
/// reach them.
///
/// `UserDefaults` lives in the app container and the container is deleted with the app, so a
/// user who had switched the bypass off would find it back on after reinstalling — which is
/// the one state they had explicitly asked not to be in. Keychain items outlive the container
/// for the same bundle identifier, which is already how this client keeps its device key
/// (see `AorusRealityDeviceIdentity`), so the switches are stored there.
///
/// The defaults suite only mirrors them, because the readers live in other modules: the
/// MTProto override sits in TelegramCore and the call proxy in TelegramCallsUI, and neither
/// can see this type. The keychain is the truth and the mirror is rewritten from it on the
/// first access in every process, so a mirror that a reinstall wiped cannot flip a switch.
public final class AorusConnectionPreferences {
    public static let shared = AorusConnectionPreferences()

    /// Posted on the main queue after either switch changes.
    public static let didChangeNotification = Notification.Name("aorusgram_connection_preferences_changed")

    private static let suiteName = "ng.session.store"
    private static let service = "com.aorusgram.connection.preferences.v1"
    private static let account = "switches"
    /// Read by the patched TelegramCore / TelegramCallsUI code, which has no access to this
    /// type. Descriptive names on purpose: these are user preferences, not key material.
    public static let bypassMirrorKey = "aorusgram_connection_bypass_enabled"
    public static let stableCallsMirrorKey = "aorusgram_connection_stable_calls_enabled"

    private struct Stored: Codable, Equatable {
        var bypass: Bool
        var stableCalls: Bool
    }

    private let lock = NSLock()
    private var cached: Stored

    private init() {
        // Both default to on: that is the behaviour every existing install already has, and a
        // fresh install has nothing to migrate.
        let loaded = Self.readKeychain() ?? Stored(bypass: true, stableCalls: true)
        self.cached = loaded
        Self.writeMirror(loaded)
    }

    /// "Режим без VPN": the master switch for the built-in bypass. Off means the client never
    /// starts its own tunnel and behaves exactly like stock Telegram.
    public var bypassEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.bypass
    }

    /// "Стабильные звонки": carry call media over the tunnel. Off means calls connect natively.
    public var stableCallsEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cached.stableCalls
    }

    public func setBypassEnabled(_ value: Bool) {
        self.update { stored in stored.bypass = value }
    }

    public func setStableCallsEnabled(_ value: Bool) {
        self.update { stored in stored.stableCalls = value }
    }

    private func update(_ transform: (inout Stored) -> Void) {
        self.lock.lock()
        var updated = self.cached
        transform(&updated)
        let changed = updated != self.cached
        if changed {
            self.cached = updated
        }
        self.lock.unlock()
        guard changed else { return }
        Self.writeKeychain(updated)
        Self.writeMirror(updated)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static func keychainQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() -> Stored? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func writeKeychain(_ value: Stored) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query = keychainQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        // Not `ThisDeviceOnly`: a restore onto a new device should keep the user's choice, and
        // a boolean pair is not key material that has to stay put.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(insert as CFDictionary, nil)
    }

    private static func writeMirror(_ value: Stored) {
        guard let store = UserDefaults(suiteName: suiteName) else { return }
        store.set(value.bypass, forKey: bypassMirrorKey)
        store.set(value.stableCalls, forKey: stableCallsMirrorKey)
    }
}
