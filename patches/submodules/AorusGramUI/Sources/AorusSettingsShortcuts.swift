import UIKit
import Display
import Foundation
import AccountContext

public struct AorusSettingsShortcutRoutes {
    public let animatedWallpapers: () -> ViewController
    public let animatedBanner: () -> ViewController
    /// Telegram's own "Прокси" screen, the one under Data and Storage. It is built by SettingsUI,
    /// which depends on this module, so the screen cannot be named here — the caller hands it in.
    public let connectionSettings: () -> ViewController

    public init(
        animatedWallpapers: @escaping () -> ViewController,
        animatedBanner: @escaping () -> ViewController,
        connectionSettings: @escaping () -> ViewController
    ) {
        self.animatedWallpapers = animatedWallpapers
        self.animatedBanner = animatedBanner
        self.connectionSettings = connectionSettings
    }
}

public enum AorusSettingsShortcutTarget: String {
    case font
    case animatedWallpapers
    case animatedBanner
}

public enum AorusSettingsShortcutHighlight {
    private static var pendingTarget: AorusSettingsShortcutTarget?

    public static func request(_ target: AorusSettingsShortcutTarget) {
        assert(Thread.isMainThread)
        pendingTarget = target
    }

    public static func consume(_ target: AorusSettingsShortcutTarget) -> Bool {
        assert(Thread.isMainThread)
        guard pendingTarget == target else {
            return false
        }
        pendingTarget = nil
        return true
    }

    public static func pulse(view: UIView, color: UIColor) {
        let overlay = UIView(frame: view.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = color
        overlay.alpha = 0.0
        // Component rows can inherit the section's capsule radius. Reusing it made
        // the animated-banner shortcut look like an oval around the switch instead
        // of the same full-row highlight used by Telegram's other settings rows.
        overlay.layer.cornerRadius = min(10.0, view.bounds.height * 0.2)
        overlay.layer.masksToBounds = true
        view.addSubview(overlay)

        UIView.animate(withDuration: 0.22, animations: {
            overlay.alpha = 0.16
        }, completion: { _ in
            UIView.animate(withDuration: 0.55, delay: 0.12, options: [.curveEaseOut], animations: {
                overlay.alpha = 0.0
            }, completion: { _ in
                overlay.removeFromSuperview()
            })
        })
    }

    public static func pulseRow(containing view: UIView, color: UIColor) {
        var target = view
        var candidate = view.superview
        while let current = candidate {
            let isRowSized = current.bounds.width >= view.bounds.width + 40.0
                && current.bounds.height >= 40.0
                && current.bounds.height <= 72.0
            if isRowSized {
                target = current
                break
            }
            if current.bounds.height > 96.0 {
                break
            }
            candidate = current.superview
        }
        pulse(view: target, color: color)
    }
}

/// How to build the AorusGram settings screen, registered by the one place that can.
///
/// The screen needs three other screens — the wallpaper grid, the appearance screen and
/// Telegram's proxy settings — and each of them lives in a module this one cannot import,
/// which is why `aorusGramController` takes them as closures. Anything else that wants to
/// open settings, the plugin API among them, has the same problem and no way to solve it.
///
/// So the settings list, which is built in a module that *can* see all three, leaves the
/// recipe here on its way past. Asking for a screen nobody has registered yet answers nil
/// rather than a screen missing two of its rows.
public enum AorusSettingsRoute {
    private static let lock = NSLock()
    private static var builder: ((AccountContext) -> ViewController)?

    public static func register(_ value: @escaping (AccountContext) -> ViewController) {
        lock.lock()
        builder = value
        lock.unlock()
    }

    public static func make(_ context: AccountContext) -> ViewController? {
        lock.lock()
        let value = builder
        lock.unlock()
        return value?(context)
    }
}
