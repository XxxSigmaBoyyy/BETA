import Foundation

/// One read-only entitlement verdict shared by UI and protected services.
///
/// The plain lock mirror is only an immediate kill switch. Granting access also
/// requires the authenticated, device-bound snapshot to remain inside its
/// server-anchored validity window, so clearing a UserDefaults flag cannot unlock
/// features or route a locked purchase flow into the main application.
public enum AorusLicenseAccess {
    @inline(__always)
    public static var canUnlock: Bool {
        guard LicenseKeyProvider.isProvisioned,
              !AorusSessionMetrics.metricFlag,
              !UserDefaults.standard.bool(forKey: "c0a8b1e2-6f4d-4a9c-b3e7-1d520f8a6b34"),
              !AorusSessionCounter.shared.isTripped else {
            return false
        }
        return LicenseStore.shared.effectiveOfflineStatus().allowsAppAccess
    }

    @inline(__always)
    public static var isAllowed: Bool {
        return !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04")
            && canUnlock
    }
}

/// Shared feature flags (UserDefaults). Public so `TelegramUI` (e.g. AppDelegate hooks) can read them.
public enum AorusGramConfig {
    public static let appName = "AorusGram"
    public static let version = "1.0.0"
    public static let officialChannelURL = "https://t.me/aorusgram"
    public static let officialChannelUsername = "aorusgram"

    public enum Feature: String, CaseIterable {
        case ghostMode          = "ghost_mode"
        case deletedMessages    = "deleted_messages"
        case maxMediaQuality    = "max_media_quality"
        case antiSpam           = "anti_spam"
        case downloadAccel      = "download_accel"
        case siriShortcuts      = "siri_shortcuts"
        case unlimitedAccounts  = "unlimited_accounts"
        case glassUI            = "glass_ui"
        case messageScheduler   = "message_scheduler"
        case mediaManager       = "media_manager"
        case translator         = "translator"
        case voiceTranscription = "voice_transcription"
        case antiScreenshot     = "anti_screenshot"
        case secretPin          = "secret_pin"
        case smartFolders       = "smart_folders"
        case streaks            = "streaks"
        case customIcons        = "custom_icons"
        case autoReply          = "auto_reply"
        case pinboard           = "pinboard"
    }

    public static func isEnabled(_ feature: Feature) -> Bool {
        // Flat feature flags are preferences, never entitlement evidence.
        guard AorusLicenseAccess.isAllowed else { return false }
        return UserDefaults.standard.object(forKey: "aorusgram_feature_\(feature.rawValue)") as? Bool ?? defaultEnabled(feature)
    }

    public static func setEnabled(_ feature: Feature, _ value: Bool) {
        let effectiveValue = AorusLicenseAccess.isAllowed ? value : false
        UserDefaults.standard.set(effectiveValue, forKey: "aorusgram_feature_\(feature.rawValue)")
    }

    private static func defaultEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .glassUI, .downloadAccel, .maxMediaQuality, .antiSpam, .deletedMessages: return true
        default: return false
        }
    }
}
