import Foundation
import UIKit
import AorusGram

// AorusGram Interface 2.0: the switch that turns the glass interface on.
//
// Released, and no longer carrying a tag that says otherwise: it heads the Interface block
// in the settings, under its own name in both languages, with no badge and no footnote.
//
// Still off by default, which is a separate question from whether it is finished. The
// feature replaces the whole profile header and repaints every list in the client, so
// opt-in is the only honest default — someone who never turns it on must see the stock
// interface, unchanged, no matter what happens in here.

public enum AorusInterfaceV2 {
    public static let key = "aorusgram_interface_v2"

    /// Posted when the switch is flipped, so an open profile can rebuild itself instead of
    /// waiting to be pushed again.
    public static let changedNotification = Notification.Name("AorusGramInterfaceV2Changed")

    public static var isEnabled: Bool {
        if !AorusLicenseAccess.isAllowed {
            return false
        }
        return UserDefaults.standard.bool(forKey: AorusInterfaceV2.key)
    }

    public static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(AorusLicenseAccess.isAllowed ? value : false, forKey: AorusInterfaceV2.key)
        NotificationCenter.default.post(name: AorusInterfaceV2.changedNotification, object: nil)
    }
}
