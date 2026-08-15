import Foundation
import UIKit
import TelegramPresentationData

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
    /// The same key the peer-info screen and the derived list themes read the page colour back
    /// from, taken from there rather than spelled out twice: the two sides cannot drift.
    public static let pageKey = AorusGlassPane.profilePageKey

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
    ///
    /// The hairline takes the page's ink, so the separators inside a section stay visible on a
    /// pale page instead of being white on near-white.
    public static var listSectionColors: (background: UIColor, separator: UIColor)? {
        guard AorusInterfaceV2.isEnabled else {
            return nil
        }
        return (.clear, AorusGlassPane.profilePageInk(0.12))
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

    /// The photo's lower half, reduced to a handful of pixels, for the page to stretch behind the
    /// whole screen -- sections, tabs, gifts and all.
    ///
    /// A flat colour was not enough. The photo does not end in one colour, it ends in a gradient,
    /// and butting a single colour against it drew a line across the screen exactly where the
    /// picture stopped. This is the same pixels the colour is averaged from, kept as an image
    /// instead of collapsed to a number.
    ///
    /// The blur is the scaling. The bitmap is a dozen pixels across, and stretching it over a
    /// phone screen with linear filtering *is* a wide, soft blur -- one that costs a 12x24
    /// texture and no filter pass at all, where CIGaussianBlur over a full-screen image would
    /// cost one on every photo change.
    public static func pageBackgroundImage(for peerId: Int64) -> UIImage? {
        return AorusGlassProfileTint.pageImages[peerId]
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
    /// `isFullPhoto` says whether `view` is the full-width photo or the small round avatar the
    /// header falls back to before the expanded page's node exists. Only the full-width one is
    /// worth an image: the round one is a centre crop behind a circular mask, so its lower half is
    /// the middle of the picture with transparent corners. A colour-only sample is kept, but it is
    /// marked as such and upgraded the moment the real photo is available.
    public static func publishAvatarTint(for peerId: Int64, photo: Int, photoCount: Int, view: UIView?, isFullPhoto: Bool, onUpdate: @escaping () -> Void) {
        guard Thread.isMainThread, AorusInterfaceV2.isEnabled else {
            return
        }
        let key = PhotoKey(peerId: peerId, photo: photo, photoCount: photoCount)
        if let existing = AorusGlassProfileTint.sampledColors[key], existing.image != nil || !isFullPhoto {
            AorusGlassProfileTint.adopt(existing, for: peerId, onUpdate: onUpdate)
            return
        }
        guard let view else {
            return
        }
        AorusGlassProfileTint.sample(key: key, view: view, isFullPhoto: isFullPhoto, attempt: 0, onUpdate: onUpdate)
    }

    /// Make `sample` the page for this peer, and ask for a repaint if that is a change.
    ///
    /// The repaint is asked for on the next runloop pass rather than here: the caller is usually
    /// in the middle of the header's layout, and laying the screen out again from inside that pass
    /// is re-entrancy the node hierarchy has no reason to tolerate.
    private static func adopt(_ sample: Sample, for peerId: Int64, onUpdate: @escaping () -> Void) {
        let hadColor = AorusGlassProfileTint.pageColors[peerId] == sample.color
        let hadImage = AorusGlassProfileTint.pageImages[peerId] === sample.image
        guard !hadColor || !hadImage else {
            AorusGlassProfileTint.apply(sample.color)
            return
        }
        // Capped so a session spent opening profiles cannot grow this without bound; a dropped
        // entry only costs one resample.
        if AorusGlassProfileTint.pageColors.count > 32 {
            AorusGlassProfileTint.pageColors.removeAll()
            AorusGlassProfileTint.pageImages.removeAll()
        }
        AorusGlassProfileTint.pageColors[peerId] = sample.color
        if let image = sample.image {
            AorusGlassProfileTint.pageImages[peerId] = image
        } else {
            AorusGlassProfileTint.pageImages.removeValue(forKey: peerId)
        }
        AorusGlassProfileTint.apply(sample.color)
        DispatchQueue.main.async {
            onUpdate()
        }
    }

    /// The page takes the avatar's colour; the tab labels take whatever reads on it.
    ///
    /// The label colour is derived from the page rather than fixed at white, because the page is no
    /// longer forced dark. A profile whose photo ends in white paper gets a near-white page and
    /// near-black labels; one that ends in a dark coat gets the dark page and white labels. Fixing
    /// it at white is what made the tabs disappear under a bright photo.
    private static func apply(_ color: UIColor) {
        AorusGlassProfileTint.setPageBackgroundColor(color)
        AorusGlassProfileTint.setSelectedTabColor(AorusGlassPane.ink(over: color))
    }

    /// One of a peer's photos. The count rides along so that adding or removing a photo, which
    /// renumbers the rest, retires the memo instead of matching the wrong picture.
    private struct PhotoKey: Hashable {
        let peerId: Int64
        let photo: Int
        let photoCount: Int
    }

    /// One photo's contribution to the page: the colour it ends on, and the same lower region kept
    /// as a tiny image. `image` is nil when only the round fallback avatar was available.
    private struct Sample {
        let color: UIColor
        let image: UIImage?
    }

    /// What the page is painted with right now, per peer on screen.
    private static var pageColors: [Int64: UIColor] = [:]
    /// The stretched backdrop for each of those, dropped together with the colours.
    private static var pageImages: [Int64: UIImage] = [:]
    /// What each individual photo sampled to, so paging back and forth never resamples.
    private static var sampledColors: [PhotoKey: Sample] = [:]
    private static var pendingKeys = Set<PhotoKey>()

    private static func sample(key: PhotoKey, view: UIView, isFullPhoto: Bool, attempt: Int, onUpdate: @escaping () -> Void) {
        if let color = AorusGlassProfileTint.bottomEdgeColor(of: view) {
            AorusGlassProfileTint.pendingKeys.remove(key)
            // Capped for the same reason as pageColors, with room for a few photos per peer.
            if AorusGlassProfileTint.sampledColors.count > 96 {
                AorusGlassProfileTint.sampledColors.removeAll()
            }
            let sample = Sample(
                color: color,
                image: isFullPhoto ? AorusGlassProfileTint.lowerRegionImage(of: view) : nil
            )
            AorusGlassProfileTint.sampledColors[key] = sample
            AorusGlassProfileTint.adopt(sample, for: key.peerId, onUpdate: onUpdate)
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
            AorusGlassProfileTint.sample(key: key, view: view, isFullPhoto: isFullPhoto, attempt: attempt + 1, onUpdate: onUpdate)
        }
    }

    /// The photo's lower region as a 12x24 image, mirrored, to be stretched over the page behind
    /// everything.
    ///
    /// The region is the bottom 55% and not the whole picture: the page begins where the photo
    /// ends, so what continues downwards has to be what was at the bottom, not an average of the
    /// face above it.
    ///
    /// It is returned upside down, and that is the point. The page's *top* is the edge that has to
    /// disappear into the photo, so the row that meets the photo has to be the photo's own last
    /// row; below it the page then drifts back up through the same colours. Kept the right way up
    /// instead, the join fell between the photo's bottom and the middle of the region and drew the
    /// very line this exists to remove.
    ///
    /// Rows are ordered top-down here, the reverse of the strip average, because this bitmap is
    /// kept as a picture rather than reduced to one number: the context is flipped once so that
    /// the image comes out the same way up as the photo, and the mirror is then asked for on the
    /// UIImage rather than by transforming twice.
    private static func lowerRegionImage(of view: UIView) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width >= 8.0, bounds.height >= 8.0 else {
            return nil
        }
        let regionHeight = max(8.0, bounds.height * 0.55)
        let width = 12
        let height = 24
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        // The bitmap is CoreGraphics' own, unlike bottomEdgeColor's, which reads the pixels back and
        // so has to supply the buffer. makeImage's copy of it is copy-on-write, and a buffer this
        // function had allocated and freed on the way out would be a copy that never happened.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        // The photo is drawn on an opaque base: the picture can have transparent corners under its
        // mask, and a stretched backdrop with holes in it would show the theme background through.
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: CGPoint(), size: CGSize(width: width, height: height)))
        // Read bottom up, as in bottomEdgeColor: bring the region's top-left to the origin, scale
        // into the view's own points, then flip for a bitmap context counting y upwards.
        context.translateBy(x: 0.0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / regionHeight)
        context.translateBy(x: 0.0, y: -(bounds.height - regionHeight))
        view.layer.render(in: context)
        guard let image = context.makeImage() else {
            return nil
        }
        // downMirrored is the vertical flip: 180 degrees and then mirrored across the vertical axis
        // leaves the columns where they were and reverses the rows, which is exactly the mirror the
        // page needs.
        return UIImage(cgImage: image, scale: 1.0, orientation: .downMirrored)
    }

    /// The colour the photo ends on, which is the colour the page continues in.
    ///
    /// Only the very bottom of the photo is sampled. The profile is one picture read downwards: the
    /// photo, then the page under it, then the sections and the gifts. For the page to read as the
    /// photo continuing rather than as a panel butted up against it, the two have to meet in the
    /// same colour, and the only colour that satisfies that is the one in the last few points of
    /// the picture.
    ///
    /// How thin the strip is decides whether the seam shows, and two earlier versions got it wrong
    /// in the same direction. A sixth of the photo is not its bottom edge -- on a portrait it is
    /// most of a torso, so a white shirt over a dark background came out mid-grey, met a white
    /// photo edge, and the join was visible across the whole width of the screen. 4% is shallow
    /// enough to be the edge and still tens of thousands of source pixels wide, so a single dark
    /// hair or a watermark cannot decide it.
    ///
    /// Nothing is pinned afterwards, and this is the second half of the same bug: an earlier
    /// version clamped brightness to 0.66 and produced the grey page under a white avatar that was
    /// reported. The clamps that remain are only the two degenerate ends -- a page dark enough to
    /// read as broken, or one so bright it is pure white -- and both are far enough out that no
    /// ordinary photo reaches them. Everything readable over the page derives its ink from the
    /// page instead, so a bright page is legible rather than avoided.
    ///
    /// Returns nil when the view has not drawn anything yet, which is how a photo that is still
    /// loading is told apart from one that is genuinely dark.
    private static func bottomEdgeColor(of view: UIView) -> UIColor? {
        let bounds = view.bounds
        guard bounds.width >= 8.0, bounds.height >= 8.0 else {
            return nil
        }
        let stripHeight = max(3.0, bounds.height * 0.04)
        let width = 12
        let height = 3
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
        // Three transforms, applied in the order written and composing right to left, so read them
        // bottom up: put the strip's top-left at the origin, express the context in the view's own
        // points, then flip, because a bitmap context counts y upwards and a layer counts it down.
        // Getting the flip wrong here would sample the top of the photo and look almost right,
        // which is the kind of almost that survives review.
        context.translateBy(x: 0.0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / stripHeight)
        context.translateBy(x: 0.0, y: -(bounds.height - stripHeight))
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
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: max(0.05, min(0.97, brightness)),
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
