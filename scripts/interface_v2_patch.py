"""Interface 2.0: native glass, centred header, frosted placeholders.

Everything here restyles code Telegram already ships rather than drawing a replacement.
The glass is Telegram's own `GlassBackgroundView`, which resolves to `UIGlassEffect(style:
.regular)` on the iOS 26 SDK and to its `LegacyGlassView` below it. That matters for three
reasons: it is the actual system material rather than a blur with a white sheen painted on
top, it needs no SDK shims of ours, and it already answers to the fork's global glass
toggle. `TintColor(kind: .clear)` is the variant with no tint, no rim and no inner fill.

Anchors in this file were checked byte for byte against Telegram-iOS at the pinned commit.
A missing one raises, which fails the build in seconds instead of an hour into compilation.
"""

from pathlib import Path

INTERFACE_V2_KEY = "aorusgram_interface_v2"

_GLASS_IMPORT = "import GlassBackgroundComponent\n"


def _replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"InterfaceV2: missing {label} anchor")
    return text.replace(old, new, 1)


def _replace_span(text: str, start: str, end: str, new: str, label: str) -> str:
    """Swap out everything from `start` through `end`, both ends included.

    For replacing a whole function whose middle is not worth transcribing: upstream's own text is
    still the anchor at both ends, so a rebase that touches either one fails here instead of
    quietly leaving the old body in place.
    """
    first = text.find(start)
    if first < 0:
        raise RuntimeError(f"InterfaceV2: missing {label} start anchor")
    last = text.find(end, first)
    if last < 0:
        raise RuntimeError(f"InterfaceV2: missing {label} end anchor")
    return text[:first] + new + text[last + len(end):]


def _read(path: Path, label: str) -> str:
    if not path.is_file():
        raise RuntimeError(f"InterfaceV2: {label} is missing")
    return path.read_text(encoding="utf-8")


def _add_build_deps(build: Path, deps: list, label: str) -> None:
    text = _read(build, f"{label} BUILD")
    missing = [dep for dep in deps if f'"{dep}"' not in text]
    if not missing:
        print(f"InterfaceV2: {label} dependencies already present")
        return
    anchor = "    deps = [\n"
    if anchor not in text:
        raise RuntimeError(f"InterfaceV2: {label} BUILD deps anchor is missing")
    insertion = "".join(f'        "{dep}",\n' for dep in missing)
    build.write_text(text.replace(anchor, anchor + insertion, 1), encoding="utf-8")
    print(f"InterfaceV2: added {label} dependencies")


_GLASS_THEME_SWIFT = '''

// MARK: - AorusGram Interface 2.0

// One derived theme instead of a patch per row. Every list row on both the settings screens
// and the peer-info screen paints itself from PresentationThemeList, so substituting that one
// struct turns all of them white-on-glass at once -- and leaves them exactly as Telegram drew
// them the moment Interface 2.0 is switched off.
//
// The derived theme has to be cached. Both ItemListPresentationData and the item nodes compare
// themes by identity (===), so handing out a fresh instance per read would make every
// comparison report a change and every list relayout itself on every pass.

private let aorusInterfaceV2Key = "__V2KEY__"

/// How a block finds out it is a block.
///
/// Under Interface 2.0 a row paints no fill of its own: the material comes from one real
/// `GlassBackgroundView` laid behind the whole run of rows that share a section, because a card that
/// paints anything over that material flattens it back into the opaque panel it used to be.
///
/// Which leaves the problem of knowing where the runs are, and there is no answer to that in any one
/// place -- a block is however many consecutive rows happen to share a section id, and each of those
/// rows is drawn by one of dozens of item classes spread across the app. So the fill becomes a
/// marker instead of a colour. Every blocks-style row in Telegram fills its background node with
/// `itemBlocksBackgroundColor`, so handing them this colour makes the nodes wearing it exactly the
/// set of card rectangles, already laid out, already overlapping their neighbours by the hairline
/// that joins them. `ItemListControllerNode` reads them back and groups them.
///
/// It is a colour rather than a flag because a colour is what those hundreds of assignments already
/// pass around, and it is 1/255 of an alpha rather than `.clear` because `.clear` is a value plenty
/// of unrelated code also produces -- this one nothing else in the app can be mistaken for, and at
/// that alpha it is invisible on any background.
public enum AorusGlassPane {
    public static var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: aorusInterfaceV2Key)
    }

    /// The two forms the marker takes: the page's own ink, at an alpha nothing can see.
    ///
    /// The first version of this was magenta, on the grounds that no other colour in the app could
    /// be mistaken for it. The alpha is what makes it unmistakable, though -- nothing else in
    /// Telegram builds a colour at 1/255 -- and the hue is the part that survives when somebody
    /// derives a new colour from a card: `withAlphaComponent(0.6)` over a row that cannot be
    /// tapped, `mixedWith` under an avatar placeholder, `.rgb` into a mini app's palette. Eighty
    /// odd places in the app do exactly that, and every one of them was turning the marker into
    /// magenta paint -- which is what the pink rectangle over an administrator's rights was. Ink at
    /// the same invisible alpha is still unique, and it is neutral everywhere it is amplified.
    ///
    /// Two of them because the amplified form has to fall on the right side of the pane it lands
    /// on: a wash over dark glass is dark, and over pale glass it is pale. That also puts every
    /// derivation back where upstream aimed it, since upstream's own card is near-black on a dark
    /// theme and near-white on a light one -- amplifying black or white lands within a shade of the
    /// colour that code was written for.
    public static let blockMarker = UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 / 255.0)
    public static let blockMarkerLight = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 / 255.0)

    /// Whether a colour is one of the two markers -- i.e. whether the node wearing it is a card.
    public static func isBlockMarker(_ color: UIColor) -> Bool {
        return color.isEqual(AorusGlassPane.blockMarker) || color.isEqual(AorusGlassPane.blockMarkerLight)
    }

    /// The wash a row gets when it has to read as unavailable.
    ///
    /// Upstream fills a disabled row with its own card colour at 40 to 60 percent, which on an
    /// opaque card is most of the way back to the page and reads as washed out. Under Interface 2.0
    /// the card is a marker, and `withAlphaComponent` replaces an alpha rather than scaling it: the
    /// same expression does not fade the marker, it makes it visible -- a slab of it at 60%, opaque
    /// enough to hide the material the row is sitting on. Which is the whole point of the row.
    ///
    /// So the wash is stated here instead: the page's own ink, deep enough to read as unavailable
    /// and shallow enough to leave the glass showing through.
    ///
    /// `ink` is the colour the row draws its text in, white on a dark pane and near-black on a pale
    /// one. Asking it rather than the theme is what lets one helper serve the settings lists and the
    /// profile, whose pane follows the avatar rather than the appearance.
    public static func rowWash(over color: UIColor, ink: UIColor, alpha: CGFloat) -> UIColor {
        guard AorusGlassPane.isBlockMarker(color) else {
            return color.withAlphaComponent(alpha)
        }
        return AorusGlassPane.isLight(ink) ? UIColor(white: 0.0, alpha: 0.25) : UIColor(white: 1.0, alpha: 0.5)
    }

    /// The radius the panes are drawn with, and the one the rows have to agree with when they clip
    /// their own content.
    public static let blockCornerRadius: CGFloat = 26.0

    /// The side inset a block needs when it has to read as a card on the page rather than a band
    /// across it. Upstream lays the editing header's name fields out edge to edge and rounds them
    /// only in landscape; a pane at `blockCornerRadius` needs room on both sides for the corner to
    /// be visible at all. Shared so the pane and the rows inside it cannot drift apart.
    public static let blockSideInset: CGFloat = 16.0

    // MARK: - Ink over the profile page

    /// Where the profile header publishes the colour it sampled off the avatar. Pinned against
    /// `AorusGlassProfileTint.pageKey`, which is the writing side.
    ///
    /// Read out of shared defaults rather than imported. The module that samples the avatar sits
    /// far above this one in the build graph -- it depends on ItemListUI, which depends on this --
    /// so an import in this direction closes a cycle and nothing links.
    public static let profilePageKey = "aorusgram_profile_page_background"

    /// Whether a colour is light enough that white text on it would be unreadable.
    ///
    /// Relative luminance rather than HSB brightness, because brightness is the largest of the
    /// three channels and calls pure blue as bright as pure white. The weights are the sRGB ones:
    /// the eye reads green as most of the light in a colour and blue as almost none of it.
    public static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return false
        }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55
    }

    /// The colour text and icons should be drawn in over `color`.
    ///
    /// Not quite black on the light side: a profile page is a photograph's own colour, and pure
    /// black over one reads as a hole punched in it where near-black reads as ink.
    public static func ink(over color: UIColor) -> UIColor {
        return AorusGlassPane.isLight(color) ? UIColor(white: 0.08, alpha: 1.0) : UIColor(white: 1.0, alpha: 1.0)
    }

    /// The page colour the profile is on right now, or nil before any avatar has been sampled.
    public static var profilePageColor: UIColor? {
        guard let value = UserDefaults.standard.object(forKey: AorusGlassPane.profilePageKey) as? Int else {
            return nil
        }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1.0
        )
    }

    /// True when the profile page wants light ink. Defaults to true, which is what an unsampled
    /// page is: the theme background, and the page a photo settles on is dark far more often than
    /// not.
    public static var profilePageIsDark: Bool {
        guard let color = AorusGlassPane.profilePageColor else {
            return true
        }
        return !AorusGlassPane.isLight(color)
    }

    /// Ink for everything drawn over the profile page: the name, the status, the header buttons,
    /// the selected tab. One place, so all of them flip together the moment the page does.
    public static var profilePageInk: UIColor {
        return AorusGlassPane.profilePageIsDark ? UIColor(white: 1.0, alpha: 1.0) : UIColor(white: 0.08, alpha: 1.0)
    }

    public static func profilePageInk(_ alpha: CGFloat) -> UIColor {
        return AorusGlassPane.profilePageIsDark ? UIColor(white: 1.0, alpha: alpha) : UIColor(white: 0.0, alpha: alpha)
    }

    /// The fill a control gets when it needs to be a shade off the page rather than a panel on it:
    /// the page's own ink at the alpha a pane of glass would have refracted to anyway.
    public static var profilePageScrim: UIColor {
        return AorusGlassPane.profilePageIsDark ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.1)
    }
}

private final class AorusGlassThemeCache {
    static let shared = AorusGlassThemeCache()

    /// One source theme, the ink it was derived for, and the result -- all three held strongly.
    ///
    /// Retaining the source is not an optimisation. This cache used to remember themes by
    /// `ObjectIdentifier` alone, and an object identifier is an address: the allocator hands it out
    /// again as soon as the object that held it is freed. Themes are minted and dropped constantly --
    /// `withModalBlocksBackground()` returns a brand new one on every emission of a modal screen's
    /// state, which on the folder screen is every keystroke and every tap -- so a fresh, underived
    /// theme could arrive at the address of a derived one that had just been released, be recognised
    /// as already derived, and be handed straight back untouched. Every block on that screen then
    /// painted its own opaque fill, the pane finder found no markers, and the screen came out as
    /// flat rectangles with no glass behind them. Holding the objects is what makes an identity
    /// comparison mean what it says.
    private final class Entry {
        let source: PresentationTheme
        let dark: Bool
        let derived: PresentationTheme

        init(source: PresentationTheme, dark: Bool, derived: PresentationTheme) {
            self.source = source
            self.dark = dark
            self.derived = derived
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func derive(from theme: PresentationTheme, dark: Bool) -> PresentationTheme {
        // Deriving from an already derived theme would compound the alpha of every colour. Which of
        // the two a theme is, it carries with it: the marker fill below is written by this method
        // and by nothing else in the app, so the test is exact and needs no memory of what was
        // handed out before -- and cannot be fooled by an address that has changed hands.
        if AorusGlassPane.isBlockMarker(theme.list.itemBlocksBackgroundColor) {
            return theme
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        for entry in self.entries {
            if entry.dark == dark && entry.source === theme {
                return entry.derived
            }
        }

        // Ink and pane, and both of them flip with the appearance. That flip is the whole of
        // light-theme support: black letters on a pale pane, where the dark theme has white
        // letters on a dark one. No border and no sheen in either -- those are the two things
        // that make a hand-drawn panel read as a fake next to the real material behind it.
        let ink: UIColor = dark ? UIColor(white: 1.0, alpha: 1.0) : UIColor(white: 0.0, alpha: 1.0)
        let hairline: UIColor = dark ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.1)
        func aorusInk(_ alpha: CGFloat) -> UIColor {
            return dark ? UIColor(white: 1.0, alpha: alpha) : UIColor(white: 0.0, alpha: alpha)
        }

        let list = theme.list.withUpdated(
            itemPrimaryTextColor: ink,
            // Full ink, not a dimmed shade of it. Interface 2.0 is one page of ink over one page
            // of colour, and every grey in the middle read as a third colour that belonged to
            // neither -- the phone number under a name, a section title, the caption under a
            // switch. Only the two placeholder shades below stay dim, because a field with no
            // value in it and a row that cannot be tapped are states rather than text.
            itemSecondaryTextColor: ink,
            itemDisabledTextColor: aorusInk(0.35),
            itemAccentColor: ink,
            itemPlaceholderTextColor: aorusInk(0.4),
            // The row paints no fill. What it paints instead is the marker the pane finder looks
            // for, so that a whole run of rows can be backed by one sheet of real glass. Every row
            // in the section carries it, not just the two at the ends, which is what stops a block
            // from coming out striped the way the corner-image version did.
            itemBlocksBackgroundColor: dark ? AorusGlassPane.blockMarker : AorusGlassPane.blockMarkerLight,
            itemModalBlocksBackgroundColor: dark ? AorusGlassPane.blockMarker : AorusGlassPane.blockMarkerLight,
            // A rectangular pressed fill leaks outside the rounded glass pane. Native controls
            // already provide their own interaction feedback, so the list itself stays clear.
            itemHighlightedBackgroundColor: .clear,
            itemBlocksSeparatorColor: hairline,
            itemPlainSeparatorColor: hairline,
            disclosureArrowColor: aorusInk(0.35),
            sectionHeaderTextColor: ink,
            freeTextColor: ink,
            controlSecondaryColor: aorusInk(0.2)
        )
        // A profile can contain a chat-list row: the personal channel a user pins to their page is
        // a real ChatListItem, laid out by ChatListUI inside a peer-info section. It takes its
        // colours from here and not from theme.list, which is why its last post stayed grey while
        // everything around it turned white -- the one complaint this block was reported for.
        let chatList = theme.chatList.withUpdated(
            itemSeparatorColor: hairline,
            itemBackgroundColor: .clear,
            pinnedItemBackgroundColor: .clear,
            itemHighlightedBackgroundColor: .clear,
            pinnedItemHighlightedBackgroundColor: .clear,
            titleColor: ink,
            secretTitleColor: ink,
            dateTextColor: ink,
            authorNameColor: ink,
            messageTextColor: ink,
            messageHighlightedTextColor: ink,
            messageDraftTextColor: ink,
            checkmarkColor: ink,
            muteIconColor: aorusInk(0.5),
            sectionHeaderTextColor: ink
        )
        let derived = PresentationTheme(
            name: theme.name,
            index: theme.index,
            referenceTheme: theme.referenceTheme,
            overallDarkAppearance: theme.overallDarkAppearance,
            intro: theme.intro,
            passcode: theme.passcode,
            rootController: theme.rootController,
            list: list,
            chatList: chatList,
            chat: theme.chat,
            actionSheet: theme.actionSheet,
            contextMenu: theme.contextMenu,
            inAppNotification: theme.inAppNotification,
            chart: theme.chart,
            preview: theme.preview
        )
        derived.forceSync = theme.forceSync
        derived.starGift = theme.starGift

        // Four, which is a modal screen's theme and the plain theme of the screen behind it in each
        // of the two inks. Oldest out first: a screen that mints a theme per emission wants the one
        // it asked for last, and the run of dead ones it left behind is what has to be let go of.
        self.entries.append(Entry(source: theme, dark: dark, derived: derived))
        if self.entries.count > 4 {
            self.entries.removeFirst(self.entries.count - 4)
        }
        return derived
    }
}

public extension PresentationTheme {
    /// Labels and panes for the settings lists: white on dark panes under a dark theme, black on
    /// pale ones under a light one.
    var aorusGlassListTheme: PresentationTheme {
        guard UserDefaults.standard.bool(forKey: aorusInterfaceV2Key) else {
            return self
        }
        return AorusGlassThemeCache.shared.derive(from: self, dark: self.overallDarkAppearance)
    }

    /// The same, for the peer-info list. The pair is chosen by the page the list sits on rather
    /// than by the theme: that page is the colour sampled off the avatar, so a pale photo gets
    /// black letters on it and a dark one white, whichever theme the app is in.
    var aorusGlassProfileTheme: PresentationTheme {
        guard UserDefaults.standard.bool(forKey: aorusInterfaceV2Key) else {
            return self
        }
        return AorusGlassThemeCache.shared.derive(from: self, dark: AorusGlassPane.profilePageIsDark)
    }

    /// A legible foreground for a badge filled with `fill`.
    ///
    /// Interface 2.0 makes `list.itemAccentColor` the page's own ink -- white letters on a dark pane,
    /// black on a pale one -- and most badges in the settings lists are filled with that accent,
    /// while the theme's own badge foreground stays white in both. The unread count beside an
    /// account in Settings therefore came out white on a white pill: legible only as the shape it
    /// left in the pane, which is what was reported.
    ///
    /// Answered from the fill rather than from a flag. A badge that carries a colour of its own --
    /// the red "!" on notifications, the blue pill on a new bot -- has legible white digits already
    /// and keeps them; only a badge whose fill has ended up on the same side of the ink as its own
    /// text is flipped, and it is flipped to that fill's opposite rather than to a fixed colour. Off
    /// Interface 2.0 this is not a derived theme and the stock colour is returned untouched, so the
    /// call sites need no test of their own.
    func aorusBadgeForegroundColor(over fill: UIColor?) -> UIColor {
        let stock = self.list.itemCheckColors.foregroundColor
        guard AorusGlassPane.isBlockMarker(self.list.itemBlocksBackgroundColor), let fill else {
            return stock
        }
        guard AorusGlassPane.isLight(fill) == AorusGlassPane.isLight(stock) else {
            return stock
        }
        return AorusGlassPane.ink(over: fill)
    }
}
'''


def _patch_glass_theme(tg: Path) -> None:
    path = tg / "submodules/TelegramPresentationData/Sources/PresentationTheme.swift"
    text = _read(path, "PresentationTheme.swift")
    if "aorusGlassListTheme" in text:
        print("InterfaceV2: glass theme already present")
        return
    if "public final class PresentationTheme: Equatable {" not in text:
        raise RuntimeError("InterfaceV2: PresentationTheme class declaration is missing")
    text = text.rstrip("\n") + "\n" + _GLASS_THEME_SWIFT.replace("__V2KEY__", INTERFACE_V2_KEY)
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: added the glass list theme")


def _patch_item_list_theme(tg: Path) -> None:
    """Route every settings list through the glass theme from the one place they share."""
    path = tg / "submodules/ItemListUI/Sources/ItemListItem.swift"
    text = _read(path, "ItemListItem.swift")
    if "aorusGlassListTheme" in text:
        print("InterfaceV2: settings lists already routed through the glass theme")
        return
    text = _replace_once(
        text,
        "        self.init(theme: presentationData.theme, fontSize: presentationData.listsFontSize,",
        "        // AorusGram: every ItemList screen in the app builds its rows from this one\n"
        "        // convenience init, which makes it the only place Interface 2.0 has to touch to\n"
        "        // restyle all of them.\n"
        "        self.init(theme: presentationData.theme.aorusGlassListTheme, fontSize: presentationData.listsFontSize,",
        "settings list theme",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: routed settings lists through the glass theme")


def _patch_profile_section_glass(tg: Path) -> None:
    """Put a real pane of glass behind each peer-info section.

    The stock section is an opaque rectangle in `itemBlocksBackgroundColor`. Interface 2.0
    keeps the rectangle's geometry -- it is what the rows are laid out against -- and swaps
    what fills it for `GlassBackgroundView`, sized and cornered from the same frame.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenItemSectionContainerNode.swift"
    text = _read(path, "PeerInfoScreenItemSectionContainerNode.swift")
    if "aorusGlassBackgroundView" in text:
        print("InterfaceV2: profile sections already glass")
        return
    if _GLASS_IMPORT not in text:
        # ComponentFlow alongside it: the `transition:` argument is a ComponentTransition, and
        # `.immediate` only resolves where that type is imported. Every other file this patch
        # touches already has it; this one does not.
        text = _replace_once(
            text,
            "import Display\n",
            "import Display\n" + _GLASS_IMPORT + "import ComponentFlow\n",
            "section glass import",
        )
    text = _replace_once(
        text,
        "    private let itemContainerNode: ASDisplayNode\n",
        "    private let itemContainerNode: ASDisplayNode\n"
        "    // AorusGram: created lazily, so a profile opened with Interface 2.0 off never pays\n"
        "    // for a visual effect view it will not show.\n"
        "    private var aorusGlassBackgroundView: GlassBackgroundView?\n",
        "section glass property",
    )
    text = _replace_once(
        text,
        "        self.backgroundNode.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor\n",
        "        // AorusGram: Interface 2.0 paints the section with the system glass material and\n"
        "        // hands the rows a theme whose labels are white, so the whole block reads as one\n"
        "        // pane rather than as tinted text on a tinted card.\n"
        "        let aorusGlass = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        var presentationData = presentationData\n"
        "        if aorusGlass {\n"
        "            presentationData = presentationData.withUpdated(theme: presentationData.theme.aorusGlassProfileTheme)\n"
        "        }\n"
        "        self.backgroundNode.backgroundColor = aorusGlass ? .clear : presentationData.theme.list.itemBlocksBackgroundColor\n",
        "section glass colours",
    )
    text = _replace_once(
        text,
        "        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentWithBackgroundOffset), size: CGSize(width: width, height: max(0.0, contentWithBackgroundHeight - contentWithBackgroundOffset))))\n",
        "        let aorusBackgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: contentWithBackgroundOffset), size: CGSize(width: width, height: max(0.0, contentWithBackgroundHeight - contentWithBackgroundOffset)))\n"
        "        transition.updateFrame(node: self.backgroundNode, frame: aorusBackgroundFrame)\n"
        "        if aorusGlass {\n"
        "            let glassView: GlassBackgroundView\n"
        "            if let current = self.aorusGlassBackgroundView {\n"
        "                glassView = current\n"
        "            } else {\n"
        "                glassView = GlassBackgroundView(frame: aorusBackgroundFrame)\n"
        "                glassView.isUserInteractionEnabled = false\n"
        "                self.aorusGlassBackgroundView = glassView\n"
        "                self.view.insertSubview(glassView, at: 0)\n"
        "            }\n"
        "            glassView.isHidden = aorusBackgroundFrame.height <= 0.0\n"
        "            transition.updateFrame(view: glassView, frame: aorusBackgroundFrame)\n"
        "            glassView.update(\n"
        "                size: aorusBackgroundFrame.size,\n"
        "                // 26, not 11: the rows in this section cut their corners at the radius\n"
        "                // Telegram uses for a glass block, and a pane rounded any tighter shows\n"
        "                // its own square shoulders outside theirs.\n"
        "                cornerRadius: hasCorners ? 26.0 : 0.0,\n"
        "                isDark: true,\n"
        "                tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        } else if let glassView = self.aorusGlassBackgroundView {\n"
        "            self.aorusGlassBackgroundView = nil\n"
        "            glassView.removeFromSuperview()\n"
        "        }\n",
        "section glass frame",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made profile sections glass")


_EDITING_FIELD_UPDATE_ANCHOR = (
    "    func update(width: CGFloat, safeInset: CGFloat, isSettings: Bool, hasPrevious: Bool,"
    " hasNext: Bool, placeholder: String, isEnabled: Bool, presentationData: PresentationData,"
    " updateText: String?) -> CGFloat {\n"
)


def _inset_editing_field(path: Path, label: str) -> None:
    """Move one editing text field in by the block inset when Interface 2.0 is on.

    Every frame in these nodes -- the fill, the text, the top separator, the clear button, the
    corner mask -- is laid out from `safeInset`, and `safeInset` is the horizontal safe area, which
    is zero in portrait. That is why the field is a full-width rectangle there. Widening the inset
    at the top of `update` moves all of those together, which is the whole reason to do it here
    rather than at each frame: there is one number to keep in step with the pane behind them.
    """
    text = _read(path, path.name)
    if "AorusGlassPane.blockSideInset" in text:
        print(f"InterfaceV2: editing {label} field already inset")
        return
    text = _replace_once(
        text,
        _EDITING_FIELD_UPDATE_ANCHOR,
        _EDITING_FIELD_UPDATE_ANCHOR
        + "        // AorusGram: Interface 2.0 draws this run of fields as a card on the profile\n"
        "        // page instead of a band across it. The pane of glass behind them is inset by\n"
        "        // AorusGlassPane.blockSideInset, so the row is inset by the same amount -- one\n"
        "        // shared constant, because a pane and its rows disagreeing by a point shows.\n"
        "        let safeInset = AorusGlassPane.isEnabled ? safeInset + AorusGlassPane.blockSideInset : safeInset\n",
        f"editing {label} field inset",
    )
    path.write_text(text, encoding="utf-8")
    print(f"InterfaceV2: inset the editing {label} field")


def _patch_editing_fields_glass(tg: Path) -> None:
    """Put the name and description fields of the editing header on glass.

    In edit mode the header keeps the profile page behind it, and the fields are the only block on
    that page still painted as an opaque card: their fill is `itemBlocksBackgroundColor` and their
    rounding comes from `PresentationResourcesItemList.cornersImage`, which Interface 2.0 returns
    nil for. So they end up a bare rectangle in list-background grey over the avatar's colour.

    The fix is the one every other block gets: hand the rows a derived theme, so the fill becomes
    the invisible marker colour and the labels become ink, and put a single `GlassBackgroundView`
    behind the whole run of them. One pane, not one per field -- the fields are rows of a block,
    and each of them carrying its own pane would show a seam at every separator.
    """
    base = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources"
    _inset_editing_field(base / "PeerInfoHeaderSingleLineTextFieldNode.swift", "single line")
    _inset_editing_field(base / "PeerInfoHeaderMultiLineTextFieldNode.swift", "multi line")

    path = base / "PeerInfoHeaderEditingContentNode.swift"
    text = _read(path, "PeerInfoHeaderEditingContentNode.swift")
    if "aorusFieldsGlassView" in text:
        print("InterfaceV2: editing header fields already glass")
        return
    if _GLASS_IMPORT not in text:
        # ComponentFlow with it: `transition:` on GlassBackgroundView.update is a ComponentTransition
        # and `.immediate` only resolves where that type is imported.
        text = _replace_once(
            text,
            "import Display\n",
            "import Display\n" + _GLASS_IMPORT + "import ComponentFlow\n",
            "editing header glass import",
        )
    text = _replace_once(
        text,
        "    var itemNodes: [PeerInfoHeaderTextFieldNodeKey: PeerInfoHeaderTextFieldNode] = [:]\n",
        "    var itemNodes: [PeerInfoHeaderTextFieldNodeKey: PeerInfoHeaderTextFieldNode] = [:]\n"
        "    // AorusGram: created lazily, so a profile edited with Interface 2.0 off never pays for\n"
        "    // a visual effect view it will not show.\n"
        "    private var aorusFieldsGlassView: GlassBackgroundView?\n",
        "editing header glass property",
    )
    text = _replace_once(
        text,
        "        let avatarSize: CGFloat = isModalOverlay ? 200.0 : 100.0\n",
        "        // AorusGram: the derived theme is what makes the rows readable on the page -- their\n"
        "        // fill becomes the marker colour the glass shows through, their text and cursor\n"
        "        // become ink, and their separators become a hairline of it. The Set Photo button\n"
        "        // above them takes its colour from the same accent, which is what puts it on the\n"
        "        // page rather than in the palette's blue.\n"
        "        let aorusGlass = AorusGlassPane.isEnabled\n"
        "        var presentationData = presentationData\n"
        "        if aorusGlass {\n"
        "            presentationData = presentationData.withUpdated(theme: presentationData.theme.aorusGlassProfileTheme)\n"
        "        }\n"
        "        let avatarSize: CGFloat = isModalOverlay ? 200.0 : 100.0\n",
        "editing header glass theme",
    )
    text = _replace_once(
        text,
        "        var hasPrevious = false\n",
        "        // Where the block starts: the loop below advances contentHeight field by field, so\n"
        "        // the pane spans from here to wherever it stops.\n"
        "        let aorusFieldsTop = contentHeight\n"
        "        var hasPrevious = false\n",
        "editing header glass top",
    )
    text = _replace_once(
        text,
        "        var removeKeys: [PeerInfoHeaderTextFieldNodeKey] = []\n",
        "        if aorusGlass && !fieldKeys.isEmpty {\n"
        "            let aorusInset = safeInset + AorusGlassPane.blockSideInset\n"
        "            let aorusGlassFrame = CGRect(\n"
        "                origin: CGPoint(x: aorusInset, y: aorusFieldsTop),\n"
        "                size: CGSize(width: max(1.0, width - aorusInset * 2.0), height: max(0.0, contentHeight - aorusFieldsTop))\n"
        "            )\n"
        "            let glassView: GlassBackgroundView\n"
        "            if let current = self.aorusFieldsGlassView {\n"
        "                glassView = current\n"
        "            } else {\n"
        "                glassView = GlassBackgroundView(frame: aorusGlassFrame)\n"
        "                glassView.isUserInteractionEnabled = false\n"
        "                self.aorusFieldsGlassView = glassView\n"
        "                // At the back: the field nodes are already subviews by now, and a field\n"
        "                // created on a later pass is appended above this one anyway.\n"
        "                self.view.insertSubview(glassView, at: 0)\n"
        "            }\n"
        "            glassView.isHidden = aorusGlassFrame.height <= 0.0\n"
        "            transition.updateFrame(view: glassView, frame: aorusGlassFrame)\n"
        "            glassView.update(\n"
        "                size: aorusGlassFrame.size,\n"
        "                cornerRadius: AorusGlassPane.blockCornerRadius,\n"
        "                isDark: true,\n"
        "                tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        } else if let glassView = self.aorusFieldsGlassView {\n"
        "            self.aorusFieldsGlassView = nil\n"
        "            glassView.removeFromSuperview()\n"
        "        }\n"
        "        var removeKeys: [PeerInfoHeaderTextFieldNodeKey] = []\n",
        "editing header glass pane",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the editing header fields glass")


def _patch_badge_contrast(tg: Path) -> None:
    """Digits inside a badge, not the hole they leave in it.

    Every badge in the client is drawn as two independent things: a filled pill, whose colour the
    row picks, and a string on top of it, whose colour comes from `list.itemCheckColors.foreground`.
    Stock can keep those two apart because the fill is always the accent and the foreground always
    white. Interface 2.0 breaks that pairing -- the derived theme makes `itemAccentColor` the page's
    own ink so that accent-coloured *text* stays legible on glass -- and a pill filled with white ink
    then has white digits on it. That is the unread count beside an account in Settings: the number
    is there, drawn white on white, readable only as the shape it leaves in the pane.

    Fixed by asking the theme for a foreground that suits the fill, at each of the three rows that
    draw a badge from the list theme. `aorusBadgeForegroundColor(over:)` answers with the stock
    colour unless the fill has landed on the same side of the luminance split as that colour, so a
    red or blue pill is untouched and so is every one of these rows with Interface 2.0 off.
    """
    peer_item = tg / "submodules/ItemListPeerItem/Sources/ItemListPeerItem.swift"
    text = _read(peer_item, "ItemListPeerItem.swift")
    if "aorusBadgeForegroundColor" in text:
        print("InterfaceV2: badge contrast already applied")
        return
    # The fill is `itemAccentColor`, chosen a few hundred lines up where `badgeColor` is decided.
    text = _replace_once(
        text,
        "            case let .badge(text):\n"
        "                labelAttributedString = NSAttributedString(string: text, font: badgeFont, "
        "textColor: item.presentationData.theme.list.itemCheckColors.foregroundColor)\n",
        "            case let .badge(text):\n"
        "                // AorusGram: over the accent, which Interface 2.0 turns into the pane's ink.\n"
        "                labelAttributedString = NSAttributedString(string: text, font: badgeFont, "
        "textColor: item.presentationData.theme.aorusBadgeForegroundColor("
        "over: item.presentationData.theme.list.itemAccentColor))\n",
        "peer item badge foreground",
    )
    peer_item.write_text(text, encoding="utf-8")

    disclosure = tg / "submodules/ItemListUI/Sources/Items/ItemListDisclosureItem.swift"
    text = _read(disclosure, "ItemListDisclosureItem.swift")
    # `badgeColor` is the pill this same closure is about to generate, and nil when there is no pill.
    text = _replace_once(
        text,
        "            switch item.labelStyle {\n"
        "            case .badge:\n"
        "                labelBadgeColor = item.presentationData.theme.list.itemCheckColors.foregroundColor\n",
        "            switch item.labelStyle {\n"
        "            case .badge:\n"
        "                // AorusGram: over the pill this row is about to fill, whatever colour it took.\n"
        "                labelBadgeColor = item.presentationData.theme.aorusBadgeForegroundColor(over: badgeColor)\n",
        "disclosure item badge foreground",
    )
    disclosure.write_text(text, encoding="utf-8")

    info_item = tg / (
        "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/ListItems/"
        "PeerInfoScreenDisclosureItem.swift"
    )
    text = _read(info_item, "PeerInfoScreenDisclosureItem.swift")
    # Both arms carry their fill on the label itself; `.labelBadge` is left alone because its fill is
    # the check *fill* colour, which stock already pairs with this foreground.
    text = _replace_once(
        text,
        "        } else if case .badge = item.label {\n"
        "            labelColorValue = presentationData.theme.list.itemCheckColors.foregroundColor\n"
        "            labelFont = Font.regular(15.0)\n",
        "        } else if case .badge = item.label {\n"
        "            // AorusGram: over the fill the label carries.\n"
        "            labelColorValue = presentationData.theme.aorusBadgeForegroundColor(over: item.label.badgeColor)\n"
        "            labelFont = Font.regular(15.0)\n",
        "peer info badge foreground",
    )
    text = _replace_once(
        text,
        "        } else if case .titleBadge = item.label {\n"
        "            labelColorValue = presentationData.theme.list.itemCheckColors.foregroundColor\n"
        "            labelFont = Font.medium(11.0)\n",
        "        } else if case .titleBadge = item.label {\n"
        "            // AorusGram: same, for the pill that sits beside a title rather than after it.\n"
        "            labelColorValue = presentationData.theme.aorusBadgeForegroundColor(over: item.label.badgeColor)\n"
        "            labelFont = Font.medium(11.0)\n",
        "peer info title badge foreground",
    )
    info_item.write_text(text, encoding="utf-8")
    print("InterfaceV2: gave badges a foreground their fill can be read against")


def _patch_corner_wedges(tg: Path) -> None:
    """Stop rounding a block by painting the page colour over its corners.

    This is the single function every blocks-style row in the client rounds itself with, and the
    way it works is a lie that only holds while the card is opaque: the row is a square node
    filled with `itemBlocksBackgroundColor`, and an image of `blocksBackgroundColor` -- the *page*
    colour -- is laid over the two corners that need cutting. Over a pane of glass those two
    corners are opaque wedges of a colour that is no longer behind anything, which is the black
    corner in every screen that was reported.

    Under Interface 2.0 the shape comes from the pane instead: a real `GlassBackgroundView` with a
    corner radius, one per block, put there by `_patch_item_list_glass` and by the peer-info
    section container. So the mask has nothing left to do and returns nothing. Nil rather than a
    transparent image, because every caller assigns this straight to an `ASImageNode`, and a nil
    image is the cheaper way to say "draw nothing" to one of those.
    """
    path = tg / "submodules/TelegramPresentationData/Sources/Resources/PresentationResourcesItemList.swift"
    text = _read(path, "PresentationResourcesItemList.swift")
    if "aorusNoCornerWedges" in text:
        print("InterfaceV2: corner wedges already dropped")
        return
    text = _replace_once(
        text,
        "    public static func cornersImage(_ theme: PresentationTheme, top: Bool, bottom: Bool, glass: Bool = false) -> UIImage? {\n"
        "        if !top && !bottom {\n"
        "            return nil\n"
        "        }\n",
        "    public static func cornersImage(_ theme: PresentationTheme, top: Bool, bottom: Bool, glass: Bool = false) -> UIImage? {\n"
        "        // AorusGram: the glass pane behind the block is its shape now, so there is no\n"
        "        // corner left to paint over. Checked before the early exit below rather than after,\n"
        "        // because both answers here are the same one.\n"
        "        let aorusNoCornerWedges = AorusGlassPane.isEnabled\n"
        "        if aorusNoCornerWedges {\n"
        "            return nil\n"
        "        }\n"
        "        if !top && !bottom {\n"
        "            return nil\n"
        "        }\n",
        "corner wedge exit",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: dropped the corner wedges")


def _patch_header_centering(tg: Path) -> None:
    """Centre the name, the status and the username while the photo is expanded.

    Telegram left-aligns all three over an expanded photo and pushes the username to the
    opposite edge, because its expanded header is a caption over a picture. Interface 2.0
    wants the stacked, centred arrangement the collapsed header already uses, so the three
    origins are recomputed and nothing else about the state is touched -- the collapse
    fraction, the scale and the navigation-bar handoff all still come from the stock code.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "aorusCentredHeader" in text:
        print("InterfaceV2: header already centred")
        return
    text = _replace_once(
        text,
        "        var titleFrame: CGRect\n"
        "        var subtitleFrame: CGRect\n"
        "        let usernameFrame: CGRect\n",
        "        // AorusGram: Interface 2.0 stacks the name, the status and the username down the\n"
        "        // middle in both states instead of only the collapsed one.\n"
        "        let aorusCentredHeader = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        var titleFrame: CGRect\n"
        "        var subtitleFrame: CGRect\n"
        "        let usernameFrame: CGRect\n",
        "centred header flag",
    )
    # titleFrame is derived from minTitleFrame.midX, so centring that frame centres the title.
    text = _replace_once(
        text,
        "            var minTitleFrame = CGRect(origin: CGPoint(x: 16.0, y: expandedAvatarHeight - bottomInset - 58.0 - UIScreenPixel + (subtitleSize.height.isZero ? 10.0 : 0.0)), size: minTitleSize)\n",
        "            let aorusMinTitleX: CGFloat = aorusCentredHeader ? floorToScreenPixels((width - minTitleSize.width) / 2.0) : 16.0\n"
        "            var minTitleFrame = CGRect(origin: CGPoint(x: aorusMinTitleX, y: expandedAvatarHeight - bottomInset - 58.0 - UIScreenPixel + (subtitleSize.height.isZero ? 10.0 : 0.0)), size: minTitleSize)\n",
        "centred header title",
    )
    text = _replace_once(
        text,
        "            subtitleFrame = CGRect(origin: CGPoint(x: 16.0 - subtitleButtonHorizontalOffset * (1.0 - titleCollapseFraction), y: minTitleFrame.maxY + 2.0), size: subtitleSize)\n"
        "            if self.subtitleRating != nil {\n"
        "                subtitleFrame.origin.x += 22.0\n"
        "            }\n"
        "            usernameFrame = CGRect(origin: CGPoint(x: width - usernameSize.width - 16.0, y: minTitleFrame.midY - usernameSize.height / 2.0), size: usernameSize)\n",
        "            // A badge sits 8pt to the right of the status and a rating badge immediately\n"
        "            // to its left, so what has to end up centred is the pair, not the words: the\n"
        "            // status moves half a badge the other way for each. Stock moves a whole rating\n"
        "            // badge because its status hangs off the left margin rather than the middle.\n"
        "            var aorusCentredSubtitleWidth = subtitleSize.width\n"
        "            if let subtitleBadgeSize {\n"
        "                aorusCentredSubtitleWidth += subtitleBadgeSize.width + 8.0\n"
        "            }\n"
        "            let aorusSubtitleX: CGFloat = aorusCentredHeader\n"
        "                ? floorToScreenPixels((width - aorusCentredSubtitleWidth) / 2.0)\n"
        "                : (16.0 - subtitleButtonHorizontalOffset * (1.0 - titleCollapseFraction))\n"
        "            subtitleFrame = CGRect(origin: CGPoint(x: aorusSubtitleX, y: minTitleFrame.maxY + 2.0), size: subtitleSize)\n"
        "            if self.subtitleRating != nil {\n"
        "                subtitleFrame.origin.x += aorusCentredHeader ? 11.0 : 22.0\n"
        "            }\n"
        "            if aorusCentredHeader {\n"
        "                // Under the status rather than opposite the name: at the edge it reads as a\n"
        "                // second, unrelated label once the name is no longer beside it.\n"
        "                usernameFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((width - usernameSize.width) / 2.0), y: subtitleFrame.maxY + 2.0), size: usernameSize)\n"
        "            } else {\n"
        "                usernameFrame = CGRect(origin: CGPoint(x: width - usernameSize.width - 16.0, y: minTitleFrame.midY - usernameSize.height / 2.0), size: usernameSize)\n"
        "            }\n",
        "centred header subtitle",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: centred the profile header")


def _patch_multi_scale_centering(tg: Path) -> None:
    """Centre the header's text in its own box, which is what makes a long status sit straight.

    The title, the status and the username are each a MultiScaleTextNode: the same string laid
    out at two font sizes, one of which is shown at a time. Every size is positioned against the
    box measured from the *main* size, pinned to that box's left edge -- and the size on screen is
    not always the main one. The expanded profile header shows the 16pt status inside a box
    measured at 17pt, so it hangs left of centre by half the difference: nothing on "online",
    several points on a bot's "1 234 567 monthly users", which is the drift that reads as a
    status sliding off to the left for no reason.

    Centring rather than remeasuring, and only under Interface 2.0: the stock header anchors this
    box at the left margin, where pinning the text to its left edge is exactly right.
    """
    path = tg / "submodules/TelegramUI/Components/MultiScaleTextNode/Sources/MultiScaleTextNode.swift"
    text = _read(path, "MultiScaleTextNode.swift")
    if "aorusTextOriginX" in text:
        print("InterfaceV2: header text already centred in its box")
        return
    text = _replace_once(
        text,
        "                    let textFrame = CGRect(origin: CGPoint(x: mainBounds.minX, y: mainBounds.minY + floor((mainBounds.height - nodeLayout.size.height) / 2.0)), size: nodeLayout.size)\n",
        "                    // AorusGram: centred in the main state's box rather than pinned to its\n"
        "                    // left edge, because the state on screen is not the state the box was\n"
        "                    // measured from -- see this pass in scripts/interface_v2_patch.py.\n"
        "                    var aorusTextOriginX = mainBounds.minX\n"
        "                    if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") {\n"
        "                        aorusTextOriginX += floor((mainBounds.width - nodeLayout.size.width) / 2.0)\n"
        "                    }\n"
        "                    let textFrame = CGRect(origin: CGPoint(x: aorusTextOriginX, y: mainBounds.minY + floor((mainBounds.height - nodeLayout.size.height) / 2.0)), size: nodeLayout.size)\n",
        "multi-scale text centring",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: centred the header text in its box")


def _patch_glass_action_buttons(tg: Path) -> None:
    """Give each action button its own pane of glass, and drop the shared blur behind them.

    Telegram draws one blurred strip behind the whole row and masks it to the union of the
    button shapes. That is the blur Interface 2.0 is meant to replace: a mask cannot be handed
    to a system glass effect, and a strip of glass behind four circles is not four circles of
    glass. So each button gets its own, and the strip is faded out.
    """
    button = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderButtonNode.swift"
    text = _read(button, "PeerInfoHeaderButtonNode.swift")
    if "aorusGlassBackground" in text:
        print("InterfaceV2: action buttons already glass")
    else:
        if _GLASS_IMPORT not in text:
            text = _replace_once(text, "import Display\n", "import Display\n" + _GLASS_IMPORT, "button glass import")
        text = _replace_once(
            text,
            "    let backgroundContainerView: UIView\n    let backgroundView: UIView\n",
            "    let backgroundContainerView: UIView\n"
            "    let backgroundView: UIView\n"
            "    // AorusGram: nil unless Interface 2.0 is on, in which case this is what the button\n"
            "    // is actually made of and backgroundView is left as the row mask's white shape.\n"
            "    private let aorusGlassBackground: GlassBackgroundView?\n",
            "button glass property",
        )
        text = _replace_once(
            text,
            "        self.backgroundView.backgroundColor = .white\n"
            "        self.backgroundContainerView.addSubview(self.backgroundView)\n",
            "        self.backgroundView.backgroundColor = .white\n"
            "        self.backgroundContainerView.addSubview(self.backgroundView)\n"
            "\n"
            "        if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") {\n"
            "            let glassBackground = GlassBackgroundView(frame: CGRect())\n"
            "            glassBackground.isUserInteractionEnabled = false\n"
            "            self.aorusGlassBackground = glassBackground\n"
            "        } else {\n"
            "            self.aorusGlassBackground = nil\n"
            "        }\n",
            "button glass creation",
        )
        text = _replace_once(
            text,
            "        transition.updateFrame(view: self.backgroundView, frame: backgroundFrame)\n",
            "        transition.updateFrame(view: self.backgroundView, frame: backgroundFrame)\n"
            "        if let glassBackground = self.aorusGlassBackground {\n"
            "            // Attached here rather than in init: this runs inside the header's layout\n"
            "            // pass, and reaching for a node's view off the main thread is a trap in\n"
            "            // AsyncDisplayKit. Index 0 keeps it below the icon and the context-menu\n"
            "            // reference node, both of which stay exactly where they were.\n"
            "            if glassBackground.superview == nil {\n"
            "                self.view.insertSubview(glassBackground, at: 0)\n"
            "            }\n"
            "            transition.updateFrame(view: glassBackground, frame: backgroundFrame)\n"
            "            glassBackground.update(\n"
            "                size: backgroundFrame.size,\n"
            "                cornerRadius: aorusIsRound ? backgroundFrame.height * 0.5 : min(16.0, backgroundFrame.height * 0.5),\n"
            "                isDark: true,\n"
            "                tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
            "                isInteractive: false,\n"
            "                isVisible: true,\n"
            "                transition: .immediate\n"
            "            )\n"
            "        }\n",
            "button glass frame",
        )
        text = _replace_once(
            text,
            "    func update(size: CGSize, text: String, icon: PeerInfoHeaderButtonIcon, isActive: Bool, presentationData: PresentationData, backgroundColor: UIColor, foregroundColor: UIColor, fraction: CGFloat, transition: ContainedViewLayoutTransition) {\n",
            "    func update(size: CGSize, text: String, icon: PeerInfoHeaderButtonIcon, isActive: Bool, presentationData: PresentationData, backgroundColor: UIColor, foregroundColor: UIColor, fraction: CGFloat, transition: ContainedViewLayoutTransition) {\n"
            "        // AorusGram: the page's own ink in every profile under Interface 2.0. The colour\n"
            "        // the header hands down is the theme's accent whenever the photo is not expanded --\n"
            "        // which is every profile that has no photo at all -- and an accent-coloured glyph on\n"
            "        // glass is the one thing these buttons must never be. Ink rather than a flat white,\n"
            "        // because the pane is over the page sampled off the photo and a pale photo makes that\n"
            "        // page pale; the glyph is drawn as a white template and tinted from here, so this one\n"
            "        // value carries the icon, the label and the caption together.\n"
            "        var foregroundColor = foregroundColor\n"
            "        if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") {\n"
            "            foregroundColor = AorusGlassPane.profilePageInk\n"
            "        }\n",
            "button white foreground",
        )
        button.write_text(text, encoding="utf-8")
        print("InterfaceV2: made the action buttons glass")

    header = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    head = _read(header, "PeerInfoHeaderNode.swift")
    if "aorusHidesButtonsBlur" in head:
        print("InterfaceV2: shared button blur already hidden")
        return
    head = _replace_once(
        head,
        "        if isReduceTransparencyEnabled() {\n"
        "            self.buttonsBackgroundNode.alpha = 0.1\n"
        "        }\n",
        "        if isReduceTransparencyEnabled() {\n"
        "            self.buttonsBackgroundNode.alpha = 0.1\n"
        "        }\n"
        "        // AorusGram: each button carries its own glass under Interface 2.0, so the strip\n"
        "        // behind the row would only add a second, differently blurred layer. Hidden after\n"
        "        // the reduce-transparency branch rather than before it, or that branch would put\n"
        "        // a tenth of it back.\n"
        "        let aorusHidesButtonsBlur = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        if aorusHidesButtonsBlur {\n"
        "            self.buttonsBackgroundNode.alpha = 0.0\n"
        "        }\n",
        "shared button blur",
    )
    header.write_text(head, encoding="utf-8")
    print("InterfaceV2: hid the shared button blur")


def _patch_avatar_tint_publish(tg: Path) -> None:
    """Publish the colour of the photo on screen from the layout pass that already has it.

    "The photo on screen" and not "the peer's photo": a peer with three avatars is paged
    through inside the header, and each of the three gets the page its own colour. The layout
    pass publishes, and the pan that changes the page republishes -- see the second patch here,
    on the screen's own currentIndexUpdated handler.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "publishAvatarTint" in text:
        print("InterfaceV2: avatar tint already published")
    else:
        text = _replace_once(
            text,
            "        self.avatarListNode.update(size: CGSize(), avatarSize: avatarSize, isExpanded: self.isAvatarExpanded, peer: peer, isForum: isForum, threadId: self.forumTopicThreadId, threadInfo: threadData?.info, theme: presentationData.theme, transition: transition)\n",
            "        self.avatarListNode.update(size: CGSize(), avatarSize: avatarSize, isExpanded: self.isAvatarExpanded, peer: peer, isForum: isForum, threadId: self.forumTopicThreadId, threadInfo: threadData?.info, theme: presentationData.theme, transition: transition)\n"
            "        // AorusGram: read the colour off the photo that was just laid out, so the page\n"
            "        // under the whole screen can be that colour. The strip this header adds below the\n"
            "        // square picture is taken from the size that was just used to lay the list out,\n"
            "        // rather than written down as the 98 a phone in portrait works out to: the same\n"
            "        // min() PeerInfoAvatarListItemNode squares the photo with, so the two cannot\n"
            "        // disagree on a shape where the container is wider than it is tall.\n"
            "        if aorusCentredHeader {\n"
            "            self.aorusMirroredTail = expandedAvatarListSize.height - min(expandedAvatarListSize.width, expandedAvatarListSize.height)\n"
            "            self.aorusPublishAvatarTint(peer: peer)\n"
            "        }\n",
            "avatar tint publish",
        )
        text = _replace_once(
            text,
            "    func updateAvatarIsHidden(entry: AvatarGalleryEntry?) {\n",
            "    // AorusGram: hand the page under the profile the colour of the photo that is on\n"
            "    // screen right now. Sampling the rendered view rather than the peer's palette is\n"
            "    // the point -- the page has to match the photo, and a photo has no palette entry --\n"
            "    // and sampling *this* photo rather than the peer's first one is what makes paging\n"
            "    // through three avatars repaint the page three times.\n"
            "    //\n"
            "    // Which photo that is comes from currentEntry rather than the list container's own\n"
            "    // index, which is internal to its module; the entries are Equatable, so the index is\n"
            "    // simply where the current one sits among them.\n"
            "    //\n"
            "    // How far this header reaches below the square picture -- the strip it fills by\n"
            "    // mirroring it, and the one figure that says which row of the photo the bottom edge of\n"
            "    // the header shows. Kept from the layout pass rather than worked out here: it is built\n"
            "    // from that pass's own width and container height, and the swipe between avatars\n"
            "    // publishes from a callback that has neither. Ninety-eight is what a phone in portrait\n"
            "    // computes, so a first publish that somehow preceded a layout would still be right.\n"
            "    var aorusMirroredTail: CGFloat = 98.0\n"
            "\n"
            "    func aorusPublishAvatarTint(peer: EnginePeer?) {\n"
            "        guard let peer, UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") else {\n"
            "            return\n"
            "        }\n"
            "        let listContainerNode = self.avatarListNode.listContainerNode\n"
            "        var photo = 0\n"
            "        // The collapsed avatar is always the first of the peer's photos, so it is the\n"
            "        // right thing to sample until the gallery has pages of its own. It is only good\n"
            "        // for the colour though: it is a centre crop behind a circular mask, so the\n"
            "        // stretched backdrop has to wait for the full-width photo.\n"
            "        var sampledView: UIView? = self.avatarListNode.avatarContainerNode.avatarNode.view\n"
            "        var isFullPhoto = false\n"
            "        if let currentEntry = listContainerNode.currentEntry,\n"
            "           let currentIndex = listContainerNode.galleryEntries.firstIndex(of: currentEntry) {\n"
            "            photo = currentIndex\n"
            "            if let itemNode = listContainerNode.currentItemNode {\n"
            "                sampledView = itemNode.imageNode.view\n"
            "                isFullPhoto = true\n"
            "            } else if currentIndex != 0 {\n"
            "                // The page exists but its node has not been built yet. Nothing to sample:\n"
            "                // the round avatar below it is a different photo, and sampling that would\n"
            "                // paint the page the colour of the one the reader just swiped away from.\n"
            "                // The next layout pass, which the pan is about to cause, finds the node.\n"
            "                sampledView = nil\n"
            "            }\n"
            "        }\n"
            "        // The page under the profile is Telegram's own bottom blur block carried the rest\n"
            "        // of the way down. One number places that block on the photo: the strip this header\n"
            "        // adds below the square picture and fills by mirroring it, which is what decides\n"
            "        // the row the header's own bottom edge shows. The block's height is not a second\n"
            "        // number -- every gradient it is drawn with is at its extreme along that bottom\n"
            "        // edge whatever the block's height, so the height cannot reach the page's colour.\n"
            "        AorusGlassProfileTint.publishAvatarTint(\n"
            "            for: peer.id.id._internalGetInt64Value(),\n"
            "            photo: photo,\n"
            "            photoCount: listContainerNode.galleryEntries.count,\n"
            "            view: sampledView,\n"
            "            mirroredTail: self.aorusMirroredTail,\n"
            "            isFullPhoto: isFullPhoto,\n"
            "            onUpdate: { [weak self] in\n"
            "                self?.requestUpdateLayout?(false)\n"
            "            }\n"
            "        )\n"
            "    }\n"
            "\n"
            "    func updateAvatarIsHidden(entry: AvatarGalleryEntry?) {\n",
            "avatar tint method",
        )
        # And the structural half of it. Everything above predicts what the bottom line of
        # Telegram's blur block comes out as, from its own recipe; this makes the two sides of the
        # join the same pixels instead of two computations of the same pixels, so that whatever is
        # left of the model's error is a gradient over the block's height and not a step at one line.
        text = _replace_once(
            text,
            "        self.avatarListNode.listContainerNode.bottomShadowNode.update(size: bottomShadowFrame.size, transition: transition)\n",
            "        self.avatarListNode.listContainerNode.bottomShadowNode.update(size: bottomShadowFrame.size, transition: transition)\n"
            "        // AorusGram: and lay the page's own row over the bottom of that block, faded up\n"
            "        // from nothing, so the block's last line and the page's first cannot disagree.\n"
            "        // Here rather than in the publish because this is the pass that knows how tall the\n"
            "        // block is. See AorusProfileHeaderFadeView.\n"
            "        self.aorusUpdateHeaderFade(peer: peer, size: bottomShadowFrame.size, transition: transition)\n",
            "header fade layout",
        )
        text = _replace_once(
            text,
            "    func aorusPublishAvatarTint(peer: EnginePeer?) {\n",
            "    // AorusGram: the page's own row, laid over the bottom of Telegram's blur block and\n"
            "    // faded in, so that the join has no two sides to disagree.\n"
            "    //\n"
            "    // The block cannot be photographed -- its blur is a private CAFilter behind a\n"
            "    // UIVisualEffectView, and layer.render(in:) over a live backdrop filter copies the\n"
            "    // gradient and none of the blur -- so the page is a model of its recipe, and a model is\n"
            "    // never exact. Rather than chase the last few levels of it, this puts the page's own row\n"
            "    // over the bottom of the block and fades it up from nothing across the block's height:\n"
            "    // what the page is painted with then *is* what the block's last line shows, by\n"
            "    // construction. Whatever error the model has left costs a gradient a hundred and eighty\n"
            "    // points tall instead of a step at one line, and only one of those two can be seen.\n"
            "    var aorusHeaderFadeView: AorusProfileHeaderFadeView?\n"
            "\n"
            "    func aorusUpdateHeaderFade(peer: EnginePeer?, size: CGSize, transition: ContainedViewLayoutTransition) {\n"
            "        guard let peer, UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") else {\n"
            "            // Interface 2.0 off, or no peer yet: the block goes back to being Telegram's own.\n"
            "            self.aorusHeaderFadeView?.removeFromSuperview()\n"
            "            self.aorusHeaderFadeView = nil\n"
            "            return\n"
            "        }\n"
            "        let image = AorusGlassProfileTint.pageBackgroundImage(for: peer.id.id._internalGetInt64Value())\n"
            "        if image == nil && self.aorusHeaderFadeView == nil {\n"
            "            // A peer with no photo has no page, so there is nothing to continue and nothing\n"
            "            // built earlier that would need hiding. The publish asks for another layout pass\n"
            "            // once it has sampled one, and this runs again then.\n"
            "            return\n"
            "        }\n"
            "        let fadeView: AorusProfileHeaderFadeView\n"
            "        if let current = self.aorusHeaderFadeView {\n"
            "            fadeView = current\n"
            "        } else {\n"
            "            fadeView = AorusProfileHeaderFadeView(frame: CGRect())\n"
            "            self.aorusHeaderFadeView = fadeView\n"
            "        }\n"
            "        let shadowView = self.avatarListNode.listContainerNode.bottomShadowNode.view\n"
            "        if fadeView.superview !== shadowView {\n"
            "            shadowView.addSubview(fadeView)\n"
            "        } else if shadowView.subviews.last !== fadeView {\n"
            "            // PeerAvatarBottomShadowNode builds its blur on its first update and adds it\n"
            "            // above whatever is already there, so being on top is something to re-assert\n"
            "            // rather than to arrange once. Only when it is actually out of order, because\n"
            "            // reordering the layer tree from every layout pass is work for nothing.\n"
            "            shadowView.bringSubviewToFront(fadeView)\n"
            "        }\n"
            "        transition.updateFrame(view: fadeView, frame: CGRect(origin: CGPoint(), size: size))\n"
            "        fadeView.update(image: image)\n"
            "    }\n"
            "\n"
            "    func aorusPublishAvatarTint(peer: EnginePeer?) {\n",
            "header fade method",
        )
        path.write_text(text, encoding="utf-8")
        print("InterfaceV2: published the avatar tint")

    screen_path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift"
    screen = _read(screen_path, "PeerInfoScreen.swift")
    if "aorusPublishAvatarTint" in screen:
        print("InterfaceV2: paged avatar tint already hooked")
        return
    # Ahead of updateNavigation, not after it: that call is where the background colour is read
    # back and applied, so publishing first lets the page change in the same pass as the swipe
    # instead of waiting for the repaint the publish itself asks for.
    screen = _replace_once(
        screen,
        "        self.headerNode.avatarListNode.listContainerNode.currentIndexUpdated = { [weak self] in\n"
        "            self?.updateNavigation(transition: .immediate, additive: true, animateHeader: true)\n"
        "        }\n",
        "        self.headerNode.avatarListNode.listContainerNode.currentIndexUpdated = { [weak self] in\n"
        "            guard let self else {\n"
        "                return\n"
        "            }\n"
        "            // AorusGram: the page under the profile follows the photo being paged to.\n"
        "            self.headerNode.aorusPublishAvatarTint(peer: self.headerNode.avatarListNode.listContainerNode.peer)\n"
        "            self.updateNavigation(transition: .immediate, additive: true, animateHeader: true)\n"
        "        }\n",
        "paged avatar tint",
    )
    screen_path.write_text(screen, encoding="utf-8")
    print("InterfaceV2: hooked the paged avatar tint")


def _patch_avatar_placeholder(tg: Path) -> None:
    """Replace the coloured placeholder gradient with frosted glass, everywhere at once.

    A peer with no photo gets initials on one of Telegram's fixed colour gradients, drawn into
    an image by AvatarNode. Interface 2.0 wants those initials on glass instead -- in the chat
    list, in search, in the contact list and in the profile. All four draw through this one
    routine, so all four change together, and because it stays a drawn image there is no
    per-row effect view and no cost to scrolling.

    A drawn frost is as close to glass as a rasterised image gets, and for a row 40 points tall
    it is indistinguishable. At the size the profile header draws it, it is not: it reads as a
    dimmed disc, which is the complaint. So the node also takes a switch -- set only by the
    profile header, which puts one real GlassBackgroundView behind that one avatar -- that stops
    the plate being drawn at all and leaves just the initials over the material.
    """
    path = tg / "submodules/AvatarNode/Sources/AvatarNode.swift"
    text = _read(path, "AvatarNode.swift")
    if "aorusPlaceholderColors" in text:
        print("InterfaceV2: avatar placeholders already frosted")
        return
    text = _replace_once(
        text,
        "            let colorsArray: NSArray = colors.map(\\.cgColor) as NSArray\n",
        "            // AorusGram: initials on frosted glass instead of on a colour. Translucent\n"
        "            // neutral greys, so what shows through is whatever the avatar sits on -- the\n"
        "            // chat list, the search results or the profile header -- and never a tint of\n"
        "            // its own. Only the lettered placeholder is touched: the archive, deleted and\n"
        "            // saved-messages avatars are icons that have to keep their meaning.\n"
        "            //\n"
        "            // A light theme gets the plate and the letters the other way round -- a pale\n"
        "            // frost with black initials -- because white letters on a pale frost cannot be\n"
        "            // read. A nil theme is the custom-letters path, which only ever draws on dark\n"
        "            // surfaces, so it takes the dark pair.\n"
        "            var aorusPlaceholderColors = colors\n"
        "            var aorusLetterColor = UIColor.white\n"
        "            if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\"),\n"
        "               let parameters = parameters as? AvatarNodeParameters,\n"
        "               parameters.icon == .none,\n"
        "               !parameters.letters.isEmpty {\n"
        "                if parameters.theme?.overallDarkAppearance == false {\n"
        "                    aorusPlaceholderColors = [\n"
        "                        UIColor(white: 1.0, alpha: 0.62),\n"
        "                        UIColor(white: 0.86, alpha: 0.62)\n"
        "                    ]\n"
        "                    aorusLetterColor = UIColor(white: 0.0, alpha: 0.85)\n"
        "                } else {\n"
        "                    aorusPlaceholderColors = [\n"
        "                        UIColor(white: 0.52, alpha: 0.5),\n"
        "                        UIColor(white: 0.32, alpha: 0.5)\n"
        "                    ]\n"
        "                }\n"
        "                if parameters.aorusHasGlassBackdrop {\n"
        "                    // A real pane of glass is already behind this one -- the profile header\n"
        "                    // puts it there -- so nothing is drawn for the plate. Frosting over a\n"
        "                    // pane of glass is exactly how it stops looking like one. Clear rather\n"
        "                    // than skipped, because this fill runs in copy blend mode, so clearing\n"
        "                    // is what leaves the material behind it visible.\n"
        "                    aorusPlaceholderColors = [UIColor.clear, UIColor.clear]\n"
        "                }\n"
        "            }\n"
        "            let colorsArray: NSArray = aorusPlaceholderColors.map(\\.cgColor) as NSArray\n",
        "avatar placeholder colours",
    )
    text = _replace_once(
        text,
        "                    let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: parameters.font, NSAttributedString.Key.foregroundColor: UIColor.white])\n",
        "                    let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: parameters.font, NSAttributedString.Key.foregroundColor: aorusLetterColor])\n",
        "avatar placeholder letters",
    )
    text = _replace_once(
        text,
        "    let cutoutRect: CGRect?\n",
        "    let cutoutRect: CGRect?\n"
        "    // AorusGram: set per display pass rather than at construction -- see drawParameters.\n"
        "    var aorusHasGlassBackdrop: Bool = false\n",
        "avatar params glass flag",
    )
    text = _replace_once(
        text,
        "        private var parameters: AvatarNodeParameters?\n",
        "        // AorusGram: raised by whoever puts a real pane of glass behind this avatar, so the\n"
        "        // drawn placeholder plate steps out of the way instead of frosting over it.\n"
        "        public var aorusHasGlassBackdrop: Bool = false {\n"
        "            didSet {\n"
        "                if self.aorusHasGlassBackdrop != oldValue, !self.displaySuspended {\n"
        "                    self.setNeedsDisplay()\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "        private var parameters: AvatarNodeParameters?\n",
        "avatar content glass flag",
    )
    text = _replace_once(
        text,
        "            return parameters ?? NSObject()\n",
        "            // AorusGram: carried in here because the node is told about the glass behind it\n"
        "            // by the profile header, which happens after setPeer has built these\n"
        "            // parameters -- and a photoless peer builds them exactly once.\n"
        "            if let parameters = self.parameters {\n"
        "                parameters.aorusHasGlassBackdrop = self.aorusHasGlassBackdrop\n"
        "                return parameters\n"
        "            }\n"
        "            return NSObject()\n",
        "avatar draw parameters glass flag",
    )
    text = _replace_once(
        text,
        "    public var unroundedImage: UIImage? {\n"
        "        get {\n"
        "            return self.contentNode.unroundedImage\n"
        "        } set(value) {\n"
        "            self.contentNode.unroundedImage = value\n"
        "        }\n"
        "    }\n",
        "    public var unroundedImage: UIImage? {\n"
        "        get {\n"
        "            return self.contentNode.unroundedImage\n"
        "        } set(value) {\n"
        "            self.contentNode.unroundedImage = value\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    // AorusGram: forwarded like the rest of the content node's drawing state.\n"
        "    public var aorusHasGlassBackdrop: Bool {\n"
        "        get {\n"
        "            return self.contentNode.aorusHasGlassBackdrop\n"
        "        } set(value) {\n"
        "            self.contentNode.aorusHasGlassBackdrop = value\n"
        "        }\n"
        "    }\n",
        "avatar node glass flag forwarding",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: frosted the avatar placeholders")


def _patch_glass_placeholder_avatar(tg: Path) -> None:
    """Put real glass under the initials of a peer that has no photo.

    The drawn frost `_patch_avatar_placeholder` installs is the right answer for a 40-point row:
    it is a rasterised image, so a list can scroll a hundred of them for nothing. At the size the
    profile draws the same avatar it stops passing for glass and reads as a dimmed disc, which is
    the whole of the complaint. Here there is exactly one avatar on screen, so it can afford a
    real GlassBackgroundView -- and the node is told to stop drawing its plate, since a frost
    painted over a pane of glass is precisely how the pane stops looking like one.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift"
    text = _read(path, "PeerInfoAvatarTransformContainerNode.swift")
    if "aorusUpdateGlassPlaceholder" in text:
        print("InterfaceV2: placeholder avatar already glass")
        return
    if _GLASS_IMPORT not in text:
        text = _replace_once(
            text,
            "import Display\n",
            "import Display\n" + _GLASS_IMPORT,
            "placeholder avatar glass import",
        )
    text = _replace_once(
        text,
        "            self.containerNode.frame = CGRect(origin: CGPoint(x: -avatarSize / 2.0, y: -avatarSize / 2.0), size: CGSize(width: avatarSize, height: avatarSize))\n"
        "            self.avatarNode.frame = self.containerNode.bounds\n"
        "            self.avatarNode.font = avatarPlaceholderFont(size: floor(avatarSize * 16.0 / 37.0))\n",
        "            self.containerNode.frame = CGRect(origin: CGPoint(x: -avatarSize / 2.0, y: -avatarSize / 2.0), size: CGSize(width: avatarSize, height: avatarSize))\n"
        "            self.avatarNode.frame = self.containerNode.bounds\n"
        "            self.avatarNode.font = avatarPlaceholderFont(size: floor(avatarSize * 16.0 / 37.0))\n"
        "            // AorusGram: initials on real glass when there is no photo to show. A thread's\n"
        "            // avatar is its emoji and a deleted account's is an icon -- neither draws\n"
        "            // letters, so neither gets a pane.\n"
        "            self.aorusUpdateGlassPlaceholder(\n"
        "                isPlaceholder: threadInfo == nil && !peer.isDeleted\n"
        "                    && (overrideImage != nil || peer.profileImageRepresentations.isEmpty),\n"
        "                cornerRadius: avatarCornerRadius,\n"
        "                theme: theme\n"
        "            )\n",
        "placeholder avatar glass call",
    )
    text = _replace_once(
        text,
        "    private func updateFromParams() {\n",
        "    private var aorusGlassPlaceholderView: GlassBackgroundView?\n"
        "\n"
        "    /// One pane of glass behind the lettered avatar, or none at all.\n"
        "    ///\n"
        "    /// Created only for a peer without a photo and released the moment one appears, so a\n"
        "    /// profile that has an avatar never pays for an effect view it cannot see. It goes\n"
        "    /// behind the avatar node rather than inside it: that node rasterises what it draws and\n"
        "    /// clips to its own rounded bounds, and a live effect view cannot be part of an image.\n"
        "    private func aorusUpdateGlassPlaceholder(isPlaceholder: Bool, cornerRadius: CGFloat, theme: PresentationTheme) {\n"
        "        let isEnabled = isPlaceholder && UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        self.avatarNode.aorusHasGlassBackdrop = isEnabled\n"
        "        guard isEnabled else {\n"
        "            if let glassView = self.aorusGlassPlaceholderView {\n"
        "                self.aorusGlassPlaceholderView = nil\n"
        "                glassView.removeFromSuperview()\n"
        "            }\n"
        "            return\n"
        "        }\n"
        "        let glassView: GlassBackgroundView\n"
        "        if let current = self.aorusGlassPlaceholderView {\n"
        "            glassView = current\n"
        "        } else {\n"
        "            glassView = GlassBackgroundView(frame: CGRect())\n"
        "            glassView.isUserInteractionEnabled = false\n"
        "            self.aorusGlassPlaceholderView = glassView\n"
        "            self.containerNode.view.insertSubview(glassView, at: 0)\n"
        "        }\n"
        "        glassView.frame = self.avatarNode.frame\n"
        "        glassView.update(\n"
        "            size: self.avatarNode.frame.size,\n"
        "            cornerRadius: cornerRadius,\n"
        "            isDark: theme.overallDarkAppearance,\n"
        "            tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "            isInteractive: false,\n"
        "            isVisible: true,\n"
        "            transition: .immediate\n"
        "        )\n"
        "    }\n"
        "\n"
        "    private func updateFromParams() {\n",
        "placeholder avatar glass view",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: glassed the placeholder avatar")


def _patch_action_sheet_glass(tg: Path) -> None:
    """Put every chooser in the client on system glass.

    An action sheet is how Telegram asks nearly every question: audio or video call, which camera,
    which account, delete for whom. All of them are built from one group node and one theme, so
    both are patched here and every sheet in the client changes at once -- there is no per-screen
    list to keep up to date.

    Two halves. The group's blur becomes the real material, which on iOS 26 is a UIGlassEffect in
    the same plain effect view the group already had -- and on anything older the stock blur stays,
    because there is no glass to fall back to. Then the items stop painting themselves: an opaque
    row over the material would flatten it into a card, so their fill goes clear and the hairline
    between them becomes the faint translucent rule that a pane of glass can carry.
    """
    theme_path = tg / "submodules/Display/Source/ActionSheetTheme.swift"
    theme_text = _read(theme_path, "ActionSheetTheme.swift")
    if "aorusGlassSheet" in theme_text:
        print("InterfaceV2: action sheets already glass")
        return
    theme_text = _replace_once(
        theme_text,
        "        self.itemBackgroundColor = itemBackgroundColor\n"
        "        self.itemHighlightedBackgroundColor = itemHighlightedBackgroundColor\n",
        "        // AorusGram: the sheet is a pane of glass under Interface 2.0, so its rows are not\n"
        "        // painted -- an opaque row on top of the material is how the material stops being\n"
        "        // one. The hairline between rows is drawn with the highlight colour, which is why\n"
        "        // that one stays a colour and becomes a translucent rule instead of clear.\n"
        "        let aorusGlassSheet = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        if aorusGlassSheet {\n"
        "            self.itemBackgroundColor = .clear\n"
        "            switch backgroundType {\n"
        "            case .light:\n"
        "                self.itemHighlightedBackgroundColor = UIColor(white: 0.0, alpha: 0.08)\n"
        "            case .dark:\n"
        "                self.itemHighlightedBackgroundColor = UIColor(white: 1.0, alpha: 0.12)\n"
        "            }\n"
        "        } else {\n"
        "            self.itemBackgroundColor = itemBackgroundColor\n"
        "            self.itemHighlightedBackgroundColor = itemHighlightedBackgroundColor\n"
        "        }\n",
        "action sheet item colours",
    )
    theme_path.write_text(theme_text, encoding="utf-8")

    group_path = tg / "submodules/Display/Source/ActionSheetItemGroupNode.swift"
    group_text = _read(group_path, "ActionSheetItemGroupNode.swift")
    group_text = _replace_once(
        group_text,
        "        self.backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: self.theme.backgroundType == .light ? .light : .dark))\n",
        "        // AorusGram: the same native material the rest of Interface 2.0 uses, in the effect\n"
        "        // view this node already had. The radius matches the clipping node's, so the glass is\n"
        "        // shaped like the sheet rather than clipped to it -- a capsule cut by a rounded rect\n"
        "        // would leave the corners empty. Older systems keep the blur; glass is iOS 26 and up.\n"
        "        if #available(iOS 26.0, *), UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") {\n"
        "            let aorusGlassEffect = UIGlassEffect(style: .regular)\n"
        "            aorusGlassEffect.isInteractive = false\n"
        "            let aorusGlassView = UIVisualEffectView(effect: aorusGlassEffect)\n"
        "            aorusGlassView.layer.cornerRadius = 16.0\n"
        "            self.backgroundEffectView = aorusGlassView\n"
        "        } else {\n"
        "            self.backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: self.theme.backgroundType == .light ? .light : .dark))\n"
        "        }\n",
        "action sheet glass effect",
    )
    group_path.write_text(group_text, encoding="utf-8")
    print("InterfaceV2: made the action sheets glass")


def _patch_action_sheet_icon_rows(tg: Path) -> None:
    """Teach a sheet row to carry an icon, leading edge first.

    A row of a stock action sheet is a centred title and nothing else, which is the right shape
    for a question with two words of answer and the wrong one for a chooser: "Аудиозвонок" and
    "Видеозвонок" are told apart by their glyph long before they are read. So the row gets an
    optional image, and the one row in the client that passes one -- the call chooser the phone
    button opens -- comes out as an icon at the leading edge with its title beside it.

    The capability goes into `ActionSheetButtonItem` rather than into a class of our own because
    the item node is what carries the highlight, the pointer interaction, the accessibility
    element and the hairline the group draws between rows; a parallel item would have to
    reimplement all four and would still be a stranger to `ActionSheetItemGroupNode`. The new
    parameter is defaulted and sits before `action`, so every existing call site still compiles,
    and a row without an icon keeps the centred title exactly as it is drawn today.
    """
    path = tg / "submodules/Display/Source/ActionSheetButtonItem.swift"
    text = _read(path, "ActionSheetButtonItem.swift")
    if "aorusIcon" in text:
        print("InterfaceV2: action sheet rows already carry icons")
        return
    text = _replace_once(
        text,
        "    public let action: () -> Void\n"
        "    \n"
        "    public init(title: String, color: ActionSheetButtonColor = .accent,"
        " font: ActionSheetButtonFont = .default, enabled: Bool = true,"
        " action: @escaping () -> Void) {\n",
        "    public let action: () -> Void\n"
        "    // AorusGram: nil for every row Telegram builds, which is what keeps those rows\n"
        "    // centred; a row that is given one is laid out around it instead.\n"
        "    public let aorusIcon: UIImage?\n"
        "    \n"
        "    public init(title: String, color: ActionSheetButtonColor = .accent,"
        " font: ActionSheetButtonFont = .default, enabled: Bool = true,"
        " aorusIcon: UIImage? = nil, action: @escaping () -> Void) {\n",
        "action sheet row icon property",
    )
    text = _replace_once(
        text,
        "        self.enabled = enabled\n"
        "        self.action = action\n",
        "        self.enabled = enabled\n"
        "        self.aorusIcon = aorusIcon\n"
        "        self.action = action\n",
        "action sheet row icon assignment",
    )
    text = _replace_once(
        text,
        "    private let label: ImmediateTextNode\n"
        "    private let accessibilityArea: AccessibilityAreaNode\n",
        "    private let label: ImmediateTextNode\n"
        "    private let aorusIconNode: ASImageNode\n"
        "    private let accessibilityArea: AccessibilityAreaNode\n",
        "action sheet row icon node",
    )
    text = _replace_once(
        text,
        "        self.accessibilityArea = AccessibilityAreaNode()\n"
        "        \n"
        "        super.init(theme: theme)\n",
        "        let aorusIconNode = ASImageNode()\n"
        "        aorusIconNode.isUserInteractionEnabled = false\n"
        "        aorusIconNode.displaysAsynchronously = false\n"
        "        aorusIconNode.displayWithoutProcessing = true\n"
        "        self.aorusIconNode = aorusIconNode\n"
        "        \n"
        "        self.accessibilityArea = AccessibilityAreaNode()\n"
        "        \n"
        "        super.init(theme: theme)\n",
        "action sheet row icon setup",
    )
    text = _replace_once(
        text,
        "        self.label.isUserInteractionEnabled = false\n"
        "        self.addSubnode(self.label)\n",
        "        self.label.isUserInteractionEnabled = false\n"
        "        self.addSubnode(self.aorusIconNode)\n"
        "        self.addSubnode(self.label)\n",
        "action sheet row icon subnode",
    )
    text = _replace_once(
        text,
        "        self.label.attributedText = NSAttributedString(string: item.title,"
        " font: textFont, textColor: textColor)\n",
        "        self.label.attributedText = NSAttributedString(string: item.title,"
        " font: textFont, textColor: textColor)\n"
        "        // AorusGram: tinted with the row's own text colour, so an icon follows the theme\n"
        "        // and the disabled state without the caller having to know either.\n"
        "        self.aorusIconNode.image = item.aorusIcon.flatMap {"
        " generateTintedImage(image: $0, color: textColor) }\n",
        "action sheet row icon tint",
    )
    text = _replace_once(
        text,
        "        let size = CGSize(width: constrainedSize.width, height: 57.0)\n"
        "        \n"
        "        self.button.frame = CGRect(origin: CGPoint(), size: size)\n"
        "        \n"
        "        let labelSize = self.label.updateLayout(CGSize(width: max(1.0, size.width - 10.0),"
        " height: size.height))\n"
        "        self.label.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width -"
        " labelSize.width) / 2.0), y: floorToScreenPixels((size.height - labelSize.height) / 2.0)),"
        " size: labelSize)\n",
        "        // AorusGram: a row with an icon is laid out the way iOS lays out one -- glyph at the\n"
        "        // leading edge, title beside it, both on the row's centre line -- and is given the\n"
        "        // three points of extra height that stops a 30pt glyph from touching the hairline.\n"
        "        let aorusIcon = self.aorusIconNode.image\n"
        "        let size = CGSize(width: constrainedSize.width, height: aorusIcon == nil ? 57.0 : 60.0)\n"
        "        \n"
        "        self.button.frame = CGRect(origin: CGPoint(), size: size)\n"
        "        \n"
        "        if let aorusIcon = aorusIcon {\n"
        "            let iconInset: CGFloat = 16.0\n"
        "            let iconColumn: CGFloat = 30.0\n"
        "            let titleInset = iconInset + iconColumn + 14.0\n"
        "            self.aorusIconNode.frame = CGRect(origin: CGPoint(x: iconInset +"
        " floorToScreenPixels((iconColumn - aorusIcon.size.width) / 2.0),"
        " y: floorToScreenPixels((size.height - aorusIcon.size.height) / 2.0)), size: aorusIcon.size)\n"
        "            let labelSize = self.label.updateLayout(CGSize(width: max(1.0, size.width -"
        " titleInset - iconInset), height: size.height))\n"
        "            self.label.frame = CGRect(origin: CGPoint(x: titleInset,"
        " y: floorToScreenPixels((size.height - labelSize.height) / 2.0)), size: labelSize)\n"
        "        } else {\n"
        "            let labelSize = self.label.updateLayout(CGSize(width: max(1.0, size.width - 10.0),"
        " height: size.height))\n"
        "            self.label.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((size.width -"
        " labelSize.width) / 2.0), y: floorToScreenPixels((size.height - labelSize.height) / 2.0)),"
        " size: labelSize)\n"
        "        }\n",
        "action sheet row icon layout",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: taught the action sheet rows to carry icons")


def _patch_share_sheet_glass(tg: Path) -> None:
    """Put "Отправить" on glass -- the sheet a tap on a username in a profile opens.

    It is not an action sheet, which is why the pass above never reached it. `ShareControllerNode`
    draws its own card out of stretchable images it generates in its initialiser: a rounded rectangle
    behind the peer grid, the same rectangle with its top squared off behind the comment field and
    the send button, and a third copy of the first behind Cancel -- all filled with
    `opaqueItemBackgroundColor`. So under Interface 2.0 this was the last plainly opaque panel left in
    the client, and it is the one a profile puts on screen most often.

    Three panes, then, one per shape, and the fills they take over go clear rather than being deleted.
    The highlighted pair stays a colour: Cancel and Send still have to answer a finger, and a
    translucent wash over the material is how the action sheets already answer one.

    Two of the panes live inside the node that used to hold the card's image, and the third inside
    Cancel's, which is what keeps all three in place for nothing: those are the nodes the sheet
    already moves. A view of our own tracking three frames would have to be told about the drag, the
    keyboard, the peer that was just selected and the search that was just opened, and told again
    every time upstream changes one of them.

    The card's pane stops where the strip's begins instead of running the height of the card. Glass
    over glass comes out brighter than either, and a sheet with a brighter rectangle across its foot
    reads as a bug; two panes tiling the card exactly read as the footer it is. Leaving the strip
    clear is not an option in the other direction -- the peer grid scrolls underneath it, which is
    why Telegram's own strip there is opaque to begin with. Which is also why the strip's pane hangs
    off the card and not off the node whose fill it replaces: that node is faded out while a search
    is open, and a pane that faded with it would leave a hole at the foot of the card.
    """
    path = tg / "submodules/ShareController/Sources/ShareControllerNode.swift"
    text = _read(path, "ShareControllerNode.swift")
    if "aorusSheetFill" in text:
        print("InterfaceV2: share sheet already glass")
        return
    text = _replace_once(
        text,
        "import ContextUI\n",
        "import ContextUI\n" + _GLASS_IMPORT,
        "share sheet import",
    )
    text = _replace_once(
        text,
        "    private let contentContainerNode: ASDisplayNode\n"
        "    private let contentBackgroundNode: ASImageNode\n",
        "    private let contentContainerNode: ASDisplayNode\n"
        "    private let contentBackgroundNode: ASImageNode\n"
        "    // AorusGram: the three panes Interface 2.0 stands this sheet on -- the card, the strip\n"
        "    // at its foot, and Cancel. Held here only so that a second layout pass finds the pane it\n"
        "    // made the first time instead of adding another one behind it.\n"
        "    private var aorusCardBackgroundView: GlassBackgroundView?\n"
        "    private var aorusActionsBackgroundView: GlassBackgroundView?\n"
        "    private var aorusCancelBackgroundView: GlassBackgroundView?\n",
        "share sheet panes",
    )

    # Written twice over: the initialiser and updatePresentationData generate the same four images
    # from the same lines, and a sheet that goes glass only until the theme changes is worse than one
    # that never did.
    images_old = (
        "        let roundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: self.presentationData.theme.actionSheet.opaqueItemBackgroundColor)\n"
        "        let highlightedRoundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: self.presentationData.theme.actionSheet.opaqueItemHighlightedBackgroundColor)\n"
        "        \n"
        "        let theme = self.presentationData.theme\n"
        "        let halfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in\n"
        "            context.clear(CGRect(origin: CGPoint(), size: size))\n"
        "            context.setFillColor(theme.actionSheet.opaqueItemBackgroundColor.cgColor)\n"
        "            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))\n"
        "            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))\n"
        "        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)\n"
        "        \n"
        "        let highlightedHalfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in\n"
        "            context.clear(CGRect(origin: CGPoint(), size: size))\n"
        "            context.setFillColor(theme.actionSheet.opaqueItemHighlightedBackgroundColor.cgColor)\n"
        "            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))\n"
        "            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))\n"
        "        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)\n"
    )
    images_new = (
        "        let theme = self.presentationData.theme\n"
        "        // AorusGram: the sheet's own paint, or nothing at all under Interface 2.0, where the\n"
        "        // panes below are what the card is made of and an opaque image over one of them is how\n"
        "        // a pane of glass stops being one. The highlight and the hairline stay colours: a row\n"
        "        // has to answer a finger, and two panes that meet need a line where they do.\n"
        "        let aorusGlassSheet = AorusGlassPane.isEnabled\n"
        "        let aorusSheetFill: UIColor = aorusGlassSheet ? .clear : theme.actionSheet.opaqueItemBackgroundColor\n"
        "        let aorusSheetHighlight: UIColor\n"
        "        let aorusSheetRule: UIColor\n"
        "        if aorusGlassSheet, theme.overallDarkAppearance {\n"
        "            aorusSheetHighlight = UIColor(white: 1.0, alpha: 0.12)\n"
        "            aorusSheetRule = UIColor(white: 1.0, alpha: 0.12)\n"
        "        } else if aorusGlassSheet {\n"
        "            aorusSheetHighlight = UIColor(white: 0.0, alpha: 0.08)\n"
        "            aorusSheetRule = UIColor(white: 0.0, alpha: 0.1)\n"
        "        } else {\n"
        "            aorusSheetHighlight = theme.actionSheet.opaqueItemHighlightedBackgroundColor\n"
        "            aorusSheetRule = theme.actionSheet.opaqueItemSeparatorColor\n"
        "        }\n"
        "        let roundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: aorusSheetFill)\n"
        "        let highlightedRoundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: aorusSheetHighlight)\n"
        "        \n"
        "        let halfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in\n"
        "            context.clear(CGRect(origin: CGPoint(), size: size))\n"
        "            context.setFillColor(aorusSheetFill.cgColor)\n"
        "            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))\n"
        "            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))\n"
        "        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)\n"
        "        \n"
        "        let highlightedHalfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in\n"
        "            context.clear(CGRect(origin: CGPoint(), size: size))\n"
        "            context.setFillColor(aorusSheetHighlight.cgColor)\n"
        "            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))\n"
        "            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))\n"
        "        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)\n"
    )
    text = _replace_once(text, images_old, images_new, "share sheet images")
    text = _replace_once(text, images_old, images_new, "share sheet images on theme change")

    text = _replace_once(
        text,
        "        self.actionSeparatorNode.backgroundColor = self.presentationData.theme.actionSheet.opaqueItemSeparatorColor\n",
        "        self.actionSeparatorNode.backgroundColor = aorusSheetRule\n",
        "share sheet separator",
    )
    text = _replace_once(
        text,
        "        self.actionSeparatorNode.backgroundColor = presentationData.theme.actionSheet.opaqueItemSeparatorColor\n",
        "        self.actionSeparatorNode.backgroundColor = aorusSheetRule\n",
        "share sheet separator on theme change",
    )

    text = _replace_once(
        text,
        "    private func contentNodeDidBeginDragging() {\n",
        "    // AorusGram: the three panes, laid out from the frames the caller has just computed.\n"
        "    //\n"
        "    // `footerHeight` is the strip at the foot of the card that the comment field and the send\n"
        "    // button stand in -- `bottomGridInset` where it is worked out, and zero when neither of them\n"
        "    // is on screen, which is also when the card gets its bottom corners back.\n"
        "    //\n"
        "    // The card's two panes are sized in the card node's own coordinates, and Cancel's in its\n"
        "    // button's, so none of them has a position of its own to keep up to date. The strip's pane\n"
        "    // hangs off the card rather than off the node it replaces because that node is faded out\n"
        "    // while a search is open, and the material underneath the send button has to stay.\n"
        "    private func aorusUpdateSheetGlass(cardSize: CGSize, footerHeight: CGFloat, cancelSize: CGSize, transition: ContainedViewLayoutTransition) {\n"
        "        guard AorusGlassPane.isEnabled else {\n"
        "            return\n"
        "        }\n"
        "        let cornerRadius: CGFloat = 16.0\n"
        "        let isDark = self.presentationData.theme.overallDarkAppearance\n"
        "        let tintColor = GlassBackgroundView.TintColor(kind: .clear)\n"
        "        \n"
        "        let cardHeight = max(0.0, cardSize.height - footerHeight)\n"
        "        if cardSize.width > 0.0, cardHeight > 0.0 {\n"
        "            let cardView = self.aorusSheetPane(self.aorusCardBackgroundView, host: self.contentBackgroundNode.view)\n"
        "            self.aorusCardBackgroundView = cardView\n"
        "            let cardFrame = CGRect(origin: CGPoint(), size: CGSize(width: cardSize.width, height: cardHeight))\n"
        "            transition.updateFrame(view: cardView, frame: cardFrame)\n"
        "            cardView.update(\n"
        "                size: cardFrame.size,\n"
        "                cornerRadii: GlassBackgroundView.CornerRadii(\n"
        "                    topLeft: cornerRadius,\n"
        "                    topRight: cornerRadius,\n"
        "                    bottomLeft: footerHeight > 0.0 ? 0.0 : cornerRadius,\n"
        "                    bottomRight: footerHeight > 0.0 ? 0.0 : cornerRadius\n"
        "                ),\n"
        "                isDark: isDark,\n"
        "                tintColor: tintColor,\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        }\n"
        "        \n"
        "        if cardSize.width > 0.0, footerHeight > 0.0 {\n"
        "            let actionsView = self.aorusSheetPane(self.aorusActionsBackgroundView, host: self.contentBackgroundNode.view)\n"
        "            self.aorusActionsBackgroundView = actionsView\n"
        "            actionsView.isHidden = false\n"
        "            let actionsFrame = CGRect(origin: CGPoint(x: 0.0, y: cardHeight), size: CGSize(width: cardSize.width, height: footerHeight))\n"
        "            transition.updateFrame(view: actionsView, frame: actionsFrame)\n"
        "            actionsView.update(\n"
        "                size: actionsFrame.size,\n"
        "                cornerRadii: GlassBackgroundView.CornerRadii(topLeft: 0.0, topRight: 0.0, bottomLeft: cornerRadius, bottomRight: cornerRadius),\n"
        "                isDark: isDark,\n"
        "                tintColor: tintColor,\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        } else {\n"
        "            // Nothing standing at the foot of the card: the card's own pane has taken the\n"
        "            // corners back and covers the whole of it.\n"
        "            self.aorusActionsBackgroundView?.isHidden = true\n"
        "        }\n"
        "        \n"
        "        if cancelSize.width > 0.0, cancelSize.height > 0.0 {\n"
        "            let cancelView = self.aorusSheetPane(self.aorusCancelBackgroundView, host: self.cancelButtonNode.view)\n"
        "            self.aorusCancelBackgroundView = cancelView\n"
        "            transition.updateFrame(view: cancelView, frame: CGRect(origin: CGPoint(), size: cancelSize))\n"
        "            cancelView.update(\n"
        "                size: cancelSize,\n"
        "                cornerRadius: cornerRadius,\n"
        "                isDark: isDark,\n"
        "                tintColor: tintColor,\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the pane a host already has, or a new one under everything it holds -- the\n"
        "    // title of a button and the highlight of one both have to stay above the material.\n"
        "    private func aorusSheetPane(_ existing: GlassBackgroundView?, host: UIView) -> GlassBackgroundView {\n"
        "        if let existing {\n"
        "            return existing\n"
        "        }\n"
        "        let view = GlassBackgroundView(frame: CGRect())\n"
        "        view.isUserInteractionEnabled = false\n"
        "        host.insertSubview(view, at: 0)\n"
        "        return view\n"
        "    }\n"
        "    \n"
        "    private func contentNodeDidBeginDragging() {\n",
        "share sheet glass helpers",
    )

    text = _replace_once(
        text,
        "        transition.updateFrame(node: self.actionSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentContainerFrame.size.height - bottomGridInset - UIScreenPixel), size: CGSize(width: contentContainerFrame.size.width, height: UIScreenPixel)), beginWithCurrentState: true)\n",
        "        transition.updateFrame(node: self.actionSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentContainerFrame.size.height - bottomGridInset - UIScreenPixel), size: CGSize(width: contentContainerFrame.size.width, height: UIScreenPixel)), beginWithCurrentState: true)\n"
        "        \n"
        "        // AorusGram: the card's own size is read back off its node rather than taken from here,\n"
        "        // because this pass never sets it -- the drag handler below is the only thing that does.\n"
        "        // Selecting a peer changes the footer's height without moving the card, which is why the\n"
        "        // panes are laid out from both places.\n"
        "        self.aorusUpdateSheetGlass(cardSize: self.contentBackgroundNode.bounds.size, footerHeight: bottomGridInset, cancelSize: CGSize(width: width, height: buttonHeight), transition: transition)\n",
        "share sheet layout panes",
    )
    text = _replace_once(
        text,
        "        if let (layout, _, _) = self.containerLayout {\n",
        "        // AorusGram: the third of these is the height of the strip at the foot of the card, and\n"
        "        // the card's pane needs it to know where to stop.\n"
        "        if let (layout, _, bottomGridInset) = self.containerLayout {\n",
        "share sheet drag layout",
    )
    text = _replace_once(
        text,
        "            transition.updateFrame(node: self.contentBackgroundNode, frame: backgroundFrame)\n",
        "            transition.updateFrame(node: self.contentBackgroundNode, frame: backgroundFrame)\n"
        "            self.aorusUpdateSheetGlass(cardSize: backgroundFrame.size, footerHeight: bottomGridInset, cancelSize: CGSize(width: width, height: buttonHeight), transition: transition)\n",
        "share sheet drag panes",
    )
    path.write_text(text, encoding="utf-8")

    peers = tg / "submodules/ShareController/Sources/SharePeersContainerNode.swift"
    peers_text = _read(peers, "SharePeersContainerNode.swift")
    peers_text = _replace_once(
        peers_text,
        "        self.contentSeparatorNode.backgroundColor = self.theme.actionSheet.opaqueItemSeparatorColor\n",
        "        // AorusGram: the rule under the sheet's title, translucent over the material for the\n"
        "        // same reason as the one above the send button.\n"
        "        if AorusGlassPane.isEnabled {\n"
        "            self.contentSeparatorNode.backgroundColor = self.theme.overallDarkAppearance ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.1)\n"
        "        } else {\n"
        "            self.contentSeparatorNode.backgroundColor = self.theme.actionSheet.opaqueItemSeparatorColor\n"
        "        }\n",
        "share sheet title rule",
    )
    peers.write_text(peers_text, encoding="utf-8")
    print("InterfaceV2: made the share sheet glass")


def _patch_avatar_expansion(tg: Path) -> None:
    """Let a collapsed header scroll away at its own size instead of folding into the navigation bar.

    This pass is about the header a peer with no photo gets. Interface 2.0 opens a profile with a
    photo at full width -- see `_patch_keep_avatar_expanded`, which is what keeps it there -- and
    the letter placeholder cannot be expanded into anything, so those profiles open in Telegram's
    collapsed arrangement: the round avatar above a centred name.

    In that arrangement stock shrinks the avatar to 0.55 and locks the name under the status bar
    the moment the list moves, which turns the header from content into chrome. Holding the
    collapse fraction at zero leaves every size alone and lets the whole header travel with the
    list: `avatarScale` becomes 1, `avatarOffset` and `apparentTitleLockOffset` become 0, and
    the offset applied to the three labels becomes the scroll offset itself. The avatar then
    slides up behind the dynamic island through the clipping node that is already there, and
    the labels, which have no such node, fade over the last stretch before they would be drawn
    across the status bar.

    Only the collapsed branch is touched. The expanded one keeps stock's fraction on purpose: it
    is what hands the name to the navigation bar as the photo scrolls past it, and the photo
    itself is not sized from that fraction, so nothing shrinks there either.

    Settings keeps the stock header: its own avatar is small and it has no photo to preserve.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "aorusScrollingHeader" in text:
        print("InterfaceV2: header already scrolls at full size")
        return
    # The same two lines appear in the expanded branch, so the anchor starts at the centred
    # titleFrame that only the collapsed branch computes.
    text = _replace_once(
        text,
        "            titleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((width - titleSize.width) / 2.0), y: avatarFrame.maxY + 9.0 + (subtitleSize.height.isZero ? 11.0 : 0.0)), size: titleSize)\n"
        "            \n"
        "            var titleCollapseOffset = titleFrame.midY - statusBarHeight - titleLockOffset\n"
        "            if case .regular = metrics.widthClass, !isSettings, !isMyProfile {\n"
        "                titleCollapseOffset -= 7.0\n"
        "            }\n"
        "            titleOffset = -min(titleCollapseOffset, contentOffset)\n"
        "            titleCollapseFraction = max(0.0, min(1.0, contentOffset / titleCollapseOffset))\n",
        "            titleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((width - titleSize.width) / 2.0), y: avatarFrame.maxY + 9.0 + (subtitleSize.height.isZero ? 11.0 : 0.0)), size: titleSize)\n"
        "            \n"
        "            var titleCollapseOffset = titleFrame.midY - statusBarHeight - titleLockOffset\n"
        "            if case .regular = metrics.widthClass, !isSettings, !isMyProfile {\n"
        "                titleCollapseOffset -= 7.0\n"
        "            }\n"
        "            if aorusScrollingHeader {\n"
        "                // AorusGram: the header scrolls, and that is all it does. Every size in it\n"
        "                // is derived from this fraction -- the photo to 0.55, the name to 0.6, the\n"
        "                // lock offset under the status bar -- so holding it at zero is what keeps\n"
        "                // the photo the size it was drawn at and moves the whole header with the\n"
        "                // list instead of folding it into the navigation bar.\n"
        "                titleOffset = -contentOffset\n"
        "                titleCollapseFraction = 0.0\n"
        "            } else {\n"
        "                titleOffset = -min(titleCollapseOffset, contentOffset)\n"
        "                titleCollapseFraction = max(0.0, min(1.0, contentOffset / titleCollapseOffset))\n"
        "            }\n",
        "scrolling header collapse fraction",
    )
    text = _replace_once(
        text,
        "        let titleOffset: CGFloat\n"
        "        let titleCollapseFraction: CGFloat\n",
        "        let titleOffset: CGFloat\n"
        "        let titleCollapseFraction: CGFloat\n"
        "        // Settings is left with the stock header: its avatar is small to begin with and\n"
        "        // there is no photo there worth keeping at full size.\n"
        "        let aorusScrollingHeader = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "            && !isSettings\n",
        "scrolling header flag",
    )
    # updateFrameAdditiveToCenter, not updateFrameAdditive: that is the collapsed branch, and the
    # expanded one has a clipping node of its own to take the labels off screen.
    text = _replace_once(
        text,
        "                    var usernameCenter = rawUsernameFrame.center\n"
        "                    usernameCenter.x = rawTitleFrame.center.x + (usernameCenter.x - rawTitleFrame.center.x) * subtitleScale\n"
        "                    transition.updateFrameAdditiveToCenter(node: self.usernameNodeContainer, frame: CGRect(origin: usernameCenter, size: CGSize()).offsetBy(dx: 0.0, dy: titleOffset))\n"
        "                }\n",
        "                    var usernameCenter = rawUsernameFrame.center\n"
        "                    usernameCenter.x = rawTitleFrame.center.x + (usernameCenter.x - rawTitleFrame.center.x) * subtitleScale\n"
        "                    transition.updateFrameAdditiveToCenter(node: self.usernameNodeContainer, frame: CGRect(origin: usernameCenter, size: CGSize()).offsetBy(dx: 0.0, dy: titleOffset))\n"
        "                    if aorusScrollingHeader {\n"
        "                        // AorusGram: each label fades out as it reaches the status bar. The\n"
        "                        // photo has the clipping node above to take it behind the dynamic\n"
        "                        // island; these three are siblings of it and would otherwise carry on\n"
        "                        // over the clock. Recomputed every pass, so scrolling back brings\n"
        "                        // them all the way back.\n"
        "                        let aorusLabelAlpha: (CGRect) -> CGFloat = { frame in\n"
        "                            return max(0.0, min(1.0, (frame.minY + titleOffset - statusBarHeight) / 20.0))\n"
        "                        }\n"
        "                        transition.updateAlpha(node: self.titleNodeContainer, alpha: aorusLabelAlpha(rawTitleFrame))\n"
        "                        transition.updateAlpha(node: self.subtitleNodeContainer, alpha: aorusLabelAlpha(rawSubtitleFrame))\n"
        "                        transition.updateAlpha(node: self.usernameNodeContainer, alpha: aorusLabelAlpha(rawUsernameFrame))\n"
        "                    }\n"
        "                }\n",
        "scrolling header label fade",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: header scrolls at full size")


def _patch_keep_avatar_expanded(tg: Path) -> None:
    """Keep the photo at full width, and never expand one that is not there.

    Interface 2.0 opens a profile on the photo itself, edge to edge, because that photo is what
    the page under the whole screen takes its colour from: the page continues the colour the
    photo ends in, so the two have to meet. scripts/profile_personalization_patch.py opens the
    header in that state; this pass is what stops the screen from immediately taking it back.

    Eight places take it back, and each is a different reason.

    Telegram collapses the expanded photo as soon as the list scrolls a single point, which is
    what would make the photo snap into the corner on the first touch. It stays expanded and
    simply scrolls away instead -- nothing is pinned and no offset is faked, the header keeps
    the size it was drawn at.

    Four more collapse it to bring the tab strip to the top of the screen: choosing a tab,
    the panes asking for the strip to be expanded, scrolling a selection into view, and the
    controller's own expandTabs. All four already scroll the content afterwards, which is the
    part that was wanted; shrinking the photo as well is what made tapping Media snap it into
    the corner. Each asks the shared test below first.

    The header is built before the peer is loaded, so the flag alone cannot tell whether there
    is a photo to expand, and expanding a profile that has none is what breaks its layout. That
    is corrected on the pass that first learns there is no photo.

    Coming back from the avatar gallery and cancelling an edit both collapse the header
    deliberately, and both have to hand the photo back afterwards, because Interface 2.0 never
    opens on a small one and offers no way back to the big one except dragging.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift"
    text = _read(path, "PeerInfoScreen.swift")
    if "aorusKeepsAvatarExpanded" in text:
        print("InterfaceV2: avatar expansion already patched")
        return
    text = _replace_once(
        text,
        "    fileprivate func resetHeaderExpansion() {\n",
        "    // AorusGram: whether Interface 2.0 is holding this profile's photo at full width right\n"
        "    // now.\n"
        "    //\n"
        "    // Every path that collapses the header on its own initiative has to ask this first, or\n"
        "    // the mode lasts exactly until the first tap on a tab. Editing and an avatar upload are\n"
        "    // excluded because both need the small header to lay their own controls out, a forum\n"
        "    // topic because its header is the topic's and not a peer's, and a peer with no photo\n"
        "    // because there is nothing to hold open -- expanding one is what breaks its layout.\n"
        "    var aorusKeepsAvatarExpandedNow: Bool {\n"
        "        return UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "            && !self.isSettings\n"
        "            && !self.isMediaOnly\n"
        "            && self.chatLocation.threadId == nil\n"
        "            && self.state.updatingAvatar == nil\n"
        "            && !self.state.isEditing\n"
        "            && self.data?.peer?.smallProfileImage != nil\n"
        "    }\n"
        "    \n"
        "    fileprivate func resetHeaderExpansion() {\n",
        "keeps avatar expanded test",
    )
    text = _replace_once(
        text,
        "            } else if offsetY >= 1.0 {\n"
        "                shouldBeExpanded = false\n"
        "                self.canOpenAvatarByDragging = false\n"
        "            }\n",
        "            } else if offsetY >= 1.0 {\n"
        "                // AorusGram: Interface 2.0 keeps the photo at full width for the whole\n"
        "                // scroll instead of shrinking it into the corner on the first point of\n"
        "                // movement. Nothing is pinned and no offsets are faked -- the header just\n"
        "                // keeps the size it already had and scrolls with the content.\n"
        "                if !self.aorusKeepsAvatarExpandedNow {\n"
        "                    shouldBeExpanded = false\n"
        "                }\n"
        "                self.canOpenAvatarByDragging = false\n"
        "            }\n",
        "keep avatar expanded",
    )
    # The four tab-strip collapses. Each is `if <receiver>.headerNode.isAvatarExpanded {` followed by
    # the same spring transition, and they are told apart by their indentation and their receiver --
    # the pane callbacks capture strongSelf, ensurePaneRectVisible and expandTabs are on self.
    for label, receiver, indent in (
        ("current pane", "strongSelf", " " * 16),
        ("expand tabs request", "strongSelf", " " * 12),
        ("pane rect visible", "self", " " * 16),
        ("expand tabs", "self", " " * 8),
    ):
        text = _replace_once(
            text,
            indent + "if " + receiver + ".headerNode.isAvatarExpanded {\n"
            + indent + "    let transition: ContainedViewLayoutTransition = .animated(duration: 0.35, curve: .spring)\n",
            indent + "// AorusGram: bringing the tabs to the top is the scroll below, not this. Under\n"
            + indent + "// Interface 2.0 the photo stays the size it was drawn at and scrolls away with\n"
            + indent + "// the content, so tapping a tab no longer snaps it into the corner.\n"
            + indent + "if " + receiver + ".headerNode.isAvatarExpanded, !" + receiver + ".aorusKeepsAvatarExpandedNow {\n"
            + indent + "    let transition: ContainedViewLayoutTransition = .animated(duration: 0.35, curve: .spring)\n",
            "keep avatar expanded on " + label,
        )
    text = _replace_once(
        text,
        "        self.data = data\n",
        "        self.data = data\n"
        "        // AorusGram: the header opens expanded under Interface 2.0, which is right for a\n"
        "        // peer with a photo and wrong for one without -- and at init, before this peer\n"
        "        // existed, there was no way to tell the two apart. Corrected here, on the pass\n"
        "        // that first learns there is no photo, before it can be laid out that way.\n"
        "        if self.headerNode.isAvatarExpanded, !self.isSettings, !self.isMediaOnly,\n"
        "           UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\"),\n"
        "           data.peer?.smallProfileImage == nil {\n"
        "            self.headerNode.ignoreCollapse = true\n"
        "            self.headerNode.updateIsAvatarExpanded(false, transition: .immediate)\n"
        "            self.headerNode.ignoreCollapse = false\n"
        "            self.updateNavigationExpansionPresentation(isExpanded: false, animated: false)\n"
        "        }\n",
        "collapse without photo",
    )
    text = _replace_once(
        text,
        "    fileprivate func resetHeaderExpansion() {\n"
        "        if self.headerNode.isAvatarExpanded {\n",
        "    fileprivate func resetHeaderExpansion() {\n"
        "        // AorusGram: returning from the avatar gallery calls this, and under Interface 2.0\n"
        "        // collapsing there would leave the photo small until the user dragged it back --\n"
        "        // the one thing the mode exists to stop. The settings screen still resets, which is\n"
        "        // where the other caller lives.\n"
        "        if self.aorusKeepsAvatarExpandedNow {\n"
        "            return\n"
        "        }\n"
        "        if self.headerNode.isAvatarExpanded {\n",
        "keep avatar expanded after gallery",
    )
    text = _replace_once(
        text,
        "                    strongSelf.state = strongSelf.state.withIsEditing(false).withUpdatingBio(nil).withUpdatingBirthDate(nil).withIsEditingBirthDate(false).withUpdatingNote(nil)\n"
        "                    if let (layout, navigationHeight) = strongSelf.validLayout {\n",
        "                    strongSelf.state = strongSelf.state.withIsEditing(false).withUpdatingBio(nil).withUpdatingBirthDate(nil).withIsEditingBirthDate(false).withUpdatingNote(nil)\n"
        "                    // AorusGram: activateEdit collapsed the photo to make room for the\n"
        "                    // editing header, and leaving edit mode has to put it back. Without this,\n"
        "                    // Edit then Cancel is a way to reach a small-photo profile that Interface\n"
        "                    // 2.0 never opens on and offers no way back from. The state above already\n"
        "                    // reads as not editing, which is what the shared test needs.\n"
        "                    if !strongSelf.headerNode.isAvatarExpanded, strongSelf.aorusKeepsAvatarExpandedNow {\n"
        "                        strongSelf.headerNode.updateIsAvatarExpanded(true, transition: .immediate)\n"
        "                        strongSelf.updateNavigationExpansionPresentation(isExpanded: true, animated: false)\n"
        "                    }\n"
        "                    if let (layout, navigationHeight) = strongSelf.validLayout {\n",
        "re-expand avatar after editing",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: patched avatar expansion")


def _patch_undo_glass(tg: Path) -> None:
    """Make every toast in the app a pane of system glass.

    Telegram shows all of them through one node: the archive pill, "Link copied", the fork's own
    "restart required". It fills that pill with the tab bar's colour and lays a dark blur over it,
    which is the look Interface 2.0 replaces. `effectView` is already typed as a plain UIView, so
    the glass goes in as that view and the panel's own colour steps aside -- the layout, the
    corner radius, the timer and the action button are all untouched. Every label in this node is
    already white, so the pill stays readable whatever the theme is.
    """
    path = tg / "submodules/UndoUI/Sources/UndoOverlayControllerNode.swift"
    text = _read(path, "UndoOverlayControllerNode.swift")
    if "aorusGlassToast" in text:
        print("InterfaceV2: toasts already glass")
        return
    if _GLASS_IMPORT not in text:
        text = _replace_once(text, "import Display\n", "import Display\n" + _GLASS_IMPORT, "toast glass import")
    text = _replace_once(
        text,
        "        if presentationData.theme.overallDarkAppearance && !(self.appearance?.isBlurred == true) {\n"
        "            self.panelNode.backgroundColor = presentationData.theme.rootController.tabBar.backgroundColor\n"
        "        } else {\n"
        "            self.panelNode.backgroundColor = .clear\n"
        "        }\n",
        "        // AorusGram: the glass is the material under Interface 2.0, so the panel's own\n"
        "        // fill would sit on top of it and flatten it back into a tinted card.\n"
        "        let aorusGlassToast = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        if aorusGlassToast {\n"
        "            self.panelNode.backgroundColor = .clear\n"
        "        } else if presentationData.theme.overallDarkAppearance && !(self.appearance?.isBlurred == true) {\n"
        "            self.panelNode.backgroundColor = presentationData.theme.rootController.tabBar.backgroundColor\n"
        "        } else {\n"
        "            self.panelNode.backgroundColor = .clear\n"
        "        }\n",
        "toast panel colour",
    )
    text = _replace_once(
        text,
        "        self.effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))\n",
        "        if aorusGlassToast {\n"
        "            let glassView = GlassBackgroundView(frame: CGRect())\n"
        "            glassView.isUserInteractionEnabled = false\n"
        "            self.effectView = glassView\n"
        "        } else {\n"
        "            self.effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))\n"
        "        }\n",
        "toast effect view",
    )
    text = _replace_once(
        text,
        "        self.effectView.frame = CGRect(x: 0.0, y: 0.0, width: panelWidth, height: contentHeight)\n",
        "        self.effectView.frame = CGRect(x: 0.0, y: 0.0, width: panelWidth, height: contentHeight)\n"
        "        if let aorusGlassView = self.effectView as? GlassBackgroundView {\n"
        "            aorusGlassView.update(\n"
        "                size: CGSize(width: panelWidth, height: contentHeight),\n"
        "                cornerRadius: min(25.0, contentHeight * 0.5),\n"
        "                isDark: true,\n"
        "                tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        }\n",
        "toast effect frame",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the toasts glass")


def _patch_header_button_set(tg: Path) -> None:
    """Always four buttons in a profile header, whatever the peer is.

    Telegram's count swings between two and five: a bot loses the call button and gains "stop",
    a channel trades search for a leave button, a support account has no overflow menu at all.
    A row of glass circles only reads as a row when it is the same row in every profile, so
    Interface 2.0 fixes it at four -- one action, mute, search, more -- and lets the overflow
    menu carry whatever the peer's own list would have added, which is where the stock header
    already puts everything it cannot fit.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift"
    text = _read(path, "PeerInfoData.swift")
    if "aorusForcedButtons" in text:
        print("InterfaceV2: header button set already fixed at four")
        return
    text = _replace_once(
        text,
        "        result.append(.mute)\n"
        "        result.append(.search)\n"
        "        result.append(.more)\n"
        "    }\n"
        "    \n"
        "    return result\n"
        "}\n",
        "        result.append(.mute)\n"
        "        result.append(.search)\n"
        "        result.append(.more)\n"
        "    }\n"
        "    \n"
        "    // AorusGram: Interface 2.0 shows the same four buttons in every profile, bots and\n"
        "    // channels included. The leading one is whichever action the peer actually supports,\n"
        "    // so a user with calls gets the phone and a channel gets its chat; the other three are\n"
        "    // supported by every peer kind. An empty result is left alone -- that is a peer with no\n"
        "    // header buttons at all, not one with too few.\n"
        "    if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\"), threadInfo == nil, !result.isEmpty {\n"
        "        var aorusForcedButtons: [PeerInfoHeaderButtonKey] = []\n"
        "        for candidate in [PeerInfoHeaderButtonKey.call, .voiceChat, .message, .discussion] {\n"
        "            if result.contains(candidate) {\n"
        "                aorusForcedButtons.append(candidate)\n"
        "                break\n"
        "            }\n"
        "        }\n"
        "        if aorusForcedButtons.isEmpty {\n"
        "            // Opening the chat: the one action that means something for every peer, and the\n"
        "            // fallback for a bot or a deleted account whose own list offered nothing else.\n"
        "            aorusForcedButtons.append(.message)\n"
        "        }\n"
        "        aorusForcedButtons.append(.mute)\n"
        "        aorusForcedButtons.append(.search)\n"
        "        aorusForcedButtons.append(.more)\n"
        "        return aorusForcedButtons\n"
        "    }\n"
        "    \n"
        "    return result\n"
        "}\n",
        "four header buttons",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: fixed the header button set at four")


_LIST_GLASS_SWIFT = '''    // MARK: - AorusGram Interface 2.0

    /// Collects the card rectangles of the rows this node is showing.
    ///
    /// A row hands its background node `AorusGlassPane.blockMarker` under Interface 2.0, which makes
    /// the marked nodes exactly the set of cards -- laid out by the item that owns them, already
    /// overlapping their neighbours by the hairline that joins two rows of one section. Reading the
    /// geometry back beats recomputing it: there is no list of block item classes anywhere in the
    /// app to enumerate, and the items disagree about insets in ways that only they know.
    ///
    /// Two levels deep is enough for every item in the app: the background node is a direct child of
    /// the item node, and the one exception is an item that wraps its row in a container.
    private func aorusCollectCardRects(_ node: ASDisplayNode, depth: Int, into rects: inout [CGRect]) {
        guard let subnodes = node.subnodes else {
            return
        }
        for subnode in subnodes {
            if let color = subnode.backgroundColor, AorusGlassPane.isBlockMarker(color) {
                // Through the layer tree rather than the node tree, because the list is drawn in a
                // rotated coordinate space and a layer conversion is what accounts for that.
                let rect = subnode.layer.convert(subnode.bounds, to: self.layer)
                if rect.height > 1.0 {
                    rects.append(rect)
                }
            } else if depth > 0 {
                self.aorusCollectCardRects(subnode, depth: depth - 1, into: &rects)
            }
        }
    }

    /// One pane of real glass per block.
    ///
    /// Panes go under the list and over this node's own background, so the page colour is what the
    /// material refracts. Rounding both ends of every run is safe because the list keeps a node for
    /// everything inside its bounds: a run that ends where the retained rows end, rather than where
    /// its section does, ends off screen, and a corner nobody can see costs nothing.
    private func aorusUpdateListGlass() {
        var isEnabled = AorusGlassPane.isEnabled
        if let listStyle = self.listStyle, case .blocks = listStyle {
        } else {
            isEnabled = false
        }
        guard isEnabled, let (aorusLayout, _, _) = self.validLayout else {
            if let container = self.aorusGlassPaneContainer {
                self.aorusGlassPaneContainer = nil
                self.aorusGlassPanes.removeAll()
                container.removeFromSupernode()
            }
            return
        }

        var rects: [CGRect] = []
        self.listNode.forEachItemNode { itemNode in
            self.aorusCollectCardRects(itemNode, depth: 2, into: &rects)
        }
        rects.sort(by: { $0.minY < $1.minY })

        // Rows of one section overlap by a hairline and sections are 35pt apart, so anything closer
        // than a couple of points is the same block and nothing else comes near the threshold.
        let minX = self.aorusListInsets.left
        let width = max(0.0, aorusLayout.size.width - self.aorusListInsets.left - self.aorusListInsets.right)
        var runs: [CGRect] = []
        for rect in rects {
            if let last = runs.last, rect.minY - last.maxY < 3.0 {
                runs[runs.count - 1] = CGRect(x: minX, y: last.minY, width: width, height: max(last.maxY, rect.maxY) - last.minY)
            } else {
                runs.append(CGRect(x: minX, y: rect.minY, width: width, height: rect.height))
            }
        }

        let container: ASDisplayNode
        if let current = self.aorusGlassPaneContainer {
            container = current
        } else {
            container = ASDisplayNode()
            container.isUserInteractionEnabled = false
            container.clipsToBounds = true
            self.aorusGlassPaneContainer = container
            self.listNodeContainer.insertSubnode(container, belowSubnode: self.listNode)
        }
        container.frame = CGRect(origin: CGPoint(), size: aorusLayout.size)

        let isDark = self.theme?.overallDarkAppearance ?? true
        while self.aorusGlassPanes.count > runs.count {
            self.aorusGlassPanes.removeLast().removeFromSuperview()
        }
        for i in 0 ..< runs.count {
            let run = runs[i]
            let paneView: GlassBackgroundView
            if i < self.aorusGlassPanes.count {
                paneView = self.aorusGlassPanes[i]
            } else {
                paneView = GlassBackgroundView(frame: run)
                paneView.isUserInteractionEnabled = false
                self.aorusGlassPanes.append(paneView)
                container.view.addSubview(paneView)
            }
            paneView.frame = run
            paneView.update(
                size: run.size,
                cornerRadius: AorusGlassPane.blockCornerRadius,
                isDark: isDark,
                tintColor: GlassBackgroundView.TintColor(kind: .clear),
                isInteractive: false,
                isVisible: true,
                transition: .immediate
            )
        }
    }

'''


def _patch_item_list_glass(tg: Path) -> None:
    """Put one pane of real glass behind every block on every settings screen.

    The stock blocks screen is an opaque page with opaque cards on it. Interface 2.0 keeps the page
    -- glass needs something behind it to be glass about -- clears the cards, and lays a
    `GlassBackgroundView` under each run of rows that share a section. The rows keep their labels,
    their hairlines and their controls, and nothing else.

    Finding the runs is the interesting part, and it is done by reading back the marker fill: see
    `AorusGlassPane.blockMarker`. This is the one file every ItemList screen in the app is hosted
    by, so the username screen, the appearance screen and the several hundred others change
    together, with no per-item patches to keep in step.
    """
    path = tg / "submodules/ItemListUI/Sources/ItemListControllerNode.swift"
    text = _read(path, "ItemListControllerNode.swift")
    if "aorusGlassPanes" in text:
        print("InterfaceV2: settings lists already on glass")
        return
    if _GLASS_IMPORT not in text:
        text = _replace_once(
            text,
            "import GlassControls\n",
            "import GlassControls\n" + _GLASS_IMPORT,
            "list glass import",
        )
    text = _replace_once(
        text,
        "    private var previousContentOffset: ListViewVisibleContentOffset?\n",
        "    private var previousContentOffset: ListViewVisibleContentOffset?\n"
        "    // AorusGram: created on the first pass that finds a marked row, so a screen opened with\n"
        "    // Interface 2.0 off never builds an effect view it will not show.\n"
        "    private var aorusGlassPaneContainer: ASDisplayNode?\n"
        "    private var aorusGlassPanes: [GlassBackgroundView] = []\n"
        "    // The side insets the rows were laid out with. A row is as wide as the whole list and\n"
        "    // relies on the overlay nodes to cover its overhang, so the pane has to be told where\n"
        "    // the visible card actually starts and ends.\n"
        "    private var aorusListInsets = UIEdgeInsets()\n",
        "list glass properties",
    )
    # Both copies of the blocks branch: one runs on a theme change, the other when the style itself
    # changes. The anchor is the same text, so the same replacement is applied twice.
    blocks_old = (
        "                        case .blocks:\n"
        "                            self.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
        "                            self.listNode.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
    )
    blocks_new = (
        "                        case .blocks:\n"
        "                            // AorusGram: the page colour stays on this node's own layer,\n"
        "                            // which is what the panes above it refract. The list itself has\n"
        "                            // to go clear or it would cover them. The two side overlays keep\n"
        "                            // the page colour, and covering the row overhang is exactly the\n"
        "                            // job they already had.\n"
        "                            self.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
        "                            self.listNode.backgroundColor = AorusGlassPane.isEnabled ? UIColor.clear : transition.theme.list.blocksBackgroundColor\n"
    )
    text = _replace_once(text, blocks_old, blocks_new, "list glass colours on theme change")
    text = _replace_once(text, blocks_old, blocks_new, "list glass colours on style change")
    text = _replace_once(
        text,
        "    private func dequeueTransitions() {\n",
        _LIST_GLASS_SWIFT + "    private func dequeueTransitions() {\n",
        "list glass helper",
    )
    # Three moments change where the blocks are: a scroll, a new set of rows, and a relayout.
    text = _replace_once(
        text,
        "            strongSelf.previousContentOffset = offset\n"
        "        }\n",
        "            strongSelf.previousContentOffset = offset\n"
        "            strongSelf.aorusUpdateListGlass()\n"
        "        }\n",
        "list glass scroll hook",
    )
    text = _replace_once(
        text,
        "                    strongSelf.afterTransactionCompleted?()\n",
        "                    strongSelf.aorusUpdateListGlass()\n"
        "                    strongSelf.afterTransactionCompleted?()\n",
        "list glass transaction hook",
    )
    text = _replace_once(
        text,
        "        self.leftOverlayNode.frame = CGRect(x: 0.0, y: 0.0, width: insets.left, height: layout.size.height)\n",
        "        // AorusGram: the panes are cut to the same gutter the overlays cover.\n"
        "        self.aorusListInsets = insets\n"
        "        self.leftOverlayNode.frame = CGRect(x: 0.0, y: 0.0, width: insets.left, height: layout.size.height)\n",
        "list glass insets capture",
    )
    text = _replace_once(
        text,
        "        var layout = layout\n"
        "        layout.intrinsicInsets.left = 4.0\n",
        "        // AorusGram: follows the page through rotation and split-view resizes.\n"
        "        self.aorusUpdateListGlass()\n"
        "\n"
        "        var layout = layout\n"
        "        layout.intrinsicInsets.left = 4.0\n",
        "list glass layout hook",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: put every settings block on its own pane of glass")


def _patch_nav_button_glass(tg: Path) -> None:
    """Take the peer's colour out of the glass behind the navigation buttons.

    Telegram already draws these two on the system material -- the back chevron and the Edit
    label over the photo are glass in stock 12.9 -- but over a coloured header it tints that
    material with the colour it sampled from the photo. Interface 2.0 asks for the material and
    nothing else, so the tint goes clear and everything else about the container is left alone.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNavigationButtonContainerNode.swift"
    text = _read(path, "PeerInfoHeaderNavigationButtonContainerNode.swift")
    if "aorusPlainNavGlass" in text:
        print("InterfaceV2: navigation button glass already untinted")
        return
    text = _replace_once(
        text,
        "        let tintColor: GlassBackgroundView.TintColor\n"
        "        let tintIsDark: Bool\n"
        "        if self.isOverColoredContents {\n",
        "        let tintColor: GlassBackgroundView.TintColor\n"
        "        let tintIsDark: Bool\n"
        "        // AorusGram: plain material under Interface 2.0. The sampled colour is what makes\n"
        "        // the back button read as a tinted disc instead of glass, and the panel variant\n"
        "        // brings a rim with it.\n"
        "        let aorusPlainNavGlass = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        if aorusPlainNavGlass {\n"
        "            tintColor = .init(kind: .clear)\n"
        "            tintIsDark = self.isOverColoredContents ? true : presentationData.theme.overallDarkAppearance\n"
        "        } else if self.isOverColoredContents {\n",
        "navigation button glass tint",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: untinted the navigation button glass")


def _patch_gift_glass(tg: Path) -> None:
    """Give a plain gift card a real pane of glass instead of a flat block of theme colour.

    A gift with a cover brings its own colours and keeps every one of them -- those cards are the
    gift, not chrome. The plain card is the one that currently fills itself with
    `list.itemBlocksBackgroundColor`, which is exactly the opaque slab Interface 2.0 replaces
    elsewhere, so that fill drops and the card becomes glass.

    One pane per card view, reused as the grid recycles them and released the moment a card turns
    out to have a cover, so a screenful of gifts costs a screenful of panes and nothing is held for
    cards that are scrolled away.
    """
    path = tg / "submodules/TelegramUI/Components/Gifts/GiftItemComponent/Sources/GiftItemComponent.swift"
    text = _read(path, "GiftItemComponent.swift")
    if "aorusUpdateGlassBackground" in text:
        print("InterfaceV2: gift cards already glass")
        return
    if _GLASS_IMPORT not in text:
        text = _replace_once(
            text,
            "import BundleIconComponent\n",
            "import BundleIconComponent\n" + _GLASS_IMPORT,
            "gift glass import",
        )
    text = _replace_once(
        text,
        "            if let backgroundColor, let _ = secondBackgroundColor {\n"
        "                self.backgroundLayer.backgroundColor = backgroundColor.cgColor\n"
        "            } else {\n"
        "                if [.buttonIcon, .tableIcon].contains(component.mode) {\n"
        "                    \n"
        "                } else if case .upgradePreview = component.mode {\n"
        "                    self.backgroundLayer.backgroundColor = component.theme.list.itemModalBlocksBackgroundColor.cgColor\n"
        "                } else {\n"
        "                    self.backgroundLayer.backgroundColor = component.theme.list.itemBlocksBackgroundColor.cgColor\n"
        "                }\n"
        "            }\n",
        "            // AorusGram: true only for the card that would be a flat block of theme colour.\n"
        "            // A gift with a cover of its own is left exactly as it is.\n"
        "            var aorusPlainCard = false\n"
        "            if let backgroundColor, let _ = secondBackgroundColor {\n"
        "                self.backgroundLayer.backgroundColor = backgroundColor.cgColor\n"
        "            } else {\n"
        "                if [.buttonIcon, .tableIcon].contains(component.mode) {\n"
        "                    \n"
        "                } else if case .upgradePreview = component.mode {\n"
        "                    aorusPlainCard = true\n"
        "                    self.backgroundLayer.backgroundColor = component.theme.list.itemModalBlocksBackgroundColor.cgColor\n"
        "                } else {\n"
        "                    aorusPlainCard = true\n"
        "                    self.backgroundLayer.backgroundColor = component.theme.list.itemBlocksBackgroundColor.cgColor\n"
        "                }\n"
        "            }\n"
        "            if aorusPlainCard, UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") {\n"
        "                // The fill goes, or it would sit on the glass and flatten it back into a card.\n"
        "                self.backgroundLayer.backgroundColor = nil\n"
        "            }\n",
        "gift card plain fill",
    )
    text = _replace_once(
        text,
        "            transition.setFrame(layer: self.backgroundLayer, frame: backgroundFrame)\n",
        "            transition.setFrame(layer: self.backgroundLayer, frame: backgroundFrame)\n"
        "            self.aorusUpdateGlassBackground(\n"
        "                frame: backgroundFrame,\n"
        "                cornerRadius: cornerRadius,\n"
        "                isPlain: aorusPlainCard,\n"
        "                isDark: component.theme.overallDarkAppearance\n"
        "            )\n",
        "gift card glass call",
    )
    text = _replace_once(
        text,
        "        public var pattern: UIView? {\n",
        "        private var aorusGlassBackgroundView: GlassBackgroundView?\n"
        "\n"
        "        /// The card's own pane of glass, or none.\n"
        "        ///\n"
        "        /// Behind every other subview and above the card's own background layer, which under\n"
        "        /// Interface 2.0 no longer paints anything -- so the icon, the title and the ribbon all\n"
        "        /// keep the order they had and only what was behind them changes.\n"
        "        private func aorusUpdateGlassBackground(frame: CGRect, cornerRadius: CGFloat, isPlain: Bool, isDark: Bool) {\n"
        "            guard isPlain, UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") else {\n"
        "                if let glassView = self.aorusGlassBackgroundView {\n"
        "                    self.aorusGlassBackgroundView = nil\n"
        "                    glassView.removeFromSuperview()\n"
        "                }\n"
        "                return\n"
        "            }\n"
        "            let glassView: GlassBackgroundView\n"
        "            if let current = self.aorusGlassBackgroundView {\n"
        "                glassView = current\n"
        "            } else {\n"
        "                glassView = GlassBackgroundView(frame: CGRect())\n"
        "                glassView.isUserInteractionEnabled = false\n"
        "                self.aorusGlassBackgroundView = glassView\n"
        "                self.insertSubview(glassView, at: 0)\n"
        "            }\n"
        "            glassView.frame = frame\n"
        "            glassView.update(\n"
        "                size: frame.size,\n"
        "                cornerRadius: cornerRadius,\n"
        "                isDark: isDark,\n"
        "                tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "                isInteractive: false,\n"
        "                isVisible: true,\n"
        "                transition: .immediate\n"
        "            )\n"
        "        }\n"
        "\n"
        "        public var pattern: UIView? {\n",
        "gift card glass view",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the gift cards glass")


def _patch_pane_container_glass(tg: Path) -> None:
    """Carry the page under the tabs, so the profile has no edge across it.

    The pane container paints a block of `list.blocksBackgroundColor` over everything from the
    tabs strip down. On a page tinted from the avatar that block is a hard horizontal edge
    partway down the profile -- the seam. Going transparent instead continues whatever the screen
    is painted with, which is the tint on a profile and the theme colour everywhere else, without
    this node having to know either.

    The tabs themselves are already real glass upstream, but asked for as `.panel`, which is the
    variant that brings a tint and a rim. Interface 2.0 asks for the plain material here for the
    same reason it does behind the navigation buttons.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoPaneContainerNode.swift"
    text = _read(path, "PeerInfoPaneContainerNode.swift")
    if "aorusPlainPanes" in text:
        print("InterfaceV2: pane container already continues the page")
        return
    text = _replace_once(
        text,
        "        self.backgroundColor = backgroundColor\n",
        "        // AorusGram: under Interface 2.0 the panes continue the page rather than covering\n"
        "        // it. Cleared rather than tinted here: the screen behind is already painted with\n"
        "        // the avatar's colour, so transparency inherits it and stays right through a\n"
        "        // push, when the colour belongs to whichever profile is being laid out.\n"
        "        let aorusPlainPanes = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        if aorusPlainPanes {\n"
        "            // Opaque is what an ASDisplayNode is by default, and this one has always had\n"
        "            // a colour to justify it. Painting nothing while keeping the flag is how a\n"
        "            // node ends up showing black instead of what is behind it.\n"
        "            self.isOpaque = false\n"
        "            self.backgroundColor = nil\n"
        "        } else {\n"
        "            self.backgroundColor = backgroundColor\n"
        "        }\n",
        "pane container background",
    )
    text = _replace_once(
        text,
        "        self.tabsBackgroundView.update(size: tabContainerFrame.size, cornerRadius: tabContainerFrame.height * 0.5, isDark: presentationData.theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: ComponentTransition(transition))\n",
        "        self.tabsBackgroundView.update(size: tabContainerFrame.size, cornerRadius: tabContainerFrame.height * 0.5, isDark: presentationData.theme.overallDarkAppearance, tintColor: .init(kind: aorusPlainPanes ? .clear : .panel), transition: ComponentTransition(transition))\n",
        "tabs glass tint",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: pane container continues the page")


def _patch_pane_page_background(tg: Path) -> None:
    """Let the gifts pane show the page instead of covering it.

    The pane container above this one already goes transparent under Interface 2.0, but the gifts
    pane paints a second opaque rectangle of its own, from the tabs strip all the way down. That
    rectangle is the dark band below the tabs: the top half of the profile is the avatar's colour
    and the bottom half is the theme's, with a hard edge between them.

    The bottom fade goes with it. It is a gradient of the same page colour drawn under the pin
    panel, and the colour it faded to is no longer the colour of anything on this screen, so the
    fade would read as a smear of the wrong grey rather than as depth. Clear leaves the gifts
    running under the panel, which is already real glass and reads them perfectly well.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoVisualMediaPaneNode/Sources/PeerInfoGiftsPaneNode.swift"
    text = _read(path, "PeerInfoGiftsPaneNode.swift")
    if "aorusContinuesPage" in text:
        print("InterfaceV2: gifts pane already continues the page")
        return
    text = _replace_once(
        text,
        "        self.backgroundNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor\n",
        "        // AorusGram: nothing at all under Interface 2.0, so that the page the profile is\n"
        "        // painted with -- the colour the avatar ends on -- carries on through the gifts.\n"
        "        // isOpaque has to go with the colour: a node that keeps the flag while painting\n"
        "        // nothing is how a view ends up black instead of transparent.\n"
        "        let aorusContinuesPage = AorusGlassPane.isEnabled\n"
        "        self.backgroundNode.isOpaque = !aorusContinuesPage\n"
        "        self.backgroundNode.backgroundColor = aorusContinuesPage ? nil : presentationData.theme.list.blocksBackgroundColor\n",
        "gifts pane background",
    )
    text = _replace_once(
        text,
        "            panelEdgeEffectView.update(content: presentationData.theme.list.blocksBackgroundColor, blur: false, rect: edgeEffectFrame, edge: .bottom, edgeSize: 40.0, transition: panelTransition)\n",
        "            panelEdgeEffectView.update(content: AorusGlassPane.isEnabled ? UIColor.clear : presentationData.theme.list.blocksBackgroundColor, blur: false, rect: edgeEffectFrame, edge: .bottom, edgeSize: 40.0, transition: panelTransition)\n",
        "gifts pane edge fade",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: gifts pane continues the page")


def _patch_members_pane_glass(tg: Path) -> None:
    """Give the members list the page it sits on instead of a black card.

    Every other pane in a profile goes transparent under Interface 2.0 and lets the page show
    through. This one cannot, because its block is not drawn the way the rest of the client draws
    blocks: it is two opaque rectangles instead of a row background. A rounded one tinted with
    `itemBlocksBackgroundColor` behind the list, and a second one above it -- white everywhere
    except a rounded hole punched in the middle -- tinted with the page colour so that the hole
    reads as the block's shape. That second rectangle is the black frame around the members list,
    the 16pt gutter down each side and the four corners the radius leaves out.

    Turning it off is not an option: the hole is what keeps the first row's avatar inside the
    block's rounded corner, and the tap highlight, which runs the full width of a row, inside its
    sides. So it goes on painting -- the page instead of the theme.

    Which is two different things, because the page has two forms. For a peer with no photo the
    page is a flat colour, and it is `blocksBackgroundColor`, the very colour this mask already
    uses: nothing to change. For a peer with a photo the page is Telegram's own bottom blur block
    kept as one row and stretched over the whole screen, so there the mask stops painting and
    becomes the mask of a view holding that same row -- laid over the screen backdrop's own
    rectangle, converted into this pane's coordinates. Not over the pane's bounds: the two are
    stretched to different heights, and anything with a gradient down it would meet itself at the
    pane's top edge as a join.

    The block behind the rows becomes real glass, cornered at the same 26 as every other block on
    the page.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/Panes/PeerInfoMembersPane.swift"
    text = _read(path, "PeerInfoMembersPane.swift")
    if "aorusPageFillView" in text:
        print("InterfaceV2: members pane already shows the page")
        return
    if _GLASS_IMPORT not in text:
        text = _replace_once(
            text,
            "import Display\n",
            "import Display\n" + _GLASS_IMPORT + "import ComponentFlow\nimport AorusGramUI\n",
            "members pane import",
        )
    text = _replace_once(
        text,
        "    private let listBackgroundView: UIImageView\n"
        "    private let listMaskView: UIImageView\n",
        "    private let listBackgroundView: UIImageView\n"
        "    private let listMaskView: UIImageView\n"
        "    // AorusGram: the peer whose page this pane sits on, kept in the form the tint is\n"
        "    // keyed by, and the glass and page fill that replace the card under Interface 2.0.\n"
        "    private let aorusPeerId: Int64\n"
        "    private var aorusGlassBackgroundView: GlassBackgroundView?\n"
        "    // The fill is two views: a plain one cut to the shape of the rows, and the picture\n"
        "    // inside it. They have to be two, because the shape is measured in the pane's own\n"
        "    // coordinates and the picture is laid over the screen's backdrop -- which begins a few\n"
        "    // hundred points above the pane, and often at a negative y from here.\n"
        "    private var aorusPageFillView: UIView?\n"
        "    private var aorusPageImageView: UIImageView?\n"
        "    // The screen's own backdrop, so its rectangle can be asked for rather than guessed at.\n"
        "    // Weak and re-found on demand: it belongs to the screen, not to this pane.\n"
        "    private weak var aorusPageBackdropView: UIView?\n"
        "    // What the two rectangles were last laid out at, and the theme they were laid out from,\n"
        "    // so a page that changes under a pane that is not being laid out can still be answered.\n"
        "    private var aorusLastBackgroundFrame: CGRect?\n"
        "    private var aorusPresentationData: PresentationData?\n"
        "    private var aorusPageObserver: NSObjectProtocol?\n"
        "    // What the page falls back to for a peer with no photo, which is also what the mask\n"
        "    // has to be handed back if a photo it was shaping ever goes away.\n"
        "    private var aorusPageFallbackColor: UIColor = .clear\n",
        "members pane properties",
    )
    text = _replace_once(
        text,
        "        self.context = context\n"
        "        self.membersContext = membersContext\n",
        "        self.context = context\n"
        "        self.membersContext = membersContext\n"
        "        self.aorusPeerId = peerId.id._internalGetInt64Value()\n",
        "members pane peer id",
    )
    text = _replace_once(
        text,
        "        self.listNode.visibleContentOffsetChanged = { [weak self] _, transition in\n",
        "        // AorusGram: paging through a peer's avatars changes the page under the profile, and\n"
        "        // nothing tells a pane about it. PeerInfoPaneWrapper.update memoises its parameters\n"
        "        // and returns early when none of them have changed -- and a swipe between two photos\n"
        "        // changes none of them: same size, same insets, same visible height. So the pane kept\n"
        "        // the previous photo's backdrop until the reader happened to scroll it, which is the\n"
        "        // report this answers. Listened for here instead, where the pane can lay its own two\n"
        "        // rectangles out again without the wrapper being involved at all.\n"
        "        self.aorusPageObserver = NotificationCenter.default.addObserver(forName: AorusGlassProfileTint.pageDidChangeNotification, object: nil, queue: .main) { [weak self] _ in\n"
        "            self?.aorusPageDidChange()\n"
        "        }\n"
        "        \n"
        "        self.listNode.visibleContentOffsetChanged = { [weak self] _, transition in\n",
        "members pane page observer",
    )
    text = _replace_once(
        text,
        "    deinit {\n"
        "        self.disposable?.dispose()\n"
        "    }\n",
        "    deinit {\n"
        "        self.disposable?.dispose()\n"
        "        if let aorusPageObserver = self.aorusPageObserver {\n"
        "            NotificationCenter.default.removeObserver(aorusPageObserver)\n"
        "        }\n"
        "    }\n",
        "members pane observer teardown",
    )
    text = _replace_once(
        text,
        "        self.currentParams = (size, isScrollingLockedAtTop)\n"
        "        self.presentationDataPromise.set(.single(presentationData))\n",
        "        self.currentParams = (size, isScrollingLockedAtTop)\n"
        "        // AorusGram: the rows are built from the theme this promise carries, so routing it\n"
        "        // here is what gives them the white labels and hairline separators of every section\n"
        "        // on the page above them. It also turns their block fill into the marker colour,\n"
        "        // which is the other half of why the card below can be cleared rather than painted.\n"
        "        //\n"
        "        // The underived one is kept as well, because the derivation depends on the page: the\n"
        "        // ink is whatever reads over it, and a peer's photos are not all light or all dark.\n"
        "        // Swiping to a pale avatar has to re-derive from here rather than reuse a theme whose\n"
        "        // labels were white for the one before it.\n"
        "        self.aorusPresentationData = presentationData\n"
        "        var presentationData = presentationData\n"
        "        if AorusGlassPane.isEnabled {\n"
        "            presentationData = presentationData.withUpdated(theme: presentationData.theme.aorusGlassProfileTheme)\n"
        "        }\n"
        "        self.aorusPageFallbackColor = presentationData.theme.list.blocksBackgroundColor\n"
        "        self.presentationDataPromise.set(.single(presentationData))\n",
        "members pane theme",
    )
    text = _replace_once(
        text,
        "        self.listBackgroundView.tintColor = presentationData.theme.list.itemBlocksBackgroundColor\n"
        "        self.listMaskView.tintColor = presentationData.theme.list.blocksBackgroundColor\n",
        "        // AorusGram: clear, because the glass laid behind it under Interface 2.0 is the\n"
        "        // card now, and anything painted over that material flattens it. The mask keeps\n"
        "        // the page colour it always had unless it has been taken over as the shape of the\n"
        "        // page fill, where opaque white is what gives the template image an alpha to cut\n"
        "        // with -- updateListBackground above has already decided which of the two it is.\n"
        "        self.listBackgroundView.tintColor = AorusGlassPane.isEnabled ? UIColor.clear : presentationData.theme.list.itemBlocksBackgroundColor\n"
        "        self.listMaskView.tintColor = self.aorusPageFillView != nil ? UIColor.white : presentationData.theme.list.blocksBackgroundColor\n",
        "members pane tints",
    )
    text = _replace_once(
        text,
        "        transition.updateFrame(view: self.listBackgroundView, frame: listBackgroundFrame)\n"
        "        transition.updateFrame(view: self.listMaskView, frame: listMaskFrame)\n"
        "    }\n",
        "        transition.updateFrame(view: self.listBackgroundView, frame: listBackgroundFrame)\n"
        "        transition.updateFrame(view: self.listMaskView, frame: listMaskFrame)\n"
        "        self.aorusUpdateGlass(backgroundFrame: listBackgroundFrame, transition: transition)\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the glass this pane's block is made of, and the page that shows through\n"
        "    // the frame around it. Called from the same place the two rectangles are laid out, so\n"
        "    // it tracks them through every scroll without a second pass.\n"
        "    private func aorusUpdateGlass(backgroundFrame: CGRect, transition: ContainedViewLayoutTransition) {\n"
        "        self.aorusLastBackgroundFrame = backgroundFrame\n"
        "        guard AorusGlassPane.isEnabled else {\n"
        "            self.aorusReleaseMask()\n"
        "            if let glassView = self.aorusGlassBackgroundView {\n"
        "                self.aorusGlassBackgroundView = nil\n"
        "                glassView.removeFromSuperview()\n"
        "            }\n"
        "            return\n"
        "        }\n"
        "        \n"
        "        let glassView: GlassBackgroundView\n"
        "        if let current = self.aorusGlassBackgroundView {\n"
        "            glassView = current\n"
        "        } else {\n"
        "            glassView = GlassBackgroundView(frame: backgroundFrame)\n"
        "            glassView.isUserInteractionEnabled = false\n"
        "            self.aorusGlassBackgroundView = glassView\n"
        "            self.view.insertSubview(glassView, at: 0)\n"
        "        }\n"
        "        transition.updateFrame(view: glassView, frame: backgroundFrame)\n"
        "        glassView.update(\n"
        "            size: backgroundFrame.size,\n"
        "            cornerRadius: 26.0,\n"
        "            isDark: true,\n"
        "            tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "            isInteractive: false,\n"
        "            isVisible: true,\n"
        "            transition: .immediate\n"
        "        )\n"
        "        \n"
        "        // No picture means a peer with no photo, and there the page is one flat colour that\n"
        "        // the mask is already painting. Nothing to take over.\n"
        "        guard let pageImage = AorusGlassProfileTint.pageBackgroundImage(for: self.aorusPeerId) else {\n"
        "            self.aorusReleaseMask()\n"
        "            return\n"
        "        }\n"
        "        let fillView: UIView\n"
        "        let imageView: UIImageView\n"
        "        if let currentFill = self.aorusPageFillView, let currentImage = self.aorusPageImageView {\n"
        "            fillView = currentFill\n"
        "            imageView = currentImage\n"
        "        } else {\n"
        "            fillView = UIView()\n"
        "            fillView.isUserInteractionEnabled = false\n"
        "            imageView = UIImageView()\n"
        "            imageView.contentMode = .scaleToFill\n"
        "            imageView.layer.magnificationFilter = .linear\n"
        "            imageView.isUserInteractionEnabled = false\n"
        "            fillView.addSubview(imageView)\n"
        "            self.aorusPageFillView = fillView\n"
        "            self.aorusPageImageView = imageView\n"
        "            // The mask leaves the hierarchy to become one: a view cannot both be a subview\n"
        "            // and shape another. Its frame goes on being set by the caller above, and it\n"
        "            // still lands in the right place, because the view it now cuts covers the\n"
        "            // pane's own bounds -- the same space that frame was always measured in.\n"
        "            self.listMaskView.removeFromSuperview()\n"
        "            self.listMaskView.tintColor = .white\n"
        "            fillView.mask = self.listMaskView\n"
        "            self.view.addSubview(fillView)\n"
        "        }\n"
        "        fillView.frame = CGRect(origin: CGPoint(), size: self.listNode.visibleSize)\n"
        "        if imageView.image !== pageImage {\n"
        "            imageView.image = pageImage\n"
        "        }\n"
        "        // The picture goes exactly where the screen's own backdrop is, converted into this\n"
        "        // pane's coordinates -- not over the pane's bounds. Both views then stretch one image\n"
        "        // over one rectangle, so the row of it at the pane's top edge is the row the page has\n"
        "        // immediately above that edge, whatever the pane's height happens to be. Stretching\n"
        "        // the same picture over two different rectangles is what put a visible join across the\n"
        "        // top of the members tab; the page is a single row again now and has nothing down it to\n"
        "        // line up, but the alignment is what keeps that true of any page it is handed.\n"
        "        //\n"
        "        // With no backdrop found -- which would mean the screen has not laid one out -- the\n"
        "        // pane's own bounds are the honest fallback rather than nothing at all.\n"
        "        var imageFrame = CGRect(origin: CGPoint(), size: self.listNode.visibleSize)\n"
        "        if let backdropView = self.aorusPageBackdrop() {\n"
        "            imageFrame = self.view.convert(backdropView.bounds, from: backdropView)\n"
        "        }\n"
        "        imageView.frame = imageFrame\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the screen's backdrop, looked up once and kept until it goes away. Walking\n"
        "    // up from here rather than being handed down: the pane is built by the pane container,\n"
        "    // which knows nothing about the page, and every view between the two is Telegram's.\n"
        "    private func aorusPageBackdrop() -> UIView? {\n"
        "        if let existing = self.aorusPageBackdropView, existing.superview != nil {\n"
        "            return existing\n"
        "        }\n"
        "        var ancestor: UIView? = self.view.superview\n"
        "        while let current = ancestor {\n"
        "            for subview in current.subviews {\n"
        "                if subview.tag == AorusGlassProfileTint.backdropTag {\n"
        "                    self.aorusPageBackdropView = subview\n"
        "                    return subview\n"
        "                }\n"
        "            }\n"
        "            ancestor = current.superview\n"
        "        }\n"
        "        return nil\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the page changed under a pane nobody is laying out -- an avatar was swiped.\n"
        "    // Both halves have to follow it: the picture, and the ink the rows are drawn in, which is\n"
        "    // derived from the page and so is not the same ink for a pale photo as for a dark one.\n"
        "    private func aorusPageDidChange() {\n"
        "        guard AorusGlassPane.isEnabled else {\n"
        "            return\n"
        "        }\n"
        "        if let presentationData = self.aorusPresentationData {\n"
        "            let aorusTheme = presentationData.theme.aorusGlassProfileTheme\n"
        "            self.aorusPageFallbackColor = aorusTheme.list.blocksBackgroundColor\n"
        "            self.presentationDataPromise.set(.single(presentationData.withUpdated(theme: aorusTheme)))\n"
        "        }\n"
        "        if let backgroundFrame = self.aorusLastBackgroundFrame {\n"
        "            self.aorusUpdateGlass(backgroundFrame: backgroundFrame, transition: .immediate)\n"
        "        }\n"
        "        if self.aorusPageFillView == nil {\n"
        "            self.listMaskView.tintColor = self.aorusPageFallbackColor\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    // AorusGram: hand the mask back its place above the list, and its own paint with it.\n"
        "    private func aorusReleaseMask() {\n"
        "        guard let fillView = self.aorusPageFillView else {\n"
        "            return\n"
        "        }\n"
        "        self.aorusPageFillView = nil\n"
        "        self.aorusPageImageView = nil\n"
        "        fillView.mask = nil\n"
        "        fillView.removeFromSuperview()\n"
        "        self.listMaskView.tintColor = self.aorusPageFallbackColor\n"
        "        self.view.addSubview(self.listMaskView)\n"
        "    }\n",
        "members pane glass",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: members pane shows the page")


def _patch_groups_pane_glass(tg: Path) -> None:
    """Give the groups tab the same glass the members tab has, instead of a black rectangle.

    This is the tab a bot's profile calls "Groups" -- the groups it has been added to -- and on any
    other peer the groups you have in common. It is built the way the members tab is built, out of
    the same two opaque rectangles: a rounded one behind the list and a second one above it with a
    rounded hole punched in the middle, so the hole reads as the block's shape and keeps the first
    row's avatar inside its corner. Everything `_patch_members_pane_glass` says about why those two
    cannot simply be turned off applies here word for word, and so does what it does about it: the
    card becomes real glass at the same 26, and the frame around it paints the page.

    What is different is the rows, and it is the whole of what was reported. The members tab is
    built from `ContactsPeerItem` with `systemStyle: .glass`, which paints no fill of its own; this
    one is built from `ItemListPeerItem` at `style: .plain`, which paints `plainBackgroundColor`
    behind every row -- pure black under the dark theme. So the rows covered the card, corners and
    all, and the tab came out as the black rectangle the reader photographed. Even upstream that is
    a rough edge: black rows over a near-black card. Here they stop painting a fill entirely
    (`displayBackground: false`) and take the glass style's own metrics, which is what puts their
    height and their separator insets where the members tab already has them.

    The rows also have to be told when the ink changes. This pane has no `presentationDataPromise`
    to push a theme through -- its rows are built by `updatePeers` out of `currentParams` -- so the
    derived theme is routed in at the top of `update`, and the entry carries the page it was built
    for so that the list's merge can see a swipe to a paler photo as a change worth rebuilding.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/Panes/PeerInfoGroupsInCommonPaneNode.swift"
    text = _read(path, "PeerInfoGroupsInCommonPaneNode.swift")
    if "aorusPageFillView" in text:
        print("InterfaceV2: groups pane already shows the page")
        return
    if _GLASS_IMPORT not in text:
        text = _replace_once(
            text,
            "import Display\n",
            "import Display\n" + _GLASS_IMPORT + "import ComponentFlow\nimport AorusGramUI\n",
            "groups pane import",
        )
    text = _replace_once(
        text,
        "private struct GroupsInCommonListEntry: Comparable, Identifiable {\n"
        "    var index: Int\n"
        "    var peer: EnginePeer\n",
        "private struct GroupsInCommonListEntry: Comparable, Identifiable {\n"
        "    var index: Int\n"
        "    var peer: EnginePeer\n"
        "    // AorusGram: which of the two inks this row was built for. Interface 2.0 takes a row's\n"
        "    // colours from the page under the profile, and the page is whatever the avatar sampled to,\n"
        "    // so a pale photo wants near-black labels where a dark one wants white. The list's merge\n"
        "    // only rebuilds an entry it can see a difference in, and without this it can see none --\n"
        "    // the group has not changed -- so paging to a photo the other side of readable would leave\n"
        "    // the labels behind. Defaulted rather than passed in, so the one place that builds these\n"
        "    // does not have to know about it.\n"
        "    var aorusPageIsDark: Bool = AorusGlassPane.profilePageIsDark\n",
        "groups pane entry page",
    )
    text = _replace_once(
        text,
        "    static func ==(lhs: GroupsInCommonListEntry, rhs: GroupsInCommonListEntry) -> Bool {\n"
        "        return lhs.peer == rhs.peer\n"
        "    }\n",
        "    static func ==(lhs: GroupsInCommonListEntry, rhs: GroupsInCommonListEntry) -> Bool {\n"
        "        return lhs.peer == rhs.peer && lhs.aorusPageIsDark == rhs.aorusPageIsDark\n"
        "    }\n",
        "groups pane entry equality",
    )
    text = _replace_once(
        text,
        "        return ItemListPeerItem(presentationData: ItemListPresentationData(presentationData), dateTimeFormat:",
        "        // AorusGram: the glass style's own metrics -- a row a point taller and its separator\n"
        "        // held 16 off the right edge -- so this tab and the members tab, which is built from a\n"
        "        // different item entirely, do not sit at two different rhythms inside the same profile.\n"
        "        // And no fill of its own: a plain row paints plainBackgroundColor, which is black under\n"
        "        // the dark theme, and a run of them painted straight over the card -- the black rectangle\n"
        "        // this tab was reported as. What the row leaves alone, the glass below shows; the\n"
        "        // separators and the tap highlight still come from the derived theme, so nothing is lost\n"
        "        // but the sheet of paint.\n"
        "        return ItemListPeerItem(presentationData: ItemListPresentationData(presentationData), systemStyle: AorusGlassPane.isEnabled ? .glass : .legacy, dateTimeFormat:",
        "groups pane item style",
    )
    text = _replace_once(
        text,
        "        }, hasTopStripe: false, noInsets: true, noCorners: true, style: .plain)\n",
        "        }, hasTopStripe: false, noInsets: true, noCorners: true, style: .plain, displayBackground: !AorusGlassPane.isEnabled)\n",
        "groups pane item background",
    )
    text = _replace_once(
        text,
        "    private let listBackgroundView: UIImageView\n"
        "    private let listMaskView: UIImageView\n",
        "    private let listBackgroundView: UIImageView\n"
        "    private let listMaskView: UIImageView\n"
        "    // AorusGram: the peer whose page this pane sits on, in the form the tint is keyed by.\n"
        "    // Computed rather than stored: the pane is handed the id already and one form of it is\n"
        "    // enough to keep in sync.\n"
        "    private var aorusPeerId: Int64 {\n"
        "        return self.peerId.id._internalGetInt64Value()\n"
        "    }\n"
        "    // The glass and the page fill that replace the card under Interface 2.0. The fill is two\n"
        "    // views: a plain one cut to the shape of the rows, and the picture inside it. They have to\n"
        "    // be two, because the shape is measured in the pane's own coordinates and the picture is\n"
        "    // laid over the screen's backdrop -- which begins a few hundred points above the pane, and\n"
        "    // often at a negative y from here.\n"
        "    private var aorusGlassBackgroundView: GlassBackgroundView?\n"
        "    private var aorusPageFillView: UIView?\n"
        "    private var aorusPageImageView: UIImageView?\n"
        "    // The screen's own backdrop, so its rectangle can be asked for rather than guessed at.\n"
        "    // Weak and re-found on demand: it belongs to the screen, not to this pane.\n"
        "    private weak var aorusPageBackdropView: UIView?\n"
        "    // What the two rectangles were last laid out at, and the theme they were laid out from,\n"
        "    // so a page that changes under a pane that is not being laid out can still be answered.\n"
        "    private var aorusLastBackgroundFrame: CGRect?\n"
        "    private var aorusPresentationData: PresentationData?\n"
        "    private var aorusPageObserver: NSObjectProtocol?\n"
        "    // What the page falls back to for a peer with no photo, which is also what the mask\n"
        "    // has to be handed back if a photo it was shaping ever goes away.\n"
        "    private var aorusPageFallbackColor: UIColor = .clear\n",
        "groups pane properties",
    )
    text = _replace_once(
        text,
        "        self.listNode.visibleContentOffsetChanged = { [weak self] _, transition in\n",
        "        // AorusGram: paging through a peer's avatars changes the page under the profile, and\n"
        "        // nothing tells a pane about it -- PeerInfoPaneWrapper.update memoises its parameters\n"
        "        // and a swipe between two photos changes none of them. Listened for here instead,\n"
        "        // where the pane can lay its own rectangles out again and rebuild its rows in the new\n"
        "        // ink without the wrapper being involved at all.\n"
        "        self.aorusPageObserver = NotificationCenter.default.addObserver(forName: AorusGlassProfileTint.pageDidChangeNotification, object: nil, queue: .main) { [weak self] _ in\n"
        "            self?.aorusPageDidChange()\n"
        "        }\n"
        "        \n"
        "        self.listNode.visibleContentOffsetChanged = { [weak self] _, transition in\n",
        "groups pane page observer",
    )
    text = _replace_once(
        text,
        "    deinit {\n"
        "        self.disposable?.dispose()\n"
        "    }\n",
        "    deinit {\n"
        "        self.disposable?.dispose()\n"
        "        if let aorusPageObserver = self.aorusPageObserver {\n"
        "            NotificationCenter.default.removeObserver(aorusPageObserver)\n"
        "        }\n"
        "    }\n",
        "groups pane observer teardown",
    )
    text = _replace_once(
        text,
        "        let isFirstLayout = self.currentParams == nil\n"
        "        self.currentParams = (size, isScrollingLockedAtTop, presentationData)\n",
        "        let isFirstLayout = self.currentParams == nil\n"
        "        // AorusGram: the rows are built from whatever theme currentParams is holding, so the\n"
        "        // derived one goes in here -- that is what gives them the white labels and hairline\n"
        "        // separators of every section on the page above them.\n"
        "        //\n"
        "        // The underived one is kept as well, because the derivation depends on the page: the\n"
        "        // ink is whatever reads over it, and a peer's photos are not all light or all dark.\n"
        "        // Swiping to a pale avatar has to re-derive from that rather than from a theme whose\n"
        "        // labels were already white for the photo before it -- deriving twice is a no-op.\n"
        "        self.aorusPresentationData = presentationData\n"
        "        var presentationData = presentationData\n"
        "        if AorusGlassPane.isEnabled {\n"
        "            presentationData = presentationData.withUpdated(theme: presentationData.theme.aorusGlassProfileTheme)\n"
        "        }\n"
        "        self.aorusPageFallbackColor = presentationData.theme.list.blocksBackgroundColor\n"
        "        self.currentParams = (size, isScrollingLockedAtTop, presentationData)\n",
        "groups pane theme",
    )
    text = _replace_once(
        text,
        "        self.listBackgroundView.tintColor = presentationData.theme.list.itemBlocksBackgroundColor\n"
        "        self.listMaskView.tintColor = presentationData.theme.list.blocksBackgroundColor\n",
        "        // AorusGram: clear, because the glass laid behind it under Interface 2.0 is the card\n"
        "        // now, and anything painted over that material flattens it. The mask keeps the page\n"
        "        // colour it always had unless it has been taken over as the shape of the page fill,\n"
        "        // where opaque white is what gives the template image an alpha to cut with --\n"
        "        // updateListBackground above has already decided which of the two it is.\n"
        "        self.listBackgroundView.tintColor = AorusGlassPane.isEnabled ? UIColor.clear : presentationData.theme.list.itemBlocksBackgroundColor\n"
        "        self.listMaskView.tintColor = self.aorusPageFillView != nil ? UIColor.white : presentationData.theme.list.blocksBackgroundColor\n",
        "groups pane tints",
    )
    text = _replace_once(
        text,
        "        transition.updateFrame(view: self.listBackgroundView, frame: listBackgroundFrame)\n"
        "        transition.updateFrame(view: self.listMaskView, frame: listMaskFrame)\n"
        "    }\n",
        "        transition.updateFrame(view: self.listBackgroundView, frame: listBackgroundFrame)\n"
        "        transition.updateFrame(view: self.listMaskView, frame: listMaskFrame)\n"
        "        self.aorusUpdateGlass(backgroundFrame: listBackgroundFrame, transition: transition)\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the glass this pane's block is made of, and the page that shows through the\n"
        "    // frame around it. Called from the same place the two rectangles are laid out, so it\n"
        "    // tracks them through every scroll without a second pass.\n"
        "    private func aorusUpdateGlass(backgroundFrame: CGRect, transition: ContainedViewLayoutTransition) {\n"
        "        self.aorusLastBackgroundFrame = backgroundFrame\n"
        "        guard AorusGlassPane.isEnabled else {\n"
        "            self.aorusReleaseMask()\n"
        "            if let glassView = self.aorusGlassBackgroundView {\n"
        "                self.aorusGlassBackgroundView = nil\n"
        "                glassView.removeFromSuperview()\n"
        "            }\n"
        "            return\n"
        "        }\n"
        "        \n"
        "        let glassView: GlassBackgroundView\n"
        "        if let current = self.aorusGlassBackgroundView {\n"
        "            glassView = current\n"
        "        } else {\n"
        "            glassView = GlassBackgroundView(frame: backgroundFrame)\n"
        "            glassView.isUserInteractionEnabled = false\n"
        "            self.aorusGlassBackgroundView = glassView\n"
        "            self.view.insertSubview(glassView, at: 0)\n"
        "        }\n"
        "        transition.updateFrame(view: glassView, frame: backgroundFrame)\n"
        "        glassView.update(\n"
        "            size: backgroundFrame.size,\n"
        "            cornerRadius: 26.0,\n"
        "            isDark: true,\n"
        "            tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "            isInteractive: false,\n"
        "            isVisible: true,\n"
        "            transition: .immediate\n"
        "        )\n"
        "        \n"
        "        // No picture means a peer with no photo, and there the page is one flat colour that\n"
        "        // the mask is already painting. Nothing to take over.\n"
        "        guard let pageImage = AorusGlassProfileTint.pageBackgroundImage(for: self.aorusPeerId) else {\n"
        "            self.aorusReleaseMask()\n"
        "            return\n"
        "        }\n"
        "        let fillView: UIView\n"
        "        let imageView: UIImageView\n"
        "        if let currentFill = self.aorusPageFillView, let currentImage = self.aorusPageImageView {\n"
        "            fillView = currentFill\n"
        "            imageView = currentImage\n"
        "        } else {\n"
        "            fillView = UIView()\n"
        "            fillView.isUserInteractionEnabled = false\n"
        "            imageView = UIImageView()\n"
        "            imageView.contentMode = .scaleToFill\n"
        "            imageView.layer.magnificationFilter = .linear\n"
        "            imageView.isUserInteractionEnabled = false\n"
        "            fillView.addSubview(imageView)\n"
        "            self.aorusPageFillView = fillView\n"
        "            self.aorusPageImageView = imageView\n"
        "            // The mask leaves the hierarchy to become one: a view cannot both be a subview\n"
        "            // and shape another. Its frame goes on being set by the caller above, and it\n"
        "            // still lands in the right place, because the view it now cuts covers the\n"
        "            // pane's own bounds -- the same space that frame was always measured in.\n"
        "            self.listMaskView.removeFromSuperview()\n"
        "            self.listMaskView.tintColor = .white\n"
        "            fillView.mask = self.listMaskView\n"
        "            self.view.addSubview(fillView)\n"
        "        }\n"
        "        fillView.frame = CGRect(origin: CGPoint(), size: self.listNode.visibleSize)\n"
        "        if imageView.image !== pageImage {\n"
        "            imageView.image = pageImage\n"
        "        }\n"
        "        // The picture goes exactly where the screen's own backdrop is, converted into this\n"
        "        // pane's coordinates, so the page inside this pane and the page around it are one\n"
        "        // stretch of one image rather than two of different heights. With no backdrop found --\n"
        "        // which would mean the screen has not laid one out -- the pane's own bounds are the\n"
        "        // honest fallback rather than nothing at all.\n"
        "        var imageFrame = CGRect(origin: CGPoint(), size: self.listNode.visibleSize)\n"
        "        if let backdropView = self.aorusPageBackdrop() {\n"
        "            imageFrame = self.view.convert(backdropView.bounds, from: backdropView)\n"
        "        }\n"
        "        imageView.frame = imageFrame\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the screen's backdrop, looked up once and kept until it goes away. Walking\n"
        "    // up from here rather than being handed down: the pane is built by the pane container,\n"
        "    // which knows nothing about the page, and every view between the two is Telegram's.\n"
        "    private func aorusPageBackdrop() -> UIView? {\n"
        "        if let existing = self.aorusPageBackdropView, existing.superview != nil {\n"
        "            return existing\n"
        "        }\n"
        "        var ancestor: UIView? = self.view.superview\n"
        "        while let current = ancestor {\n"
        "            for subview in current.subviews {\n"
        "                if subview.tag == AorusGlassProfileTint.backdropTag {\n"
        "                    self.aorusPageBackdropView = subview\n"
        "                    return subview\n"
        "                }\n"
        "            }\n"
        "            ancestor = current.superview\n"
        "        }\n"
        "        return nil\n"
        "    }\n"
        "    \n"
        "    // AorusGram: the page changed under a pane nobody is laying out -- an avatar was swiped.\n"
        "    // Both halves have to follow it: the picture, and the ink the rows are drawn in, which is\n"
        "    // derived from the page and so is not the same ink for a pale photo as for a dark one.\n"
        "    // The rows are rebuilt rather than repainted, because this pane has no promise to push a\n"
        "    // theme down; the entry carries the page it was built for, so the merge sees the change.\n"
        "    private func aorusPageDidChange() {\n"
        "        guard AorusGlassPane.isEnabled else {\n"
        "            return\n"
        "        }\n"
        "        if let presentationData = self.aorusPresentationData, let currentParams = self.currentParams {\n"
        "            let aorusTheme = presentationData.theme.aorusGlassProfileTheme\n"
        "            let updated = presentationData.withUpdated(theme: aorusTheme)\n"
        "            self.aorusPageFallbackColor = aorusTheme.list.blocksBackgroundColor\n"
        "            self.currentParams = (currentParams.size, currentParams.isScrollingLockedAtTop, updated)\n"
        "            if let state = self.state {\n"
        "                self.updatePeers(state: state, presentationData: updated)\n"
        "            }\n"
        "        }\n"
        "        if let backgroundFrame = self.aorusLastBackgroundFrame {\n"
        "            self.aorusUpdateGlass(backgroundFrame: backgroundFrame, transition: .immediate)\n"
        "        }\n"
        "        if self.aorusPageFillView == nil {\n"
        "            self.listMaskView.tintColor = self.aorusPageFallbackColor\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    // AorusGram: hand the mask back its place above the list, and its own paint with it.\n"
        "    private func aorusReleaseMask() {\n"
        "        guard let fillView = self.aorusPageFillView else {\n"
        "            return\n"
        "        }\n"
        "        self.aorusPageFillView = nil\n"
        "        self.aorusPageImageView = nil\n"
        "        fillView.mask = nil\n"
        "        fillView.removeFromSuperview()\n"
        "        self.listMaskView.tintColor = self.aorusPageFallbackColor\n"
        "        self.view.addSubview(self.listMaskView)\n"
        "    }\n",
        "groups pane glass",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: groups pane shows the page")


def _patch_recommended_pane_glass(tg: Path) -> None:
    """The same black rows, one tab over: "Similar channels" and "Similar bots".

    Found by looking for the rest of the fault `_patch_groups_pane_glass` fixes rather than waiting
    for it to be reported -- an `ItemListPeerItem` at `style: .plain` inside a profile pane, which
    paints `plainBackgroundColor` behind every row and so paints black over the page.

    It needs much less than the groups tab does, because upstream gives it no card: the rows run
    edge to edge over the pane's own background, and that background is already the page, because
    the pane container above it goes transparent under Interface 2.0. So there is no glass to lay
    and no rounded hole to keep an avatar out of -- only the fill to stop painting, the glass row
    metrics to match the rest of the profile, and the ink.

    The ink is free here. This entry already carries the theme it was built with and compares it by
    identity, which is exactly the test a derived theme answers: deriving for the other ink returns
    a different object, so routing the derived theme in at the top of `update` is enough for the
    list's merge to see a swipe to a paler photo as a change and rebuild the rows in readable
    colours. The pane's own promise carries it the rest of the way, which is also how a swipe is
    answered while nobody is laying this pane out -- the notification re-pushes it.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/Panes/PeerInfoRecommendedPeersPane.swift"
    text = _read(path, "PeerInfoRecommendedPeersPane.swift")
    if "aorusPageDidChange" in text:
        print("InterfaceV2: recommended peers pane already shows the page")
        return
    text = _replace_once(
        text,
        "import ComponentFlow\nimport TelegramCore\n",
        "import ComponentFlow\nimport AorusGramUI\nimport TelegramCore\n",
        "recommended pane import",
    )
    text = _replace_once(
        text,
        "            return ItemListPeerItem(presentationData: ItemListPresentationData(presentationData), dateTimeFormat:",
        "            // AorusGram: no fill of its own, and the glass style's own metrics. A plain row\n"
        "            // paints plainBackgroundColor -- black under the dark theme -- and a run of them\n"
        "            // is a black band over the page the profile is painted with. What the row leaves\n"
        "            // alone the page shows; its separators and its tap highlight still come from the\n"
        "            // derived theme, so nothing is lost but the sheet of paint.\n"
        "            return ItemListPeerItem(presentationData: ItemListPresentationData(presentationData), systemStyle: AorusGlassPane.isEnabled ? .glass : .legacy, dateTimeFormat:",
        "recommended pane item style",
    )
    text = _replace_once(
        text,
        "            }, hasTopStripe: false, noInsets: true, noCorners: true, style: .plain, disableInteractiveTransitionIfNecessary: true)\n",
        "            }, hasTopStripe: false, noInsets: true, noCorners: true, style: .plain, displayBackground: !AorusGlassPane.isEnabled, disableInteractiveTransitionIfNecessary: true)\n",
        "recommended pane item background",
    )
    text = _replace_once(
        text,
        "    private var theme: PresentationTheme?\n"
        "    private let presentationDataPromise = Promise<PresentationData>()\n",
        "    private var theme: PresentationTheme?\n"
        "    private let presentationDataPromise = Promise<PresentationData>()\n"
        "    // AorusGram: the theme as it arrived, before the page was taken into account. Kept\n"
        "    // because the derivation depends on the page: the ink is whatever reads over it, and a\n"
        "    // peer's photos are not all light or all dark, so a swipe has to re-derive from this\n"
        "    // rather than from a theme whose labels were already white for the photo before it.\n"
        "    private var aorusPresentationData: PresentationData?\n"
        "    private var aorusPageObserver: NSObjectProtocol?\n",
        "recommended pane properties",
    )
    text = _replace_once(
        text,
        "        self.listNode.visibleBottomContentOffsetChanged = { [weak self] offset in\n"
        "            if let self {\n"
        "                self.layoutUnlockPanel(transition: .animated(duration: 0.4, curve: .spring))\n"
        "            }\n"
        "        }\n",
        "        // AorusGram: paging through a peer's avatars changes the page under the profile, and\n"
        "        // nothing tells a pane about it -- PeerInfoPaneWrapper.update memoises its parameters\n"
        "        // and a swipe between two photos changes none of them.\n"
        "        self.aorusPageObserver = NotificationCenter.default.addObserver(forName: AorusGlassProfileTint.pageDidChangeNotification, object: nil, queue: .main) { [weak self] _ in\n"
        "            self?.aorusPageDidChange()\n"
        "        }\n"
        "        \n"
        "        self.listNode.visibleBottomContentOffsetChanged = { [weak self] offset in\n"
        "            if let self {\n"
        "                self.layoutUnlockPanel(transition: .animated(duration: 0.4, curve: .spring))\n"
        "            }\n"
        "        }\n",
        "recommended pane page observer",
    )
    text = _replace_once(
        text,
        "    deinit {\n"
        "        self.disposable?.dispose()\n"
        "    }\n",
        "    deinit {\n"
        "        self.disposable?.dispose()\n"
        "        if let aorusPageObserver = self.aorusPageObserver {\n"
        "            NotificationCenter.default.removeObserver(aorusPageObserver)\n"
        "        }\n"
        "    }\n",
        "recommended pane observer teardown",
    )
    text = _replace_once(
        text,
        "        let isFirstLayout = self.currentParams == nil\n"
        "        self.currentParams = (size, sideInset, bottomInset, isScrollingLockedAtTop, presentationData)\n",
        "        let isFirstLayout = self.currentParams == nil\n"
        "        // AorusGram: the rows, the footer and the button are all built from whatever theme\n"
        "        // goes in here, so the derived one goes in -- that is what gives them the white\n"
        "        // labels and hairline separators of every section on the page above them.\n"
        "        self.aorusPresentationData = presentationData\n"
        "        var presentationData = presentationData\n"
        "        if AorusGlassPane.isEnabled {\n"
        "            presentationData = presentationData.withUpdated(theme: presentationData.theme.aorusGlassProfileTheme)\n"
        "        }\n"
        "        self.currentParams = (size, sideInset, bottomInset, isScrollingLockedAtTop, presentationData)\n",
        "recommended pane theme",
    )
    text = _replace_once(
        text,
        "    @objc private func unlockPressed() {\n",
        "    // AorusGram: the page changed under a pane nobody is laying out -- an avatar was swiped.\n"
        "    // Re-derived and pushed back through the pane's own promise, which is what builds the\n"
        "    // rows: the entry holds the theme it was built with and compares it by identity, so a\n"
        "    // theme derived for the other ink is a difference the list's merge can see.\n"
        "    private func aorusPageDidChange() {\n"
        "        guard AorusGlassPane.isEnabled, let presentationData = self.aorusPresentationData else {\n"
        "            return\n"
        "        }\n"
        "        let updated = presentationData.withUpdated(theme: presentationData.theme.aorusGlassProfileTheme)\n"
        "        if let currentParams = self.currentParams {\n"
        "            self.currentParams = (currentParams.size, currentParams.sideInset, currentParams.bottomInset, currentParams.isScrollingLockedAtTop, updated)\n"
        "        }\n"
        "        self.presentationDataPromise.set(.single(updated))\n"
        "    }\n"
        "    \n"
        "    @objc private func unlockPressed() {\n",
        "recommended pane page change",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: recommended peers pane shows the page")


def _patch_rating_shield(tg: Path) -> None:
    """One shield, and it is the white one.

    Stock chooses between two badges. A plain header gets the accent-blue one with the level
    written on it in the check foreground; an expanded photo gets a white shield with the digits
    knocked out of it, because the only thing behind it then is somebody's photograph. Interface
    2.0 leaves the header in the second situation permanently -- the page is the colour the photo
    ends on whether or not the photo itself is open -- so the blue one, sized and shaped for a
    theme-coloured header, is the wrong one on every profile.

    A clear foreground is not an invisible number. `PeerInfoRatingComponent` switches to `.copy`
    for any foreground below full alpha and cuts the digits out of the shield, which is what makes
    the white badge legible against a page it knows nothing about.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "aorusWhiteShield" in text:
        print("InterfaceV2: rating shield already white")
        return
    text = _replace_once(
        text,
        "        let ratingBackgroundColor: UIColor\n"
        "        let ratingBorderColor: UIColor\n"
        "        let ratingForegroundColor: UIColor\n",
        "        // AorusGram: var, because Interface 2.0 overrides all three after the chain below\n"
        "        // has picked whichever pair of them stock would have used.\n"
        "        var ratingBackgroundColor: UIColor\n"
        "        var ratingBorderColor: UIColor\n"
        "        var ratingForegroundColor: UIColor\n",
        "rating shield declarations",
    )
    text = _replace_once(
        text,
        "                ratingBackgroundColor = accentRatingBackgroundColor\n"
        "                ratingBorderColor = UIColor.clear\n"
        "                ratingForegroundColor = presentationData.theme.list.itemCheckColors.foregroundColor\n"
        "            }\n"
        "        }\n"
        "        \n"
        "        do {\n"
        "            self.currentCredibilityIcon = credibilityIcon\n",
        "                ratingBackgroundColor = accentRatingBackgroundColor\n"
        "                ratingBorderColor = UIColor.clear\n"
        "                ratingForegroundColor = presentationData.theme.list.itemCheckColors.foregroundColor\n"
        "            }\n"
        "        }\n"
        "        \n"
        "        // AorusGram: the knocked-out shield, on every profile and in every state, because\n"
        "        // every one of them puts it on the page the photo is the colour of. This is the same\n"
        "        // triple the expanded-photo branch above sets, taken out of that one condition --\n"
        "        // except for the shield itself, which is the page's ink rather than always white.\n"
        "        // A profile whose photo ends pale is drawn in near-black text, and a white badge\n"
        "        // beside near-black digits was the one thing on the page not reading as part of it.\n"
        "        let aorusWhiteShield = AorusGlassPane.isEnabled\n"
        "        if aorusWhiteShield {\n"
        "            ratingBackgroundColor = AorusGlassPane.profilePageInk\n"
        "            ratingBorderColor = .clear\n"
        "            ratingForegroundColor = .clear\n"
        "        }\n"
        "        \n"
        "        do {\n"
        "            self.currentCredibilityIcon = credibilityIcon\n",
        "rating shield override",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the rating shield white")


def _patch_overlay_palette(tg: Path) -> None:
    """Keep every label in a profile header white, whatever the peer happens to have.

    Stock picks the header's palette from what is behind it, and it only knows two answers: the
    theme's own accent and primary text when the header sits on the theme background, white when the
    photo is expanded or the peer has a profile colour or a gift status. Interface 2.0 gives it a
    third case it has no branch for -- a page painted with the avatar's own colour -- and a peer
    with neither a profile colour nor an expanded photo lands on the first answer: near-black text
    on that page.

    The saved-music capsule is where it shows most, because it is laid out from `isOverlay`, which
    asks the same question: a peer with music gets the track in the theme's accent blue and the
    artist in the theme's grey, sitting on the avatar's colour, while a peer with nothing there
    keeps the white name above it. That is the reading of "labels take the theme colour where there
    is music, white where there is not".

    So the theme-coloured ends of all three pairs go white under Interface 2.0, and the two capsule
    fills that carried them go to the same white-on-glass the expanded state uses -- both ends, not
    just the text, or a white label lands on a white card in the light theme. Only the values change;
    which branch runs is left alone, because that is also what decides whether the navigation bar may
    take the title over, and a profile that scrolls has to keep doing that.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "aorusOverlayPalette" in text:
        print("InterfaceV2: header labels already on the overlay palette")
        return
    text = _replace_once(
        text,
        "        let isLandscape = containerInset > 16.0\n",
        "        // AorusGram: this header is over the avatar's colour, not over the theme's page.\n"
        "        let aorusOverlayPalette = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "            && !isSettings\n"
        "            && !isMediaOnly\n"
        "\n"
        "        // Ink taken from the page instead of fixed at white. The page is the colour sampled\n"
        "        // off the bottom of the photo and is no longer forced dark, so a light photo gives a\n"
        "        // light page -- and every label, capsule and icon over it has to follow, or it comes\n"
        "        // out white on white. Off Interface 2.0 these are the values the stock code had.\n"
        "        let aorusOverlayInk: UIColor = aorusOverlayPalette ? AorusGlassPane.profilePageInk : UIColor.white\n"
        "        let aorusOverlaySecondaryInk: UIColor = aorusOverlayPalette ? AorusGlassPane.profilePageInk(0.7) : UIColor(white: 1.0, alpha: 0.7)\n"
        "        let aorusOverlayScrim: UIColor = aorusOverlayPalette ? AorusGlassPane.profilePageScrim : UIColor(white: 1.0, alpha: 0.1)\n"
        "\n"
        "        let isLandscape = containerInset > 16.0\n",
        "overlay palette flag",
    )
    text = _replace_once(
        text,
        "        let regularNavigationContentsAccentColor: UIColor = peer?.effectiveProfileColor != nil ? .white : presentationData.theme.list.itemAccentColor\n"
        "        let collapsedHeaderNavigationContentsAccentColor = presentationData.theme.list.itemAccentColor\n"
        "        let expandedAvatarNavigationContentsAccentColor: UIColor = .white\n",
        "        let regularNavigationContentsAccentColor: UIColor = (aorusOverlayPalette || peer?.effectiveProfileColor != nil) ? aorusOverlayInk : presentationData.theme.list.itemAccentColor\n"
        "        let collapsedHeaderNavigationContentsAccentColor: UIColor = aorusOverlayPalette ? aorusOverlayInk : presentationData.theme.list.itemAccentColor\n"
        "        // The expanded palette is the one that runs for every peer with a photo now, since\n"
        "        // Interface 2.0 keeps the photo expanded, so it is the one the ink matters most for.\n"
        "        let expandedAvatarNavigationContentsAccentColor: UIColor = aorusOverlayInk\n",
        "overlay palette accent",
    )
    text = _replace_once(
        text,
        "        let regularNavigationContentsPrimaryColor: UIColor = peer?.effectiveProfileColor != nil ? .white : presentationData.theme.list.itemPrimaryTextColor\n"
        "        let collapsedHeaderNavigationContentsPrimaryColor = presentationData.theme.list.itemPrimaryTextColor\n"
        "        let expandedAvatarNavigationContentsPrimaryColor: UIColor = .white\n",
        "        let regularNavigationContentsPrimaryColor: UIColor = (aorusOverlayPalette || peer?.effectiveProfileColor != nil) ? aorusOverlayInk : presentationData.theme.list.itemPrimaryTextColor\n"
        "        let collapsedHeaderNavigationContentsPrimaryColor: UIColor = aorusOverlayPalette ? aorusOverlayInk : presentationData.theme.list.itemPrimaryTextColor\n"
        "        let expandedAvatarNavigationContentsPrimaryColor: UIColor = aorusOverlayInk\n",
        "overlay palette primary",
    )
    text = _replace_once(
        text,
        "        let collapsedHeaderContentButtonBackgroundColor = presentationData.theme.list.itemBlocksBackgroundColor\n"
        "        let expandedAvatarContentButtonBackgroundColor: UIColor = UIColor(white: 1.0, alpha: 0.1)\n",
        "        // Same fill the expanded state uses: a card the theme picked would be opaque, and in\n"
        "        // the light theme it would be white under white text.\n"
        "        let collapsedHeaderContentButtonBackgroundColor: UIColor = aorusOverlayPalette ? aorusOverlayScrim : presentationData.theme.list.itemBlocksBackgroundColor\n"
        "        let expandedAvatarContentButtonBackgroundColor: UIColor = aorusOverlayScrim\n",
        "overlay palette collapsed capsule",
    )
    text = _replace_once(
        text,
        "        let regularContentButtonForegroundColor: UIColor = peer?.effectiveProfileColor != nil ? UIColor.white : presentationData.theme.list.itemAccentColor\n"
        "        let collapsedHeaderContentButtonForegroundColor = presentationData.theme.list.itemAccentColor\n"
        "        let expandedAvatarContentButtonForegroundColor: UIColor = .white\n",
        "        let regularContentButtonForegroundColor: UIColor = (aorusOverlayPalette || peer?.effectiveProfileColor != nil) ? aorusOverlayInk : presentationData.theme.list.itemAccentColor\n"
        "        let collapsedHeaderContentButtonForegroundColor: UIColor = aorusOverlayPalette ? aorusOverlayInk : presentationData.theme.list.itemAccentColor\n"
        "        let expandedAvatarContentButtonForegroundColor: UIColor = aorusOverlayInk\n",
        "overlay palette capsule label",
    )
    text = _replace_once(
        text,
        "            regularNavigationContentsSecondaryColor = presentationData.theme.list.itemSecondaryTextColor\n"
        "            regularContentButtonBackgroundColor = presentationData.theme.list.itemBlocksBackgroundColor\n",
        "            regularNavigationContentsSecondaryColor = aorusOverlayPalette ? aorusOverlaySecondaryInk : presentationData.theme.list.itemSecondaryTextColor\n"
        "            regularContentButtonBackgroundColor = aorusOverlayPalette ? aorusOverlayScrim : presentationData.theme.list.itemBlocksBackgroundColor\n",
        "overlay palette secondary",
    )
    text = _replace_once(
        text,
        "        let collapsedHeaderNavigationContentsSecondaryColor = presentationData.theme.list.itemSecondaryTextColor\n"
        "        let expandedAvatarNavigationContentsSecondaryColor: UIColor = .white\n",
        "        let collapsedHeaderNavigationContentsSecondaryColor: UIColor = aorusOverlayPalette ? aorusOverlaySecondaryInk : presentationData.theme.list.itemSecondaryTextColor\n"
        "        let expandedAvatarNavigationContentsSecondaryColor: UIColor = aorusOverlayInk\n",
        "overlay palette collapsed secondary",
    )
    text = _replace_once(
        text,
        "            let isOverlay = self.isAvatarExpanded || hasBackground\n",
        "            // AorusGram: the capsule is over the avatar's colour whether or not the photo is\n"
        "            // expanded, so the track and the artist take the page's ink either way.\n"
        "            let isOverlay = self.isAvatarExpanded || hasBackground || aorusOverlayPalette\n",
        "overlay palette music capsule",
    )
    text = _replace_once(
        text,
        "                subtitleArrowNode.image = generateTintedImage(image: UIImage(bundleImageName: \"Item List/DisclosureArrow\"), color: presentationData.theme.list.itemSecondaryTextColor)\n",
        "                subtitleArrowNode.image = generateTintedImage(image: UIImage(bundleImageName: \"Item List/DisclosureArrow\"), color: aorusOverlayPalette ? aorusOverlayInk : presentationData.theme.list.itemSecondaryTextColor)\n",
        "overlay palette subtitle arrow",
    )
    text = _replace_once(
        text,
        "            self.subtitleNode.updateTintColor(color: presentationData.theme.list.itemSecondaryTextColor, transition: navigationTransition)\n",
        "            self.subtitleNode.updateTintColor(color: aorusOverlayPalette ? aorusOverlayInk : presentationData.theme.list.itemSecondaryTextColor, transition: navigationTransition)\n",
        "overlay palette subtitle tint",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: header labels stay white on the avatar's page")


_SECTION_GLASS_SWIFT = '''    // MARK: - AorusGram Interface 2.0

    /// Whether this section is drawn as a real pane of glass instead of a coloured card.
    ///
    /// A plain-style section is the page itself rather than a card standing on it, so it keeps its
    /// colour. Everything else -- every blocks section on every screen built out of components
    /// rather than out of `ItemListItem`s -- becomes glass, which is the same trade
    /// `ItemListControllerNode` makes for the older screens.
    private func aorusUsesGlass(_ configuration: Configuration) -> Bool {
        guard AorusGlassPane.isEnabled else {
            return false
        }
        if case .plain = configuration.style {
            return false
        }
        return true
    }

    /// The fill the card carries, given that a pane behind it is doing the work.
    ///
    /// Clear, except while a row is held down: there this colour *is* the touch feedback, and it has
    /// to sit on the glass rather than instead of it.
    private func aorusCardColor(_ configuration: Configuration, isHighlighted: Bool, _ color: UIColor) -> UIColor {
        if self.aorusUsesGlass(configuration), !isHighlighted {
            return .clear
        }
        return color
    }

    private func aorusUpdateGlass(configuration: Configuration, size: CGSize, corners: DynamicCornerRadiusView.Corners, isVisible: Bool, transition: ComponentTransition) {
        guard self.aorusUsesGlass(configuration), isVisible, size.width > 1.0, size.height > 1.0 else {
            if let glassView = self.aorusGlassView {
                self.aorusGlassView = nil
                glassView.removeFromSuperview()
            }
            return
        }
        let glassView: GlassBackgroundView
        if let current = self.aorusGlassView {
            glassView = current
        } else {
            // Inside the card's own view, so the pane inherits the frame this section already keeps
            // up to date and there is no second copy of that geometry to hold in step. The card is
            // a shape layer and does not clip, so the pane cuts its own corners below.
            glassView = GlassBackgroundView(frame: CGRect(origin: CGPoint(), size: size))
            glassView.isUserInteractionEnabled = false
            self.aorusGlassView = glassView
            self.externalContentBackgroundView.insertSubview(glassView, at: 0)
        }
        glassView.frame = CGRect(origin: CGPoint(), size: size)
        glassView.update(
            size: size,
            cornerRadii: GlassBackgroundView.CornerRadii(
                topLeft: corners.minXMinY,
                topRight: corners.maxXMinY,
                bottomLeft: corners.minXMaxY,
                bottomRight: corners.maxXMaxY
            ),
            isDark: configuration.theme.overallDarkAppearance,
            tintColor: GlassBackgroundView.TintColor(kind: .clear),
            isInteractive: false,
            isVisible: true,
            transition: transition
        )
    }

'''


def _patch_component_section_glass(tg: Path) -> None:
    """Put the same glass behind the sections of every screen built out of components.

    `ItemListControllerNode` covers the screens made of `ItemListItem`s, which is most of the app but
    not the newer half of Settings: gifts, stars, business, the affiliate and verification screens and
    some fifty others lay their sections out with `ListSectionComponent` instead, which draws its own
    card and never goes through an ItemList at all. Those were the blocks still coming out flat.

    One file covers all of them, because the card is drawn in exactly one place: a shape layer filled
    with `itemBlocksBackgroundColor`. Under Interface 2.0 the fill goes clear and a `GlassBackgroundView`
    goes inside that same view, cut with the same corners -- including the asymmetric ones a `.range`
    section asks for, where only the rows below a given item are meant to be carded.
    """
    path = tg / "submodules/TelegramUI/Components/ListSectionComponent/Sources/ListSectionComponent.swift"
    text = _read(path, "ListSectionComponent.swift")
    if "aorusUsesGlass" in text:
        print("InterfaceV2: component sections already on glass")
        return
    text = _replace_once(
        text,
        "import DynamicCornerRadiusView\n",
        "import DynamicCornerRadiusView\n" + _GLASS_IMPORT,
        "section glass import",
    )
    text = _replace_once(
        text,
        "    public let externalContentBackgroundView: DynamicCornerRadiusView\n",
        "    public let externalContentBackgroundView: DynamicCornerRadiusView\n"
        "    // AorusGram: built on the first pass that draws a card, so a section laid out with\n"
        "    // Interface 2.0 off never allocates an effect view it will not show.\n"
        "    private var aorusGlassView: GlassBackgroundView?\n",
        "section glass property",
    )
    text = _replace_once(
        text,
        "            self.externalContentBackgroundView.updateColor(color: backgroundColor, transition: transition)\n"
        "        } else {\n",
        "            self.externalContentBackgroundView.updateColor(color: self.aorusCardColor(configuration, isHighlighted: itemId != nil, backgroundColor), transition: transition)\n"
        "        } else {\n",
        "section glass highlight colour",
    )
    text = _replace_once(
        text,
        "        self.externalContentBackgroundView.updateColor(color: backgroundColor, transition: transition)\n"
        "        \n"
        "        let cornerRadius: CGFloat\n",
        "        self.externalContentBackgroundView.updateColor(color: self.aorusCardColor(configuration, isHighlighted: self.highlightedItemId != nil && configuration.extendsItemHighlightToSection, backgroundColor), transition: transition)\n"
        "        \n"
        "        let cornerRadius: CGFloat\n",
        "section glass card colour",
    )
    text = _replace_once(
        text,
        "        var contentCornerRadius: CGFloat = cornerRadius\n",
        "        var contentCornerRadius: CGFloat = cornerRadius\n"
        "        // AorusGram: the corners the card is cut with, so the pane behind it is cut to match.\n"
        "        var aorusCorners = DynamicCornerRadiusView.Corners(minXMinY: cornerRadius, maxXMinY: cornerRadius, minXMaxY: cornerRadius, maxXMaxY: cornerRadius)\n",
        "section glass corners",
    )
    text = _replace_once(
        text,
        "            self.externalContentBackgroundView.update(size: backgroundFrame.size, corners: corners, transition: transition)\n",
        "            aorusCorners = corners\n"
        "            self.externalContentBackgroundView.update(size: backgroundFrame.size, corners: corners, transition: transition)\n",
        "section glass range corners",
    )
    text = _replace_once(
        text,
        "        transition.setAlpha(view: self.externalContentBackgroundView, alpha: backgroundAlpha)\n",
        "        self.aorusUpdateGlass(configuration: configuration, size: backgroundFrame.size, corners: aorusCorners, isVisible: backgroundAlpha > 0.0, transition: transition)\n"
        "        transition.setAlpha(view: self.externalContentBackgroundView, alpha: backgroundAlpha)\n",
        "section glass update hook",
    )
    text = _replace_once(
        text,
        "    public func update(configuration: Configuration, width: CGFloat, leftInset: CGFloat, readyItems: [ReadyItem], transition: ComponentTransition) -> UpdateResult {\n",
        _SECTION_GLASS_SWIFT
        + "    public func update(configuration: Configuration, width: CGFloat, leftInset: CGFloat, readyItems: [ReadyItem], transition: ComponentTransition) -> UpdateResult {\n",
        "section glass helper",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: put every component section on its own pane of glass")


def _patch_static_avatar(tg: Path) -> None:
    """Make the photo an ordinary block: it scrolls with the content and nothing else.

    Stock treats the expanded photo as a backdrop rather than as part of the page, and does three
    things to it that a block never does. It moves the photo at half the speed of the finger, so
    the list slides over a picture that drifts the other way. It scales the photo up while the list
    is pulled past its top, so the picture stretches and its centre creeps downwards. And on a
    dynamic-island device it masks the photo into the island and fades a black cover in over it as
    the offset grows, so the top of the picture darkens on the way out.

    Under Interface 2.0 all three go. What is left is the frame the layout already computes minus
    the content offset, exactly once -- the same arithmetic the title, the status and the buttons
    above it already use, which is why they now travel together instead of sliding apart.

    The mask branch is skipped rather than emptied, and its `else` gains the one line that branch
    owned outright: the top shadow's visibility. Everything else in there only ever set the covers
    and the mask, which the `else` already clears.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "aorusStaticAvatar" in text:
        print("InterfaceV2: photo already static")
        return
    text = _replace_once(
        text,
        "        var apparentAvatarFrame: CGRect\n"
        "        var apparentAvatarListFrame: CGRect\n"
        "        let controlsClippingFrame: CGRect\n"
        "        if self.isAvatarExpanded {\n"
        "            let expandedAvatarCenter = CGPoint(x: expandedAvatarListSize.width / 2.0, y: expandedAvatarListSize.width / 2.0 - contentOffset / 2.0)\n",
        "        // AorusGram: the photo is a block on the page, not a backdrop behind it. A block\n"
        "        // moves by exactly what the list moved.\n"
        "        let aorusStaticAvatar = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        let aorusAvatarScrollOffset: CGFloat = aorusStaticAvatar ? contentOffset : contentOffset / 2.0\n"
        "        var apparentAvatarFrame: CGRect\n"
        "        var apparentAvatarListFrame: CGRect\n"
        "        let controlsClippingFrame: CGRect\n"
        "        if self.isAvatarExpanded {\n"
        "            let expandedAvatarCenter = CGPoint(x: expandedAvatarListSize.width / 2.0, y: expandedAvatarListSize.width / 2.0 - aorusAvatarScrollOffset)\n",
        "static avatar centre",
    )
    text = _replace_once(
        text,
        "            let expandedAvatarListCenter = CGPoint(x: expandedAvatarListSize.width / 2.0, y: expandedAvatarListSize.height / 2.0 - contentOffset / 2.0)\n",
        "            let expandedAvatarListCenter = CGPoint(x: expandedAvatarListSize.width / 2.0, y: expandedAvatarListSize.height / 2.0 - aorusAvatarScrollOffset)\n",
        "static avatar list centre",
    )
    text = _replace_once(
        text,
        "            avatarListContainerScale = 1.0 + max(0.0, -contentOffset / avatarListContainerFrame.width)\n",
        "            // No rubber band: a pull past the top must not stretch the picture, and with the\n"
        "            // scale pinned at 1.0 the vertical offset derived from it below falls out at zero.\n"
        "            avatarListContainerScale = aorusStaticAvatar ? 1.0 : 1.0 + max(0.0, -contentOffset / avatarListContainerFrame.width)\n",
        "static avatar scale",
    )
    text = _replace_once(
        text,
        "        if deviceMetrics.hasDynamicIsland && statusBarHeight > 0.0 && self.forumTopicThreadId == nil && self.navigationTransition == nil && !isLandscape {\n"
        "            let maskValue = max(0.0, min(1.0, contentOffset / 120.0))\n",
        "        if !aorusStaticAvatar && deviceMetrics.hasDynamicIsland && statusBarHeight > 0.0 && self.forumTopicThreadId == nil && self.navigationTransition == nil && !isLandscape {\n"
        "            let maskValue = max(0.0, min(1.0, contentOffset / 120.0))\n",
        "static avatar island mask",
    )
    text = _replace_once(
        text,
        "        } else {\n"
        "            self.avatarListNode.bottomCoverNode.isHidden = true\n"
        "            self.avatarListNode.topCoverNode.isHidden = true\n"
        "            self.avatarListNode.containerNode.view.mask = nil\n"
        "        }\n",
        "        } else {\n"
        "            self.avatarListNode.bottomCoverNode.isHidden = true\n"
        "            self.avatarListNode.topCoverNode.isHidden = true\n"
        "            self.avatarListNode.containerNode.view.mask = nil\n"
        "            // The only line the island branch owned that this one did not: the shadow that\n"
        "            // keeps the status bar legible over a photo. Skipping the branch must not take it.\n"
        "            self.avatarListNode.listContainerNode.topShadowNode.isHidden = !self.isAvatarExpanded\n"
        "        }\n",
        "static avatar top shadow",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the profile photo static")


def _patch_compact_music(tg: Path) -> None:
    """Size the saved-music capsule to the mockup and sit it in the gap under the buttons.

    Stock sizes this row for a full-width strip across the bottom of the header: 24pt of content at
    12pt type, and the capsule pass wraps it in a pill, which came out 38pt tall and read as the
    loudest thing on the screen. The mockup has a small pill under the buttons, so the content drops
    to 18pt -- 24pt of pill once the capsule's own 3pt of padding is counted at each end -- and the
    header reserves proportionally less room beneath the photo for it. The type stays at 12pt, the
    size the rest of the header is set in: 11pt made the pill smaller than the mockup's and the
    track unreadable at arm's length, which is not the same thing as compact.

    Where it sits is measured from the bottom of the button row rather than from the bottom of the
    photo. The row does not always end in the same place -- an action button such as "Add to
    contacts" pushes it down by its own height -- so a pill placed a fixed distance off the header's
    edge slid under the buttons in exactly those profiles. Centred in whatever is left between the
    two instead, which for the ordinary profile is 5pt of photo above the pill and 5pt below it.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "aorusCompactMusic" in text:
        print("InterfaceV2: music capsule already compact")
        return
    text = _replace_once(
        text,
        "        let musicHeight: CGFloat = hasBackground || self.isAvatarExpanded ? 24.0 : 16.0\n",
        "        // AorusGram: read here rather than reused from the flags further down, because this\n"
        "        // is the first line in the pass that needs it -- the height it picks feeds the inset\n"
        "        // the whole header is measured with, and through that the gap the pill is centred in.\n"
        "        let aorusCompactMusic = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        let musicHeight: CGFloat = aorusCompactMusic ? 18.0 : (hasBackground || self.isAvatarExpanded ? 24.0 : 16.0)\n",
        "compact music height",
    )
    text = _replace_once(
        text,
        "            musicString.append(NSAttributedString(string: track ?? \"\", font: Font.semibold(12.0), textColor: isOverlay ? .white : presentationData.theme.list.itemAccentColor))\n"
        "            musicString.append(NSAttributedString(string: \" - \\(artist)\", font: Font.regular(12.0), textColor: isOverlay ? UIColor.white.withAlphaComponent(0.7) : presentationData.theme.list.itemSecondaryTextColor))\n",
        "            musicString.append(NSAttributedString(string: track ?? \"\", font: Font.semibold(12.0), textColor: isOverlay ? aorusOverlayInk : presentationData.theme.list.itemAccentColor))\n"
        "            musicString.append(NSAttributedString(string: \" - \\(artist)\", font: Font.regular(12.0), textColor: isOverlay ? aorusOverlayInk.withAlphaComponent(0.7) : presentationData.theme.list.itemSecondaryTextColor))\n",
        "compact music font",
    )
    # The two glyphs in the pill, for the same reason as its text: white on a pale page is a hole
    # in it. Outside Interface 2.0 aorusOverlayInk is UIColor.white, which is what these were.
    text = _replace_once(
        text,
        "                                    component: AnyComponent(BundleIconComponent(name: \"Media Editor/SmallAudio\", tintColor: isOverlay ? .white : presentationData.theme.list.itemAccentColor))\n",
        "                                    component: AnyComponent(BundleIconComponent(name: \"Media Editor/SmallAudio\", tintColor: isOverlay ? aorusOverlayInk : presentationData.theme.list.itemAccentColor))\n",
        "compact music icon",
    )
    text = _replace_once(
        text,
        "                                    component: AnyComponent(BundleIconComponent(name: \"Item List/InlineTextRightArrow\", tintColor: isOverlay ? .white : presentationData.theme.list.itemSecondaryTextColor))\n",
        "                                    component: AnyComponent(BundleIconComponent(name: \"Item List/InlineTextRightArrow\", tintColor: isOverlay ? aorusOverlayInk.withAlphaComponent(0.7) : presentationData.theme.list.itemSecondaryTextColor))\n",
        "compact music arrow",
    )
    # The pill's padding is written by the music-capsule pass, one script earlier. Pinned rather
    # than re-written here: the height this pass picks and the padding that pass adds are the same
    # measurement seen from two sides, and there is no way to notice they have drifted at runtime.
    if "insetBy(dx: -12.0, dy: -3.0)" not in text:
        raise RuntimeError("InterfaceV2: the saved-music capsule padding is no longer the compact one")
    # Where the button row ends, taken at the point its y is final -- the line above moves it down
    # by an action button's height, and reading it any earlier is how the pill ended up over the
    # buttons on profiles that have one.
    text = _replace_once(
        text,
        "        if !actionButtonKeys.isEmpty {\n"
        "            buttonRightOrigin.y += actionButtonSize.height + 24.0\n"
        "        }\n",
        "        if !actionButtonKeys.isEmpty {\n"
        "            buttonRightOrigin.y += actionButtonSize.height + 24.0\n"
        "        }\n"
        "        // AorusGram: the bottom of the button row, for the saved-music pill below it.\n"
        "        let aorusButtonsBottom = buttonRightOrigin.y + buttonSize.height\n",
        "buttons bottom edge",
    )
    # Centred in the gap between the buttons and the bottom of the photo. For the ordinary profile
    # that gap is 34pt -- 18 of reserved inset and 16 of button margin -- and the pill is 24 with its
    # padding, so 5pt of picture is left above it and 5pt below. The 4pt floor is for a header with
    # no room to centre anything in: it puts the pill under the buttons rather than through them,
    # which is the one arrangement that must not happen. Measured off musicSize and not musicHeight
    # because the capsule is drawn around the row's real size, whatever the component returned.
    #
    # The frame computed here is the row, and the pill is 3pt taller at each end, so the row starts
    # 3pt inside the pill's top. The x term is the capsule pass's centring, which is why this
    # anchors on its line.
    text = _replace_once(
        text,
        "            let musicFrame = CGRect(origin: CGPoint(x: aorusMusicX, y: (apparentBackgroundHeight - backgroundHeight) + backgroundHeight - musicHeight - (hasBackground || self.isAvatarExpanded ? 0.0 : 4.0)), size: musicSize)\n",
        "            let aorusMusicPillHeight = musicSize.height + 6.0\n"
        "            let aorusMusicPillTop = aorusButtonsBottom + max(4.0, floor((backgroundHeight - aorusButtonsBottom - aorusMusicPillHeight) / 2.0))\n"
        "            let aorusMusicY: CGFloat = aorusCompactMusic ? (aorusMusicPillTop + 3.0) : (backgroundHeight - musicHeight - (hasBackground || self.isAvatarExpanded ? 0.0 : 4.0))\n"
        "            let musicFrame = CGRect(origin: CGPoint(x: aorusMusicX, y: (apparentBackgroundHeight - backgroundHeight) + aorusMusicY), size: musicSize)\n",
        "compact music placement",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the saved-music capsule compact")


def _patch_music_player_glass(tg: Path) -> None:
    """Stand the whole music player on one pane of glass, and put its button in the page's ink.

    The player a tap on the profile's music pill opens is built out of four opaque fills: a backdrop
    behind the playlist, a 16pt strip down each side of it, a band behind the header, and a flat panel
    across the bottom with a shadow over it that the controls stand in. Under Interface 2.0 all four go
    clear and one `GlassBackgroundView` runs from the top of the modal to the bottom of the screen.

    One pane and not four. Glass over glass comes out brighter than either, so a player with a pane
    per fill would have a bright rectangle across its foot where the controls overlap the playlist,
    and a brighter band at the top where the header does. One pane also means the seams between those
    fills stop existing rather than being painted over: the wedges Telegram draws to round the
    playlist's top corners into the header band are hidden here, because they are painted in the
    modal's own colour and there is no such colour any more.

    The pane is laid out from both places that move the player -- the layout pass, which is what runs
    when it opens, and the floating-header pass, which is what moves the top edge as the playlist is
    dragged. It goes in below everything the content node holds, so the playlist, the header buttons
    and the controls all stay above the material rather than through it.

    "Добавить в профиль" was the one control left in the player wearing a colour that belonged to no
    surface behind it -- the accent fill, over glass. It becomes the page's ink, white on a dark theme
    and near-black on a light one, with its label and glyph in the inverse: the pair the profile's own
    header buttons already use. The remove state keeps its own translucent fill, which reads over the
    material as it always did.
    """
    path = tg / "submodules/TelegramUI/Sources/OverlayAudioPlayerControllerNode.swift"
    text = _read(path, "OverlayAudioPlayerControllerNode.swift")
    if "aorusPlayerBackgroundView" in text:
        print("InterfaceV2: music player already glass")
        return
    text = _replace_once(
        text,
        "import GlassControls\nimport PhotoResources\n",
        "import GlassControls\nimport PhotoResources\n" + _GLASS_IMPORT,
        "music player import",
    )
    text = _replace_once(
        text,
        "    private let historyBackgroundNode: ASDisplayNode\n"
        "    private let historyBackgroundContentNode: ASDisplayNode\n",
        "    private let historyBackgroundNode: ASDisplayNode\n"
        "    private let historyBackgroundContentNode: ASDisplayNode\n"
        "    // AorusGram: the pane of glass the whole player stands on under Interface 2.0. Held so that\n"
        "    // the second layout pass finds the one the first made instead of laying another behind it.\n"
        "    private var aorusPlayerBackgroundView: GlassBackgroundView?\n",
        "music player pane",
    )
    text = _replace_once(
        text,
        "        self.historyBackgroundContentNode.backgroundColor = self.presentationData.theme.list.itemModalBlocksBackgroundColor\n"
        "        \n"
        "        self.historyBackgroundNode.addSubnode(self.historyBackgroundContentNode)\n"
        "        \n"
        "        self.historyFrameNode = SparseNode()\n"
        "        self.historyFrameLeftOverlayNode = ASDisplayNode()\n"
        "        self.historyFrameLeftOverlayNode.backgroundColor = self.presentationData.theme.list.modalBlocksBackgroundColor\n"
        "        \n"
        "        self.historyFrameRightOverlayNode = ASDisplayNode()\n"
        "        self.historyFrameRightOverlayNode.backgroundColor = self.presentationData.theme.list.modalBlocksBackgroundColor\n",
        "        // AorusGram: the four fills the player is made of in stock, and nothing at all under\n"
        "        // Interface 2.0 -- the pane laid in below them is what the player is made of there, and a\n"
        "        // panel painted over a pane of glass is how it stops being one.\n"
        "        let aorusPlayerGlass = AorusGlassPane.isEnabled\n"
        "        let aorusListFill: UIColor = aorusPlayerGlass ? UIColor.clear : self.presentationData.theme.list.itemModalBlocksBackgroundColor\n"
        "        let aorusFrameFill: UIColor = aorusPlayerGlass ? UIColor.clear : self.presentationData.theme.list.modalBlocksBackgroundColor\n"
        "        self.historyBackgroundContentNode.backgroundColor = aorusListFill\n"
        "        \n"
        "        self.historyBackgroundNode.addSubnode(self.historyBackgroundContentNode)\n"
        "        \n"
        "        self.historyFrameNode = SparseNode()\n"
        "        self.historyFrameLeftOverlayNode = ASDisplayNode()\n"
        "        self.historyFrameLeftOverlayNode.backgroundColor = aorusFrameFill\n"
        "        \n"
        "        self.historyFrameRightOverlayNode = ASDisplayNode()\n"
        "        self.historyFrameRightOverlayNode.backgroundColor = aorusFrameFill\n",
        "music player fills",
    )
    text = _replace_once(
        text,
        "        self.historyFrameTopOverlayNode.backgroundColor = self.presentationData.theme.list.modalBlocksBackgroundColor\n"
        "        self.historyFrameTopOverlayNode.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]\n",
        "        self.historyFrameTopOverlayNode.backgroundColor = aorusFrameFill\n"
        "        self.historyFrameTopOverlayNode.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]\n",
        "music player header fill",
    )
    text = _replace_once(
        text,
        "        self.historyBackgroundContentNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.itemModalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor\n"
        "        self.historyFrameLeftOverlayNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor\n"
        "        self.historyFrameRightOverlayNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor\n"
        "        self.historyFrameTopOverlayNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor\n",
        "        // AorusGram: the same four fills as the initialiser, cleared for the same reason. A\n"
        "        // player that was glass until the theme changed under it would be worse than one that\n"
        "        // never was, and this line runs on every theme change and every empty-playlist flip.\n"
        "        let aorusPlayerGlass = AorusGlassPane.isEnabled\n"
        "        let aorusListFill = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.itemModalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor\n"
        "        let aorusFrameFill = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor\n"
        "        self.historyBackgroundContentNode.backgroundColor = aorusPlayerGlass ? UIColor.clear : aorusListFill\n"
        "        self.historyFrameLeftOverlayNode.backgroundColor = aorusPlayerGlass ? UIColor.clear : aorusFrameFill\n"
        "        self.historyFrameRightOverlayNode.backgroundColor = aorusPlayerGlass ? UIColor.clear : aorusFrameFill\n"
        "        self.historyFrameTopOverlayNode.backgroundColor = aorusPlayerGlass ? UIColor.clear : aorusFrameFill\n",
        "music player fills on theme change",
    )
    text = _replace_once(
        text,
        "        self.historyFrameTopMaskNode.isHidden = self.controlsNode.hasPlainBackground\n",
        "        // AorusGram: those two wedges round the playlist's corners into the header band by\n"
        "        // painting the modal's own fill over them, and Interface 2.0 has no such fill -- one pane\n"
        "        // of glass runs behind both, with nothing between them to round.\n"
        "        self.historyFrameTopMaskNode.isHidden = self.controlsNode.hasPlainBackground || AorusGlassPane.isEnabled\n",
        "music player corner wedges",
    )
    text = _replace_once(
        text,
        "    private func updateFloatingHeaderOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {\n",
        "    // AorusGram: the pane of glass the player stands on, from the top of the modal to the foot\n"
        "    // of the screen.\n"
        "    //\n"
        "    // The top edge is the frame node's, which is the one thing in here that moves: dragging the\n"
        "    // playlist down slides the whole modal, and the header band travels with it. Before the\n"
        "    // playlist has reported an offset that frame is still empty, which is what the inset below is\n"
        "    // for -- the player would otherwise open with its glass an inch too high for one frame.\n"
        "    //\n"
        "    // The bottom edge is the screen's and not the controls panel's: the panel is a fill in stock\n"
        "    // and part of the same material here, so the pane runs under it. The container this sits in\n"
        "    // is already clipped to the screen's own corner radius, which is why only the top two are\n"
        "    // rounded -- 38pt, the radius Telegram rounds the band behind the header with.\n"
        "    private func aorusUpdatePlayerGlass(transition: ContainedViewLayoutTransition) {\n"
        "        guard AorusGlassPane.isEnabled, let layout = self.validLayout else {\n"
        "            return\n"
        "        }\n"
        "        var top = self.historyFrameNode.frame.minY\n"
        "        if top <= 0.0 {\n"
        "            top = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)\n"
        "        }\n"
        "        let frame = CGRect(origin: CGPoint(x: 0.0, y: top), size: CGSize(width: layout.size.width, height: max(0.0, layout.size.height - top)))\n"
        "        guard frame.width > 0.0, frame.height > 0.0 else {\n"
        "            return\n"
        "        }\n"
        "        let view: GlassBackgroundView\n"
        "        if let current = self.aorusPlayerBackgroundView {\n"
        "            view = current\n"
        "        } else {\n"
        "            view = GlassBackgroundView(frame: frame)\n"
        "            view.isUserInteractionEnabled = false\n"
        "            self.aorusPlayerBackgroundView = view\n"
        "            self.contentNode.view.insertSubview(view, at: 0)\n"
        "        }\n"
        "        transition.updateFrame(view: view, frame: frame)\n"
        "        view.update(\n"
        "            size: frame.size,\n"
        "            cornerRadii: GlassBackgroundView.CornerRadii(topLeft: 38.0, topRight: 38.0, bottomLeft: 0.0, bottomRight: 0.0),\n"
        "            isDark: self.presentationData.theme.overallDarkAppearance,\n"
        "            tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "            isInteractive: false,\n"
        "            isVisible: true,\n"
        "            transition: .immediate\n"
        "        )\n"
        "    }\n"
        "    \n"
        "    private func updateFloatingHeaderOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {\n",
        "music player glass helper",
    )
    text = _replace_once(
        text,
        "        if self.hasAnyHistoryMessages != previousHasAnyHistoryMessages {\n"
        "            self.updatePresentationData(self.presentationData)\n"
        "        }\n",
        "        self.aorusUpdatePlayerGlass(transition: transition)\n"
        "        \n"
        "        if self.hasAnyHistoryMessages != previousHasAnyHistoryMessages {\n"
        "            self.updatePresentationData(self.presentationData)\n"
        "        }\n",
        "music player glass follows the drag",
    )
    text = _replace_once(
        text,
        "        let controlsTransition = self.controlsNode.frame.width > 0.0 ? transition : .immediate\n"
        "        controlsTransition.updateFrame(node: self.controlsNode, frame: controlsFrame)\n",
        "        let controlsTransition = self.controlsNode.frame.width > 0.0 ? transition : .immediate\n"
        "        controlsTransition.updateFrame(node: self.controlsNode, frame: controlsFrame)\n"
        "        \n"
        "        // AorusGram: laid out here as well as from the drag, because this is the pass that runs\n"
        "        // when the player opens and when the device is turned.\n"
        "        self.aorusUpdatePlayerGlass(transition: transition)\n",
        "music player glass on layout",
    )
    path.write_text(text, encoding="utf-8")

    controls = tg / "submodules/TelegramUI/Sources/OverlayAudioPlayerControlsNode.swift"
    controls_text = _read(controls, "OverlayAudioPlayerControlsNode.swift")
    # The panel across the foot of the player, and the taller version of it the player wears when the
    # playlist is empty. Answered at the source rather than at the three places the image is assigned
    # -- the initialiser, the theme change and the empty-playlist flip -- because the shadow over it
    # has to go too, and a shadow is not a colour that can be cleared.
    for name in ("generateBackground", "generatePlainBackground"):
        controls_text = _replace_once(
            controls_text,
            "private func " + name + "(theme: PresentationTheme) -> UIImage? {\n"
            "    return generateImage(",
            "private func " + name + "(theme: PresentationTheme) -> UIImage? {\n"
            "    // AorusGram: no panel and no shadow under Interface 2.0 -- the controls stand on the\n"
            "    // same pane of glass as the playlist above them, and this is the fill that used to cut\n"
            "    // the player in two across the middle.\n"
            "    if AorusGlassPane.isEnabled {\n"
            "        return nil\n"
            "    }\n"
            "    return generateImage(",
            "music controls panel " + name,
        )
    controls_text = _replace_once(
        controls_text,
        "        self.addSubnode(self.scrubberNode)\n",
        "        // AorusGram: the position line is drawn as a wave under Interface 2.0. Shape only: the\n"
        "        // two colours it is drawn in are the ones handed to the content above, unchanged.\n"
        "        self.scrubberNode.aorusWaveStyle = AorusGlassPane.isEnabled\n"
        "        self.addSubnode(self.scrubberNode)\n",
        "music controls wave",
    )
    controls_text = _replace_once(
        controls_text,
        "            let profileAudioButtonContent: AnyComponentWithIdentity<Empty>\n"
        "            var buttonBackgroundColor = self.presentationData.theme.list.itemCheckColors.fillColor\n",
        "            let profileAudioButtonContent: AnyComponentWithIdentity<Empty>\n"
        "            // AorusGram: \"Добавить в профиль\" in the page's ink -- white on a dark theme, near-black\n"
        "            // on a light one -- with its label and glyph in the inverse of it, which is the pair the\n"
        "            // profile's own header buttons are drawn with. The accent fill it replaces was the last\n"
        "            // colour in the player that answered to no surface behind it.\n"
        "            let aorusPlayerInk: UIColor? = AorusGlassPane.isEnabled ? AorusGlassPane.ink(over: self.presentationData.theme.list.plainBackgroundColor) : nil\n"
        "            let aorusButtonInk: UIColor = aorusPlayerInk.flatMap { AorusGlassPane.ink(over: $0) } ?? self.presentationData.theme.list.itemCheckColors.foregroundColor\n"
        "            var buttonBackgroundColor = aorusPlayerInk ?? self.presentationData.theme.list.itemCheckColors.fillColor\n",
        "music controls button ink",
    )
    controls_text = _replace_once(
        controls_text,
        "                            BundleIconComponent(name: \"Peer Info/SaveMusic\", tintColor: self.presentationData.theme.list.itemCheckColors.foregroundColor)\n",
        "                            BundleIconComponent(name: \"Peer Info/SaveMusic\", tintColor: aorusButtonInk)\n",
        "music controls button icon",
    )
    controls_text = _replace_once(
        controls_text,
        "                            MultilineTextComponent(text: .plain(NSAttributedString(string: self.presentationData.strings.MediaPlayer_SavedMusic_AddToProfile, font: Font.semibold(17.0), textColor: self.presentationData.theme.list.itemCheckColors.foregroundColor)))\n",
        "                            MultilineTextComponent(text: .plain(NSAttributedString(string: self.presentationData.strings.MediaPlayer_SavedMusic_AddToProfile, font: Font.semibold(17.0), textColor: aorusButtonInk)))\n",
        "music controls button label",
    )
    controls.write_text(controls_text, encoding="utf-8")
    print("InterfaceV2: stood the music player on glass")


def _patch_wave_scrubber(tg: Path) -> None:
    """Teach the scrubbing node to draw its line as a wave, and leave every colour where it was.

    The music player's position line is a 7pt bar: a stretchable rounded rectangle in the background
    colour, a second rectangle in the foreground colour, and a clipping node over the second one whose
    width is the progress. Interface 2.0 asks for a wave in the same two colours -- the shape changes
    and nothing else does.

    Off by default, and set from one place. Every other scrubber in the app -- the video player, the
    voice message, the chat's own music panel -- is a bar and stays one, so this is a property rather
    than a change to what `.standard` means; adding a case to that enum would have to be answered at
    every construction site in the client.

    Drawn at the width it is laid out at rather than tiled. A layer stretches an image, it does not
    repeat one, and a stretched wave is a different wave: the crests slide off the ones behind them.
    So the pair of images is regenerated when the size or the colours change, which for a player
    already on screen is never -- the layout pass runs on every frame of playback, and the key below
    is what keeps it from redrawing two images sixty times a second.

    The played part is the same wave in the other colour, clipped by the foreground node. Both images
    are generated for the same size and pinned to the same left edge, so a crest sits exactly over the
    crest behind it however far along the track is, and the cut edge falls wherever the playhead is --
    which is what a played waveform looks like everywhere else in the app.
    """
    path = tg / "submodules/MediaPlayer/Sources/MediaPlayerScrubbingNode.swift"
    text = _read(path, "MediaPlayerScrubbingNode.swift")
    if "aorusWaveStyle" in text:
        print("InterfaceV2: scrubber already waves")
        return
    text = _replace_once(
        text,
        "    public var ignoreSeekId: Int?\n",
        "    public var ignoreSeekId: Int?\n"
        "    \n"
        "    // AorusGram: Interface 2.0's designer line -- a wave rather than a bar, in the two colours\n"
        "    // the content already carries. Set from the overlay music player and nowhere else.\n"
        "    public var aorusWaveStyle: Bool = false {\n"
        "        didSet {\n"
        "            if self.aorusWaveStyle != oldValue {\n"
        "                self.aorusWaveKey = nil\n"
        "                self.updateProgressAnimations()\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    // What the pair of wave images was last drawn for: size and colours. The layout pass runs\n"
        "    // on every frame of playback, so this is what stops two images being generated per frame.\n"
        "    private var aorusWaveKey: String?\n"
        "    \n"
        "    // The colours to draw the wave in. Kept because the content is not: the node holds the\n"
        "    // nodes it built out of it and lets the enum go.\n"
        "    private var aorusWaveColors: (background: UIColor, foreground: UIColor)?\n"
        "    \n"
        "    // One cubic per half period, alternating side. Symmetric control points at four thirds of\n"
        "    // the amplitude put the crest exactly on it -- a cubic reaches three quarters of the way to\n"
        "    // a pair of controls that agree -- so the curve fills the box it is given and overshoots\n"
        "    // neither, which is the difference between a wave and a wave with its crests clipped flat.\n"
        "    private static func aorusWaveImage(size: CGSize, color: UIColor, lineWidth: CGFloat, halfPeriod: CGFloat) -> UIImage? {\n"
        "        return generateImage(size, rotatedContext: { size, context in\n"
        "            context.clear(CGRect(origin: CGPoint(), size: size))\n"
        "            let midY = size.height / 2.0\n"
        "            let amplitude = max(0.0, (size.height - lineWidth) / 2.0)\n"
        "            context.setStrokeColor(color.cgColor)\n"
        "            context.setLineWidth(lineWidth)\n"
        "            context.setLineCap(.round)\n"
        "            context.setLineJoin(.round)\n"
        "            context.beginPath()\n"
        "            context.move(to: CGPoint(x: 0.0, y: midY))\n"
        "            var x: CGFloat = 0.0\n"
        "            var isUp = true\n"
        "            while x < size.width {\n"
        "                let nextX = min(x + halfPeriod, size.width)\n"
        "                let control = isUp ? midY - amplitude * 4.0 / 3.0 : midY + amplitude * 4.0 / 3.0\n"
        "                context.addCurve(\n"
        "                    to: CGPoint(x: nextX, y: midY),\n"
        "                    control1: CGPoint(x: x + (nextX - x) * 0.36, y: control),\n"
        "                    control2: CGPoint(x: x + (nextX - x) * 0.64, y: control)\n"
        "                )\n"
        "                x = nextX\n"
        "                isUp = !isUp\n"
        "            }\n"
        "            context.strokePath()\n"
        "        })\n"
        "    }\n"
        "    \n"
        "    // The wave, redrawn when its size or its colours change and left alone every other time.\n"
        "    //\n"
        "    // The bar's own rounding and its buffering line both go: a pill behind a wave, or a fat\n"
        "    // rounded line through it, is the shape the wave was put there instead of.\n"
        "    private func aorusUpdateWave(node: StandardMediaPlayerScrubbingNodeContentNode, size: CGSize) {\n"
        "        guard size.width > 1.0, size.height > 1.0, let colors = self.aorusWaveColors else {\n"
        "            return\n"
        "        }\n"
        "        let key = \"\\(size.width)x\\(size.height)|\\(colors.background.hashValue)|\\(colors.foreground.hashValue)\"\n"
        "        if self.aorusWaveKey == key {\n"
        "            return\n"
        "        }\n"
        "        self.aorusWaveKey = key\n"
        "        let lineWidth: CGFloat = 3.0\n"
        "        let halfPeriod: CGFloat = 15.0\n"
        "        node.backgroundNode.backgroundColor = nil\n"
        "        node.backgroundNode.image = MediaPlayerScrubbingNode.aorusWaveImage(size: size, color: colors.background, lineWidth: lineWidth, halfPeriod: halfPeriod)\n"
        "        node.foregroundContentNode.backgroundColor = nil\n"
        "        node.foregroundContentNode.image = MediaPlayerScrubbingNode.aorusWaveImage(size: size, color: colors.foreground, lineWidth: lineWidth, halfPeriod: halfPeriod)\n"
        "        node.foregroundNode.layer.cornerRadius = 0.0\n"
        "        node.bufferingNode.isHidden = true\n"
        "    }\n",
        "wave scrubber state",
    )
    text = _replace_once(
        text,
        "    public init(content: MediaPlayerScrubbingNodeContent) {\n"
        "        self.contentNodes = MediaPlayerScrubbingNode.contentNodesFromContent(content, enableScrubbing: self.enableScrubbing)\n",
        "    public init(content: MediaPlayerScrubbingNodeContent) {\n"
        "        self.contentNodes = MediaPlayerScrubbingNode.contentNodesFromContent(content, enableScrubbing: self.enableScrubbing)\n"
        "        // AorusGram: the colours the wave is drawn in, taken while the content is still here.\n"
        "        if case let .standard(_, _, _, backgroundColor, foregroundColor, _, _) = content {\n"
        "            self.aorusWaveColors = (background: backgroundColor, foreground: foregroundColor)\n"
        "        }\n",
        "wave scrubber colours at init",
    )
    text = _replace_once(
        text,
        "    public func updateContent(_ content: MediaPlayerScrubbingNodeContent) {\n"
        "        self.contentNodes = MediaPlayerScrubbingNode.contentNodesFromContent(content, enableScrubbing: self.enableScrubbing)\n",
        "    public func updateContent(_ content: MediaPlayerScrubbingNodeContent) {\n"
        "        self.contentNodes = MediaPlayerScrubbingNode.contentNodesFromContent(content, enableScrubbing: self.enableScrubbing)\n"
        "        // AorusGram: a new set of nodes, so the wave has to be drawn into them again -- and the\n"
        "        // colours come off the new content, which is where a track change puts them.\n"
        "        if case let .standard(_, _, _, backgroundColor, foregroundColor, _, _) = content {\n"
        "            self.aorusWaveColors = (background: backgroundColor, foreground: foregroundColor)\n"
        "        }\n"
        "        self.aorusWaveKey = nil\n",
        "wave scrubber colours on content change",
    )
    text = _replace_once(
        text,
        "                    case .square:\n"
        "                        node.backgroundNode.backgroundColor = backgroundColor\n"
        "                        node.foregroundContentNode.backgroundColor = foregroundColor\n"
        "                }\n",
        "                    case .square:\n"
        "                        node.backgroundNode.backgroundColor = backgroundColor\n"
        "                        node.foregroundContentNode.backgroundColor = foregroundColor\n"
        "                }\n"
        "                // AorusGram: the wave takes the new pair over the bar's, and is redrawn in place.\n"
        "                // A theme can change while the player is open, and the two lines above have just\n"
        "                // put a bar back where the wave was.\n"
        "                if self.aorusWaveStyle {\n"
        "                    self.aorusWaveColors = (background: backgroundColor, foreground: foregroundColor)\n"
        "                    self.aorusWaveKey = nil\n"
        "                    self.aorusUpdateWave(node: node, size: node.backgroundNode.bounds.size)\n"
        "                }\n",
        "wave scrubber colours on theme change",
    )
    text = _replace_once(
        text,
        "                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: floor((bounds.size.height - node.lineHeight) / 2.0)), size: CGSize(width: bounds.size.width, height: node.lineHeight))\n",
        "                // AorusGram: a wave needs room to be one -- 16pt of box for a 3pt line with 6.5pt\n"
        "                // of crest either side of the middle, where the bar it replaces asked for 7. Never\n"
        "                // more than the height the scrubber was laid out at: a caller with less room than\n"
        "                // that gets a shorter wave rather than a clipped one. Every frame below is measured\n"
        "                // off this one, so the played part and the handle follow it without being told.\n"
        "                let aorusLineHeight: CGFloat = self.aorusWaveStyle ? min(bounds.size.height, max(node.lineHeight, 16.0)) : node.lineHeight\n"
        "                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: floor((bounds.size.height - aorusLineHeight) / 2.0)), size: CGSize(width: bounds.size.width, height: aorusLineHeight))\n"
        "                if self.aorusWaveStyle {\n"
        "                    self.aorusUpdateWave(node: node, size: backgroundFrame.size)\n"
        "                }\n",
        "wave scrubber layout",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the player's position line a wave")


def _patch_chat_nav_glass(tg: Path) -> None:
    """Take the tablet out from behind the chat's title and its avatar, and leave the rest.

    A chat's navigation bar has three panes of glass in it: one behind the back button, one behind
    the name and status, and one behind whatever is on the right -- in a chat, the peer's avatar, or
    the ghost-mode badge that replaces it. Interface 2.0 keeps the first and drops the other two, so
    the name reads straight off the wallpaper and the avatar is a photo rather than a photo in a
    lozenge.

    The right-hand pane is shared with every text button in the app -- Edit, Done, Cancel, Select --
    and those keep theirs, because a bare word floating in a navigation bar has nothing to say it is
    a button. `singleCustomNode` is exactly that distinction: it is non-nil only for a bar item built
    from a display node of its own, which the avatar and the ghost badge are and a title button is
    not.

    The title pane is written twice over, because there are two title views. `ChatTitleView` is the
    older one and still carries a `backgroundView` of its own; the one a chat actually installs is
    `ChatNavigationBarTitleView`, whose pane belongs to the `ChatTitleComponent` inside it. Hiding
    only the first is why the capsule under the name survived a build that took the avatar's away.
    """
    title = tg / "submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleView.swift"
    text = _read(title, "ChatTitleView.swift")
    if "aorusHidesTitleGlass" in text:
        print("InterfaceV2: chat title tablet already hidden")
    else:
        text = _replace_once(
            text,
            "        self.backgroundView.update(size: backgroundFrame.size, cornerRadius: backgroundFrame.height * 0.5, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, transition: componentTransition)\n",
            "        // AorusGram: no tablet behind the name and the status under Interface 2.0. The pane\n"
            "        // is told not to draw *and* hidden: isVisible is what actually takes the glass\n"
            "        // away, and isHidden keeps a stale snapshot of it from showing through during a\n"
            "        // push. It is still laid out, so switching the setting off puts it back with the\n"
            "        // geometry this pass just computed.\n"
            "        let aorusHidesTitleGlass = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
            "        self.backgroundView.update(size: backgroundFrame.size, cornerRadius: backgroundFrame.height * 0.5, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isInteractive: false, isVisible: !aorusHidesTitleGlass, transition: componentTransition)\n"
            "        self.backgroundView.isHidden = aorusHidesTitleGlass\n",
            "chat title glass",
        )
        title.write_text(text, encoding="utf-8")
        print("InterfaceV2: hid the chat title tablet")

    component = tg / "submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleComponent.swift"
    text = _read(component, "ChatTitleComponent.swift")
    if "aorusHidesTitlePill" in text:
        print("InterfaceV2: chat title pill already dropped")
    else:
        # Not the pane's isVisible, as in the older view above: here the name and the status are
        # subviews of the pane's own contentView, so a hidden pane takes them with it. The component
        # already has the branch for a title with no pane -- displayBackground: false lifts the two
        # lines back out into the view itself, gives them the frame the capsule would have had and
        # clears the corner radius -- so the pass supplies the flag it was waiting for instead of
        # inventing a second way to do it. The tap that opens the profile is on the content, not on
        # the pane, so it survives; turning the setting off restores the capsule exactly.
        text = _replace_once(
            text,
            "            let displayBackground: Bool = true\n",
            "            // AorusGram: Interface 2.0 stands the name and the status on the wallpaper\n"
            "            // with no tablet under them. The back button keeps its own pane, which is a\n"
            "            // different view in the navigation bar.\n"
            "            let aorusHidesTitlePill = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
            "            let displayBackground: Bool = !aorusHidesTitlePill\n",
            "chat title pill",
        )
        component.write_text(text, encoding="utf-8")
        print("InterfaceV2: dropped the chat title pill")

    bar = tg / "submodules/TelegramUI/Components/NavigationBarImpl/Sources/NavigationBarImpl.swift"
    text = _read(bar, "NavigationBarImpl.swift")
    if "aorusHidesCustomButtonGlass" in text:
        print("InterfaceV2: chat avatar tablet already hidden")
        return
    text = _replace_once(
        text,
        "                rightButtonsBackgroundView.background.isHidden = false\n"
        "                rightButtonsBackgroundView.background.update(size: rightButtonsBackgroundFrame.size, cornerRadius: rightButtonsBackgroundFrame.height * 0.5, isDark: self.presentationData.theme.overallDarkAppearance, tintColor: rightButtonsColor, isInteractive: true, transition: rightButtonsBackgroundTransition)\n",
        "                rightButtonsBackgroundView.background.isHidden = false\n"
        "                // AorusGram: the chat's avatar -- and the ghost-mode badge that stands in for\n"
        "                // it -- is a display node of its own, and Interface 2.0 shows it without a\n"
        "                // tablet. Text buttons keep theirs: they have no shape of their own, and the\n"
        "                // left-hand pane behind the back button is a different view entirely.\n"
        "                //\n"
        "                // isVisible and not isHidden: the button is added to this container's own\n"
        "                // contentView, so hiding the container takes the avatar with it, which is how\n"
        "                // the first version of this made both the avatar and the badge disappear.\n"
        "                let aorusHidesCustomButtonGlass = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\") && self.rightButtonNodeImpl.singleCustomNode != nil\n"
        "                rightButtonsBackgroundView.background.update(size: rightButtonsBackgroundFrame.size, cornerRadius: rightButtonsBackgroundFrame.height * 0.5, isDark: self.presentationData.theme.overallDarkAppearance, tintColor: rightButtonsColor, isInteractive: true, isVisible: !aorusHidesCustomButtonGlass, transition: rightButtonsBackgroundTransition)\n",
        "chat right button glass",
    )
    bar.write_text(text, encoding="utf-8")
    print("InterfaceV2: hid the chat avatar tablet")


def _patch_legacy_menu_glass(tg: Path) -> None:
    """Give the old-style tap menu the real material, the one a username in a profile opens.

    Telegram has two context menus. The one a long press opens is ContextControllerImpl, which is
    already glass on iOS 26. The one a *tap* on a username, a phone number or a link opens is the
    older ContextMenuNode, and it paints a flat 0x2f2f2f rectangle -- which under Interface 2.0 is
    the one obviously opaque panel left on the profile.

    Both halves of it are already written. The container takes an isBlurred flag that swaps its
    fill for an effect view, and every row takes the same flag and swaps its opaque grey for a
    translucent highlight; nothing else in either class depends on it. So this pass turns that flag
    on and upgrades the effect behind it from UIBlurEffect to UIGlassEffect, leaving the arrow, the
    mask that cuts it, the paging and the layout exactly as they were.
    """
    container = tg / "submodules/Display/Source/ContextMenuContainerNode.swift"
    text = _read(container, "ContextMenuContainerNode.swift")
    if "aorusGlassMenu" in text:
        print("InterfaceV2: legacy menu container already glass")
    else:
        text = _replace_once(
            text,
            "        if isBlurred {\n"
            "            let effectView = UIVisualEffectView(effect: UIBlurEffect(style: isDark ? .dark : .light))\n"
            "            self.containerNode.view.addSubview(effectView)\n"
            "            self.effectView = effectView\n"
            "        } else {\n",
            "        if isBlurred {\n"
            "            // AorusGram: the system material under Interface 2.0, the stock blur before\n"
            "            // it and on anything older than iOS 26. The corner radius matches the one the\n"
            "            // mask below cuts, so the glass edge lands on the shape that is actually\n"
            "            // visible; the arrow keeps its own edge from the mask.\n"
            "            let aorusGlassMenu = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
            "            let effectView: UIVisualEffectView\n"
            "            if #available(iOS 26.0, *), aorusGlassMenu {\n"
            "                effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))\n"
            "                effectView.cornerConfiguration = .corners(radius: UICornerRadius(floatLiteral: 10.0))\n"
            "            } else {\n"
            "                effectView = UIVisualEffectView(effect: UIBlurEffect(style: isDark ? .dark : .light))\n"
            "            }\n"
            "            self.containerNode.view.addSubview(effectView)\n"
            "            self.effectView = effectView\n"
            "        } else {\n",
            "legacy menu container glass",
        )
        container.write_text(text, encoding="utf-8")
        print("InterfaceV2: made the legacy menu container glass")

    node = tg / "submodules/TelegramUI/Components/ContextMenuScreen/Sources/ContextMenuNode.swift"
    text = _read(node, "ContextMenuNode.swift")
    if "aorusBlurredMenu" in text:
        print("InterfaceV2: legacy menu already blurred")
        return
    # A separate name rather than shadowing the parameter: the flag has to reach the container and
    # every row, and a local of the same name as the argument is the kind of thing that reads as a
    # typo in review.
    text = _replace_once(
        text,
        "        self.blurred = blurred\n"
        "        self.isDark = isDark\n",
        "        // AorusGram: a tap menu is glass under Interface 2.0, the same as the long-press one\n"
        "        // has been since iOS 26. One flag, because the container and the rows both already\n"
        "        // take it.\n"
        "        let aorusBlurredMenu = blurred || UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        self.blurred = aorusBlurredMenu\n"
        "        self.isDark = isDark\n",
        "legacy menu blurred flag",
    )
    text = _replace_once(
        text,
        "        self.containerNode = ContextMenuContainerNode(isBlurred: blurred, isDark: isDark)\n",
        "        self.containerNode = ContextMenuContainerNode(isBlurred: aorusBlurredMenu, isDark: isDark)\n",
        "legacy menu container flag",
    )
    text = _replace_once(
        text,
        "            return ContextMenuActionNode(action: action, blurred: blurred, isDark: isDark)\n",
        "            return ContextMenuActionNode(action: action, blurred: aorusBlurredMenu, isDark: isDark)\n",
        "legacy menu action flag",
    )
    # Rasterizing the fade is a group-opacity optimisation from when this menu was a flat grey
    # rectangle. Flattening a UIVisualEffectView into a bitmap is how a material comes out as a grey
    # slab for the length of the animation, so a menu that is blurred at all now skips it -- the
    # existing dark case already did, and the light one only ever rasterized a blur.
    for _ in range(2):
        text = _replace_once(
            text,
            "        if !(self.blurred && self.isDark) {\n",
            "        if !self.blurred {\n",
            "legacy menu fade rasterization",
        )
    node.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the legacy menu rows translucent")


_TAP_MENU_SWIFT = '''
// MARK: - AorusGram Interface 2.0

// The five menus a *tap* opens in a profile -- on a birthday, a bio, a phone number, a username, a
// business address -- are the last ones in the app built on ContextMenuNode, and next to the system
// menu a long press brings up on the very same rows they read as a panel from an older version of
// iOS. Under Interface 2.0 they are presented through the controller everything else uses, so they
// arrive in the same material, with the same rows and the same dismissal. Answering false leaves
// the caller to present the old menu exactly as it always did.
//
// The anchor is a point and not a view: sourceRect is the rect of the one username that was tapped
// inside a row that may list several of them, and a reference source can only be handed a view.
extension PeerInfoScreenNode {
    func aorusPresentTapMenu(actions: [ContextMenuAction], sourceNode: ASDisplayNode, sourceRect: CGRect?) -> Bool {
        guard AorusGlassPane.isEnabled, let controller = self.controller else {
            return false
        }
        let strings = self.presentationData.strings
        var items: [ContextMenuItem] = []
        for action in actions {
            let title: String
            switch action.content {
            case let .text(text, _):
                title = text
            case let .textWithIcon(text, _):
                title = text
            case let .textWithSubtitleAndIcon(text, _, _):
                title = text
            case .icon:
                // An action carrying a picture in place of a title has nothing to put in a list
                // row. No caller here makes one; if one ever does, the old menu draws it correctly.
                return false
            }
            // Copy and Translate are the only two titles these five menus ever carry. Reading the
            // icon off the string is what lets the rows keep the glyphs every other menu shows.
            let iconName: String?
            if title == strings.Conversation_ContextMenuCopy {
                iconName = "Chat/Context Menu/Copy"
            } else if title == strings.Conversation_ContextMenuTranslate {
                iconName = "Chat/Context Menu/Translate"
            } else {
                iconName = nil
            }
            let performAction = action.action
            items.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                guard let iconName else {
                    return nil
                }
                return generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.contextMenu.primaryColor)
            }, action: { c, _ in
                c?.dismiss {
                    performAction()
                }
            })))
        }
        if items.isEmpty {
            return false
        }
        // The left edge and the bottom of the tapped text, in the window's own coordinates: a
        // location source lays the menu out downwards from its left edge, which is where the old
        // menu opened too.
        let anchorRect = sourceRect ?? sourceNode.bounds
        let location = sourceNode.view.convert(CGPoint(x: anchorRect.minX, y: anchorRect.maxY), to: nil)
        let contextController = makeContextController(
            presentationData: self.presentationData,
            source: .location(AorusTapMenuLocationSource(location: location)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: nil
        )
        controller.present(contextController, in: .window(.root))
        return true
    }
}

private final class AorusTapMenuLocationSource: ContextLocationContentSource {
    private let location: CGPoint

    init(location: CGPoint) {
        self.location = location
    }

    func transitionInfo() -> ContextControllerLocationViewInfo? {
        return ContextControllerLocationViewInfo(location: self.location, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
'''


def _legacy_tap_present(indent: str) -> str:
    """The present block all five branches end on, byte for byte, at whatever depth it sits."""
    return (
        indent + "controller.present(contextMenuController, in: .window(.root), with: ContextMenuControllerPresentationArguments(sourceNodeAndRect: { [weak self, weak sourceNode] in\n"
        + indent + "    if let controller = self?.controller, let sourceNode = sourceNode {\n"
        + indent + "        var rect = sourceNode.bounds.insetBy(dx: 0.0, dy: 2.0)\n"
        + indent + "        if let sourceRect = sourceRect {\n"
        + indent + "            rect = sourceRect.insetBy(dx: 0.0, dy: 2.0)\n"
        + indent + "        }\n"
        + indent + "        return (sourceNode, rect, controller.displayNode, controller.view.bounds)\n"
        + indent + "    } else {\n"
        + indent + "        return nil\n"
        + indent + "    }\n"
        + indent + "}))\n"
    )


def _glass_tap_present(indent: str, call: str, actions: str) -> str:
    return (
        indent + "// AorusGram: the glass menu under Interface 2.0, the old panel without it.\n"
        + indent + "if " + call + " {\n"
        + indent + "    let contextMenuController = makeContextMenuController(actions: " + actions + ")\n"
        + _legacy_tap_present(indent + "    ")
        + indent + "}\n"
    )


def _patch_profile_tap_menu_glass(tg: Path) -> None:
    """Send the profile's tap menus through the system context controller.

    The container and the rows of the old menu were taught the material in the pass above, and it
    is still the right fix for the menus elsewhere in the app that use it. In a profile it is not
    enough: what a username opens there sits inches from the long-press menu on the same row, and
    side by side the difference in shape, in the arrow and in the spring is the whole complaint.
    So these five present the real thing instead.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenOpenPeerInfoContextMenu.swift"
    text = _read(path, "PeerInfoScreenOpenPeerInfoContextMenu.swift")
    if "aorusPresentTapMenu" in text:
        print("InterfaceV2: profile tap menus already glass")
        return

    text = _replace_once(
        text,
        "import AsyncDisplayKit\nimport UndoUI\n",
        "import AsyncDisplayKit\nimport ContextUI\nimport TelegramPresentationData\nimport UndoUI\n",
        "profile tap menu imports",
    )

    # A birthday, a bio and a business address build their actions into a local first. The bio does
    # it inside a `[weak self]` closure, so there self is an optional and the call has to be one.
    #
    # Deepest first: each of these keeps the old menu nested one level inside the new branch, which
    # leaves a second copy of the block four spaces further in. Working outwards means that copy is
    # always deeper than anything still to be matched -- run the other way round and the bio's
    # pattern finds the birthday's leftovers instead of the bio.
    for indent, call, label in (
        (" " * 20, "self?.aorusPresentTapMenu(actions: actions, sourceNode: sourceNode, sourceRect: sourceRect) != true", "bio"),
        (" " * 16, "!self.aorusPresentTapMenu(actions: actions, sourceNode: sourceNode, sourceRect: sourceRect)", "birthday"),
        (" " * 12, "!self.aorusPresentTapMenu(actions: actions, sourceNode: sourceNode, sourceRect: sourceRect)", "business address"),
    ):
        text = _replace_once(
            text,
            indent + "let contextMenuController = makeContextMenuController(actions: actions)\n" + _legacy_tap_present(indent),
            _glass_tap_present(indent, call, "actions"),
            f"profile tap menu ({label})",
        )

    # A phone number and a username pass their one action straight into the call. Naming the array
    # is what lets both menus read it, and both branches are the same two lines.
    for label in ("phone", "username"):
        text = _replace_once(
            text,
            "            let contextMenuController = makeContextMenuController(actions: [ContextMenuAction(content: .text(title: self.presentationData.strings.Conversation_ContextMenuCopy, accessibilityLabel: self.presentationData.strings.Conversation_ContextMenuCopy), action: { [weak self] in\n",
            "            let aorusTapActions: [ContextMenuAction] = [ContextMenuAction(content: .text(title: self.presentationData.strings.Conversation_ContextMenuCopy, accessibilityLabel: self.presentationData.strings.Conversation_ContextMenuCopy), action: { [weak self] in\n",
            f"profile tap menu actions ({label})",
        )
    for label in ("phone", "username"):
        text = _replace_once(
            text,
            "            })])\n" + _legacy_tap_present(" " * 12),
            "            })]\n"
            + _glass_tap_present(
                " " * 12,
                "!self.aorusPresentTapMenu(actions: aorusTapActions, sourceNode: sourceNode, sourceRect: sourceRect)",
                "aorusTapActions",
            ),
            f"profile tap menu ({label})",
        )

    path.write_text(text + _TAP_MENU_SWIFT, encoding="utf-8")
    print("InterfaceV2: made the profile tap menus glass")


_PROXY_ORDER_SWIFT = '''    /// Ordering by one number per case instead of a switch over every pair of them.
    ///
    /// Upstream compared each case against all the others, which means four new cases would have
    /// meant a new arm inside each of the seven existing ones -- seven places to get wrong, and a
    /// comparison that disagrees with itself sorts a list into nonsense. One number per case says
    /// the same thing once. Servers keep their own relative order because a server's index is added
    /// to its base, and the three trailing rows are parked far above any list of servers.
    private var sortIndex: Int {
        switch self {
            case .aorusHeader:
                return 0
            case .aorusBypass:
                return 1
            case .aorusStableCalls:
                return 2
            case .aorusInfo:
                return 3
            case let .aorusUserVPN(_, row):
                // Every new block sorts by the row's own index, offset to sit between the saved
                // proxies and the three rows upstream keeps at the bottom -- which is where the
                // configurations belong: under the proxies, above "Поделиться списком".
                return 2000000 + row.sortIndex
            case .enabled:
                return 4
            case .serversHeader:
                return 5
            case .addServer:
                return 6
            case let .server(index, _, _, _, _, _, _, _):
                return 1000 + index
            case .shareProxyList:
                return 10000000
            case .useForCalls:
                return 10000001
            case .useForCallsInfo:
                return 10000002
        }
    }

    static func <(lhs: ProxySettingsControllerEntry, rhs: ProxySettingsControllerEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }
'''


def _patch_switch_item_leading_icon(tg: Path) -> None:
    """A leading glyph that lines up with the title rather than with the two-line block, and turns.

    Upstream centres a switch row's icon on the whole content block: with a status line present its
    centre lands on the gap between title and status, which is right for a settings glyph that
    stands for the row, and wrong for a *status* glyph that stands for the title beside it -- it
    reads as crooked, roughly half the status line's height low.

    The second half is the turning. A row whose status is "connecting" needs the same indefinite
    spinner the rest of Telegram uses, and the row already has an icon slot in exactly the right
    place; giving that slot Telegram's own rotation is a great deal less invasive than threading an
    `ActivityIndicator` subnode through the item's layout. The animation is upstream's to the
    parameter: `transform.rotation.z` from 0 to 2*pi, half a second, linear, forever.

    So both halves are opt-in and nothing else moves: two defaulted parameters, false everywhere
    they are not asked for, and the only branches they add are the ones they ask for. Rows without a
    status line are untouched either way, since with `text == nil` upstream already centres on the
    row.
    """
    path = tg / "submodules/ItemListUI/Sources/Items/ItemListSwitchItem.swift"
    text = _read(path, "ItemListSwitchItem.swift")
    if "aorusIconAlignsWithTitle" in text:
        print("InterfaceV2: switch item leading icon already applied")
        return

    text = _replace_once(
        text,
        "    let icon: UIImage?\n"
        "    let title: String\n",
        "    let icon: UIImage?\n"
        "    // AorusGram: put `icon` on the title's line instead of the content block's centre.\n"
        "    let aorusIconAlignsWithTitle: Bool\n"
        "    // AorusGram: turn `icon` the way an indefinite activity indicator turns.\n"
        "    let aorusIconSpins: Bool\n"
        "    let title: String\n",
        "switch item icon alignment property",
    )
    text = _replace_once(
        text,
        "icon: UIImage? = nil, title: String,",
        "icon: UIImage? = nil, aorusIconAlignsWithTitle: Bool = false, aorusIconSpins: Bool = false, title: String,",
        "switch item icon alignment parameter",
    )
    text = _replace_once(
        text,
        "        self.icon = icon\n"
        "        self.title = title\n",
        "        self.icon = icon\n"
        "        self.aorusIconAlignsWithTitle = aorusIconAlignsWithTitle\n"
        "        self.aorusIconSpins = aorusIconSpins\n"
        "        self.title = title\n",
        "switch item icon alignment assignment",
    )
    # The title sits at `topInset + 1.0` and is `titleLayout.size.height` tall, so this is its
    # centre less half the glyph -- clamped, because a glyph taller than the title would otherwise
    # be asked to start above the row.
    text = _replace_once(
        text,
        "                        let iconY: CGFloat\n"
        "                        if item.text == nil {\n"
        "                            iconY = floor((layout.contentSize.height - icon.size.height) / 2.0)\n"
        "                        } else {\n",
        "                        let iconY: CGFloat\n"
        "                        if item.text == nil {\n"
        "                            iconY = floor((layout.contentSize.height - icon.size.height) / 2.0)\n"
        "                        } else if item.aorusIconAlignsWithTitle {\n"
        "                            iconY = max(0.0, floor(topInset + 1.0 + (titleLayout.size.height - icon.size.height) / 2.0))\n"
        "                        } else {\n",
        "switch item icon alignment layout",
    )
    # The glyph and the rotation are set together, by one method, from the item the node holds --
    # see the comment on it. Upstream's `updateIcon` diff is left in place: it still decides whether
    # the *image assignment* happens on this pass, and the reconcile below corrects it either way.
    text = _replace_once(
        text,
        "                        iconTransition.updateFrame(node: strongSelf.iconNode, frame: CGRect(origin: CGPoint(x: params.leftInset + floor((leftInset - params.leftInset - icon.size.width) / 2.0), y: iconY), size: icon.size))\n"
        "                    } else if strongSelf.iconNode.supernode != nil {\n"
        "                        strongSelf.iconNode.image = nil\n"
        "                        strongSelf.iconNode.removeFromSupernode()\n",
        "                        iconTransition.updateFrame(node: strongSelf.iconNode, frame: CGRect(origin: CGPoint(x: params.leftInset + floor((leftInset - params.leftInset - icon.size.width) / 2.0), y: iconY), size: icon.size))\n"
        "                        strongSelf.aorusReconcileIcon()\n"
        "                    } else if strongSelf.iconNode.supernode != nil {\n"
        "                        strongSelf.iconNode.image = nil\n"
        "                        strongSelf.iconNode.removeFromSupernode()\n"
        "                        strongSelf.aorusReconcileIcon()\n",
        "switch item icon rotation",
    )
    text = _replace_once(
        text,
        "        (self.switchNode.view as? UISwitch)?.addTarget(self, action: #selector(self.switchValueChanged(_:)), for: .valueChanged)\n"
        "        self.switchGestureNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))\n"
        "    }\n",
        "        (self.switchNode.view as? UISwitch)?.addTarget(self, action: #selector(self.switchValueChanged(_:)), for: .valueChanged)\n"
        "        self.switchGestureNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))\n"
        "    }\n"
        + _SWITCH_ITEM_ICON_SWIFT,
        "switch item icon reconcile",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: switch item leading icon aligned with title")


_SWITCH_ITEM_ICON_SWIFT = '''
    /// The leading glyph and its rotation, decided together from the item this node is holding.
    ///
    /// They used to be decided apart, and that is how a *checkmark* came to spin. Upstream assigns
    /// the image only when it differs from the previous item's (`updateIcon`), while the rotation was
    /// added from the item of the pass that was running -- two different comparisons for one glyph.
    /// A pass that skipped the assignment but added the animation left the rotation turning whatever
    /// image happened to be on the node, and a row that is reloaded on every state signal gets a
    /// great many passes. Reading both from `self.item`, and the image from the node itself, means
    /// they cannot disagree: the animation runs only while the glyph under it is the spinner.
    ///
    /// It also runs when the node re-enters the hierarchy, because Core Animation drops a layer's
    /// animations while it is out of one -- a spinner that was turning when the user opened a
    /// configuration came back from it standing still. Telegram's own ActivityIndicator restarts
    /// itself on the same hook, for the same reason.
    ///
    /// The transform is reset on the way out because a layer keeps whatever an interrupted rotation
    /// left it at: without this, a glyph that stopped at 200 degrees stays crooked for as long as
    /// the node lives.
    private func aorusReconcileIcon() {
        var spins = false
        if let item = self.item, let icon = item.icon {
            if self.iconNode.image !== icon {
                self.iconNode.image = icon
            }
            spins = item.aorusIconSpins
        }
        if spins {
            // Re-adding an identical animation would restart it from zero on every layout pass,
            // which on a row that reloads this often is a visible stutter.
            if self.iconNode.layer.animation(forKey: "aorusIconRotation") == nil {
                self.iconNode.layer.transform = CATransform3DIdentity
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = NSNumber(value: Float(0.0))
                rotation.toValue = NSNumber(value: Float.pi * 2.0)
                rotation.duration = 0.5
                rotation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.linear)
                rotation.repeatCount = Float.infinity
                self.iconNode.layer.add(rotation, forKey: "aorusIconRotation")
            }
        } else {
            self.iconNode.layer.removeAnimation(forKey: "aorusIconRotation")
            self.iconNode.layer.transform = CATransform3DIdentity
        }
    }

    override public func willEnterHierarchy() {
        super.willEnterHierarchy()

        self.aorusReconcileIcon()
    }
'''


def _patch_proxy_connection_section(tg: Path) -> None:
    """AorusGram's own transport, on Telegram's own Proxy screen.

    Two switches. One decides whether this client carries a tunnel at all; the other whether calls
    go through it instead of straight out. They belong on this screen rather than on a screen of
    ours: it is where a user goes when a connection will not come up, and the rest of it is already
    about that. Settings gains one row above "Диагностика прокси" that opens this same screen.

    Under the saved proxies come the user's own VLESS configurations -- a switch that hands this
    client's transport to them, the configurations themselves with a "+" row that imports whatever
    is on the clipboard, each with its own servers under it.

    The rows themselves, the state signals and the support-chat jump live in AorusGramUI, in
    AorusConnectionSection.swift and AorusUserVPNSection.swift. What is added here is five entries
    -- four for the connection block, one carrying every row of the configuration blocks -- their
    place in the order, and the closures behind them. Nothing upstream draws is changed, and with
    the switches left alone the screen behaves exactly as it shipped.
    """
    path = tg / "submodules/SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift"
    text = _read(path, "ProxyListSettingsController.swift")
    if "aorusConnectionSwitchItem" in text:
        print("InterfaceV2: proxy connection section already applied")
        return

    text = _replace_once(
        text,
        "import ShareController\nimport UrlEscaping\n",
        "import ShareController\nimport UrlEscaping\nimport AorusGramUI\n",
        "proxy list imports",
    )

    # The three halves of the arguments object: fields, init parameters, assignments.
    text = _replace_once(
        text,
        "    let shareProxyList: () -> Void\n",
        "    let shareProxyList: () -> Void\n"
        "    // The context is what the caption's tappable link needs; the second entry point can be\n"
        "    // built without one, and the block is then left out rather than drawn half-working.\n"
        "    let aorusContext: AccountContext?\n"
        "    let aorusToggleBypass: (Bool) -> Void\n"
        "    let aorusToggleStableCalls: (Bool) -> Void\n"
        "    let aorusOpenSupport: () -> Void\n"
        "    // The user's own VLESS configurations. Three closures and no more: everything that is\n"
        "    // a mutation goes straight to AorusGramUI's own free functions, and only what needs\n"
        "    // this controller -- a screen to present on, a stack to push on -- comes through here.\n"
        "    let aorusPresent: (ViewController) -> Void\n"
        "    let aorusOpenUserVPNConfig: (String) -> Void\n"
        "    let aorusAddUserVPNConfig: () -> Void\n",
        "proxy arguments fields",
    )
    text = _replace_once(
        text,
        "toggleUseForCalls: @escaping (Bool) -> Void, shareProxyList: @escaping () -> Void) {\n",
        "toggleUseForCalls: @escaping (Bool) -> Void, shareProxyList: @escaping () -> Void, "
        "aorusContext: AccountContext?, aorusToggleBypass: @escaping (Bool) -> Void, "
        "aorusToggleStableCalls: @escaping (Bool) -> Void, aorusOpenSupport: @escaping () -> Void, "
        "aorusPresent: @escaping (ViewController) -> Void, "
        "aorusOpenUserVPNConfig: @escaping (String) -> Void, "
        "aorusAddUserVPNConfig: @escaping () -> Void) {\n",
        "proxy arguments init",
    )
    text = _replace_once(
        text,
        "        self.shareProxyList = shareProxyList\n",
        "        self.shareProxyList = shareProxyList\n"
        "        self.aorusContext = aorusContext\n"
        "        self.aorusToggleBypass = aorusToggleBypass\n"
        "        self.aorusToggleStableCalls = aorusToggleStableCalls\n"
        "        self.aorusOpenSupport = aorusOpenSupport\n"
        "        self.aorusPresent = aorusPresent\n"
        "        self.aorusOpenUserVPNConfig = aorusOpenUserVPNConfig\n"
        "        self.aorusAddUserVPNConfig = aorusAddUserVPNConfig\n",
        "proxy arguments assignments",
    )

    text = _replace_once(
        text,
        "private enum ProxySettingsControllerSection: Int32 {\n    case enabled\n",
        "private enum ProxySettingsControllerSection: Int32 {\n"
        "    case aorusConnection\n"
        "    // The switch, then a block per configuration -- its card, its traffic and its own\n"
        "    // servers -- and the button and caption under all of them. Two of the three names are\n"
        "    // bases the per-configuration and footer ids are offset from, not single sections.\n"
        "    case aorusUserVPNToggle\n"
        "    case aorusUserVPNConfigs\n"
        "    case aorusUserVPNServers\n"
        "    case enabled\n",
        "proxy section enum",
    )

    text = _replace_once(
        text,
        "private enum ProxySettingsControllerEntry: ItemListNodeEntry {\n"
        "    case enabled(PresentationTheme, String, Bool, Bool)\n",
        "private enum ProxySettingsControllerEntry: ItemListNodeEntry {\n"
        "    case aorusHeader(PresentationTheme, String)\n"
        "    case aorusBypass(PresentationTheme, String, String?, AorusConnectionIndicator, Bool)\n"
        "    case aorusStableCalls(PresentationTheme, String, Bool)\n"
        "    case aorusInfo(PresentationTheme, String, String)\n"
        "    // One case for both new blocks: what the rows are, in what order and what a tap does\n"
        "    // are decided in AorusGramUI, so a change to the VPN screen is a change to one module.\n"
        "    case aorusUserVPN(PresentationTheme, AorusUserVPNRow)\n"
        "    case enabled(PresentationTheme, String, Bool, Bool)\n",
        "proxy entry cases",
    )

    text = _replace_once(
        text,
        "            case .enabled:\n"
        "                return ProxySettingsControllerSection.enabled.rawValue\n",
        "            case .aorusHeader, .aorusBypass, .aorusStableCalls, .aorusInfo:\n"
        "                return ProxySettingsControllerSection.aorusConnection.rawValue\n"
        "            case let .aorusUserVPN(_, row):\n"
        "                switch row.section {\n"
        "                    case .toggle:\n"
        "                        return ProxySettingsControllerSection.aorusUserVPNToggle.rawValue\n"
        "                    case let .config(index):\n"
        "                        // One block per configuration: a card, its traffic and its own\n"
        "                        // servers read as one thing, and two lists of the same kind of row\n"
        "                        // never end up next to each other. Offset past every section id on\n"
        "                        // this screen, and clamped so a pathological number of imports\n"
        "                        // merges the tail of the list into one block instead of colliding\n"
        "                        // with the caption below it.\n"
        "                        return ProxySettingsControllerSection.aorusUserVPNConfigs.rawValue + 1000 + Int32(min(index, 1900))\n"
        "                    case .footer:\n"
        "                        return ProxySettingsControllerSection.aorusUserVPNServers.rawValue + 5000\n"
        "                }\n"
        "            case .enabled:\n"
        "                return ProxySettingsControllerSection.enabled.rawValue\n",
        "proxy entry section",
    )

    # Well clear of upstream's 0...5 so a row added upstream cannot collide with one of these.
    text = _replace_once(
        text,
        "            case .enabled:\n                return .index(0)\n",
        "            case .aorusHeader:\n"
        "                return .index(20)\n"
        "            case .aorusBypass:\n"
        "                return .index(21)\n"
        "            case .aorusStableCalls:\n"
        "                return .index(22)\n"
        "            case .aorusInfo:\n"
        "                return .index(23)\n"
        "            case let .aorusUserVPN(_, row):\n"
        "                // The row's own index is unique across both blocks, so it is the stable id\n"
        "                // as well as the order -- offset past every id on this screen.\n"
        "                return .index(2000000 + row.sortIndex)\n"
        "            case .enabled:\n"
        "                return .index(0)\n",
        "proxy entry stable id",
    )

    text = _replace_once(
        text,
        "        switch lhs {\n"
        "            case let .enabled(lhsTheme, lhsText, lhsValue, lhsCreatesNew):\n",
        "        switch lhs {\n"
        "            case let .aorusHeader(lhsTheme, lhsText):\n"
        "                if case let .aorusHeader(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, "
        "lhsText == rhsText {\n"
        "                    return true\n"
        "                } else {\n"
        "                    return false\n"
        "                }\n"
        "            case let .aorusBypass(lhsTheme, lhsText, lhsStatus, lhsIndicator, lhsValue):\n"
        "                if case let .aorusBypass(rhsTheme, rhsText, rhsStatus, rhsIndicator, rhsValue) = rhs, "
        "lhsTheme === rhsTheme, lhsText == rhsText, lhsStatus == rhsStatus, "
        "lhsIndicator == rhsIndicator, lhsValue == rhsValue {\n"
        "                    return true\n"
        "                } else {\n"
        "                    return false\n"
        "                }\n"
        "            case let .aorusStableCalls(lhsTheme, lhsText, lhsValue):\n"
        "                if case let .aorusStableCalls(rhsTheme, rhsText, rhsValue) = rhs, "
        "lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {\n"
        "                    return true\n"
        "                } else {\n"
        "                    return false\n"
        "                }\n"
        "            case let .aorusInfo(lhsTheme, lhsText, lhsLink):\n"
        "                if case let .aorusInfo(rhsTheme, rhsText, rhsLink) = rhs, "
        "lhsTheme === rhsTheme, lhsText == rhsText, lhsLink == rhsLink {\n"
        "                    return true\n"
        "                } else {\n"
        "                    return false\n"
        "                }\n"
        "            case let .aorusUserVPN(lhsTheme, lhsRow):\n"
        "                if case let .aorusUserVPN(rhsTheme, rhsRow) = rhs, "
        "lhsTheme === rhsTheme, lhsRow == rhsRow {\n"
        "                    return true\n"
        "                } else {\n"
        "                    return false\n"
        "                }\n"
        "            case let .enabled(lhsTheme, lhsText, lhsValue, lhsCreatesNew):\n",
        "proxy entry equality",
    )

    text = _replace_span(
        text,
        "    static func <(lhs: ProxySettingsControllerEntry, rhs: ProxySettingsControllerEntry) -> Bool {\n",
        "            case .useForCallsInfo:\n                return false\n        }\n    }\n",
        _PROXY_ORDER_SWIFT,
        "proxy entry ordering",
    )

    text = _replace_once(
        text,
        "            case let .enabled(_, text, value, createsNew):\n",
        "            case let .aorusHeader(_, text):\n"
        "                return ItemListSectionHeaderItem(presentationData: presentationData, text: text, "
        "sectionId: self.section)\n"
        "            case let .aorusBypass(_, text, status, indicator, value):\n"
        "                return aorusConnectionSwitchItem(presentationData: presentationData, title: text, "
        "statusText: status, indicator: indicator, value: value, sectionId: self.section, updated: { value in\n"
        "                    arguments.aorusToggleBypass(value)\n"
        "                })\n"
        "            case let .aorusStableCalls(_, text, value):\n"
        "                return aorusConnectionSwitchItem(presentationData: presentationData, title: text, "
        "statusText: nil, indicator: AorusConnectionIndicator.none, value: value, sectionId: self.section, "
        "updated: { value in\n"
        "                    arguments.aorusToggleStableCalls(value)\n"
        "                })\n"
        "            case let .aorusInfo(_, text, linkText):\n"
        "                guard let aorusContext = arguments.aorusContext else {\n"
        "                    return ItemListTextItem(presentationData: presentationData, text: .plain(text), "
        "sectionId: self.section)\n"
        "                }\n"
        "                return aorusConnectionFooterItem(presentationData: presentationData, "
        "context: aorusContext, text: text, linkText: linkText, sectionId: self.section, openSupport: {\n"
        "                    arguments.aorusOpenSupport()\n"
        "                })\n"
        "            case let .aorusUserVPN(_, row):\n"
        "                // The \"+\" row is built here rather than in AorusGramUI because "
        "ProxySettingsActionItem is internal to this module: the button under the configurations has\n"
        "                // to be the same button as \"Добавить прокси\" above it, not a lookalike.\n"
        "                return aorusUserVPNRowItem(presentationData: presentationData, "
        "context: arguments.aorusContext, row: row, sectionId: self.section, present: { controller in\n"
        "                    arguments.aorusPresent(controller)\n"
        "                }, openConfig: { configId in\n"
        "                    arguments.aorusOpenUserVPNConfig(configId)\n"
        "                }, buildAddRow: { text in\n"
        "                    return ProxySettingsActionItem(presentationData: presentationData, "
        "systemStyle: .glass, title: text, icon: .add, sectionId: self.section, editing: false, action: {\n"
        "                        arguments.aorusAddUserVPNConfig()\n"
        "                    })\n"
        "                })\n"
        "            case let .enabled(_, text, value, createsNew):\n",
        "proxy entry items",
    )

    text = _replace_once(
        text,
        "connectionStatus: ConnectionStatus) -> [ProxySettingsControllerEntry] {\n",
        "connectionStatus: ConnectionStatus, aorusContext: AccountContext?, "
        "aorusState: AorusConnectionSectionState, "
        "aorusUserVPNState: AorusUserVPNSectionState) -> [ProxySettingsControllerEntry] {\n",
        "proxy entries signature",
    )
    text = _replace_once(
        text,
        "    entries.append(.enabled(theme, strings.ChatSettings_ConnectionType_UseProxy, "
        "proxySettings.enabled, proxySettings.servers.isEmpty))\n",
        "    if aorusContext != nil {\n"
        "        let l10n = AorusL10n(strings.baseLanguageCode)\n"
        "        // A switch that is off is not waiting for anything, so it carries no status at all.\n"
        "        let indicator = aorusState.bypassIndicator\n"
        "        let status: String?\n"
        "        switch indicator {\n"
        "            case .none:\n"
        "                status = nil\n"
        "            case .connecting:\n"
        "                status = l10n.connectionConnecting\n"
        "            case .connected:\n"
        "                status = l10n.connectionConnected\n"
        "            case .suspended:\n"
        "                status = l10n.connectionSuspended\n"
        "        }\n"
        "        entries.append(.aorusHeader(theme, l10n.connectionHeader))\n"
        "        entries.append(.aorusBypass(theme, l10n.connectionBypass, status, indicator, "
        "aorusState.bypassEnabled))\n"
        "        entries.append(.aorusStableCalls(theme, l10n.connectionStableCalls, "
        "aorusState.stableCallsEnabled))\n"
        "        entries.append(.aorusInfo(theme, l10n.connectionFooter, l10n.connectionSupportLink))\n"
        "        // The configuration blocks. They sort themselves under the saved proxies, so\n"
        "        // they are appended with the rest of the AorusGram rows rather than spliced into\n"
        "        // the middle of upstream's own list.\n"
        "        for row in aorusUserVPNRows(state: aorusUserVPNState, languageCode: strings.baseLanguageCode) {\n"
        "            entries.append(.aorusUserVPN(theme, row))\n"
        "        }\n"
        "    }\n"
        "\n"
        "    entries.append(.enabled(theme, strings.ChatSettings_ConnectionType_UseProxy, "
        "proxySettings.enabled, proxySettings.servers.isEmpty))\n",
        "proxy entries block",
    )

    text = _replace_once(
        text,
        "    var shareProxyListImpl: (() -> Void)?\n",
        "    var shareProxyListImpl: (() -> Void)?\n"
        "    var aorusOpenSupportImpl: (() -> Void)?\n"
        "    // Upstream has no present impl on this screen -- everything it does either pushes or\n"
        "    // dismisses -- and the import pill and its error alert need one.\n"
        "    var aorusPresentImpl: ((ViewController) -> Void)?\n",
        "proxy support impl declaration",
    )
    text = _replace_once(
        text,
        "    }, shareProxyList: {\n       shareProxyListImpl?()\n    })\n",
        "    }, shareProxyList: {\n"
        "       shareProxyListImpl?()\n"
        "    }, aorusContext: context, aorusToggleBypass: { value in\n"
        "        aorusConnectionSetBypassEnabled(value)\n"
        "    }, aorusToggleStableCalls: { value in\n"
        "        aorusConnectionSetStableCallsEnabled(value)\n"
        "    }, aorusOpenSupport: {\n"
        "        aorusOpenSupportImpl?()\n"
        "    }, aorusPresent: { controller in\n"
        "        aorusPresentImpl?(controller)\n"
        "    }, aorusOpenUserVPNConfig: { configId in\n"
        "        guard let context = context else {\n"
        "            return\n"
        "        }\n"
        "        // Pushed the same way upstream pushes a proxy's own screen from this list.\n"
        "        pushControllerImpl?(aorusUserVPNSettingsController(context: context, configId: configId))\n"
        "    }, aorusAddUserVPNConfig: {\n"
        "        guard let context = context else {\n"
        "            return\n"
        "        }\n"
        "        aorusUserVPNImportFromClipboard(context: context, present: { controller in\n"
        "            aorusPresentImpl?(controller)\n"
        "        })\n"
        "    })\n",
        "proxy arguments construction",
    )

    text = _replace_once(
        text,
        "    let signal = combineLatest(updatedPresentationData, statePromise.get(), proxySettings.get(), "
        "statusesContext.statuses(), network.connectionStatus)\n"
        "    |> map { presentationData, state, proxySettings, statuses, connectionStatus -> "
        "(ItemListControllerState, (ItemListNodeState, Any)) in\n",
        "    // The two AorusGram states are combined into one argument rather than added as two:\n"
        "    // upstream's own five are already at this combineLatest's widest proven arity here.\n"
        "    let signal = combineLatest(updatedPresentationData, statePromise.get(), proxySettings.get(), "
        "statusesContext.statuses(), network.connectionStatus, "
        "combineLatest(aorusConnectionSectionState(), aorusUserVPNSectionState()))\n"
        "    |> map { presentationData, state, proxySettings, statuses, connectionStatus, aorusStates -> "
        "(ItemListControllerState, (ItemListNodeState, Any)) in\n",
        "proxy state signal",
    )
    text = _replace_once(
        text,
        "statuses: statuses, connectionStatus: connectionStatus), style: .blocks, "
        "ensureVisibleItemTag: focusOnItemTag)\n",
        "statuses: statuses, connectionStatus: connectionStatus, aorusContext: context, "
        "aorusState: aorusStates.0, aorusUserVPNState: aorusStates.1), style: .blocks, "
        "ensureVisibleItemTag: focusOnItemTag)\n",
        "proxy list state",
    )

    text = _replace_once(
        text,
        "    shareProxyListImpl = { [weak controller] in\n",
        "    aorusOpenSupportImpl = { [weak controller] in\n"
        "        guard let context = context, let strongController = controller else {\n"
        "            return\n"
        "        }\n"
        "        // This screen is a modal container, and anything pushed after it joins that container:\n"
        "        // the support chat would open inside the sheet. Taking the screen out of the stack first\n"
        "        // leaves the chat on the main one, where a chat opened from settings belongs. Filtering a\n"
        "        // controller that is not in the stack -- the modally presented variant -- does nothing.\n"
        "        let navigationController = strongController.navigationController as? NavigationController\n"
        "        navigationController?.filterController(strongController, animated: true)\n"
        "        aorusOpenConnectionSupportChat(context: context, navigationController: navigationController)\n"
        "    }\n"
        "    \n"
        "    aorusPresentImpl = { [weak controller] presented in\n"
        "        controller?.present(presented, in: .window(.root))\n"
        "    }\n"
        "    \n"
        "    shareProxyListImpl = { [weak controller] in\n",
        "proxy support impl",
    )

    path.write_text(text, encoding="utf-8")
    # The AorusGramUI dep is also added by patch_custom_font, which runs later; asking here as well
    # keeps this pass standing on its own, and both write the same line so neither can double it.
    # AorusGram itself is named in nothing this file writes, but the state it hands the screen
    # carries a route mode out of that module, so the module has to be loadable from here rather
    # than only reachable through AorusGramUI's own deps.
    _add_build_deps(
        tg / "submodules/SettingsUI/BUILD",
        ["//submodules/AorusGramUI", "//submodules/AorusGram:AorusGram"],
        "SettingsUI",
    )
    print("InterfaceV2: put the AorusGram connection and VLESS blocks on the Proxy screen")


# A row that cannot be tapped is dimmed by painting the card's own colour over it at a raised
# alpha: on an opaque card that reads as "this row is the block, only fainter". Under glass the
# card has no colour of its own -- it is the marker -- and `withAlphaComponent` keeps a colour's
# hue while replacing only its alpha, so the expression does not fade the marker, it makes it
# opaque enough to see: a slab at 60% that hides the material underneath. That is what put a pink
# rectangle over an administrator's default-granted rights -- `ItemListExpandableSwitchItem`
# disables those rows, and its wash took the marker from 1/255 to 153/255. With the marker
# neutralised the slab is ink rather than magenta, which is the right colour and still far too
# much of it.
#
# `AorusGlassPane.rowWash` restates the intent instead of the mechanism: over a real card it is
# still `withAlphaComponent`, byte for byte what upstream did; over the marker it returns a scrim
# shallow enough to leave the glass visible through the dimmed row. Each site hands it the ink
# beside it, which is why the receiver differs from file to file.
_ROW_WASH_SITES = (
    (
        "submodules/ItemListUI/Sources/Items/ItemListSwitchItem.swift",
        "currentDisabledOverlayNode.backgroundColor = itemBackgroundColor.withAlphaComponent(0.6)",
        "currentDisabledOverlayNode.backgroundColor = AorusGlassPane.rowWash(over: itemBackgroundColor, ink: item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.6)",
    ),
    (
        "submodules/ItemListUI/Sources/Items/ItemListExpandableSwitchItem.swift",
        "currentDisabledOverlayNode.backgroundColor = itemBackgroundColor.withAlphaComponent(0.6)",
        "currentDisabledOverlayNode.backgroundColor = AorusGlassPane.rowWash(over: itemBackgroundColor, ink: item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.6)",
    ),
    (
        "submodules/PeerInfoUI/Sources/ItemListReactionItem.swift",
        "currentDisabledOverlayNode.backgroundColor = itemBackgroundColor.withAlphaComponent(0.6)",
        "currentDisabledOverlayNode.backgroundColor = AorusGlassPane.rowWash(over: itemBackgroundColor, ink: item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.6)",
    ),
    (
        "submodules/ItemListPeerItem/Sources/ItemListPeerItem.swift",
        "currentDisabledOverlayNode?.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.5)",
        "currentDisabledOverlayNode?.backgroundColor = AorusGlassPane.rowWash(over: item.presentationData.theme.list.itemBlocksBackgroundColor, ink: item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.5)",
    ),
    (
        "submodules/ItemListStickerPackItem/Sources/ItemListStickerPackItem.swift",
        "currentDisabledOverlayNode?.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.5)",
        "currentDisabledOverlayNode?.backgroundColor = AorusGlassPane.rowWash(over: item.presentationData.theme.list.itemBlocksBackgroundColor, ink: item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.5)",
    ),
    (
        "submodules/PeerInfoUI/Sources/PeerAutoremoveTimeoutItem.swift",
        "strongSelf.disabledOverlayNode.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.4)",
        "strongSelf.disabledOverlayNode.backgroundColor = AorusGlassPane.rowWash(over: item.presentationData.theme.list.itemBlocksBackgroundColor, ink: item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.4)",
    ),
    (
        "submodules/SettingsUI/Sources/Text Size/TextSizeSelectionItem.swift",
        "strongSelf.disabledOverlayNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.4)",
        "strongSelf.disabledOverlayNode.backgroundColor = AorusGlassPane.rowWash(over: item.theme.list.itemBlocksBackgroundColor, ink: item.theme.list.itemPrimaryTextColor, alpha: 0.4)",
    ),
    (
        "submodules/SettingsUI/Sources/Themes/ThemeSettingsFontSizeItem.swift",
        "strongSelf.disabledOverlayNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.4)",
        "strongSelf.disabledOverlayNode.backgroundColor = AorusGlassPane.rowWash(over: item.theme.list.itemBlocksBackgroundColor, ink: item.theme.list.itemPrimaryTextColor, alpha: 0.4)",
    ),
    (
        "submodules/ListMessageItem/Sources/ListMessageFileItemNode.swift",
        "strongSelf.restrictionNode.backgroundColor = item.presentationData.theme.theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.6)",
        "strongSelf.restrictionNode.backgroundColor = AorusGlassPane.rowWash(over: item.presentationData.theme.theme.list.itemBlocksBackgroundColor, ink: item.presentationData.theme.theme.list.itemPrimaryTextColor, alpha: 0.6)",
    ),
)


def _patch_disabled_row_wash(tg: Path) -> None:
    """Dim a disabled row without repainting the card's colour over it.

    Nine sites, each the same shape and each already importing TelegramPresentationData, so this
    adds no dependency anywhere. The other seventy-odd derivations of the card colour -- shimmer
    placeholders, gradient blends, the mini-app palettes -- are left to the marker alone, and they
    are right by construction now that it carries the page's ink: upstream's card is near-black on
    a dark theme and near-white on a light one, so a derivation that amplifies black or white lands
    within a shade of where upstream aimed it. These nine are the ones where landing on upstream's
    own value is still wrong, because upstream's own value is an opaque slab and the point of the
    row is that the glass shows through it.
    """
    for relative, old, new in _ROW_WASH_SITES:
        path = tg / relative
        text = _read(path, Path(relative).name)
        if "AorusGlassPane.rowWash" in text:
            print(f"InterfaceV2: disabled row wash already applied in {Path(relative).name}")
            continue
        text = _replace_once(text, old, new, f"{Path(relative).name} disabled row wash")
        path.write_text(text, encoding="utf-8")
    print("InterfaceV2: dimmed disabled rows with a neutral scrim instead of the card colour")


def _patch_build(tg: Path) -> None:
    _add_build_deps(
        tg / "submodules/UndoUI/BUILD",
        ["//submodules/TelegramUI/Components/GlassBackgroundComponent"],
        "UndoUI",
    )
    _add_build_deps(
        tg / "submodules/TelegramUI/Components/Gifts/GiftItemComponent/BUILD",
        ["//submodules/TelegramUI/Components/GlassBackgroundComponent"],
        "GiftItemComponent",
    )
    _add_build_deps(
        tg / "submodules/TelegramUI/Components/ListSectionComponent/BUILD",
        ["//submodules/TelegramUI/Components/GlassBackgroundComponent"],
        "ListSectionComponent",
    )
    _add_build_deps(
        tg / "submodules/ShareController/BUILD",
        ["//submodules/TelegramUI/Components/GlassBackgroundComponent"],
        "ShareController",
    )


def patch_interface_v2(tg: Path) -> None:
    """Interface 2.0, end to end.

    Runs after patch_profile_personalization, not before: the glass behind an action button is
    cornered from the round-button flag that patch inserts, and the section pane has to be put in
    place after the code that used to colour those sections has been pointed at a clear fill.
    """
    _patch_glass_theme(tg)
    _patch_item_list_theme(tg)
    _patch_badge_contrast(tg)
    _patch_corner_wedges(tg)
    _patch_profile_section_glass(tg)
    _patch_editing_fields_glass(tg)
    _patch_header_centering(tg)
    _patch_multi_scale_centering(tg)
    _patch_glass_action_buttons(tg)
    _patch_avatar_tint_publish(tg)
    _patch_avatar_placeholder(tg)
    _patch_glass_placeholder_avatar(tg)
    _patch_avatar_expansion(tg)
    _patch_keep_avatar_expanded(tg)
    _patch_overlay_palette(tg)
    _patch_static_avatar(tg)
    _patch_compact_music(tg)
    _patch_music_player_glass(tg)
    _patch_wave_scrubber(tg)
    _patch_chat_nav_glass(tg)
    _patch_legacy_menu_glass(tg)
    _patch_profile_tap_menu_glass(tg)
    _patch_action_sheet_glass(tg)
    _patch_action_sheet_icon_rows(tg)
    _patch_share_sheet_glass(tg)
    _patch_gift_glass(tg)
    _patch_undo_glass(tg)
    _patch_header_button_set(tg)
    _patch_item_list_glass(tg)
    _patch_component_section_glass(tg)
    _patch_nav_button_glass(tg)
    _patch_pane_container_glass(tg)
    _patch_pane_page_background(tg)
    _patch_members_pane_glass(tg)
    _patch_groups_pane_glass(tg)
    _patch_recommended_pane_glass(tg)
    _patch_rating_shield(tg)
    _patch_switch_item_leading_icon(tg)
    _patch_disabled_row_wash(tg)
    _patch_proxy_connection_section(tg)
    _patch_build(tg)
