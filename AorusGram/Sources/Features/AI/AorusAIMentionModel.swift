import Foundation

// The part of AorusAI's inline mentions that has nothing to do with drawing: what a
// resolved handle is, how a handle is found in text, how the text the user actually wrote
// is recovered from a rendering that shows people instead of handles, and what this
// session has already looked up.
//
// It lives in the core module rather than next to the views so the release preflight can
// typecheck it and run tests against it. The regex that decides what counts as a handle,
// and the walk that turns pills back into the string the transport sends, are the two
// pieces where being subtly wrong is both easy and invisible.

/// One handle that has been resolved to a real peer.
public struct AorusAIMention: Equatable {
    /// Exactly what was written: `@durov`, `t.me/durov`, `https://t.me/durov/12`.
    public var sourceText: String
    public var username: String
    public var peerId: Int64
    public var displayName: String

    public init(sourceText: String, username: String, peerId: Int64, displayName: String) {
        self.sourceText = sourceText
        self.username = username
        self.peerId = peerId
        self.displayName = displayName
    }
}

/// Box for the attributed-string attribute.
///
/// Deliberately without an `isEqual(_:)` override: `NSAttributedString` merges adjacent
/// runs whose attribute values compare equal, and identity comparison is what keeps two
/// mentions written one after another — `@durov @durov` — as two runs instead of one, which
/// is the difference between rebuilding the source text correctly and silently dropping a
/// handle.
public final class AorusAIMentionBox: NSObject {
    public let mention: AorusAIMention
    /// How many UTF-16 units the pill occupied when it was drawn.
    ///
    /// A run carrying this box is not necessarily still just the pill. `UITextView` re-reads
    /// `typingAttributes` from the character before the caret whenever the selection moves,
    /// so text typed straight after a pill inherits this very attribute and merges into its
    /// run — and rebuilding the source from the run as a whole then replaced the typed
    /// characters with the handle and threw them away. The length says where the pill ends
    /// and the user's own text begins.
    public let renderedLength: Int

    public init(_ mention: AorusAIMention, renderedLength: Int) {
        self.mention = mention
        self.renderedLength = max(0, renderedLength)
    }
}

extension NSAttributedString.Key {
    public static let aorusAIMention = NSAttributedString.Key("AorusAIMention")
    /// What a drawn formula reads as. A drawing occupies one OBJECT REPLACEMENT CHARACTER,
    /// and copying that character gives a reader nothing, so the text form travels with it.
    public static let aorusAIMathText = NSAttributedString.Key("AorusAIMathText")
    /// And the same formula as LaTeX, for pasting somewhere that understands it.
    public static let aorusAIMathLaTeX = NSAttributedString.Key("AorusAIMathLaTeX")
    /// The inside of an inline code span. What is written in code is shown as written, so
    /// every pass that would otherwise read a marker, a link or a handle there leaves it be.
    public static let aorusAICodeSpan = NSAttributedString.Key("AorusAICodeSpan")
}

extension NSAttributedString {
    /// The text as it was written, with every pill collapsed back to its source handle.
    ///
    /// This — never what is on screen — is the draft, the transport text and the string
    /// mentions are scanned in, so drawing a person in place of a handle can never change
    /// what leaves the device.
    public var aorusAIPlainText: String {
        guard length > 0 else { return "" }
        let source = string as NSString
        var result = ""
        enumerateAttribute(.aorusAIMention, in: NSRange(location: 0, length: length), options: []) { value, range, _ in
            guard let box = value as? AorusAIMentionBox else {
                result += source.substring(with: range)
                return
            }
            // `enumerateAttribute` hands back maximal runs of one attribute value, and a run
            // carrying a pill's box can be longer than the pill: anything typed straight
            // after it inherits the attribute from `typingAttributes` and merges in. Only the
            // pill's own units collapse to the handle; whatever follows is the user's text
            // and is taken verbatim. Emitting the handle for the whole run is what silently
            // dropped it from the message that was sent.
            let pill = min(box.renderedLength, range.length)
            result += box.mention.sourceText
            if range.length > pill {
                result += source.substring(with: NSRange(location: range.location + pill, length: range.length - pill))
            }
        }
        return result
    }
}

/// Finds Telegram handles in plain text.
///
/// Both spellings are recognised everywhere: the bare `@name` and the link form, with or
/// without a scheme and with or without a trailing message id. The floor is four
/// characters, not five: Telegram sells four-letter usernames through Fragment and they
/// are exactly the ones people write about.
public enum AorusAIMentionScanner {
    public struct Match: Equatable {
        public var range: NSRange
        public var username: String

        public init(range: NSRange, username: String) {
            self.range = range
            self.username = username
        }
    }

    private static let expressions: [NSRegularExpression] = {
        let patterns = [
            // Not after a word character, so an e-mail address is not read as a mention,
            // and not after another @.
            #"(?<![\w@])@([A-Za-z0-9_]{4,32})(?![A-Za-z0-9_])"#,
            // The reserved paths are excluded by name. `t.me/joinchat/AAAA` is an invite
            // link, not a person, and reading it as one turned the link into a pill of a
            // user called "joinchat" followed by a loose `/AAAA`. Same for sticker packs,
            // themes, proxies and the rest of Telegram's own routes.
            #"(?<![\w@/.])(?:https?://)?t\.me/(?:s/)?(?!(?:joinchat|addstickers|addemoji|addtheme|setlanguage|proxy|socks|share|confirmphone|login|invoice|giftcode|boost|contact|bg|c|iv)(?![A-Za-z0-9_]))([A-Za-z0-9_]{4,32})(?:/\d+)?(?![A-Za-z0-9_])"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// Every handle in `text`, in the order it appears, never overlapping.
    public static func matches(in text: String) -> [Match] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var result: [Match] = []
        var occupied: [NSRange] = []
        for expression in expressions {
            for match in expression.matches(in: text, range: full) {
                guard match.numberOfRanges > 1 else { continue }
                guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                occupied.append(match.range)
                result.append(Match(range: match.range, username: source.substring(with: match.range(at: 1))))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
}

/// Handles this session has already resolved.
///
/// "Instantly" is only possible for a handle whose peer is already known, so every
/// resolution is remembered: the second time the same name is written — in the input, in
/// the next question, in the model's answer — the pill is drawn in the same frame, with no
/// round trip and no flicker from plain text to pill.
public final class AorusAIMentionStore {
    public static let shared = AorusAIMentionStore()

    private let lock = NSLock()
    private var entries: [String: (peerId: Int64, displayName: String)] = [:]
    private var order: [String] = []
    private static let limit = 512

    private init() {}

    public func lookup(_ username: String) -> (peerId: Int64, displayName: String)? {
        let key = username.lowercased()
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    public func store(username: String, peerId: Int64, displayName: String) {
        let key = username.lowercased()
        guard !key.isEmpty, peerId != 0, !displayName.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
            if order.count > Self.limit {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[key] = (peerId: peerId, displayName: displayName)
    }
}
