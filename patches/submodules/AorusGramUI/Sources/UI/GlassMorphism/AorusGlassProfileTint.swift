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
    /// The blur itself is a gaussian of the block's own sigma, run across a small sample of those
    /// rows -- see `sampleBlurSigma`. Scaling is not a blur: an early version stretched a strip
    /// thirty-two pixels wide straight across the screen and every vertical edge in it stayed
    /// perfectly sharp.
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
    /// `mirroredTail` is the one number that places Telegram's own bottom blur block on the photo:
    /// how far the header reaches below the square picture -- the strip it fills by mirroring that
    /// picture upside down. That single figure decides which row of the photo the bottom edge of the
    /// header shows, and the block's own kernel decides how far either side of it to read; see
    /// `bandRange(tail:)`. The block's height is deliberately not among the arguments -- see the same
    /// place for why it cannot matter.
    public static func publishAvatarTint(for peerId: Int64, photo: Int, photoCount: Int, view: UIView?, mirroredTail: CGFloat, isFullPhoto: Bool, onUpdate: @escaping () -> Void) {
        guard Thread.isMainThread, AorusInterfaceV2.isEnabled else {
            return
        }
        let key = PhotoKey(peerId: peerId, photo: photo, photoCount: photoCount)
        // Recorded before anything below can return early: a reading still in flight for the photo
        // the reader has just swiped away from tests this and stops, instead of sampling a node that
        // has since been given a different picture to hold.
        AorusGlassProfileTint.currentKeys[peerId] = key
        if let existing = AorusGlassProfileTint.sampledColors[key] {
            AorusGlassProfileTint.adopt(existing, for: peerId, onUpdate: onUpdate)
            // What this peer has already sampled to is the page immediately, but it is only the last
            // word once the picture behind it has stopped changing -- see `sampleAndSettle` for what
            // reading it once and never again did to the join.
            if AorusGlassProfileTint.settledKeys.contains(key) {
                return
            }
        }
        // Refused here rather than inside the sampler, so that a profile whose photo is not laid out
        // as the expanded page -- or which has no photo at all -- does not pay for a snapshot on
        // every layout pass that could only be thrown away.
        guard isFullPhoto, let view else {
            return
        }
        // One reader per photo. This is published from every layout pass, and a second loop started
        // from the next one would double every snapshot for as long as the two of them overlapped.
        guard !AorusGlassProfileTint.pendingKeys.contains(key) else {
            return
        }
        AorusGlassProfileTint.sampleAndSettle(key: key, view: view, tail: mirroredTail, read: 1, stable: 0, onUpdate: onUpdate)
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
    /// `bandDepth` are both divided by.
    private static let mirrorStretch: CGFloat = 3.0

    /// Which rows of the photo Telegram's bottom blur block is made of, as a distance above the
    /// photo's bottom edge: the row its own bottom edge shows, and how far past that row -- one way,
    /// not both -- its blur reads.
    ///
    /// Both figures come out of the replicator's own transform rather than out of trial and error.
    /// The header is `tail` taller than the square picture, and it fills that strip with the second
    /// instance of `AvatarListContentNode.View` -- `Translate(0, (W - tail) * 2 - 4, 0)` over
    /// `Scale(1, -3, 1)`, in a layer whose origin is the header's own centre. Writing `u` for a row
    /// of the container measured from the top of the picture and `s` for where that row is displayed,
    /// the pair composes to `s = 4(W - 1) - 3u`; setting `s` to the bottom of the header, `W + tail`,
    /// leaves `u = W - (tail + 4) / 3`. So the row the header's last line shows is
    /// `(tail + 4) / mirrorStretch` above the bottom of the picture -- thirty-four points on a phone
    /// -- and the picture's own size cancels out of it completely. That is `edge`, and it is measured
    /// off `imageNode`'s bounds, which `PeerInfoAvatarListItemNode` lays out as the square picture
    /// itself and not as the taller container.
    ///
    /// `depth` is that same kernel converted into the same picture, and it runs one way rather than
    /// both. The bottom edge of the block is the bottom edge of its blur as well, and the filter is
    /// built with `inputNormalizeEdges` set -- at that edge it divides by the weight it actually
    /// used instead of reaching past it, so the last line of the block is an average of the rows
    /// *inside* the block, which are the ones above it on screen. Up the screen is down the picture,
    /// because the strip is mirrored. So the band runs from `edge` towards the bottom of the photo
    /// and not five points each way about it, and it is three sigma long because that is where a
    /// gaussian has spent itself.
    ///
    /// How tall the block is does not appear here, and that is the correction rather than an
    /// omission. All three of its ingredients are at their extreme along its bottom edge whatever
    /// its height: the mask that scales the blur reaches 1.0 there, the gradient layer that fades
    /// the whole effect out reaches full opacity there, and the black gradient over it reaches its
    /// 0.4. The row the page continues is that bottom edge, so the block's height cannot change the
    /// page's colour -- and an earlier version that reached `shadowHeight - tail` into the picture
    /// spent ninety points of it, averaging rows the header never shows anywhere near its bottom and
    /// landing the page some thirty points of picture -- ninety of screen -- away from the row it
    /// joins. That was the seam that was reported twice.
    private static func bandRange(tail: CGFloat) -> (edge: CGFloat, depth: CGFloat) {
        let edge = (max(0.0, tail) + 4.0) / AorusGlassProfileTint.mirrorStretch
        return (edge, AorusGlassProfileTint.bandDepth)
    }

    /// How far into the picture the block's blur reads from the row its bottom edge shows: three
    /// sigma, one way.
    private static var bandDepth: CGFloat {
        return AorusGlassProfileTint.bandSigma * 3.0
    }

    /// The block's kernel in points of picture rather than points of screen.
    ///
    /// It blurs fifteen points of what is behind it, and what is behind it is the mirrored strip
    /// stretched threefold, so fifteen points of screen are five points of photo.
    private static var bandSigma: CGFloat {
        return AorusGlassProfileTint.nativeBlurRadius / AorusGlassProfileTint.mirrorStretch
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

    /// Standard deviation the sampled band is blurred with, in that sample's own pixels.
    ///
    /// Converted rather than copied, and a sigma rather than a radius. The block's fifteen points are
    /// `inputRadius` on a `CAFilter` gaussian, which is that kernel's standard deviation; the sample
    /// is ninety-six pixels across a photo as wide as the screen -- about four points to a pixel, so
    /// the same kernel is a little over three and a half pixels here. Across the band that is what
    /// keeps the avatar's own light and dark sides on the page instead of their average.
    ///
    /// Three versions of this went wrong before it, all of them one mistake in different clothes.
    /// The first spent the fifteen points as fifteen pixels of a thirty-two pixel sample -- a kernel
    /// half the width of the picture, and the flat wash of one colour that was reported. The second
    /// wrote it down as a bare seven. The third derived exactly the figure below, which is right, and
    /// then handed it to `ImageBlur.blurredImage`, whose `radius` is the *width of a box* convolved
    /// three times: three and a half became a box of three, and a box of three convolved thrice is a
    /// sigma of sqrt(2), a blur two and a half times weaker than the block's. That was measurable off
    /// the report -- the page held two and a quarter times the block's contrast, thirty-seven levels
    /// too bright at the left edge of the join and fifteen too dark at the right. The gaussian is
    /// applied in this file now, at exactly this sigma, so there is no second unit left for it to be
    /// lost in.
    private static func sampleBlurSigma(width: CGFloat) -> CGFloat {
        guard width > 0.0 else {
            return AorusGlassProfileTint.nativeBlurRadius
        }
        return AorusGlassProfileTint.nativeBlurRadius * CGFloat(AorusGlassProfileTint.sampleSize) / width
    }

    /// What the page is painted with right now, per peer on screen.
    private static var pageColors: [Int64: UIColor] = [:]
    /// The stretched backdrop for each of those, dropped together with the colours.
    private static var pageImages: [Int64: UIImage] = [:]
    /// What each individual photo has sampled to so far, so paging back and forth costs nothing once
    /// the photo has settled.
    private static var sampledColors: [PhotoKey: Sample] = [:]
    private static var pendingKeys = Set<PhotoKey>()
    /// Photos whose picture has stopped changing. Their sample is the last word, and no further
    /// reading is booked for them. Cleared together with `sampledColors`, which they are receipts
    /// for: a key left marked settled with no sample behind it would never be read again.
    private static var settledKeys = Set<PhotoKey>()
    /// Which of a peer's photos is on screen right now, so a reading that comes back after the
    /// reader has swiped can tell that the node it is holding is no longer the picture it was
    /// started for.
    private static var currentKeys: [Int64: PhotoKey] = [:]

    /// How many times the band is read before the page settles for what it has.
    ///
    /// A reading is one `layer.render(in:)` of the avatar into a ninety-six pixel buffer and a box
    /// blur across that, and the loop stops the moment two of them agree -- so a photo already in the
    /// cache costs exactly two, and the cap is only ever reached by one that never finishes arriving.
    private static let settleReads = 16

    /// How long to wait before reading again: close together at first, then further apart.
    ///
    /// The page can only be out of step with the header for one of these gaps, so the early ones are
    /// short -- the reader has just opened the profile, and the photo usually lands within a few
    /// hundred milliseconds of that. The later ones are long, so sixteen readings still cover the
    /// five seconds a photo can take to arrive over a bad connection instead of running out after
    /// three: running out early is exactly how the placeholder became the page permanently, and a
    /// slow line should not be enough to bring that back.
    private static func settleDelay(after read: Int) -> Double {
        return read < 8 ? 0.12 : 0.5
    }

    /// Read the band, give the page what it says, and keep reading until the picture stops changing.
    ///
    /// The loop is the correction, and it is worth writing down why the single reading it replaces
    /// could not have worked. Telegram hands a gallery item its picture in two stages:
    /// `PeerInfoAvatarListItemNode` builds its image signal with
    /// `chatAvatarGalleryPhoto(... immediateThumbnailData:)`, and that signal emits the stripped
    /// thumbnail first -- decoded at ninety pixels, run through `telegramFastBlurMore`, scaled up and
    /// blurred a second time -- then emits again with the full-size photo drawn over it once it has
    /// downloaded. Both stages fill the node edge to edge and both are opaque, so nothing measurable
    /// from here tells them apart: the placeholder renders, it covers the band, it averages to a
    /// colour. An earlier version took the first reading it got, memoised it under the photo's key
    /// and never looked again -- and when that reading was the placeholder, the page stayed painted
    /// from a picture blurred nearly flat while the header's own block, which is a live backdrop
    /// filter, went on showing the real photo. Measured off the report: twenty points of blue apart
    /// at the join, and permanent. That is the seam that was reported three times over, and every
    /// attempt to close it by correcting the geometry was reading the right rows of the wrong picture.
    ///
    /// So the page follows the photo rather than guessing when it has arrived -- which is what the
    /// block it continues does, blurring whatever is behind it at that moment, placeholder included.
    /// Two identical readings in a row end the loop. One would not do: a placeholder is perfectly
    /// stable for exactly as long as the download takes.
    private static func sampleAndSettle(key: PhotoKey, view: UIView, tail: CGFloat, read: Int, stable: Int, onUpdate: @escaping () -> Void) {
        guard let sample = AorusGlassProfileTint.bottomBandSample(of: view, tail: tail) else {
            // Nothing drawn yet: the picture is still decoding, or the node has not been laid out at
            // the size the header gives it. Read again on a delay rather than from the next layout
            // pass, because a profile that is simply sitting there gets no further passes, and
            // drawing the avatar on every pass of one being scrolled would cost a snapshot a frame.
            AorusGlassProfileTint.scheduleRead(key: key, view: view, tail: tail, read: read, stable: stable, onUpdate: onUpdate)
            return
        }
        let previous = AorusGlassProfileTint.sampledColors[key]
        let unchanged = previous?.color == sample.color && (previous?.image != nil) == (sample.image != nil)
        if !unchanged {
            // Capped for the same reason as pageColors, with room for a few photos per peer.
            if AorusGlassProfileTint.sampledColors.count > 96 {
                AorusGlassProfileTint.sampledColors.removeAll()
                AorusGlassProfileTint.settledKeys.removeAll()
            }
            AorusGlassProfileTint.sampledColors[key] = sample
            AorusGlassProfileTint.adopt(sample, for: key.peerId, onUpdate: onUpdate)
        }
        guard stable + (unchanged ? 1 : 0) < 2 else {
            AorusGlassProfileTint.pendingKeys.remove(key)
            AorusGlassProfileTint.settledKeys.insert(key)
            return
        }
        AorusGlassProfileTint.scheduleRead(key: key, view: view, tail: tail, read: read, stable: unchanged ? stable + 1 : 0, onUpdate: onUpdate)
    }

    /// Book the next reading of a photo, or stop when there is nothing left to read for.
    private static func scheduleRead(key: PhotoKey, view: UIView, tail: CGFloat, read: Int, stable: Int, onUpdate: @escaping () -> Void) {
        guard read < AorusGlassProfileTint.settleReads else {
            // Out of readings. Marked settled rather than left open: the page keeps whatever the last
            // one gave it, and a photo that never finished arriving should not go on costing a
            // snapshot every time the profile lays itself out.
            AorusGlassProfileTint.pendingKeys.remove(key)
            AorusGlassProfileTint.settledKeys.insert(key)
            return
        }
        AorusGlassProfileTint.pendingKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + AorusGlassProfileTint.settleDelay(after: read)) { [weak view] in
            // The node is gone, the reader has swiped to another photo, or this one settled in the
            // meantime. Nothing is marked settled in the swipe case, so coming back to that photo
            // starts a fresh loop instead of trusting a reading that was cut short.
            guard let view,
                  AorusGlassProfileTint.currentKeys[key.peerId] == key,
                  !AorusGlassProfileTint.settledKeys.contains(key)
            else {
                AorusGlassProfileTint.pendingKeys.remove(key)
                return
            }
            AorusGlassProfileTint.sampleAndSettle(key: key, view: view, tail: tail, read: read + 1, stable: stable, onUpdate: onUpdate)
        }
    }

    /// Both halves of a sample -- the row and the colour -- from one render of the view.
    ///
    /// One pass and one buffer, not two of each: the colour is the average of the very pixels the
    /// backdrop is built from, so the flat page behind a photo-less profile and the row stretched
    /// over one with a photo are the same decision made twice rather than two decisions.
    ///
    /// What is rendered is the band Telegram's own bottom blur block reads -- `bandRange` says where
    /// that is -- weighted the way the block's own kernel weighs it. The row the header's bottom edge
    /// shows sits in the middle of the band, and a row counts here in proportion to how near it lies:
    /// a tent, peaking on that row and gone five points of picture either side of it, which is the
    /// fifteen-point kernel converted through the mirror's threefold stretch. So the average lands on
    /// the row the page has to join, with no bias to either side of it.
    ///
    /// Returns nil when the view has drawn next to nothing, which is how a photo that is still
    /// loading is told apart from one that is genuinely dark -- a dark photo is still opaque.
    private static func bottomBandSample(of view: UIView, tail: CGFloat) -> Sample? {
        let bounds = view.bounds
        guard bounds.width >= 8.0, bounds.height >= 8.0 else {
            return nil
        }
        // `seam` is the row of the picture that the bottom edge of the header shows, and the whole of
        // this function exists to hand the page that row's colour. The band is centred on it and both
        // ends are kept inside the picture: a header taller than three times the photo it is built
        // from is a shape this was never given, but clamping is three lines and a crash is a crash.
        let range = AorusGlassProfileTint.bandRange(tail: tail)
        let seam = min(bounds.height, max(0.0, bounds.height - range.edge))
        // The band starts at the seam and runs towards the bottom of the picture, because the block's
        // blur does: its bottom edge is the page's join and also the edge its kernel is renormalised
        // against, so the last line of it averages rows from inside the block -- up the screen, which
        // over a strip mirrored and stretched threefold is down the photo. See `bandRange`.
        let bandTop = max(0.0, seam)
        let bandBottom = min(bounds.height, max(bandTop + 1.0, seam + range.depth))
        let bandHeight = max(1.0, bandBottom - bandTop)
        let size = AorusGlassProfileTint.sampleSize
        // Where the seam ended up in the buffer, once the band was scaled into it. The first row when
        // nothing clamped, and this is what the weights below are hung on rather than a fixed row --
        // clamping moves the seam within the band, and a weight that assumed the first row would
        // quietly start averaging the wrong rows on the shapes where that happens.
        let seamRow = min(Double(size), max(0.0, Double(size) * Double((seam - bandTop) / bandHeight)))
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
        // The band is stretched across and down into a shape of its own, so ask for the filtering
        // that averages the rows it lands between rather than the one that is free to pick one source
        // pixel out of them.
        context.interpolationQuality = .high
        // Three transforms, applied in the order written and composing right to left, so read them
        // bottom up: put the band's top-left at the origin, express the context in the view's own
        // points, then flip, because a bitmap context counts y upwards and a layer counts it down.
        // Getting the flip wrong here samples the top of the photo and looks almost right, which is
        // the kind of almost that survives review. It also fixes which end of the buffer is which for
        // everything below: row zero is the top of the band, the last row its bottom edge, and
        // `seamRow` lies between them wherever the seam does.
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
            let weight = AorusGlassProfileTint.bandWeight(row: row, seamRow: seamRow, of: size)
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
        // No image rather than the unflattened one if the flatten fails. `color` is the same weighted
        // average of the same band, so a page painted flat with it is the right colour and simply
        // shows no left-to-right variation; a ninety-six row gradient stretched over the screen and
        // over each pane separately would be two scales of one gradient meeting at the pane's edge,
        // which is worse than not having the variation at all.
        return Sample(
            color: color,
            image: AorusGlassProfileTint.flattenedRow(
                of: sampled,
                seamRow: seamRow,
                sigma: Double(AorusGlassProfileTint.sampleBlurSigma(width: bounds.width))
            )
        )
    }

    /// How much a row of the sampled band counts: all of it on the row the header's bottom edge
    /// shows, falling away from there towards the bottom of the picture, and nothing at all on the
    /// other side of it.
    ///
    /// This is the block's own kernel read as a weight instead of as a blur, and it is one-sided
    /// because the block's is. The bottom edge of the block is where the page joins and is also the
    /// bottom edge of its blur: the filter is built with `inputNormalizeEdges`, so at that edge it
    /// divides by the weight it actually used rather than reaching past it, and its last line is
    /// therefore half a gaussian over the rows *inside* the block. Those are the rows above it on
    /// screen, and the strip is mirrored, so on the photo they are the ones running from `seamRow`
    /// towards its bottom edge.
    ///
    /// A symmetric tent, which is what stood here, gets this wrong twice over: half its weight lands
    /// on rows past the block's edge that the join never shows, and the five points of picture it
    /// spends on them are fifteen points of screen -- so the page came out as an average of the block
    /// and of what the block would have shown had it been taller, which is a step in colour at
    /// exactly the one line where a step can be seen.
    private static func bandWeight(row: Int, seamRow: Double, of size: Int) -> Double {
        guard size > 0 else {
            return 1.0
        }
        // Signed rather than absolute: the far side of the seam is not a low weight, it is not part
        // of the kernel at all. Measured from the middle of the row rather than its edge.
        let distance = Double(row) + 0.5 - seamRow
        // Never quite zero, on either branch: a total of exactly zero is a division the caller would
        // have to answer for, and on a clamped band every row can end up on the far side.
        guard distance >= 0.0 else {
            return 0.0001
        }
        // The kernel's sigma in rows of this buffer. The band is `bandDepth` of picture scaled over
        // `size` rows and that depth is three sigma, so a sigma is a third of the buffer -- the
        // photo's own size, the sample's size and the screen's all cancel out of the ratio.
        let sigma = max(1.0, Double(size) / 3.0)
        return max(0.0001, exp(-(distance * distance) / (2.0 * sigma * sigma)))
    }

    /// One row of interleaved lanes blurred across, with the kernel renormalised at both ends.
    ///
    /// Renormalised and not clamped, because the filter this reproduces is built with
    /// `inputNormalizeEdges` set: where it can no longer see a full kernel it divides by the weight
    /// it actually used instead of pretending the edge pixel repeats forever. The two differ by
    /// roughly a third of a sigma's worth of the picture's own slope, in opposite directions at the
    /// two ends -- and measured off the report that was thirteen levels at the left edge of the join,
    /// because a photo's dark side can be a long way from its bright one and the page meets the block
    /// across the whole width at once.
    ///
    /// Written here rather than borrowed from `ImageBlur`. That module's `radius` is the width of a
    /// box it convolves three times with `kvImageEdgeExtend`: the wrong unit and the wrong edge
    /// policy, and passing a sigma to it cost this file two and a half times the blur it asked for.
    /// Ninety-six columns by a kernel of about twenty-three is some nine thousand multiplies, run
    /// once when a photo settles, so there is nothing to buy back by being clever about it.
    private static func horizontallyBlurred(_ lanes: [Double], width: Int, sigma: Double) -> [Double] {
        let lanesPerPixel = 4
        guard width > 1, sigma > 0.05, lanes.count == width * lanesPerPixel else {
            return lanes
        }
        // Three sigma each way, which is where a gaussian has spent itself, and never wider than the
        // picture -- a kernel longer than what it reads is weight that can only be renormalised away.
        let reach = max(1, min(width - 1, Int((sigma * 3.0).rounded(.up))))
        var kernel = [Double](repeating: 0.0, count: reach * 2 + 1)
        for index in 0 ... reach * 2 {
            let offset = Double(index - reach)
            kernel[index] = exp(-(offset * offset) / (2.0 * sigma * sigma))
        }
        var result = lanes
        for column in 0 ..< width {
            var sums = [Double](repeating: 0.0, count: lanesPerPixel)
            var weight = 0.0
            for index in 0 ... reach * 2 {
                let source = column + index - reach
                guard source >= 0, source < width else {
                    continue
                }
                let tap = kernel[index]
                weight += tap
                let base = source * lanesPerPixel
                for lane in 0 ..< lanesPerPixel {
                    sums[lane] += tap * lanes[base + lane]
                }
            }
            guard weight > 0.0 else {
                continue
            }
            let base = column * lanesPerPixel
            for lane in 0 ..< lanesPerPixel {
                result[base + lane] = sums[lane] / weight
            }
        }
        return result
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
    /// alpha is a property of the bitmap's byte order, and a mean is a mean in any order -- and the
    /// alpha lane is then forced opaque, because a backdrop with holes in it would show the theme's
    /// own background through the page.
    ///
    /// The blurred image is redrawn into a buffer of this file's own making rather than read out of
    /// whatever some other module handed back. That version asked the image for its data provider and
    /// its layout and gave up -- silently, returning the picture unflattened -- when either was not
    /// what it expected. Unflattened means ninety-six rows of gradient, drawn at one height by the
    /// screen's backdrop and at another by every pane over it: two scales of the same gradient meeting
    /// at the pane's top edge, which is a seam produced by the very code written to avoid one. Failing
    /// here is now a nil the caller answers for, and the common path cannot fail at all.
    ///
    /// The blur happens here too, on the one row and after the averaging, which is the same result as
    /// blurring the band and cheaper by ninety-six: the average of a blur and the blur of an average
    /// are the same thing when the kernel runs across and the average runs down. It also runs on the
    /// means rather than on bytes, so the kernel's work is not rounded into 8-bit steps before it is
    /// stretched over a whole screen.
    private static func flattenedRow(of image: UIImage, seamRow: Double, sigma: Double) -> UIImage? {
        let size = AorusGlassProfileTint.sampleSize
        guard let cgImage = image.cgImage, size > 0 else {
            return nil
        }
        let bytesPerRow = size * 4
        let count = bytesPerRow * size
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        pixels.initialize(repeating: 0, count: count)
        defer {
            pixels.deinitialize(count: count)
            pixels.deallocate()
        }
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
        context.interpolationQuality = .high
        // Drawn upright into a bitmap context, which puts the image's own first row in the buffer's
        // first row -- the same end `seamRow` is measured from.
        context.draw(cgImage, in: CGRect(origin: CGPoint(), size: CGSize(width: size, height: size)))
        var lanes = [Double](repeating: 0.0, count: bytesPerRow)
        var totalWeight = 0.0
        for line in 0 ..< size {
            let weight = AorusGlassProfileTint.bandWeight(row: line, seamRow: seamRow, of: size)
            totalWeight += weight
            let offset = line * bytesPerRow
            for lane in 0 ..< bytesPerRow {
                lanes[lane] += Double(pixels[offset + lane]) * weight
            }
        }
        guard totalWeight > 0.0 else {
            return nil
        }
        var means = [Double](repeating: 0.0, count: bytesPerRow)
        for lane in 0 ..< bytesPerRow {
            means[lane] = lanes[lane] / totalWeight
        }
        let smoothed = AorusGlassProfileTint.horizontallyBlurred(means, width: size, sigma: sigma)
        var row = [UInt8](repeating: 0, count: bytesPerRow)
        for column in 0 ..< size {
            row[column * 4] = AorusGlassProfileTint.byte(smoothed[column * 4])
            row[column * 4 + 1] = AorusGlassProfileTint.byte(smoothed[column * 4 + 1])
            row[column * 4 + 2] = AorusGlassProfileTint.byte(smoothed[column * 4 + 2])
            row[column * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(row) as CFData),
              let flattened = CGImage(
                  width: size,
                  height: 1,
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
            return nil
        }
        return UIImage(cgImage: flattened, scale: 1.0, orientation: .up)
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

/// The last stretch of Telegram's own bottom blur block, cross-faded into the page it continues.
///
/// Everything above this is arithmetic that predicts what the block's bottom line comes out as, from
/// its own recipe: the rows of the photo it reads, the kernel it reads them with, the edge policy that
/// kernel uses, the 0.32 of black over the result. Every one of those was wrong at least once, and
/// each time the mistake arrived as a visible step across the whole width of the screen.
///
/// This is the part that does not have to be predicted. The block's blur is a private `CAFilter`
/// behind a `UIVisualEffectView`, and `layer.render(in:)` over a live backdrop filter copies the
/// gradient and none of the blur -- so the block cannot be photographed, only modelled, and a model
/// is never exact. Laid over the bottom of the block, this makes the two sides of the join the same
/// pixels by construction: the page's own row, faded in from nothing over the height of the block, so
/// that whatever the page is painted with *is* what the block's last line shows. Any error left in the
/// model then costs a gradient spread over a hundred and eighty points instead of a step at one line,
/// and only one of those two can be seen.
///
/// Nothing about the fade is delicate, because there is no boundary in it to get wrong: both sides are
/// the same rows of the same photo blurred the same way, so the blend has nothing to make ugly. What
/// it does is stop the bottom of the header varying down the screen a little sooner than it otherwise
/// would, which is exactly what "the block carried the rest of the way down" means.
public final class AorusProfileHeaderFadeView: UIView {
    private let imageView = UIImageView()
    private let fade = CAGradientLayer()

    public override init(frame: CGRect) {
        super.init(frame: frame)

        // Never in the way: the block sits under the call buttons and the music row, and every touch
        // that lands here belongs to one of them or to the avatar's own pager.
        self.isUserInteractionEnabled = false
        self.layer.allowsGroupOpacity = false

        // One row stretched, the same way the page and every pane over it stretch it. `scaleToFill`
        // rather than `scaleAspectFill` because the row is ninety-six by one and its aspect is not a
        // property anything wants preserved.
        self.imageView.contentMode = .scaleToFill

        // Cubed rather than linear. Linear would have a quarter of the page's colour showing half way
        // up the block, where the block still has most of its own gradient left to give; cubed, the
        // fade is imperceptible where it starts and does its work over the fifty points nearest the
        // join, which is close enough to the join that the block keeps its look and far enough from
        // it that no line of the fade is a line anyone can find.
        let steps = 8
        self.fade.colors = (0 ... steps).map { step in
            let fraction = CGFloat(step) / CGFloat(steps)
            return UIColor(white: 1.0, alpha: fraction * fraction * fraction).cgColor
        }
        self.fade.locations = (0 ... steps).map { step in
            return NSNumber(value: Double(step) / Double(steps))
        }
        self.fade.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.fade.endPoint = CGPoint(x: 0.0, y: 1.0)
        self.layer.mask = self.fade

        self.addSubview(self.imageView)
    }

    required public init?(coder: NSCoder) {
        preconditionFailure("AorusProfileHeaderFadeView is not built from a coder")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        self.imageView.frame = self.bounds
        // A mask's frame is read in the masked layer's own coordinates, so it follows the bounds and
        // not the frame. Kept in step here rather than in the setter because the block is resized by
        // the header's layout, which does not go through the setter.
        self.fade.frame = self.bounds
    }

    /// The page's own row, or nil to draw nothing at all -- a peer with no photo has no page, and the
    /// block is then Telegram's unaltered.
    public func update(image: UIImage?) {
        if self.imageView.image !== image {
            self.imageView.image = image
        }
        self.isHidden = image == nil
    }
}
