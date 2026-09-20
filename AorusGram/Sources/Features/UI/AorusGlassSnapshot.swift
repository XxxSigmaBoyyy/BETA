import Foundation
import UIKit

// AorusGram: the glass has to survive the app switcher.
//
// The report: with Interface 2.0 on, leave the app and look at its card in the switcher, and
// the panes are there with no material in them. Open the app and the material is back.
//
// Why it happens
// --------------
// A pane is a live backdrop. On iOS 26 it is `UIVisualEffectView(effect: UIGlassEffect)`, and
// below it Telegram's `LegacyGlassView` over a private backdrop layer. Neither of them holds
// what it shows: they read the pixels behind them, in the render server, every frame they are
// drawn. The card in the switcher is one picture of the app, and by the time it is taken that
// reading has stopped.
//
// What is done about it
// ---------------------
// The screen is photographed while the material is still being drawn — on `willResignActive`,
// the last moment the app is still rendering — and each pane is given the piece of that
// photograph that covers it, placed exactly where it was taken from. It all comes down again on
// `didBecomeActive`.
//
// `drawHierarchy(in:afterScreenUpdates:)` is the capture: it asks the render server for the
// frame rather than re-running the layer tree in process, which is the difference that decides
// whether a backdrop is in it at all. (`layer.render(in:)` is the one that cannot — that is
// written down elsewhere in this fork and it cost a day to learn. Telegram takes its own
// locked-window cover with `drawHierarchy` for the same reason.)
//
// The photograph is an EXACT copy: same pixels, same scale, same place, nothing filtered.
// That is what makes it safe. Laid back over the region it came from it cannot be told apart
// from what was there — the row titles it inevitably contains land precisely on the real ones
// and disappear into them. It can only add: the one thing it holds that the card would
// otherwise lose is the material.
//
// (An earlier version blurred the photograph, on the theory that a blur would stand in for the
// material if the capture came back without it. On screen that theory was a smear across the
// whole app, which is exactly what it was. Nothing is filtered now.)
//
// When a pane moves after the picture is taken
// --------------------------------------------
// It does: a profile header re-lays itself out on the way out, and a copy left at the old place
// is the band of the wrong size that came back as a report. An earlier version answered that by
// dropping such copies — which threw away the very panes the whole thing exists for.
//
// The window's photograph is kept for as long as the copies are up, so a pane that has moved is
// re-cut from it at its new place instead. The copy follows the pane; it is never stretched,
// never left behind, and never thrown away for moving.
//
// Each photograph goes INSIDE its own pane, underneath that pane's own content, so nothing is
// covered that the pane was not already covering, and nothing is ever added above anything — a
// passcode cover, when one is put up, is the window's own and stays over everything.
public enum AorusGlassSnapshot {
    /// One pane, the picture standing in for its material, and the photograph that picture was
    /// cut from — kept so the cut can be made again if the pane moves.
    private final class Frozen {
        weak var pane: UIView?
        weak var window: UIWindow?
        let host: UIView
        let picture: UIImageView
        let source: UIImage
        var rect: CGRect

        init(pane: UIView, window: UIWindow, host: UIView, picture: UIImageView,
             source: UIImage, rect: CGRect) {
            self.pane = pane
            self.window = window
            self.host = host
            self.picture = picture
            self.source = source
            self.rect = rect
        }
    }

    private static var frozen: [Frozen] = []
    private static var isInstalled = false

    /// Called once, from the bootstrap.
    public static func install() {
        guard !self.isInstalled else { return }
        self.isInstalled = true
        let center = NotificationCenter.default
        // `willResignActive`, not `didEnterBackground`: the app is still drawing here, which is
        // the whole point. It also covers the switcher reached by a swipe, which the app can
        // enter without ever going to the background.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            self.freeze()
        }
        // The going-away transition moves things. Every copy is re-cut at its pane's new place
        // before the picture the switcher shows is taken.
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            self.refit()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            self.thaw()
        }
    }

    // MARK: - Freezing

    private static func freeze() {
        guard self.frozen.isEmpty else { return }
        // Nothing to preserve when there is no glass to begin with. Interface 2.0 is one way to
        // have some; the fork's own glass switch is the other. The first is read by its key, the
        // way the patched Telegram code reads it, because the switch itself lives in the UI
        // module and this runs from the core one — but the entitlement behind it is asked the
        // same way every feature asks it, since a stored key on its own has never been
        // permission to do anything in this fork.
        let interfaceV2 = AorusLicenseAccess.isAllowed
            && UserDefaults.standard.bool(forKey: "aorusgram_interface_v2")
        guard interfaceV2 || AorusGramConfig.isEnabled(.glassUI) else { return }

        for window in self.windows() {
            var panes: [UIView] = []
            self.collectPanes(in: window, into: &panes)
            guard !panes.isEmpty else { continue }
            guard let frame = self.capture(window: window) else { continue }
            for pane in panes {
                self.freeze(pane: pane, from: frame, in: window)
            }
        }
        // The first re-cut, a turn of the run loop after the capture: the layout pass that the
        // screen going inactive sets off has run by then.
        DispatchQueue.main.async {
            self.refit()
        }
    }

    private static func freeze(pane: UIView, from capture: UIImage, in window: UIWindow) {
        let host = self.contentView(of: pane)
        let rect = self.rect(of: pane, in: window)
        guard rect.width >= 1.0, rect.height >= 1.0 else { return }
        guard let cropped = self.crop(capture, to: rect) else { return }

        let picture = UIImageView(image: cropped)
        picture.isUserInteractionEnabled = false
        // Exactly where it was taken from, at exactly the size it was taken at. Scaling is the
        // one thing that would make the copy differ from the original, so there is none: the
        // picture's frame is the rect it was cut at.
        picture.frame = host.convert(rect, from: window)
        picture.contentMode = .scaleToFill
        self.applyShape(of: pane, to: picture)
        host.insertSubview(picture, at: 0)
        self.frozen.append(Frozen(pane: pane, window: window, host: host, picture: picture,
                                  source: capture, rect: rect))
    }

    /// Re-cuts every copy at its pane's current place, and drops the ones whose pane has gone.
    private static func refit() {
        var kept: [Frozen] = []
        for entry in self.frozen {
            guard let pane = entry.pane, let window = entry.window, pane.window === window,
                  entry.picture.superview != nil else {
                entry.picture.image = nil
                entry.picture.removeFromSuperview()
                continue
            }
            let rect = self.rect(of: pane, in: window)
            guard rect.width >= 1.0, rect.height >= 1.0 else {
                entry.picture.image = nil
                entry.picture.removeFromSuperview()
                continue
            }
            if !rect.equalTo(entry.rect) {
                guard let cropped = self.crop(entry.source, to: rect) else {
                    entry.picture.image = nil
                    entry.picture.removeFromSuperview()
                    continue
                }
                entry.picture.image = cropped
                entry.rect = rect
            }
            // The frame is set every time, moved pane or not: the view it lives in may have been
            // laid out again even when the pane's place on screen has not changed.
            entry.picture.frame = entry.host.convert(rect, from: window)
            self.applyShape(of: pane, to: entry.picture)
            kept.append(entry)
        }
        self.frozen = kept
    }

    /// Where a pane is, in its window, clipped to what is on screen.
    private static func rect(of pane: UIView, in window: UIWindow) -> CGRect {
        return pane.convert(pane.bounds, to: window).intersection(window.bounds)
    }

    /// Where a stand-in goes: under the pane's content, over the pane's material.
    ///
    /// For an effect view that is `contentView`, which is the only place UIKit allows anything
    /// to be put and is exactly the right one. Telegram's legacy pane has no content of its own:
    /// it is one backdrop layer in a clipping view, and a picture added to it lands over it.
    private static func contentView(of pane: UIView) -> UIView {
        if let effect = pane as? UIVisualEffectView {
            return effect.contentView
        }
        return pane
    }

    /// The corners the pane is cut to, given to the picture as well.
    private static func applyShape(of pane: UIView, to picture: UIImageView) {
        picture.layer.cornerCurve = pane.layer.cornerCurve
        picture.layer.cornerRadius = pane.layer.cornerRadius
        picture.layer.masksToBounds = pane.layer.cornerRadius > 0.0
    }

    // MARK: - Thawing

    private static func thaw() {
        let entries = self.frozen
        self.frozen = []
        for entry in entries {
            entry.picture.image = nil
            entry.picture.removeFromSuperview()
        }
    }

    // MARK: - Finding the panes

    private static func windows() -> [UIWindow] {
        var result: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            guard windowScene.activationState != .background else { continue }
            for window in windowScene.windows where !window.isHidden && window.alpha > 0.01 {
                guard window.bounds.width > 1.0, window.bounds.height > 1.0 else { continue }
                result.append(window)
            }
        }
        return result
    }

    /// Every pane in a window, outermost first.
    ///
    /// A pane's own subtree is not searched: on iOS 26 a `GlassBackgroundView` HOLDS the effect
    /// view that does the work, and freezing both would put two copies where one belongs. A
    /// `UIGlassContainerEffect` is different: it only groups the real glass effects below it, so
    /// it is deliberately skipped and its subtree remains searchable. `LegacyGlassView` is a
    /// pane in its own right on older systems.
    private static func collectPanes(in view: UIView, into result: inout [UIView]) {
        for subview in view.subviews {
            if subview.isHidden || subview.alpha <= 0.02 { continue }
            let size = subview.bounds.size
            if self.isPane(subview) {
                // A hairline or a pane with no area is not worth a picture.
                if size.width >= 16.0, size.height >= 16.0 {
                    result.append(subview)
                }
                continue
            }
            if size.width <= 0.0 || size.height <= 0.0 { continue }
            self.collectPanes(in: subview, into: &result)
        }
    }

    /// Telegram's pre-iOS-26 pane. It is a plain view over a private backdrop layer, so there is
    /// no type here to test against — but it is Telegram's own class, and its name is as good a
    /// handle as an import would be. Nothing is called on it: it is only asked whether it is the
    /// view a picture belongs in.
    private static let legacyPaneName = "LegacyGlassView"
    private static let containerEffectName = "UIGlassContainerEffect"

    private static func isPane(_ view: UIView) -> Bool {
        if let effect = view as? UIVisualEffectView {
            guard let current = effect.effect else { return false }
            // The iOS 26 container is only a grouping effect. Its nested glass effects draw
            // the material and must be discovered separately by collectPanes.
            if String(describing: type(of: current)) == self.containerEffectName {
                return false
            }
            return true
        }
        return String(describing: type(of: view)) == self.legacyPaneName
    }

    // MARK: - Pictures

    /// The window exactly as it is on screen, material included.
    private static func capture(window: UIWindow) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        // The screen's own scale, which `preferred()` already carries. A copy taken at fewer
        // pixels than the screen has would be soft where the original is sharp, and softness is
        // the one thing that would give the copy away.
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var drawn = false
        let image = renderer.image { _ in
            // `true`: it drives a real render pass rather than copying the last committed frame,
            // and a backdrop filter has nothing to give until something renders it.
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return drawn ? image : nil
    }

    private static func crop(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let scale = image.scale
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        let bounds = CGRect(x: 0.0, y: 0.0, width: CGFloat(source.width), height: CGFloat(source.height))
        let clamped = pixels.intersection(bounds)
        guard clamped.width >= 1.0, clamped.height >= 1.0 else { return nil }
        guard let cropped = source.cropping(to: clamped) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }
}
