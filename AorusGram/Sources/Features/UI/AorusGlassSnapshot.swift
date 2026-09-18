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
// below it Telegram's `LegacyGlassView` over a private backdrop layer. Neither of them contains
// what it shows: they read the pixels behind them, in the render server, every frame they are
// drawn. The card in the switcher is a picture of the app taken once, and by the time it is
// taken that reading has stopped.
//
// What is done about it
// ---------------------
// The screen is photographed while the material is still being drawn — on `willResignActive`,
// which is the last moment the app is still rendering — and each pane is given the piece of
// that photograph that covers it, placed exactly where it was taken from. It comes down again
// on `didBecomeActive`.
//
// The photograph is an EXACT copy: same pixels, same scale, same place, nothing filtered. That
// is what makes this safe. Laid back over the region it came from, it cannot be told apart from
// what was there — the row titles it inevitably contains land precisely on the real ones, at
// the same size, and disappear into them. It can only add: the one thing it holds that the card
// would otherwise lose is the material.
//
// (An earlier version blurred the photograph, on the theory that a blur would stand in for the
// material if the capture came back without it. It did not read as glass. It read as a smear
// over the whole app, which is exactly what it was, and it also covered material that was
// rendering perfectly well. Nothing is filtered now.)
//
// `afterScreenUpdates: true` is the capture that can see a backdrop: it drives a real render
// pass rather than copying the layer tree's last committed frame, and a backdrop filter has
// nothing to give until something renders it. (`layer.render(in:)` cannot do it at all — that
// is written down elsewhere in this fork, and it cost a day to learn.) If it comes back without
// the material anyway, the copy is a copy of what the card already shows, and nothing about the
// card changes.
//
// Each photograph goes INSIDE its own pane, underneath that pane's own content, so nothing is
// covered that the pane was not already covering, and nothing is ever added above anything — a
// passcode cover, if one is put up, is added over everything and stays there.
public enum AorusGlassSnapshot {
    /// Each picture, the pane it was taken from and the place it was taken at. The place is
    /// what makes it checkable: a copy is only honest while its pane is still where it was.
    private struct Frozen {
        weak var pane: UIView?
        let picture: UIImageView
        let rect: CGRect
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
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            self.thaw()
        }
        // A second checkpoint, after the going-away transition has settled. The header of a
        // profile re-lays itself out on the way out — which is how a copy came to sit over
        // content that had moved, and be seen as a band of the wrong size. Anything that no
        // longer matches what it was taken from is dropped before the picture is taken.
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            self.dropStale()
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
        // An exact copy is exact only while the pane it was taken from stays where it was. A
        // layout pass right after the capture — the screen going inactive is one — would leave
        // a copy over content that has since moved, and that is the one way any of this can be
        // seen at all. Checked once on the next turn of the run loop, and again when the app
        // actually reaches the background.
        DispatchQueue.main.async {
            self.dropStale()
        }
    }

    private static func freeze(pane: UIView, from capture: UIImage, in window: UIWindow) {
        let host = self.contentView(of: pane)
        let rect = pane.convert(pane.bounds, to: window).intersection(window.bounds)
        guard rect.width >= 1.0, rect.height >= 1.0 else { return }
        guard let cropped = self.crop(capture, to: rect) else { return }

        let picture = UIImageView(image: cropped)
        picture.isUserInteractionEnabled = false
        // Exactly where it was taken from, at exactly the size it was taken at. A pane running
        // off the edge of the screen keeps its material where it was visible rather than having
        // the piece stretched across the whole of it — and stretching is what would make the
        // copy differ from the original at all.
        picture.frame = host.convert(rect, from: window)
        picture.contentMode = .scaleToFill
        self.applyShape(of: pane, to: picture)
        host.insertSubview(picture, at: 0)
        self.frozen.append(Frozen(pane: pane, picture: picture, rect: rect))
    }

    /// Drops every copy whose pane has moved, resized or gone since it was taken.
    private static func dropStale() {
        var kept: [Frozen] = []
        for entry in self.frozen {
            guard let pane = entry.pane, let window = pane.window,
                  entry.picture.superview != nil,
                  pane.convert(pane.bounds, to: window).intersection(window.bounds).equalTo(entry.rect) else {
                entry.picture.image = nil
                entry.picture.removeFromSuperview()
                continue
            }
            kept.append(entry)
        }
        self.frozen = kept
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
    ///
    /// Mostly the pane already does this: an effect view clips its own content view, and the
    /// legacy pane clips everything inside it. The radius is copied anyway, for the case where
    /// a pane is rounded by a radius it does not clip to.
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
    /// view that does the work, and freezing both would put two copies where one belongs.
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

    private static func isPane(_ view: UIView) -> Bool {
        if let effect = view as? UIVisualEffectView {
            return effect.effect != nil
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
            // `true`, and this is the whole difference between a copy that carries the material
            // and one that does not: it runs a render pass, and a backdrop has nothing to give
            // until something renders it.
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
