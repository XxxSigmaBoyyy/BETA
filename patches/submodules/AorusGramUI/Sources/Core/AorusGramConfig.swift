import Foundation
import AorusGram

enum AorusGramConfig {
    static let appName = "AorusGram"
    static let version = "1.0.0"
    static let officialChannelURL = "https://t.me/aorusgram"
    static let officialChannelUsername = "aorusgram"

    enum Feature: String, CaseIterable {
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
        case editLocally        = "edit_locally"
    }

    static func isEnabled(_ feature: Feature) -> Bool {
        guard AorusLicenseAccess.isAllowed else { return false }
        return UserDefaults.standard.object(forKey: "aorusgram_feature_\(feature.rawValue)") as? Bool ?? defaultEnabled(feature)
    }

    static func setEnabled(_ feature: Feature, _ value: Bool) {
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
