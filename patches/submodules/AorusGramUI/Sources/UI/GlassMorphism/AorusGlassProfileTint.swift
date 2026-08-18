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

    /// The tag on the one view that holds the stretched backdrop, so everything painting the page
    /// paints the same rectangle.
    ///
    /// The profile screen owns that view and lays it over its own bounds. The members pane cannot:
    /// it has to cut the same picture into the shape of its rows, and a pane is a few hundred
    /// points down the screen. Given the frame of the screen's backdrop it can convert it into its
    /// own coordinates and lay the image exactly there, which is the only arrangement in which the
    /// two rectangles cannot disagree -- they are one rectangle drawn twice. Written down here
    /// rather than in either of them because two spellings of a tag is a seam waiting to happen.
    public static let backdropTag = 0x41475042

    /// Posted, on the main thread, when a peer's page colour or backdrop has changed.
    ///
    /// The screen itself needs no notification: the sampler asks it for a layout and the layout
    /// reads the new page. The panes do, because `PeerInfoPaneWrapper.update` memoises its
    /// parameters and returns early when none of them have changed -- and paging through a peer's
    /// avatars changes none of them. That early return is why the members tab kept the previous
    /// photo's backdrop until the reader happened to scroll it, which is what was reported.
    public static let pageDidChangeNotification = Notification.Name("AorusGramProfilePageDidChange")

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

    /// Telegram's own bottom blur block, kept as a single blurred row for the page to stretch behind
    /// the whole screen -- sections, tabs, gifts and all.
    ///
    /// The block is a real node, `PeerAvatarBottomShadowNode`, and it is the small one the reader
    /// pointed at: laid along the bottom edge of the expanded avatar, under the call buttons,
    /// eighty-eight points tall on a settings page and a hundred and eighty-eight on somebody
    /// else's profile. Two things make it. A variable blur of fifteen points, at full strength along
    /// that bottom edge and faded out towards the top of the block by a gradient mask, and over it a
    /// black gradient reaching 0.4 in an image view held at 0.8 alpha -- 0.32 black at the last row.
    /// That is the material, and the page is that material continued downwards rather than a second
    /// effect invented for it.
    ///
    /// The page cannot *be* the node. It lives inside the clipped avatar container, exists only
    /// while the photo is expanded, and a UIVisualEffectView blurs what happens to be behind it on
    /// screen -- below the header there is nothing behind the page but the page. `layer.render(in:)`
    /// over a live backdrop filter copies the gradient and none of the blur, so a snapshot of the
    /// node would be a black fade over nothing at all. What is reproduced instead is its recipe,
    /// ingredient for ingredient: the same rows of the photo, the same fifteen-point kernel, the
    /// same 0.32 of black. See `bottomBandSample`.
    ///
    /// The blur itself is `ImageBlur.blurredImage` -- the box convolution Telegram blurs its own
    /// thumbnails and wallpapers with -- run over a small sample of those rows. Scaling is not a
    /// blur: an early version stretched a strip thirty-two pixels wide straight across the screen
    /// and every vertical edge in it stayed perfectly sharp.
    ///
    /// One row rather than a picture, because one row is the whole of what the page has to show.
    /// The screen's backdrop and every pane laid over it stretch this same image over rectangles of
    /// different heights, so anything with a gradient down it would be drawn at two scales and meet
    /// itself at their edges as a join.
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
    /// yield a backdrop: the round one is a centre crop behind a circular mask, so a band across it
    /// is mostly the transparent corners outside the circle, and `bottomBandSample` refuses it
    /// rather than average three-quarters of nothing into the page.
    ///
    /// `mirroredTail` and `nativeShadowHeight` are the two numbers that place Telegram's own bottom
    /// blur block inside the photo: how far the header reaches below the square picture -- the strip
    /// it fills by mirroring -- and how tall the block along that bottom edge is. Together they say
    /// which rows of the photo the block is made of; see `bandRange(tail:shadowHeight:)`.
    public static func publishAvatarTint(for peerId: Int64, photo: Int, photoCount: Int, view: UIView?, mirroredTail: CGFloat, nativeShadowHeight: CGFloat, isFullPhoto: Bool, onUpdate: @escaping () -> Void) {
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
        AorusGlassProfileTint.sample(key: key, view: view, tail: mirroredTail, shadowHeight: nativeShadowHeight, attempt: 0, onUpdate: onUpdate)
    }

    /// Make `sample` the page for this peer, and ask for a repaint if that is a change.
    ///
    /// The slot the rest of the app reads is deliberately not written here. It is global and this is
    /// per peer, so the screen being laid out claims it from its own layout pass instead -- see
    /// `publishPageColor`. The repaint is asked for on the next runloop pass rather than inline: the
    /// caller is usually in the middle of the header's layout, and laying the screen out again from
    /// inside that pass is re-entrancy the node hierarchy has no reason to tolerate.
    ///
    /// The notification goes out after that layout and not before. `onUpdate` is the header's
    /// `requestUpdateLayout`, which lays the screen out synchronously and publishes the new page
    /// colour on the way through; a pane woken any earlier would derive its rows' ink from the
    /// previous photo's page and read white-on-white under a pale avatar.
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
            NotificationCenter.default.post(name: AorusGlassProfileTint.pageDidChangeNotification, object: nil)
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

    /// One photo's contribution to the page: the colour it averages to, and the same band kept as a
    /// single blurred row. `image` is nil when only the round fallback avatar was available.
    private struct Sample {
        let color: UIColor
        let image: UIImage?
    }

    /// The darkening Telegram's own bottom block puts on the photo's last row: a gradient that
    /// reaches 0.4 black, in an image view held at 0.8 alpha.
    ///
    /// Flat here rather than a gradient, because what the page continues is one row of that block --
    /// its bottom edge, where the gradient is at full strength. Sampling the photo as stored and
    /// painting the page with that is why the page once came out a third brighter than the block
    /// above it and the join was visible.
    private static let bandShadow: Double = 0.4 * 0.8

    /// The radius of the block's own blur, in points on the screen.
    ///
    /// `PeerAvatarBottomShadowNode` builds a `VariableBlurView(gradientMask:maxBlurRadius: 15.0)`.
    /// Everything below that has to do with a blur is this figure converted into some other unit
    /// rather than a number chosen by eye.
    private static let nativeBlurRadius: CGFloat = 15.0

    /// How far the strip under the photo stretches what it mirrors.
    ///
    /// `AvatarListContentNode.View` is a replicator layer with two instances, the second scaled by
    /// -3 down the y axis and hinged four points below the photo's edge. Threefold: so a point of
    /// that strip is a third of a point of picture, which is the conversion `bandRange` and
    /// `bandHeight` are both divided by.
    private static let mirrorStretch: CGFloat = 3.0

    /// Which rows of the photo Telegram's bottom blur block is made of, as a distance above the
    /// photo's bottom edge: the row its own bottom edge shows, and how far up from there it reaches.
    ///
    /// The block is `shadowHeight` tall and sits at the bottom of the expanded avatar, so its bottom
    /// edge is the bottom of the header -- and the header is taller than the square photo by `tail`,
    /// a strip filled by the mirror above. The row reaching the bottom of the header is therefore a
    /// third of the way up that strip, `(tail + 4) / mirrorStretch` above the photo's edge, and the
    /// algebra cancels the photo's own size out of it entirely: thirty-four points on a phone. From
    /// there the block reaches `shadowHeight - tail` further into the picture, and never less than
    /// the kernel it blurs that first row with.
    private static func bandRange(tail: CGFloat, shadowHeight: CGFloat) -> (edge: CGFloat, depth: CGFloat) {
        let edge = (max(0.0, tail) + 4.0) / AorusGlassProfileTint.mirrorStretch
        let reach = max(0.0, shadowHeight - max(0.0, tail))
        return (edge, max(AorusGlassProfileTint.bandHeight, reach))
    }

    /// The kernel that first row is blurred with, taken at the source: ten points.
    ///
    /// The block blurs fifteen points of whatever is behind it, and behind it there is the mirrored
    /// strip -- stretched threefold, so fifteen points of strip are five points of photo either way.
    /// This is the floor under `bandRange`'s reach, so that a block barely deeper than the strip it
    /// covers still averages the picture over the width of its own blur.
    private static var bandHeight: CGFloat {
        return AorusGlassProfileTint.nativeBlurRadius * 2.0 / AorusGlassProfileTint.mirrorStretch
    }

    /// How many pixels across and down the band is sampled at, before the blur.
    ///
    /// Coarse on purpose -- it is stretched over a whole screen, so anything finer is detail the page
    /// has no business showing -- but not so coarse that the blur below cannot be expressed in it.
    /// Ninety-six across a 390-point screen is close enough to four points a pixel that a kernel
    /// measured in points can be written down in pixels without the figure turning into a lie.
    /// Square rather than one row tall because the blur's box kernel has to fit inside both
    /// dimensions; the rows are averaged into one afterwards, so what the page ends up holding is
    /// ninety-six pixels by one.
    private static let sampleSize = 96

    /// Radius the sampled band is blurred with, in that sample's own pixels.
    ///
    /// Converted rather than copied. The block's fifteen points are points of screen, and the sample
    /// is ninety-six pixels across a photo as wide as the screen -- about four points to a pixel, so
    /// the same kernel is a little over three pixels here. Across the band that is what keeps the
    /// avatar's own light and dark sides on the page instead of their average; down it the figure
    /// hardly matters, because the rows are averaged into one anyway.
    ///
    /// Two versions of this went wrong before it. The first spent the fifteen points as fifteen
    /// pixels of a thirty-two pixel sample -- a kernel half the width of the picture, and the flat
    /// wash of one colour that was reported. The second wrote it down as a bare seven, which is
    /// thirty points of screen once the sample is stretched back out: twice the block's own blur, and
    /// a page plainly softer than the block it continues, which is what was reported next. A figure
    /// derived from the width it is applied to cannot drift from Telegram's like that again.
    private static func sampleBlurRadius(width: CGFloat) -> CGFloat {
        guard width > 0.0 else {
            return AorusGlassProfileTint.nativeBlurRadius
        }
        return AorusGlassProfileTint.nativeBlurRadius * CGFloat(AorusGlassProfileTint.sampleSize) / width
    }

    /// What the page is painted with right now, per peer on screen.
    private static var pageColors: [Int64: UIColor] = [:]
    /// The stretched backdrop for each of those, dropped together with the colours.
    private static var pageImages: [Int64: UIImage] = [:]
    /// What each individual photo sampled to, so paging back and forth never resamples.
    private static var sampledColors: [PhotoKey: Sample] = [:]
    private static var pendingKeys = Set<PhotoKey>()

    private static func sample(key: PhotoKey, view: UIView, tail: CGFloat, shadowHeight: CGFloat, attempt: Int, onUpdate: @escaping () -> Void) {
        if let sample = AorusGlassProfileTint.bottomBandSample(of: view, tail: tail, shadowHeight: shadowHeight) {
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
            AorusGlassProfileTint.sample(key: key, view: view, tail: tail, shadowHeight: shadowHeight, attempt: attempt + 1, onUpdate: onUpdate)
        }
    }

    /// Both halves of a sample -- the row and the colour -- from one render of the view.
    ///
    /// One pass and one buffer, not two of each: the colour is the average of the very pixels the
    /// backdrop is built from, so the flat page behind a photo-less profile and the row stretched
    /// over one with a photo are the same decision made twice rather than two decisions.
    ///
    /// What is rendered is the band Telegram's own bottom blur block is made of -- `bandRange` says
    /// which rows those are -- weighted the way the block weighs them. Its gradient is at full
    /// strength along its bottom edge and gone by its top, so a row counts here in proportion to how
    /// near that edge it lies: the average lands a third of the way up the band, which on a phone is
    /// the row the bottom of the header actually shows. An unweighted average over ninety points of
    /// picture would be the block's material without being the block's colour, and the page would
    /// step away from the row it continues.
    ///
    /// Returns nil when the view has drawn next to nothing, which is how a photo that is still
    /// loading is told apart from one that is genuinely dark -- a dark photo is still opaque.
    private static func bottomBandSample(of view: UIView, tail: CGFloat, shadowHeight: CGFloat) -> Sample? {
        let bounds = view.bounds
        guard bounds.width >= 8.0, bounds.height >= 8.0 else {
            return nil
        }
        // Kept inside the picture at both ends: a header taller than the photo it is built from is a
        // shape this was never given, but clamping is two lines and a crash is a crash.
        let range = AorusGlassProfileTint.bandRange(tail: tail, shadowHeight: shadowHeight)
        let bandBottom = min(bounds.height, max(1.0, bounds.height - range.edge))
        let bandTop = max(0.0, bandBottom - range.depth)
        let bandHeight = max(1.0, bandBottom - bandTop)
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
        // the kind of almost that survives review. It also decides which end of the buffer the
        // weights below belong to: the band's bottom edge lands in the last row of it.
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
        // Unweighted, and only for the did-it-draw-anything test below: a weighted sum would fail
        // that test on a perfectly good photo simply because most of the weight is in a few rows.
        var coverage = 0.0
        for row in 0 ..< size {
            let weight = AorusGlassProfileTint.bandWeight(row: row, of: size)
            let offset = row * bytesPerRow
            for column in 0 ..< size {
                let index = offset + column * 4
                totalRed += Double(pixels[index]) / 255.0 * weight
                totalGreen += Double(pixels[index + 1]) / 255.0 * weight
                totalBlue += Double(pixels[index + 2]) / 255.0 * weight
                let alpha = Double(pixels[index + 3]) / 255.0
                totalAlpha += alpha * weight
                coverage += alpha
            }
        }
        guard coverage > 0.5 * Double(size * size), totalAlpha > 0.0 else {
            return nil
        }
        // Premultiplied, so dividing by the accumulated alpha both un-premultiplies and weights the
        // average towards the pixels that are actually opaque. Nothing is pinned afterwards: an
        // earlier version clamped brightness and produced the grey page under a white avatar that
        // was reported, and the block's own shadow already keeps the result away from white.
        let shade = 1.0 - AorusGlassProfileTint.bandShadow
        let color = UIColor(
            red: CGFloat(min(1.0, totalRed / totalAlpha * shade)),
            green: CGFloat(min(1.0, totalGreen / totalAlpha * shade)),
            blue: CGFloat(min(1.0, totalBlue / totalAlpha * shade)),
            alpha: 1.0
        )
        // Composited over black and darkened by the block's own factor, in place. A premultiplied
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
        // first time the page is drawn -- thirty-six kilobytes, once per photo, is not worth being
        // clever about.
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
        // Telegram's own blur, at Telegram's own radius, over the band the page is about to stretch.
        // Module-qualified so that nothing else called `blurredImage` can quietly be picked up
        // instead, and falling back to the unblurred sample rather than to nothing: a page that keeps
        // a little too much detail is still the right colours, where no page at all is the flat theme
        // background this whole feature exists to get rid of.
        let blurred = ImageBlur.blurredImage(sampled, radius: AorusGlassProfileTint.sampleBlurRadius(width: bounds.width))
        return Sample(color: color, image: AorusGlassProfileTint.flattened(blurred ?? sampled))
    }

    /// How much a row of the sampled band counts, from nothing at its top to all of it at its bottom.
    ///
    /// This is the gradient Telegram's block is drawn with, read as a weight instead of as an alpha:
    /// linear, zero where the block fades out and one along the edge the page continues. Row zero of
    /// the buffer is the top of the band -- see the flip in `bottomBandSample` -- so the weight grows
    /// with the index, and `+ 1` keeps the first row from counting for literally nothing.
    private static func bandWeight(row: Int, of size: Int) -> Double {
        guard size > 0 else {
            return 1.0
        }
        return Double(row + 1) / Double(size)
    }

    /// The blurred sample averaged down to a single row, which is what makes the backdrop safe to
    /// stretch over more than one rectangle.
    ///
    /// The page is not the only thing that stretches the result. Each pane lays the same image over
    /// its own rectangle, which starts below the header and ends above the tab bar, so a picture with
    /// a vertical gradient in it would be drawn at two different heights and meet itself at the
    /// pane's edge as a seam. One row leaves nothing down the picture for two rectangles to disagree
    /// about, and every bit of the blur's work across the band -- which is the direction the page
    /// shows -- is kept.
    ///
    /// Weighted exactly as the colour beside it was, by `bandWeight`, so the row and the flat colour
    /// cannot drift apart: the colour is one average of the whole band, this is that same average
    /// taken one column at a time. The lanes are averaged where they lie -- which of the four is
    /// alpha is a property of the bitmap's byte order, and a mean is a mean in any order, so the row
    /// is handed back with the byte order it came in with.
    private static func flattened(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage, cgImage.height > 1,
              cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32,
              let data = cgImage.dataProvider?.data
        else {
            return image
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        guard let source = CFDataGetBytePtr(data), CFDataGetLength(data) >= bytesPerRow * height else {
            return image
        }
        var weights = [Double](repeating: 0.0, count: height)
        var totalWeight = 0.0
        for line in 0 ..< height {
            let weight = AorusGlassProfileTint.bandWeight(row: line, of: height)
            weights[line] = weight
            totalWeight += weight
        }
        guard totalWeight > 0.0 else {
            return image
        }
        var row = [UInt8](repeating: 0, count: width * 4)
        for column in 0 ..< width {
            var first = 0.0
            var second = 0.0
            var third = 0.0
            var fourth = 0.0
            for line in 0 ..< height {
                let offset = line * bytesPerRow + column * 4
                let weight = weights[line]
                first += Double(source[offset]) * weight
                second += Double(source[offset + 1]) * weight
                third += Double(source[offset + 2]) * weight
                fourth += Double(source[offset + 3]) * weight
            }
            row[column * 4] = AorusGlassProfileTint.byte(first / totalWeight)
            row[column * 4 + 1] = AorusGlassProfileTint.byte(second / totalWeight)
            row[column * 4 + 2] = AorusGlassProfileTint.byte(third / totalWeight)
            row[column * 4 + 3] = AorusGlassProfileTint.byte(fourth / totalWeight)
        }
        guard let provider = CGDataProvider(data: Data(row) as CFData),
              let flattened = CGImage(
                  width: width,
                  height: 1,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: cgImage.bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            return image
        }
        return UIImage(cgImage: flattened, scale: image.scale, orientation: image.imageOrientation)
    }

    /// A weighted mean back into the lane it came from, clamped rather than trusted: the arithmetic
    /// cannot leave 0...255 on its own, but one badly rounded double turning into a UInt8 traps.
    private static func byte(_ value: Double) -> UInt8 {
        return UInt8(max(0.0, min(255.0, value.rounded())))
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
