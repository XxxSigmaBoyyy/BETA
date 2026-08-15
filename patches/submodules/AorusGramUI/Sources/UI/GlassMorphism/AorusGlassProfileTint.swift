import Foundation
import UIKit

// AorusGram Interface 2.0: the avatar's colours, published for the rest of the profile screen.
//
// Interface 2.0 restyles what Telegram already draws instead of laying new panels over it.
// The screen keeps its own username row, its "More", its "Add to contacts" and "Block" —
// they simply stop being opaque blocks on a flat background and become panes of glass on a
// page tinted from the avatar. Drawing a second username card on top, as an earlier version
// did, only duplicated a row the screen was already showing.
//
// Two consumers sit at different distances. The peer-info screen is in a module that can
// import this one, so it reads the colours directly. The tab bar cannot: ItemListUI depends
// on it and AorusGramUI depends back on ItemListUI, so an import there closes a cycle in the
// build graph and nothing links. Both therefore go through shared defaults, which costs one
// key each and keeps the graph acyclic — the same trade the rest of the fork makes.
//
// scripts/profile_personalization_patch.py pins the tab key on the reading side against the
// one here.
//
// Main-thread only, like the layout passes that read and write these.

public enum AorusGlassProfileTint {
    public static let key = "aorusgram_profile_tab_accent"
    public static let pageKey = "aorusgram_profile_page_background"

    /// Colour for the selected tab's label, or nil to leave the tab bar as Telegram draws it.
    public static var selectedTabColor: UIColor? {
        return AorusGlassProfileTint.color(forKey: AorusGlassProfileTint.key)
    }

    public static func setSelectedTabColor(_ color: UIColor?) {
        AorusGlassProfileTint.setColor(color, forKey: AorusGlassProfileTint.key)
    }

    /// The page the whole profile sits on, so the list below the header continues the
    /// avatar's colours instead of meeting a flat theme background partway down.
    public static var pageBackgroundColor: UIColor? {
        return AorusGlassProfileTint.color(forKey: AorusGlassProfileTint.pageKey)
    }

    public static func setPageBackgroundColor(_ color: UIColor?) {
        AorusGlassProfileTint.setColor(color, forKey: AorusGlassProfileTint.pageKey)
    }

    /// What a peer-info list section should paint itself with while a glass profile is on
    /// screen, or nil when it should stay exactly as Telegram draws it.
    ///
    /// Fully clear, because the section is a real pane of `GlassBackgroundView` inserted behind
    /// these nodes rather than a colour standing in for one. Anything painted here would sit on
    /// top of that pane and turn the system material back into a flat translucent card — which
    /// is exactly what the first version of Interface 2.0 got wrong.
    public static var listSectionColors: (background: UIColor, separator: UIColor)? {
        guard AorusInterfaceV2.isEnabled else {
            return nil
        }
        return (.clear, UIColor(white: 1.0, alpha: 0.12))
    }

    // MARK: - Avatar sampling

    /// The page colour for one peer, or nil until its avatar has been sampled.
    ///
    /// Per peer rather than one global colour: two profiles are on screen together during a
    /// push, both lay out on every frame of it, and a single slot would let them overwrite each
    /// other's colour back and forth for the length of the animation.
    public static func pageBackgroundColor(for peerId: Int64) -> UIColor? {
        return AorusGlassProfileTint.pageColors[peerId]
    }

    /// Sample the photo as drawn and keep the result as this peer's page colour.
    ///
    /// Sampling the rendered view is the whole point: the page has to match the photo, and a
    /// photo has no palette entry to look up. A peer with no photo lands here too and yields
    /// the frosted grey of its lettered placeholder, which is the right page for it.
    ///
    /// `photo` says *which* of the peer's photos is on screen, and `photoCount` how many there
    /// are. A peer with three avatars therefore gets three page colours, and paging to the second
    /// one repaints the page in the second one's colour. Each is memoised under its own key, so
    /// paging back is instant and costs no second snapshot; the count is part of the key because
    /// an index means something different once a photo has been added or removed, and including
    /// it retires the whole peer's memo the moment that happens.
    ///
    /// `onUpdate` asks for one more layout, and is called only when the page colour actually
    /// changes. The header publishes this from every layout pass, so calling it unconditionally
    /// would be a layout loop; never calling it would leave the page on the previous photo's
    /// colour until something unrelated happened to lay the screen out again.
    public static func publishAvatarTint(for peerId: Int64, photo: Int, photoCount: Int, view: UIView?, onUpdate: @escaping () -> Void) {
        guard Thread.isMainThread, AorusInterfaceV2.isEnabled else {
            return
        }
        let key = PhotoKey(peerId: peerId, photo: photo, photoCount: photoCount)
        if let existing = AorusGlassProfileTint.sampledColors[key] {
            AorusGlassProfileTint.adopt(existing, for: peerId, onUpdate: onUpdate)
            return
        }
        guard let view else {
            return
        }
        AorusGlassProfileTint.sample(key: key, view: view, attempt: 0, onUpdate: onUpdate)
    }

    /// Make `color` the page colour for this peer, and ask for a repaint if that is a change.
    ///
    /// The repaint is asked for on the next runloop pass rather than here: the caller is usually
    /// in the middle of the header's layout, and laying the screen out again from inside that pass
    /// is re-entrancy the node hierarchy has no reason to tolerate.
    private static func adopt(_ color: UIColor, for peerId: Int64, onUpdate: @escaping () -> Void) {
        guard AorusGlassProfileTint.pageColors[peerId] != color else {
            AorusGlassProfileTint.apply(color)
            return
        }
        // Capped so a session spent opening profiles cannot grow this without bound; a dropped
        // entry only costs one resample.
        if AorusGlassProfileTint.pageColors.count > 32 {
            AorusGlassProfileTint.pageColors.removeAll()
        }
        AorusGlassProfileTint.pageColors[peerId] = color
        AorusGlassProfileTint.apply(color)
        DispatchQueue.main.async {
            onUpdate()
        }
    }

    /// The page takes the avatar's colour; the tab labels take white.
    ///
    /// White rather than that colour: the labels sit on the tinted page, so tinting them too is
    /// how text ends up close in tone to what is behind it. It also honours the rule the rest of
    /// Interface 2.0 follows -- the glass is the system material, and the profile's colour shows
    /// through it instead of being painted onto everything in front of it.
    private static func apply(_ color: UIColor) {
        AorusGlassProfileTint.setPageBackgroundColor(color)
        AorusGlassProfileTint.setSelectedTabColor(.white)
    }

    /// One of a peer's photos. The count rides along so that adding or removing a photo, which
    /// renumbers the rest, retires the memo instead of matching the wrong picture.
    private struct PhotoKey: Hashable {
        let peerId: Int64
        let photo: Int
        let photoCount: Int
    }

    /// What the page is painted with right now, per peer on screen.
    private static var pageColors: [Int64: UIColor] = [:]
    /// What each individual photo sampled to, so paging back and forth never resamples.
    private static var sampledColors: [PhotoKey: UIColor] = [:]
    private static var pendingKeys = Set<PhotoKey>()

    private static func sample(key: PhotoKey, view: UIView, attempt: Int, onUpdate: @escaping () -> Void) {
        if let color = AorusGlassProfileTint.averageColor(of: view) {
            AorusGlassProfileTint.pendingKeys.remove(key)
            // Capped for the same reason as pageColors, with room for a few photos per peer.
            if AorusGlassProfileTint.sampledColors.count > 96 {
                AorusGlassProfileTint.sampledColors.removeAll()
            }
            AorusGlassProfileTint.sampledColors[key] = color
            AorusGlassProfileTint.adopt(color, for: key.peerId, onUpdate: onUpdate)
            return
        }
        // Nothing to sample yet: the photo is still decoding. Retried on a delay rather than
        // from the next layout pass, because a profile that is simply sitting there gets no
        // further passes, and drawing the avatar on every pass of one that is being scrolled
        // would cost a snapshot per frame.
        if attempt == 0, AorusGlassProfileTint.pendingKeys.contains(key) {
            return
        }
        guard attempt < 6 else {
            AorusGlassProfileTint.pendingKeys.remove(key)
            return
        }
        AorusGlassProfileTint.pendingKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
            guard let view, AorusGlassProfileTint.sampledColors[key] == nil else {
                AorusGlassProfileTint.pendingKeys.remove(key)
                return
            }
            AorusGlassProfileTint.sample(key: key, view: view, attempt: attempt + 1, onUpdate: onUpdate)
        }
    }

    /// Returns nil when the view has not drawn anything yet, which is how a photo that is still
    /// loading is told apart from one that is genuinely dark.
    private static func averageColor(of view: UIView) -> UIColor? {
        let bounds = view.bounds
        guard bounds.width >= 8.0, bounds.height >= 8.0 else {
            return nil
        }
        let width = 8
        let height = 8
        let count = width * height * 4
        // Allocated rather than taken from an Array's buffer: the context outlives the call that
        // produces the pointer, and a pointer into an Array is only valid inside the closure it
        // was handed to.
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        pixels.initialize(repeating: 0, count: count)
        defer {
            pixels.deinitialize(count: count)
            pixels.deallocate()
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        // render(in:) rather than drawHierarchy(in:afterScreenUpdates:): the avatar is a layer
        // with an image in it, this stays on the current thread without a screen update, and it
        // is the cheaper of the two by a wide margin.
        view.layer.render(in: context)

        var totalRed = 0.0
        var totalGreen = 0.0
        var totalBlue = 0.0
        var totalAlpha = 0.0
        for index in stride(from: 0, to: count, by: 4) {
            totalRed += Double(pixels[index]) / 255.0
            totalGreen += Double(pixels[index + 1]) / 255.0
            totalBlue += Double(pixels[index + 2]) / 255.0
            totalAlpha += Double(pixels[index + 3]) / 255.0
        }
        guard totalAlpha > 0.35 * Double(width * height) else {
            return nil
        }
        // Premultiplied, so dividing by the accumulated alpha both un-premultiplies and weights
        // the average towards the pixels that are actually opaque.
        let source = UIColor(
            red: CGFloat(min(1.0, totalRed / totalAlpha)),
            green: CGFloat(min(1.0, totalGreen / totalAlpha)),
            blue: CGFloat(min(1.0, totalBlue / totalAlpha)),
            alpha: 1.0
        )
        var hue: CGFloat = 0.0
        var saturation: CGFloat = 0.0
        var brightness: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        guard source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return nil
        }
        // The hue is the avatar's; the rest is pinned. White labels and glass panes both need a
        // dark, unsaturated page to sit on, and an average colour taken from a photo is neither
        // reliably dark nor reliably subtle.
        return UIColor(
            hue: hue,
            saturation: min(0.5, saturation * 1.1),
            brightness: 0.17,
            alpha: 1.0
        )
    }

    // MARK: - Storage

    /// Writes only on an actual change: the profile header publishes these from every layout
    /// pass, and a defaults write per scroll frame would be pure overhead — each one also
    /// wakes every observer of UserDefaults.didChangeNotification.
    private static func setColor(_ color: UIColor?, forKey key: String) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: key) as? Int
        guard let color else {
            if current != nil {
                defaults.removeObject(forKey: key)
            }
            return
        }
        let packed = AorusGlassProfileTint.packed(from: color)
        if current != packed {
            defaults.set(packed, forKey: key)
        }
    }

    private static func color(forKey key: String) -> UIColor? {
        guard let value = UserDefaults.standard.object(forKey: key) as? Int else {
            return nil
        }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1.0
        )
    }

    private static func packed(from color: UIColor) -> Int {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        let component: (CGFloat) -> Int = { value in
            return Int((max(0.0, min(1.0, value)) * 255.0).rounded())
        }
        return (component(red) << 16) | (component(green) << 8) | component(blue)
    }
}
