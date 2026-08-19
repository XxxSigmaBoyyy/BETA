import UIKit
import Display

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
