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

    public static let blockMarker = UIColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0 / 255.0)

    /// The radius the panes are drawn with, and the one the rows have to agree with when they clip
    /// their own content.
    public static let blockCornerRadius: CGFloat = 26.0

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

    private let lock = NSLock()
    private var sourceIdentifier: ObjectIdentifier?
    private var variants: [Int: PresentationTheme] = [:]
    private var derivedIdentifiers = Set<ObjectIdentifier>()

    func derive(from theme: PresentationTheme, dark: Bool) -> PresentationTheme {
        self.lock.lock()
        defer { self.lock.unlock() }

        // Deriving from an already derived theme would compound the alpha of every colour.
        if self.derivedIdentifiers.contains(ObjectIdentifier(theme)) {
            return theme
        }
        let identifier = ObjectIdentifier(theme)
        if self.sourceIdentifier != identifier {
            self.sourceIdentifier = identifier
            self.variants.removeAll()
        }
        // Two: dark ink or light ink.
        let slot = dark ? 1 : 0
        if let cached = self.variants[slot] {
            return cached
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
            itemBlocksBackgroundColor: AorusGlassPane.blockMarker,
            itemModalBlocksBackgroundColor: AorusGlassPane.blockMarker,
            itemHighlightedBackgroundColor: aorusInk(dark ? 0.1 : 0.06),
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
            itemHighlightedBackgroundColor: aorusInk(dark ? 0.1 : 0.06),
            pinnedItemHighlightedBackgroundColor: aorusInk(dark ? 0.1 : 0.06),
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

        if self.derivedIdentifiers.count > 8 {
            self.derivedIdentifiers.removeAll()
        }
        self.variants[slot] = derived
        self.derivedIdentifiers.insert(ObjectIdentifier(derived))
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
            "        // under the whole screen can be that colour.\n"
            "        if aorusCentredHeader {\n"
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
            "        AorusGlassProfileTint.publishAvatarTint(\n"
            "            for: peer.id.id._internalGetInt64Value(),\n"
            "            photo: photo,\n"
            "            photoCount: listContainerNode.galleryEntries.count,\n"
            "            view: sampledView,\n"
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

    Four places take it back, and each is a different reason.

    Telegram collapses the expanded photo as soon as the list scrolls a single point, which is
    what would make the photo snap into the corner on the first touch. It stays expanded and
    simply scrolls away instead -- nothing is pinned and no offset is faked, the header keeps
    the size it was drawn at.

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
        "            } else if offsetY >= 1.0 {\n"
        "                shouldBeExpanded = false\n"
        "                self.canOpenAvatarByDragging = false\n"
        "            }\n",
        "            } else if offsetY >= 1.0 {\n"
        "                // AorusGram: Interface 2.0 keeps the photo at full width for the whole\n"
        "                // scroll instead of shrinking it into the corner on the first point of\n"
        "                // movement. Nothing is pinned and no offsets are faked -- the header just\n"
        "                // keeps the size it already had and scrolls with the content.\n"
        "                let aorusKeepsAvatarExpanded = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "                    && !self.isSettings\n"
        "                    && self.chatLocation.threadId == nil\n"
        "                    && self.state.updatingAvatar == nil\n"
        "                    && !self.state.isEditing\n"
        "                    && self.data?.peer?.smallProfileImage != nil\n"
        "                if !aorusKeepsAvatarExpanded {\n"
        "                    shouldBeExpanded = false\n"
        "                }\n"
        "                self.canOpenAvatarByDragging = false\n"
        "            }\n",
        "keep avatar expanded",
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
        "        if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\"),\n"
        "           !self.isSettings,\n"
        "           self.chatLocation.threadId == nil,\n"
        "           self.data?.peer?.smallProfileImage != nil {\n"
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
        "                    // 2.0 never opens on and offers no way back from.\n"
        "                    if UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\"),\n"
        "                       !strongSelf.headerNode.isAvatarExpanded,\n"
        "                       !strongSelf.isSettings, !strongSelf.isMediaOnly,\n"
        "                       strongSelf.chatLocation.threadId == nil,\n"
        "                       strongSelf.data?.peer?.smallProfileImage != nil {\n"
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
            if let color = subnode.backgroundColor, color.isEqual(AorusGlassPane.blockMarker) {
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
    """Shrink the saved-music capsule to the size it is in the mockup.

    Stock sizes this row for a full-width strip across the bottom of the header: 24pt of content at
    12pt type, and the capsule pass wraps it in a pill, which came out 38pt tall and read as the
    loudest thing on the screen. The mockup has a small pill under the buttons, so the content drops
    to 16pt at 11pt type and the header reserves proportionally less room beneath the photo for it.
    The pill's own padding is set where the pill is created, one script earlier, and checked here.

    It is also lifted clear of the bottom of the photo. Stock bottom-aligns the row to the header,
    which for a pill means its lower quarter hangs over the join between the picture and the page --
    reported as looking unfinished, and it did. 12pt puts the whole capsule inside the photo.
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
        "        // the whole header is measured with.\n"
        "        let aorusCompactMusic = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        let musicHeight: CGFloat = aorusCompactMusic ? 16.0 : (hasBackground || self.isAvatarExpanded ? 24.0 : 16.0)\n",
        "compact music height",
    )
    text = _replace_once(
        text,
        "            musicString.append(NSAttributedString(string: track ?? \"\", font: Font.semibold(12.0), textColor: isOverlay ? .white : presentationData.theme.list.itemAccentColor))\n"
        "            musicString.append(NSAttributedString(string: \" - \\(artist)\", font: Font.regular(12.0), textColor: isOverlay ? UIColor.white.withAlphaComponent(0.7) : presentationData.theme.list.itemSecondaryTextColor))\n",
        "            let aorusMusicFontSize: CGFloat = aorusCompactMusic ? 11.0 : 12.0\n"
        "            musicString.append(NSAttributedString(string: track ?? \"\", font: Font.semibold(aorusMusicFontSize), textColor: isOverlay ? aorusOverlayInk : presentationData.theme.list.itemAccentColor))\n"
        "            musicString.append(NSAttributedString(string: \" - \\(artist)\", font: Font.regular(aorusMusicFontSize), textColor: isOverlay ? aorusOverlayInk.withAlphaComponent(0.7) : presentationData.theme.list.itemSecondaryTextColor))\n",
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
    # Lifted off the bottom edge of the photo. The clearance is exact: the buttons above end
    # 16 + bottomInset points above the header's bottom, bottomInset is this row's own 16, and the
    # pill is 22 tall with its padding -- so 10 leaves 3 points under the buttons and 7 above the
    # join. The x term is the capsule pass's centring, which is why this anchors on its line.
    text = _replace_once(
        text,
        "            let musicFrame = CGRect(origin: CGPoint(x: aorusMusicX, y: (apparentBackgroundHeight - backgroundHeight) + backgroundHeight - musicHeight - (hasBackground || self.isAvatarExpanded ? 0.0 : 4.0)), size: musicSize)\n",
        "            let aorusMusicLift: CGFloat = aorusCompactMusic ? 10.0 : 0.0\n"
        "            let musicFrame = CGRect(origin: CGPoint(x: aorusMusicX, y: (apparentBackgroundHeight - backgroundHeight) + backgroundHeight - musicHeight - (hasBackground || self.isAvatarExpanded ? 0.0 : 4.0) - aorusMusicLift), size: musicSize)\n",
        "compact music lift",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: made the saved-music capsule compact")


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


def patch_interface_v2(tg: Path) -> None:
    """Interface 2.0, end to end.

    Runs after patch_profile_personalization, not before: the glass behind an action button is
    cornered from the round-button flag that patch inserts, and the section pane has to be put in
    place after the code that used to colour those sections has been pointed at a clear fill.
    """
    _patch_glass_theme(tg)
    _patch_item_list_theme(tg)
    _patch_corner_wedges(tg)
    _patch_profile_section_glass(tg)
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
    _patch_chat_nav_glass(tg)
    _patch_legacy_menu_glass(tg)
    _patch_action_sheet_glass(tg)
    _patch_gift_glass(tg)
    _patch_undo_glass(tg)
    _patch_header_button_set(tg)
    _patch_item_list_glass(tg)
    _patch_component_section_glass(tg)
    _patch_nav_button_glass(tg)
    _patch_pane_container_glass(tg)
    _patch_pane_page_background(tg)
    _patch_build(tg)
