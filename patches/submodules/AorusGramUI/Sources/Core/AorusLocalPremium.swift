import Foundation
import AorusGram

// Local Telegram Premium toggle. Stored in UserDefaults under a plain key so the
// low-level premium gate (PeerUtils.isPremium / AccountContextImpl, in the Telegram
// source) can read the same flag without importing this module.
//
// Default is ON: a fresh install (key absent) has premium enabled, matching the
// previous always-on behaviour. The toggle in the "Прочее" screen flips it.
public enum AorusLocalPremium {
    public static let key = "aorusgram_local_premium"
    public static let changedNotification = Notification.Name("aorusgram_local_premium_changed")

    public static var isEnabled: Bool {
        guard AorusLicenseAccess.isAllowed else {
            return false
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    public static func setEnabled(_ value: Bool) {
        let defaults = UserDefaults.standard
        let effectiveValue = AorusLicenseAccess.isAllowed ? value : false
        guard isEnabled != effectiveValue else {
            return
        }
        defaults.set(effectiveValue, forKey: key)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        // AccountContext refreshes its cached premium state first. Rebuild visible
        // controllers on the next run-loop turn so they read the refreshed value.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("aorusgram_settings_changed"), object: nil)
        }
    }
}
