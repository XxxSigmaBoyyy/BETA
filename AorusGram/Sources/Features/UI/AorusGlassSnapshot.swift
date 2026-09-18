import Foundation
import UIKit

// AorusGram: the glass has to survive the app switcher.
//
// The report: with Interface 2.0 on, leave the app and look at its card in the switcher, and
// the glass is gone — the panes are there, the material is not. Open the app and it is back.
//
// Why it happens
// --------------
// A pane is a live backdrop. On iOS 26 it is `UIVisualEffectView(effect: UIGlassEffect)`, and
// below it Telegram's `LegacyGlassView`, which is a private backdrop layer; both of them read
// the pixels behind them every frame, in the render server. When the app stops being the
// front-most one that reading stops — there is nothing to sample and nothing to spend power
// on — and the card the switcher shows is a picture of the app taken at exactly that moment.
// So the card gets the panes with their tint and their rim, and no material inside them.
//
// This is not something the pane can be asked to keep doing; it is the system deciding not to
// composite a backdrop for an app nobody is looking at, and it is right to.
//
// What is done about it
// ---------------------
// The material is photographed while it is still being drawn, and the photograph is put where
// the material was until the app comes back.
//
// `drawHierarchy(in:afterScreenUpdates:false)` is the capture that can do it: it asks the
// render server for the frame that is already on screen, backdrops included. (`layer.render(in:)`
// cannot — it re-runs the layer tree in-process, and a backdrop filter has nothing to sample
// there. That is written down elsewhere in this fork, and it cost a day to learn.)
//
// The photograph is then blurred before it is used, about as hard as the material blurs what is
// behind it. If the capture came back with the material in it, that costs a softness nobody can
// see in a card the size of a thumb. If it came back without — some materials fall back to a
// flat fill when their backdrop is not available — the blur is what makes the page behind read
// as glass rather than as a sharp rectangle where a pane should be. Either way the card looks
// like the app.
//
// The photograph is of the screen, which means it also holds whatever was drawn ON the pane —
// the row titles, the switches. The blur is strong enough that they come back as part of the
// wash rather than as a second, softer copy of themselves, and that is the price of not touching
// the hierarchy before the capture: emptying every pane for one frame to photograph it clean
// risks a frame of empty panes reaching anyone who swiped up and changed their mind.
//
// Each photograph goes INSIDE its own pane, underneath the pane's own content, so nothing is
// covered that was not already covered by that pane: a label sitting on the glass still sits on
// it, and the picture cannot end up over anything else on the screen. That matters beyond
// tidiness — a passcode cover, if one is put up, is a view of its own added over everything,
// and it stays over everything, because this never adds anything above a pane.
//
// It all comes down again on `didBecomeActive`, so nothing frozen is ever on screen while
// somebody is looking at the app.
public enum AorusGlassSnapshot {
    /// The pictures currently standing in for the materials.
    private static var frozen: [UIImageView] = []
    private static var isInstalled = false

    /// Called once, from the bootstrap.
    public static func install() {
        guard !self.isInstalled else { return }
        self.isInstalled = true
        let center = NotificationCenter.default
        // `willResignActive` and not `didEnterBackground`: the app is still drawing here, which
        // is the whole point — a capture taken after the material has stopped being composited
        // would photograph the very thing being worked around. It also covers the switcher
        // itself, which the app reaches without ever entering the background.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            self.freeze()
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
            let material = self.blurred(frame)
            for pane in panes {
                self.freeze(pane: pane, from: material, in: window)
            }
        }
    }

    private static func freeze(pane: UIView, from capture: UIImage, in window: UIWindow) {
        let host = self.contentView(of: pane)
        let rect = pane.convert(pane.bounds, to: window).intersection(window.bounds)
        guard rect.width >= 1.0, rect.height >= 1.0 else { return }
        guard let cropped = self.crop(capture, to: rect) else { return }

        let picture = UIImageView(image: cropped)
        picture.isUserInteractionEnabled = false
        // The crop is the part of the pane that was on screen, so it is placed where that part
        // of the pane is: a pane running off the edge keeps its material where it is visible
        // instead of having the crop stretched across the whole of it. Placed in the host's
        // own coordinates, because the view a picture goes into is not always the pane itself.
        picture.frame = host.convert(rect, from: window)
        picture.contentMode = .scaleToFill
        self.applyShape(of: pane, to: picture)
        host.insertSubview(picture, at: 0)
        self.frozen.append(picture)
    }

    /// Where a stand-in goes: under the pane's content, over the pane's material.
    ///
    /// For an effect view that is `contentView`, which is the only place UIKit allows anything
    /// to be put and is exactly the right one — above the backdrop, below whatever the pane
    /// carries. Telegram's own legacy pane has no content of its own at all: it is one backdrop
    /// layer in a clipping view, and a picture added to it lands over that layer.
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
    /// the pane is rounded by a radius it does not clip to — a square picture in a rounded pane
    /// would show its corners, and that is the one way this can be seen at all.
    private static func applyShape(of pane: UIView, to picture: UIImageView) {
        picture.layer.cornerCurve = pane.layer.cornerCurve
        picture.layer.cornerRadius = pane.layer.cornerRadius
        picture.layer.masksToBounds = pane.layer.cornerRadius > 0.0
    }

    // MARK: - Thawing

    private static func thaw() {
        let pictures = self.frozen
        self.frozen = []
        for picture in pictures {
            picture.layer.mask = nil
            picture.image = nil
            picture.removeFromSuperview()
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
    /// view that does the work, and freezing both would put two pictures where one belongs.
    private static func collectPanes(in view: UIView, into result: inout [UIView]) {
        for subview in view.subviews {
            if subview.isHidden || subview.alpha <= 0.02 { continue }
            let size = subview.bounds.size
            if self.isPane(subview) {
                // A hairline or a pane with no area is not worth a picture, and a pane far from
                // anything anyone can see is not worth one either.
                if size.width >= 16.0, size.height >= 16.0 {
                    result.append(subview)
                }
                continue
            }
            if size.width <= 0.0 || size.height <= 0.0 { continue }
            self.collectPanes(in: subview, into: &result)
        }
    }

    /// Telegram's pre-iOS-26 pane. It is a plain view over a private backdrop layer, so there
    /// is no type here to test against — but it is Telegram's own class, and its name is as
    /// good a handle as an import would be. Nothing is called on it: it is only asked whether
    /// it is the view a picture belongs in.
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
        // Points, not device pixels. The picture is blurred and then shown at the size it was
        // taken from, so a third of the memory and none of the detail is the right trade.
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var drawn = false
        let image = renderer.image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return drawn ? image : nil
    }

    /// A blur, done by throwing the detail away and letting the resampler put it back.
    ///
    /// Not a gaussian: a gaussian of this radius over a full screen is tens of milliseconds and
    /// a CoreImage context to go with it, and what it would buy is detail nobody will look for
    /// in a card an inch tall. Drawing the frame into a tenth of its size and back out again
    /// with the smooth resampler is two draws and reads as the same thing.
    private static func blurred(_ image: UIImage) -> UIImage {
        let size = image.size
        // A sixteenth, which is a strong blur on purpose. The material itself is that blurry —
        // a pane over a photograph is a wash of its colours, not a soft copy of it — and the
        // strength is also what turns the row titles the capture happens to contain into part
        // of the wash instead of a legible ghost behind the real ones.
        let small = CGSize(width: max(1.0, (size.width / 16.0).rounded(.up)),
                           height: max(1.0, (size.height / 16.0).rounded(.up)))
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1.0
        let reduced = UIGraphicsImageRenderer(size: small, format: format).image { context in
            context.cgContext.interpolationQuality = .medium
            image.draw(in: CGRect(origin: CGPoint(), size: small))
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            reduced.draw(in: CGRect(origin: CGPoint(), size: size))
        }
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
