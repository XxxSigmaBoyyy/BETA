import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import SwiftSignalKit
import AvatarNode
import AorusGram

// AorusAI mentions.
//
// Anywhere a Telegram handle appears inside AorusAI — the text the user is typing, the
// message they sent, the answer the model wrote back, a quoted message — it is drawn as
// the person rather than as a string: their avatar in a small ringed circle, followed by
// the name from their profile in the accent colour.
//
// The handle is replaced *in place*, in the run of the sentence. An earlier revision cut
// the handle out of the text and listed the peers in a separate scrolling strip below the
// bubble, which left the sentence with a hole in it ("расскажи про" — chip) and put the
// person somewhere the eye does not read them.
//
// The characters the user typed are never lost: every pill carries its own source text in
// an attribute, and `aorusAIPlainText` walks those attributes to rebuild exactly what was
// written. That string — not what is on screen — is what the composer sends, so the
// transport is byte-for-byte what it was before the pill existed.
//
// What a mention *is*, how one is found in text and how that reconstruction works live in
// the AorusGram core module, where the preflight can typecheck them and run tests against
// them. This file is only the drawing.

enum AorusAIMentionRenderer {
    /// The circle is sized to the cap height of the surrounding text rather than to a
    /// fixed number, so a pill in a 13pt quote and one in a 16.5pt answer both read as
    /// part of their line instead of as an inserted object.
    static func avatarSize(for font: UIFont) -> CGFloat {
        return max(16.0, min(24.0, ceil(font.pointSize * 1.16)))
    }

    /// The colour the ring and the name are drawn in — Telegram's own accent, which is
    /// blue in every stock theme.
    static func accentColor(_ theme: PresentationTheme) -> UIColor {
        return theme.list.itemAccentColor
    }

    /// The one- or two-letter monogram shown until the photo arrives, and for peers who
    /// have no photo at all. Never blank, so a pill never reads as a loading failure.
    static func letters(for name: String) -> [String] {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        let words = cleaned.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? ["#"] : letters
    }

    /// The avatar, drawn into the attachment itself.
    ///
    /// An earlier version reserved an empty box on the line and floated a real `AvatarNode`
    /// over it, positioned from the layout manager's glyph geometry. That is where the
    /// circle sitting a few points below the name came from: an attachment glyph's reported
    /// origin is not the text baseline, so every pill was placed against the wrong datum.
    /// Handing TextKit a picture removes the question — it aligns the image itself, exactly
    /// the way it aligns a glyph, and there is no geometry left to get wrong.
    private static func attachment(font: UIFont, image: UIImage) -> NSTextAttachment {
        let size = avatarSize(for: font)
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centred on the cap band, which is the band the eye reads a name in.
        attachment.bounds = CGRect(x: 0.0, y: (font.capHeight - size) / 2.0, width: size, height: size)
        return attachment
    }

    /// The gap between the circle and the name. A thin space, so the pill reads as one
    /// object without the name touching the ring.
    private static let gap = "\u{2009}"

    private static func pill(for mention: AorusAIMention, font: UIFont, accent: UIColor, link: Bool) -> NSAttributedString {
        let nameFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let size = avatarSize(for: font)
        let image = AorusAIMentionAvatarCache.shared.image(for: mention, diameter: size, ring: accent)
        let value = NSMutableAttributedString()
        value.append(NSAttributedString(attachment: attachment(font: font, image: image)))
        value.append(NSAttributedString(string: gap + mention.displayName))
        // The box carries the pill's own length, so text that later merges into this run —
        // anything typed straight after it inherits the attribute — is not mistaken for part
        // of the pill when the source text is rebuilt.
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: accent,
            .aorusAIMention: AorusAIMentionBox(mention, renderedLength: value.length)
        ]
        if link, let url = URL(string: "aorus-peer://\(mention.peerId)") {
            attributes[.link] = url
        }
        let full = NSRange(location: 0, length: value.length)
        value.addAttributes(attributes, range: full)
        // The font is applied to the name only: giving it to the attachment glyph would
        // change the line height the attachment is measured against.
        value.addAttribute(.font, value: nameFont, range: NSRange(location: 1, length: value.length - 1))
        return value
    }

    /// One rendered pill and the source it came from, so a caret can be carried across a
    /// rebuild.
    struct Placement {
        var source: NSRange
        var rendered: NSRange
    }

    /// Builds the display text of `source` from scratch. Used by the composer, which owns
    /// its plain text and needs the source↔display mapping to keep the caret still.
    ///
    /// `plain` names one handle that must be left as the characters it is made of, however
    /// well it resolves. The composer passes the handle the user is in the middle of
    /// typing: `@durov` is a real person the moment those six characters exist, and
    /// replacing it with a pill right then is what made `@durovnews` impossible to type —
    /// the name was gone before the rest of it could be written.
    static func render(
        source: String,
        resolved: [String: AorusAIMention],
        base: [NSAttributedString.Key: Any],
        font: UIFont,
        accent: UIColor,
        link: Bool,
        plain: NSRange? = nil
    ) -> (text: NSMutableAttributedString, placements: [Placement]) {
        let value = NSMutableAttributedString()
        var placements: [Placement] = []
        let nsSource = source as NSString
        var cursor = 0
        for match in AorusAIMentionScanner.matches(in: source) {
            if let plain, NSEqualRanges(plain, match.range) { continue }
            guard let mention = resolved[match.username.lowercased()] else { continue }
            if match.range.location > cursor {
                let gap = NSRange(location: cursor, length: match.range.location - cursor)
                value.append(NSAttributedString(string: nsSource.substring(with: gap), attributes: base))
            }
            let renderedLocation = value.length
            let sourceText = nsSource.substring(with: match.range)
            var placed = mention
            placed.sourceText = sourceText
            value.append(pill(for: placed, font: font, accent: accent, link: link))
            placements.append(Placement(
                source: match.range,
                rendered: NSRange(location: renderedLocation, length: value.length - renderedLocation)
            ))
            cursor = NSMaxRange(match.range)
        }
        if cursor < nsSource.length {
            let tail = NSRange(location: cursor, length: nsSource.length - cursor)
            value.append(NSAttributedString(string: nsSource.substring(with: tail), attributes: base))
        }
        return (value, placements)
    }

    /// Replaces the handles inside an already formatted string. Used by message bodies,
    /// whose text has been through the markdown renderer and no longer lines up with the
    /// ranges the entities were found at.
    @discardableResult
    static func apply(
        to value: NSMutableAttributedString,
        resolved: [String: AorusAIMention],
        font: UIFont,
        accent: UIColor,
        link: Bool
    ) -> Int {
        guard !resolved.isEmpty, value.length > 0 else { return 0 }
        let matches = AorusAIMentionScanner.matches(in: value.string)
        guard !matches.isEmpty else { return 0 }
        let source = value.string as NSString
        var replaced = 0
        for match in matches.reversed() {
            guard let mention = resolved[match.username.lowercased()] else { continue }
            guard NSMaxRange(match.range) <= value.length else { continue }
            // A handle that is already part of a pill, or that the markdown renderer
            // turned into a link with its own destination, is left alone.
            if value.attribute(.aorusAIMention, at: match.range.location, effectiveRange: nil) != nil { continue }
            var placed = mention
            placed.sourceText = source.substring(with: match.range)
            // The paragraph style of the run being replaced is kept, otherwise a pill in a
            // list item would reset that line's indentation and spacing.
            let paragraph = value.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil)
            let pillValue = NSMutableAttributedString(attributedString: pill(for: placed, font: font, accent: accent, link: link))
            if let paragraph {
                pillValue.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: pillValue.length))
            }
            value.replaceCharacters(in: match.range, with: pillValue)
            replaced += 1
        }
        return replaced
    }

    /// A one-line preview — a row in the conversation list, the caption of a quoted
    /// message — with every known handle written as the person's name in the accent
    /// colour.
    ///
    /// No avatar here on purpose: these lines live in scrolling rows, and a real
    /// `AvatarNode` per row costs more than a preview is worth. The name alone is already
    /// the difference between "расскажи про @durov" and "расскажи про Pavel Durov".
    static func previewText(_ source: String, color: UIColor, font: UIFont, accent: UIColor) -> NSAttributedString {
        let value = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: color])
        let matches = AorusAIMentionScanner.matches(in: source)
        guard !matches.isEmpty else { return value }
        let nameFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        for match in matches.reversed() {
            guard let cached = AorusAIMentionStore.shared.lookup(match.username) else { continue }
            guard NSMaxRange(match.range) <= value.length else { continue }
            value.replaceCharacters(in: match.range, with: NSAttributedString(
                string: cached.displayName,
                attributes: [.font: nameFont, .foregroundColor: accent]
            ))
        }
        return value
    }

    /// The lookup a renderer takes, built from whatever the screen has resolved so far.
    /// Entities that never resolved are simply absent, so their handle stays plain text
    /// rather than turning into a pill for a person who does not exist.
    static func map(from entities: [AorusAITelegramEntity]) -> [String: AorusAIMention] {
        var result: [String: AorusAIMention] = [:]
        for entity in entities {
            guard let username = entity.username?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")), !username.isEmpty else { continue }
            let key = username.lowercased()
            if let peerId = entity.peerId, peerId != 0, !entity.displayName.isEmpty {
                result[key] = AorusAIMention(
                    sourceText: entity.sourceText,
                    username: username,
                    peerId: peerId,
                    displayName: entity.displayName
                )
            } else if let cached = AorusAIMentionStore.shared.lookup(username) {
                // Resolution has not landed for this message yet, but this handle was
                // resolved earlier in the session — the pill appears immediately instead
                // of a beat later.
                result[key] = AorusAIMention(
                    sourceText: entity.sourceText,
                    username: username,
                    peerId: cached.peerId,
                    displayName: cached.displayName
                )
            }
        }
        return result
    }

    /// Everything in `text` that this session has already resolved.
    ///
    /// A message's own entities are only filled in once its turn has finished, so an
    /// answer that is still streaming would otherwise show plain handles until the last
    /// token arrived. Handles the user has just written about are in the cache, which is
    /// exactly the case where the model is most likely to write them back.
    static func cachedMap(in text: String) -> [String: AorusAIMention] {
        guard !text.isEmpty else { return [:] }
        var result: [String: AorusAIMention] = [:]
        let source = text as NSString
        for match in AorusAIMentionScanner.matches(in: text) {
            let key = match.username.lowercased()
            guard result[key] == nil, let cached = AorusAIMentionStore.shared.lookup(match.username) else { continue }
            result[key] = AorusAIMention(
                sourceText: source.substring(with: match.range),
                username: match.username,
                peerId: cached.peerId,
                displayName: cached.displayName
            )
        }
        return result
    }

    /// What a message renders with: its own resolved entities, plus anything else in its
    /// text the session already knows.
    static func map(entities: [AorusAITelegramEntity], text: String) -> [String: AorusAIMention] {
        var result = cachedMap(in: text)
        for (key, value) in map(from: entities) {
            result[key] = value
        }
        return result
    }

    /// A stable description of what a text would render as. The composer compares it
    /// against the last one it drew and rebuilds only when the pills themselves change —
    /// typing an ordinary character must never rewrite the input's attributed text under
    /// the user's caret.
    ///
    /// `plain` takes part in it: a handle held back because it is being typed and the same
    /// handle drawn as its person are two different pictures of the same text, so moving
    /// the caret off the end of a handle has to count as a change even though not one
    /// character moved.
    static func signature(source: String, resolved: [String: AorusAIMention], plain: NSRange? = nil) -> String {
        var parts: [String] = []
        let nsSource = source as NSString
        for match in AorusAIMentionScanner.matches(in: source) {
            if let plain, NSEqualRanges(plain, match.range) { continue }
            guard let mention = resolved[match.username.lowercased()] else { continue }
            parts.append("\(mention.peerId)/\(nsSource.substring(with: match.range))/\(mention.displayName)")
        }
        if let plain {
            parts.append("typing@\(plain.location),\(plain.length)")
        }
        return parts.joined(separator: "|")
    }

    /// The handle the caret is still inside, if there is one.
    ///
    /// "Still inside" is deliberately narrow: the caret has to sit at the very end of the
    /// handle *and* the handle has to run to the end of the text. Both together are the
    /// one state that means the user has not finished writing it — anywhere else, the
    /// handle is followed by something they have already typed, so it is finished and is
    /// drawn as the person.
    ///
    /// Parking the caret behind a finished pill therefore leaves it a pill, which is what
    /// makes a single backspace able to delete the whole person: a pill that dissolved
    /// back into its letters as soon as the caret arrived would only ever lose its last
    /// letter.
    static func handleBeingTyped(source: String, caret: Int) -> NSRange? {
        let length = (source as NSString).length
        guard caret == length, length > 0 else { return nil }
        for match in AorusAIMentionScanner.matches(in: source) where NSMaxRange(match.range) == length {
            return match.range
        }
        return nil
    }
}

/// The pictures the pills are drawn with.
///
/// A pill is built synchronously — it is one run inside an attributed string that has to
/// exist the moment the text does — while a peer's photo arrives whenever the network and
/// the media box get to it. So every mention is drawn immediately with a monogram, the real
/// photo is fetched once per peer and size, and the views holding pills are told to swap
/// the picture in when it lands. Keyed by peer, diameter and ring colour, because the same
/// person appears at one size in an answer and another in a quote.
final class AorusAIMentionAvatarCache {
    static let shared = AorusAIMentionAvatarCache()

    /// Posted when a photo has been drawn, so text already on screen can pick it up.
    static let changedNotification = Notification.Name("aorusgram.ai.mentionAvatar")

    private struct Key: Hashable {
        var peerId: Int64
        var diameter: Int
        var ring: Int
    }

    private var images: [Key: UIImage] = [:]
    /// Monograms are cached too, so a miss returns the *same* instance every time. Without
    /// this, every pill whose photo had not arrived was re-rendered from scratch on every
    /// change notification, and the identity check that is supposed to skip an unchanged
    /// attachment never matched.
    private var monograms: [Key: UIImage] = [:]
    private var pending: Set<Key> = []
    private var disposables: [Key: Disposable] = [:]
    /// Order of use, oldest first, for eviction.
    private var order: [Key] = []
    private weak var context: AccountContext?
    private static let limit = 256

    private init() {}

    /// The account the photos are read through. Set by whichever screen draws first; the
    /// cache holds it weakly, so it never keeps a logged-out account alive.
    func use(context: AccountContext) {
        self.context = context
    }

    /// The picture for one mention right now: the real photo when it has been drawn, and
    /// the monogram until then. Never nil, so a pill is never an empty hole.
    func image(for mention: AorusAIMention, diameter: CGFloat, ring: UIColor) -> UIImage {
        let key = Key(peerId: mention.peerId, diameter: Int(diameter.rounded()), ring: Int(ring.aorusRGBAKey))
        if let image = images[key] {
            touch(key)
            return image
        }
        request(key: key, mention: mention, diameter: diameter, ring: ring)
        if let cached = monograms[key] {
            return cached
        }
        let drawn = AorusAIMentionAvatarCache.monogram(
            letters: AorusAIMentionRenderer.letters(for: mention.displayName),
            diameter: diameter,
            ring: ring
        )
        if monograms.count >= AorusAIMentionAvatarCache.limit {
            monograms.removeAll(keepingCapacity: true)
        }
        monograms[key] = drawn
        return drawn
    }

    private func request(key: Key, mention: AorusAIMention, diameter: CGFloat, ring: UIColor) {
        guard let context, !pending.contains(key) else { return }
        pending.insert(key)
        let peerId = PeerId(mention.peerId)
        let inner = diameter - AorusAIMentionAvatarCache.ringWidth * 2.0
        // The context is captured weakly inside the signal as well as outside it. This object
        // lives for the whole process and keeps the disposable, so a strong capture here made
        // an in-flight fetch hold the account, its postbox and its network stack alive after a
        // logout — the exact thing the weak property above is there to prevent.
        let signal = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> mapToSignal { [weak context] peer -> Signal<UIImage?, NoError> in
            guard let peer, let context else { return .single(nil) }
            return peerAvatarCompleteImage(
                account: context.account,
                peer: peer,
                size: CGSize(width: inner, height: inner)
            )
        }
        |> deliverOnMainQueue
        // `pending` is cleared on completion as well as on a value. A signal that finishes
        // without emitting — a peer the account does not know, a disposed upstream — used to
        // leave the key marked pending for the life of the process, and every later request
        // for that person returned early: the pill kept its monogram for good.
        let disposable = signal.start(next: { [weak self] photo in
            guard let self else { return }
            self.pending.remove(key)
            guard let photo else { return }
            self.store(key: key, image: AorusAIMentionAvatarCache.ringed(photo: photo, diameter: diameter, ring: ring))
            NotificationCenter.default.post(name: AorusAIMentionAvatarCache.changedNotification, object: nil)
        }, completed: { [weak self] in
            self?.pending.remove(key)
        })
        // Assigned after `start`, never during it: a signal that delivers synchronously would
        // otherwise have its entry overwritten by this line and leak the finished disposable.
        disposables[key]?.dispose()
        disposables[key] = disposable
    }

    /// Marks a key as most recently used.
    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    /// Least-recently-used eviction, a quarter of the cache at a time.
    ///
    /// It used to empty the whole dictionary on overflow and then post a change
    /// notification, so crossing 256 people made every avatar on screen pop back to a letter
    /// at once and then trickle in again.
    private func store(key: Key, image: UIImage) {
        if images.count >= AorusAIMentionAvatarCache.limit {
            let drop = max(1, AorusAIMentionAvatarCache.limit / 4)
            for stale in order.prefix(drop) {
                images.removeValue(forKey: stale)
            }
            order.removeFirst(min(drop, order.count))
        }
        images[key] = image
        touch(key)
    }

    static let ringWidth: CGFloat = 1.5

    /// The photo inside its ring.
    private static func ringed(photo: UIImage, diameter: CGFloat, ring: UIColor) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let inset = ringWidth
            let inner = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            // The clip is scoped rather than reset, so the ring below is stroked against a
            // clean state whatever the renderer handed us.
            rendererContext.cgContext.saveGState()
            UIBezierPath(ovalIn: inner).addClip()
            photo.draw(in: inner)
            rendererContext.cgContext.restoreGState()
            let stroke = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: inset / 2.0, dy: inset / 2.0))
            stroke.lineWidth = inset
            ring.setStroke()
            stroke.stroke()
        }
    }

    /// One or two letters on a tint of the ring colour, drawn while the photo is on its
    /// way and kept for peers who have no photo at all.
    private static func monogram(letters: [String], diameter: CGFloat, ring: UIColor) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let text = letters.joined()
        return UIGraphicsImageRenderer(size: size).image { _ in
            let inset = ringWidth
            let inner = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            ring.withAlphaComponent(0.18).setFill()
            UIBezierPath(ovalIn: inner).fill()
            let stroke = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: inset / 2.0, dy: inset / 2.0))
            stroke.lineWidth = inset
            ring.setStroke()
            stroke.stroke()
            let font = UIFont.systemFont(ofSize: max(7.0, diameter * 0.42), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ring]
            let bounds = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: (size.width - bounds.width) / 2.0, y: (size.height - bounds.height) / 2.0),
                withAttributes: attributes
            )
        }
    }
}

private extension UIColor {
    /// A cheap identity for a colour, so two pills asking for the same ring share a picture.
    var aorusRGBAKey: Int {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        return (Int(red * 255.0) << 24) | (Int(green * 255.0) << 16) | (Int(blue * 255.0) << 8) | Int(alpha * 255.0)
    }
}

/// A text view whose pills pick up their photos when those arrive.
///
/// TextKit 1 is requested explicitly through the designated initializer: on iOS 16 and
/// later `UITextView` defaults to TextKit 2, where `layoutManager` exists only as a
/// compatibility shim that silently migrates the view the first time it is touched.
class AorusAIMentionTextView: UITextView, UIGestureRecognizerDelegate {
    private var avatarObserver: NSObjectProtocol?
    private weak var aorusMentionTap: UITapGestureRecognizer?

    /// Builds one with its own TextKit 1 stack.
    ///
    /// A factory rather than a bare `init()`: overriding the designated initializer keeps
    /// every inherited `UITextView` initializer available, which a new designated one
    /// would take away.
    static func make() -> AorusAIMentionTextView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0.0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return AorusAIMentionTextView(frame: .zero, textContainer: container)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // The recogniser must be invisible to every touch that is not on a pill.
        //
        // This class is the composer as well as the answer, and a bare recogniser added
        // to a UITextView competes with the text interaction that makes it first
        // responder — which is how tapping the AorusAI input stopped opening the
        // keyboard. `gestureRecognizerShouldBegin` below refuses the touch unless it
        // landed on a mention, so for every ordinary tap this recogniser never starts
        // and the field behaves exactly as it did before it existed; the delegate also
        // allows simultaneous recognition so that even on a pill nothing is starved.
        let tap = UITapGestureRecognizer(target: self, action: #selector(aorusHandleMentionTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        aorusMentionTap = tap
        addGestureRecognizer(tap)
        avatarObserver = NotificationCenter.default.addObserver(
            forName: AorusAIMentionAvatarCache.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMentionImages()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let avatarObserver {
            NotificationCenter.default.removeObserver(avatarObserver)
        }
    }

    func configureMentions(context: AccountContext, theme: PresentationTheme) {
        AorusAIMentionAvatarCache.shared.use(context: context)
        refreshMentionImages()
    }

    /// Copying a pill yields the handle that was written, not the name that is drawn.
    ///
    /// A pill's characters *are* the person's display name — that is what the layout has
    /// to draw — so the system's own copy puts "Durov" on the pasteboard when what was
    /// typed, and the only thing that can be pasted back and resolved again, is "@monk".
    /// Every pill run already carries its `AorusAIMentionBox`, so the handle is there to
    /// be put back; this walks the selection and swaps each run for it.
    ///
    /// Only the pill's own drawn length is swapped. Characters typed straight after a pill
    /// inherit its attributes and join the run, and those are the reader's own text.
    override func copy(_ sender: Any?) {
        guard let text = aorusSourceText(in: selectedRange), !text.isEmpty else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = text
    }

    /// The selection as LaTeX, for pasting somewhere that understands it.
    ///
    /// Every drawn formula carries the source it was set from, so this is the formula itself
    /// rather than a description of it. Text around the formulas comes along as it reads.
    @objc func aorusCopyLaTeX(_ sender: Any?) {
        let text = aorusText(in: selectedRange, preferringLaTeX: true)
        guard let text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    /// True when the selection has a drawn formula in it, which is when offering LaTeX makes
    /// any sense at all.
    func aorusSelectionCarriesMaths() -> Bool {
        return aorusCarriesMaths(in: selectedRange)
    }

    func aorusCarriesMaths(in range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return false }
        var found = false
        textStorage.enumerateAttribute(.aorusAIMathLaTeX, in: range, options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(aorusCopyLaTeX(_:)) {
            return aorusSelectionCarriesMaths()
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Cut is a copy and a deletion, and it must put the same thing on the pasteboard.
    ///
    /// The deletion is left to UIKit — it owns the caret, the undo stack and the delegate
    /// round trip — and only what it wrote to the pasteboard is corrected afterwards.
    override func cut(_ sender: Any?) {
        let text = aorusSourceText(in: selectedRange)
        super.cut(sender)
        if let text, !text.isEmpty {
            UIPasteboard.general.string = text
        }
    }

    /// The selected text with every pill restored to its `@handle`.
    ///
    /// Returns nil when the selection carries no pill at all, so the ordinary path is left
    /// to UIKit rather than reimplemented.
    func aorusSourceText(in range: NSRange) -> String? {
        return aorusText(in: range, preferringLaTeX: false)
    }

    /// The selected text with every pill restored to its `@handle` and every drawn formula
    /// restored to what it reads as — or, when asked, to the LaTeX it was set from.
    ///
    /// Returns nil when the selection carries neither, so the ordinary path is left to UIKit
    /// rather than reimplemented.
    func aorusText(in range: NSRange, preferringLaTeX: Bool) -> String? {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return nil }
        var carriesMention = false
        var result = ""
        var cursor = range.location
        let end = NSMaxRange(range)
        let string = textStorage.string as NSString
        while cursor < end {
            var effective = NSRange(location: 0, length: 0)
            // A drawn formula first: it is one character, and that character is OBJECT
            // REPLACEMENT. Copying it as itself is what puts an empty box on the pasteboard.
            let latex = textStorage.attribute(.aorusAIMathLaTeX, at: cursor, effectiveRange: nil) as? String
            let plain = textStorage.attribute(.aorusAIMathText, at: cursor, effectiveRange: nil) as? String
            if latex != nil || plain != nil {
                carriesMention = true
                result += (preferringLaTeX ? latex : plain) ?? plain ?? latex ?? ""
                cursor += 1
                continue
            }
            let box = textStorage.attribute(.aorusAIMention, at: cursor, effectiveRange: &effective) as? AorusAIMentionBox
            if let box, box.renderedLength > 0 {
                // The pill's own extent, which is not the whole attribute run: characters
                // typed straight after a pill inherit its attributes and join the run, and
                // those are the reader's own text.
                let pill = NSRange(location: effective.location, length: min(box.renderedLength, effective.length))
                if NSLocationInRange(cursor, pill) || cursor == pill.location {
                    // ANY overlap is enough, and this is the correction.
                    //
                    // Long-pressing a mention selects the *word* — "Durov" — not the whole
                    // pill, so a selection almost never begins on the attachment. Requiring
                    // that it did meant the common case fell through and the drawn name went
                    // to the pasteboard instead of the handle that was typed.
                    carriesMention = true
                    result += "@" + box.mention.username
                    cursor = min(NSMaxRange(pill), end)
                    // A selection that ends inside the pill has now consumed all of it; the
                    // handle is whole or it is nothing.
                    if cursor >= end { break }
                    continue
                }
                // Past the pill: the tail of the run is ordinary typed text.
                let tail = min(NSMaxRange(effective), end)
                let taken = max(1, tail - cursor)
                result += string.substring(with: NSRange(location: cursor, length: min(taken, end - cursor)))
                cursor += min(taken, end - cursor)
                continue
            }
            let next = min(NSMaxRange(effective), end)
            let taken = max(1, next - cursor)
            result += string.substring(with: NSRange(location: cursor, length: min(taken, end - cursor)))
            cursor += min(taken, end - cursor)
        }
        return carriesMention ? result : nil
    }

    /// Raised when a pill is tapped, carrying the person it stands for.
    ///
    /// The pill is no longer a `.link`, so this is how a tap reaches the profile. Doing it
    /// with a recogniser instead of a link attribute is what removes the long-press preview
    /// UIKit builds for link ranges — the one that crashed on a run starting with a text
    /// attachment.
    var onMentionTap: ((AorusAIMention) -> Void)?

    /// The pill under `point`, in this view's coordinates, or nil.
    private func mention(at point: CGPoint) -> AorusAIMention? {
        guard textStorage.length > 0 else { return nil }
        var location = point
        location.x -= textContainerInset.left
        location.y -= textContainerInset.top
        guard location.x >= 0.0, location.y >= 0.0 else { return nil }
        let index = layoutManager.characterIndex(
            for: location,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index >= 0, index < textStorage.length else { return nil }
        // `characterIndex(for:...)` answers with the nearest character even when the point
        // is past the end of a line, so the glyph actually under the finger is confirmed
        // before a tap is claimed.
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        guard rect.insetBy(dx: -2.0, dy: -2.0).contains(location) else { return nil }
        guard let box = textStorage.attribute(.aorusAIMention, at: index, effectiveRange: nil) as? AorusAIMentionBox else {
            return nil
        }
        return box.mention
    }

    /// Only ever begins on a pill. Everything else — placing the caret, focusing the
    /// composer, starting a selection, dragging the scroll view — is left entirely to
    /// UIKit, which is why anything that is not our own recogniser goes to `super`:
    /// `UIScrollView` gates its own pan recogniser here.
    override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === aorusMentionTap else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard onMentionTap != nil else { return false }
        return mention(at: gestureRecognizer.location(in: self)) != nil
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return gestureRecognizer === aorusMentionTap || other === aorusMentionTap
    }

    @objc private func aorusHandleMentionTap(_ recognizer: UITapGestureRecognizer) {
        guard let handler = onMentionTap else { return }
        guard let mention = mention(at: recognizer.location(in: self)) else { return }
        handler(mention)
    }

    /// Asked before the system deletes anything backwards. Returning true means the pill
    /// under the caret was taken out whole and UIKit must not act again.
    var onDeleteBackward: (() -> Bool)?

    /// One tap of the backspace key removes the whole person.
    ///
    /// This has to be caught here rather than in
    /// `textView(_:shouldChangeTextIn:replacementText:)`, which already knows how to widen
    /// an edit to cover a pill: a pill begins with a text attachment, and UIKit's own
    /// backspace handling for a run containing one selects it first and deletes it on the
    /// *second* press — a selection change, not a text change, so the delegate is never
    /// consulted and the widening never runs. Overriding the key itself is what makes the
    /// first press the only one needed.
    ///
    /// Only a bare caret standing immediately after a pill is claimed. A real selection,
    /// or a caret with ordinary text behind it, is left to `super`, which still goes
    /// through the delegate.
    override func deleteBackward() {
        if onDeleteBackward?() == true {
            return
        }
        super.deleteBackward()
    }

    /// The pill that ends exactly at `caret`, or nil if the caret is not standing right
    /// behind one.
    ///
    /// The run carrying the attribute is not always the pill alone: characters typed
    /// straight after a pill inherit its attributes and merge into the run, which is why
    /// the box records the pill's own drawn length. Those characters are the user's own
    /// text and backspace must take them one at a time, so the run is trimmed to the pill
    /// and claimed only when the caret is at the pill's own end.
    func mentionRun(endingAt caret: Int) -> NSRange? {
        guard caret > 0, caret <= textStorage.length else { return nil }
        var effective = NSRange(location: 0, length: 0)
        guard let box = textStorage.attribute(.aorusAIMention, at: caret - 1, effectiveRange: &effective) as? AorusAIMentionBox else { return nil }
        guard effective.length > 0, box.renderedLength > 0 else { return nil }
        let run = NSRange(location: effective.location, length: min(effective.length, box.renderedLength))
        guard NSMaxRange(run) == caret else { return nil }
        return run
    }

    /// Swaps a newly drawn photo into the pills already on screen.
    ///
    /// The attachment is edited in place and only its glyph is invalidated, so a photo
    /// landing mid-answer does not relayout the text or disturb the caret.
    func refreshMentionImages() {
        let storage = textStorage
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.aorusAIMention, in: full, options: []) { value, range, _ in
            guard let box = value as? AorusAIMentionBox, range.length > 0 else { return }
            guard let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else { return }
            let diameter = attachment.bounds.height
            guard diameter > 0.0 else { return }
            let ring = (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor) ?? .systemBlue
            let image = AorusAIMentionAvatarCache.shared.image(for: box.mention, diameter: diameter, ring: ring)
            guard attachment.image !== image else { return }
            attachment.image = image
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: range.location, length: 1))
        }
    }

    /// Grows an edit range so it always covers whole pills.
    ///
    /// Backspacing into `Pavel Durov` must delete the person, not the last letter of a
    /// name that would then no longer match anything.
    func rangeCoveringMentions(_ range: NSRange) -> NSRange {
        let length = textStorage.length
        guard length > 0 else { return range }
        let start = max(0, min(range.location, length))
        let end = max(start, min(NSMaxRange(range), length))
        var lower = start
        var upper = end

        if end > start {
            // A deletion or a replacement. Every pill it would cut in half is taken whole:
            // backspacing at the end of `Pavel Durov` deletes the person, not the "v" that
            // would leave a name standing for nobody.
            var index = start
            while index < end {
                var effective = NSRange(location: 0, length: 0)
                let attribute = textStorage.attribute(.aorusAIMention, at: index, effectiveRange: &effective)
                if attribute != nil {
                    lower = min(lower, effective.location)
                    upper = max(upper, NSMaxRange(effective))
                }
                index = max(NSMaxRange(effective), index + 1)
            }
        } else if start > 0, start < length {
            // An insertion. Only a caret that has been put *inside* a pill is a problem —
            // typing there would leave half a name carrying a source handle it no longer
            // spells. A caret resting against either edge simply types next to it, and
            // must not disturb the pill at all.
            var effective = NSRange(location: 0, length: 0)
            if textStorage.attribute(.aorusAIMention, at: start, effectiveRange: &effective) != nil,
               start > effective.location {
                lower = effective.location
                upper = NSMaxRange(effective)
            }
        }
        return NSRange(location: lower, length: upper - lower)
    }
}
