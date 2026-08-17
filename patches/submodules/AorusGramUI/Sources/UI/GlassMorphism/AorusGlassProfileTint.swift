import Foundation
import UIKit
import ImageBlur
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

    /// The photo's last few points of picture, blurred and kept tiny, for the page to stretch behind
    /// the whole screen -- sections, tabs, gifts and all.
    ///
    /// This is Telegram's own bottom blur carried on downwards rather than a second effect invented
    /// for the page. An expanded avatar already ends in `PeerAvatarBottomShadowNode`: a variable
    /// blur of the photo's own bottom band under a gradient that reaches 0.32 black at the very
    /// last row, there so that the name and the buttons read against the picture. The page has to
    /// begin in exactly the colour that band ends in, and it cannot *be* that view -- the node
    /// lives inside the clipped avatar container, exists only while the photo is expanded, and a
    /// UIVisualEffectView has nothing to blur below the photo in any case. So the page reproduces
    /// the same material: the same pixels, the same darkening, through the same blur.
    ///
    /// The blur is `ImageBlur.blurredImage` -- the box convolution Telegram blurs its own thumbnails
    /// and wallpapers with -- run over a small square sample of that band. Scaling is not a blur:
    /// an earlier version stretched a strip thirty-two pixels wide straight across the screen, and
    /// every vertical edge in it stayed perfectly sharp. A person standing in the middle of a selfie
    /// came out as one long band down the page, which is what was reported. Blurring the sample
    /// first is what makes the stretch read as the picture's colours rather than as the picture.
    ///
    /// What comes back out of the blur is one row of it, so the picture varies across and not down.
    /// The page is not the only rectangle this is stretched over -- the members pane lays the same
    /// image across its own bounds, which begin further down the screen -- and a vertical gradient
    /// stretched over two different heights meets itself at the pane's edge as a seam.
    public static func pageBackgroundImage(for peerId: Int64) -> UIImage? {
        return AorusGlassProfileTint.pageImages[peerId]
    }

    /// Sample the photo as drawn and keep the result as this peer's page colour.
    ///
    /// Sampling the rendered view is the whole point: the page has to match the photo, and a
    /// photo has no palette entry to look up. A peer with no photo yields nothing here, on purpose
    /// -- its placeholder is a pane of glass, which has no colour of its own, and the screen paints
    /// such a profile with the theme's own background instead.
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
    /// header falls back to before the expanded page's node exists. Only the full-width one can
    /// yield anything: the round one is a centre crop behind a circular mask, so a strip across its
    /// bottom is mostly the transparent corners outside the circle, and `bottomBandSample` refuses
    /// it rather than average three-quarters of nothing into the page.
    ///
    /// `mirroredTail` is how far the header reaches below the square photo -- the strip Telegram
    /// fills by mirroring, and the strip the page has to continue. It decides which row of the
    /// picture is sampled; see `mirrorDepth(tail:)`.
    public static func publishAvatarTint(for peerId: Int64, photo: Int, photoCount: Int, view: UIView?, mirroredTail: CGFloat, isFullPhoto: Bool, onUpdate: @escaping () -> Void) {
        guard Thread.isMainThread, AorusInterfaceV2.isEnabled else {
            return
        }
        let key = PhotoKey(peerId: peerId, photo: photo, photoCount: photoCount)
        if let existing = AorusGlassProfileTint.sampledColors[key] {
            AorusGlassProfileTint.adopt(existing, for: peerId, onUpdate: onUpdate)
            return
        }
        // Refused here rather than inside the sampler, so that a profile whose photo is not laid out
        // as the expanded page -- or which has no photo at all -- does not pay for a snapshot on
        // every layout pass that could only be thrown away.
        guard isFullPhoto, let view else {
            return
        }
        AorusGlassProfileTint.sample(key: key, view: view, tail: mirroredTail, attempt: 0, onUpdate: onUpdate)
    }

    /// Make `sample` the page for this peer, and ask for a repaint if that is a change.
    ///
    /// The slot the rest of the app reads is deliberately not written here. It is global and this is
    /// per peer, so the screen being laid out claims it from its own layout pass instead -- see
    /// `publishPageColor`. The repaint is asked for on the next runloop pass rather than inline: the
    /// caller is usually in the middle of the header's layout, and laying the screen out again from
    /// inside that pass is re-entrancy the node hierarchy has no reason to tolerate.
    private static func adopt(_ sample: Sample, for peerId: Int64, onUpdate: @escaping () -> Void) {
        let sameColor = AorusGlassProfileTint.pageColors[peerId] == sample.color
        let sameImage = AorusGlassProfileTint.pageImages[peerId] === sample.image
        guard !sameColor || !sameImage else {
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
        DispatchQueue.main.async {
            onUpdate()
        }
    }

    /// Claim the page slot for a colour, and with it the ink everything drawn over the page uses.
    ///
    /// The page takes the avatar's colour; the labels take whatever reads on it. The ink is derived
    /// from the page rather than fixed at white, because the page is not forced dark: a profile
    /// whose photo ends in white paper gets a pale page and near-black labels, one that ends in a
    /// dark coat gets the dark page and white labels. Fixing it at white is what made the tabs
    /// disappear under a bright photo.
    ///
    /// Called by the profile screen from its own layout rather than from the sampler, because the
    /// colour is per peer and this slot is global. During a push two profiles lay out on every
    /// frame, and whichever sampled last would otherwise repaint the other one's labels. The screen
    /// being laid out is the one that knows which peer the page belongs to -- and it is also the
    /// only place that knows what a peer with no photo at all ended up painted with, which is the
    /// case that used to leave a previous profile's pale ink over a near-black page.
    public static func publishPageColor(_ color: UIColor) {
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

    /// One photo's contribution to the page: the colour it ends on, and the same bottom band kept as
    /// a single blurred row. `image` is nil when only the round fallback avatar was available.
    private struct Sample {
        let color: UIColor
        let image: UIImage?
    }

    /// How far above the photo's bottom edge the row the page has to continue actually sits.
    ///
    /// Not at the edge, which is what this used to sample. The header is taller than the square
    /// photo, and Telegram fills the strip below it by mirroring: a replicator layer draws a second
    /// copy of the picture flipped and stretched threefold, hinged four points above the photo's
    /// edge. So the row that reaches the bottom of the header -- the one the page begins under -- is
    /// a third of the way up that strip, `(tail + 4) / 3` above the edge, and the algebra cancels the
    /// photo's own size out of it entirely. Thirty-four points on a phone, against the eleven the
    /// last-six-percent band was centred on: enough that a page could come out plainly a different
    /// colour than the strip immediately above it, which is what was reported.
    private static func mirrorDepth(tail: CGFloat) -> CGFloat {
        return (max(0.0, tail) + 4.0) / 3.0
    }

    /// How tall a slice of the picture the page is averaged over, centred on that row: ten points.
    ///
    /// The band over the mirrored strip is blurred with a fifteen-point radius, and the strip is
    /// stretched threefold, so each row of it already carries about five points of picture either
    /// way -- this is the same average, taken at the source. Wider would drag in rows the bottom of
    /// the header never shows; narrower would let one dark hair or a watermark decide the colour of
    /// a whole page.
    private static let bandHeight: CGFloat = 10.0

    /// The darkening Telegram's own bottom band puts on the photo's last row: a gradient that
    /// reaches 0.4 black, in an image view held at 0.8 alpha.
    ///
    /// The page carries the same factor because the row it meets is the darkened one, not the raw
    /// picture. Sampling the photo as stored and painting the page with that is why the page came
    /// out a third brighter than the band above it and the join was visible.
    private static let bandShadow: Double = 0.4 * 0.8

    /// How many pixels across and down the band is sampled at, before the blur.
    ///
    /// Small on purpose: it is stretched over a whole screen, so anything finer is detail the page
    /// has no business showing. Square rather than one row tall because the blur's box kernel has to
    /// fit inside both dimensions, and fifteen does not fit inside one. The row is taken back out of
    /// it afterwards, so what the page ends up holding is still thirty-two pixels by one.
    private static let sampleSize = 32

    /// Radius the sampled band is blurred with, in that sample's own pixels.
    ///
    /// Telegram's band over the mirrored strip is a fifteen-point variable blur, and this is the same
    /// figure read in the sample's units: after three box passes it is a standard deviation of about
    /// a quarter of the picture's width. Enough that a figure in the middle of the frame becomes
    /// shading instead of a shape, and not so much that a landscape's left-to-right colours collapse
    /// into one flat tone.
    private static let sampleBlurRadius: CGFloat = 15.0

    /// What the page is painted with right now, per peer on screen.
    private static var pageColors: [Int64: UIColor] = [:]
    /// The stretched backdrop for each of those, dropped together with the colours.
    private static var pageImages: [Int64: UIImage] = [:]
    /// What each individual photo sampled to, so paging back and forth never resamples.
    private static var sampledColors: [PhotoKey: Sample] = [:]
    private static var pendingKeys = Set<PhotoKey>()

    private static func sample(key: PhotoKey, view: UIView, tail: CGFloat, attempt: Int, onUpdate: @escaping () -> Void) {
        if let sample = AorusGlassProfileTint.bottomBandSample(of: view, tail: tail) {
            AorusGlassProfileTint.pendingKeys.remove(key)
            // Capped for the same reason as pageColors, with room for a few photos per peer.
            if AorusGlassProfileTint.sampledColors.count > 96 {
                AorusGlassProfileTint.sampledColors.removeAll()
            }
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
            AorusGlassProfileTint.sample(key: key, view: view, tail: tail, attempt: attempt + 1, onUpdate: onUpdate)
        }
    }

    /// Both halves of a sample -- the picture and the colour -- from one render of the view.
    ///
    /// One pass and one buffer, not two of each: the colour is the average of the very pixels the
    /// backdrop is built from, so the flat page behind the screen and the image stretched over it
    /// cannot disagree about the row the header ends on.
    ///
    /// Returns nil when the view has drawn next to nothing, which is how a photo that is still
    /// loading is told apart from one that is genuinely dark -- a dark photo is still opaque.
    private static func bottomBandSample(of view: UIView, tail: CGFloat) -> Sample? {
        let bounds = view.bounds
        guard bounds.width >= 8.0, bounds.height >= 8.0 else {
            return nil
        }
        let bandHeight = min(AorusGlassProfileTint.bandHeight, bounds.height)
        // Centred on the row the header ends on, and kept inside the picture: a tail deeper than the
        // photo is a shape this was never given, but clamping is a line and a crash is a crash.
        let center = bounds.height - AorusGlassProfileTint.mirrorDepth(tail: tail)
        let bandTop = max(0.0, min(bounds.height - bandHeight, center - bandHeight / 2.0))
        let size = AorusGlassProfileTint.sampleSize
        let bytesPerRow = size * 4
        let count = bytesPerRow * size
        // Allocated rather than borrowed from an Array's buffer: the context outlives the call that
        // would produce that pointer, and a pointer into an Array is only valid inside the closure
        // it was handed to.
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        pixels.initialize(repeating: 0, count: count)
        defer {
            pixels.deinitialize(count: count)
            pixels.deallocate()
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        // The band is squashed across and down into a fraction of its own size, so ask for the
        // filtering that averages what it drops rather than the one that is free to pick one source
        // pixel out of it.
        context.interpolationQuality = .high
        // Three transforms, applied in the order written and composing right to left, so read them
        // bottom up: put the band's top-left at the origin, express the context in the view's own
        // points, then flip, because a bitmap context counts y upwards and a layer counts it down.
        // Getting the flip wrong here samples the top of the photo and looks almost right, which is
        // the kind of almost that survives review.
        context.translateBy(x: 0.0, y: CGFloat(size))
        context.scaleBy(x: CGFloat(size) / bounds.width, y: -CGFloat(size) / bandHeight)
        context.translateBy(x: 0.0, y: -bandTop)
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
        guard totalAlpha > 0.5 * Double(size * size) else {
            return nil
        }
        // Premultiplied, so dividing by the accumulated alpha both un-premultiplies and weights the
        // average towards the pixels that are actually opaque. Nothing is pinned afterwards: an
        // earlier version clamped brightness and produced the grey page under a white avatar that
        // was reported, and the band's own shadow already keeps the result away from white.
        let shade = 1.0 - AorusGlassProfileTint.bandShadow
        let color = UIColor(
            red: CGFloat(min(1.0, totalRed / totalAlpha * shade)),
            green: CGFloat(min(1.0, totalGreen / totalAlpha * shade)),
            blue: CGFloat(min(1.0, totalBlue / totalAlpha * shade)),
            alpha: 1.0
        )
        // Composited over black and darkened by the band's own factor, in place. A premultiplied
        // component *is* the composite over black already, so this is one multiply per channel and
        // a forced alpha -- and the alpha has to be forced, because a backdrop with holes in it
        // would show the theme's background through the page.
        for index in stride(from: 0, to: count, by: 4) {
            pixels[index] = AorusGlassProfileTint.shaded(pixels[index])
            pixels[index + 1] = AorusGlassProfileTint.shaded(pixels[index + 1])
            pixels[index + 2] = AorusGlassProfileTint.shaded(pixels[index + 2])
            pixels[index + 3] = 255
        }
        // Copied into a Data the image owns. CGContext.makeImage over a client-supplied buffer is a
        // copy-on-write of memory this function frees on the way out, which is a use after free the
        // first time the page is drawn -- four kilobytes is not worth being clever about.
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: count) as CFData),
              let band = CGImage(
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            return Sample(color: color, image: nil)
        }
        let sampled = UIImage(cgImage: band, scale: 1.0, orientation: .up)
        // Telegram's own blur, over the picture the page is about to stretch. Module-qualified so
        // that nothing else called `blurredImage` can quietly be picked up instead, and falling back
        // to the unblurred sample rather than to nothing: a page that keeps a little too much detail
        // is still the right colours, where no page at all is the flat theme background this whole
        // feature exists to get rid of.
        let blurred = ImageBlur.blurredImage(sampled, radius: AorusGlassProfileTint.sampleBlurRadius)
        return Sample(color: color, image: AorusGlassProfileTint.flattened(blurred ?? sampled))
    }

    /// The row through the middle of a blurred sample, which is what makes the backdrop safe to
    /// stretch over more than one rectangle.
    ///
    /// The blur is square -- it runs down the sample as well as across it -- and the page is not the
    /// only thing that stretches the result. The members pane lays the same image over its own
    /// bounds, which start below the header and end above the tab bar, so a picture with a vertical
    /// gradient in it would be drawn at two different heights and meet itself at the pane's edge as a
    /// seam. Taking one row keeps every bit of the blur's work across the band, which is where the
    /// artefact this fixes lives, and leaves nothing down it for two rectangles to disagree about.
    ///
    /// The middle row rather than the top or the bottom: three box passes of a fifteen-pixel kernel
    /// over thirty-two rows leave it holding an average of the whole band, where the outer rows are
    /// weighted towards whatever `kvImageEdgeExtend` repeated past the edge.
    private static func flattened(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage, cgImage.height > 1 else {
            return image
        }
        let row = CGRect(
            x: 0.0,
            y: CGFloat(cgImage.height / 2),
            width: CGFloat(cgImage.width),
            height: 1.0
        )
        guard let cropped = cgImage.cropping(to: row) else {
            return image
        }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func shaded(_ component: UInt8) -> UInt8 {
        let value = Double(component) * (1.0 - AorusGlassProfileTint.bandShadow)
        return UInt8(max(0.0, min(255.0, value.rounded())))
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
