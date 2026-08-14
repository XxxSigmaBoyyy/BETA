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

private final class AorusGlassThemeCache {
    static let shared = AorusGlassThemeCache()

    private let lock = NSLock()
    private var sourceIdentifier: ObjectIdentifier?
    private var darkVariant: PresentationTheme?
    private var lightVariant: PresentationTheme?
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
            self.darkVariant = nil
            self.lightVariant = nil
        }
        if dark, let cached = self.darkVariant {
            return cached
        }
        if !dark, let cached = self.lightVariant {
            return cached
        }

        // Ink and pane, and both of them flip with the appearance. That flip is the whole of
        // light-theme support: black letters on a pale pane, where the dark theme has white
        // letters on a dark one. No border and no sheen in either -- those are the two things
        // that make a hand-drawn panel read as a fake next to the real material behind it.
        let ink: UIColor = dark ? UIColor(white: 1.0, alpha: 1.0) : UIColor(white: 0.0, alpha: 1.0)
        let pane: UIColor = dark ? UIColor(white: 1.0, alpha: 0.09) : UIColor(white: 1.0, alpha: 0.55)
        let hairline: UIColor = dark ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.1)
        func aorusInk(_ alpha: CGFloat) -> UIColor {
            return dark ? UIColor(white: 1.0, alpha: alpha) : UIColor(white: 0.0, alpha: alpha)
        }

        let list = theme.list.withUpdated(
            itemPrimaryTextColor: ink,
            itemSecondaryTextColor: aorusInk(0.65),
            itemDisabledTextColor: aorusInk(0.35),
            itemAccentColor: ink,
            itemPlaceholderTextColor: aorusInk(0.4),
            itemBlocksBackgroundColor: pane,
            itemHighlightedBackgroundColor: aorusInk(dark ? 0.1 : 0.06),
            itemBlocksSeparatorColor: hairline,
            itemPlainSeparatorColor: hairline,
            disclosureArrowColor: aorusInk(0.35),
            sectionHeaderTextColor: aorusInk(0.6),
            freeTextColor: aorusInk(0.55),
            controlSecondaryColor: aorusInk(0.2)
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
            chatList: theme.chatList,
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
        if dark {
            self.darkVariant = derived
        } else {
            self.lightVariant = derived
        }
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

    /// The same, for the peer-info list. Always the dark pair whatever the theme is: the page
    /// under this one is the avatar's colour, which is dark by construction.
    var aorusGlassProfileTheme: PresentationTheme {
        guard UserDefaults.standard.bool(forKey: aorusInterfaceV2Key) else {
            return self
        }
        return AorusGlassThemeCache.shared.derive(from: self, dark: true)
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
        "                cornerRadius: hasCorners ? 11.0 : 0.0,\n"
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
        "            let aorusSubtitleX: CGFloat = aorusCentredHeader\n"
        "                ? floorToScreenPixels((width - subtitleSize.width) / 2.0)\n"
        "                : (16.0 - subtitleButtonHorizontalOffset * (1.0 - titleCollapseFraction))\n"
        "            subtitleFrame = CGRect(origin: CGPoint(x: aorusSubtitleX, y: minTitleFrame.maxY + 2.0), size: subtitleSize)\n"
        "            if self.subtitleRating != nil, !aorusCentredHeader {\n"
        "                subtitleFrame.origin.x += 22.0\n"
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
    """Publish the avatar's colour from the layout pass that already has the avatar."""
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    text = _read(path, "PeerInfoHeaderNode.swift")
    if "publishAvatarTint" in text:
        print("InterfaceV2: avatar tint already published")
        return
    text = _replace_once(
        text,
        "        self.avatarListNode.update(size: CGSize(), avatarSize: avatarSize, isExpanded: self.isAvatarExpanded, peer: peer, isForum: isForum, threadId: self.forumTopicThreadId, threadInfo: threadData?.info, theme: presentationData.theme, transition: transition)\n",
        "        self.avatarListNode.update(size: CGSize(), avatarSize: avatarSize, isExpanded: self.isAvatarExpanded, peer: peer, isForum: isForum, threadId: self.forumTopicThreadId, threadInfo: threadData?.info, theme: presentationData.theme, transition: transition)\n"
        "        // AorusGram: read the colour off the avatar that was just laid out, so the page\n"
        "        // under the whole screen can be that colour. Sampling the rendered view rather\n"
        "        // than the peer's palette is the point: the page has to match the photo, and a\n"
        "        // photo has no palette entry. The screen repaints its background at the end of\n"
        "        // this same pass, so the only case needing a callback is a photo that finishes\n"
        "        // decoding after it -- one more layout, once, when the colour finally lands.\n"
        "        if aorusCentredHeader, let peer {\n"
        "            AorusGlassProfileTint.publishAvatarTint(\n"
        "                for: peer.id.id._internalGetInt64Value(),\n"
        "                view: self.avatarListNode.avatarContainerNode.avatarNode.view,\n"
        "                onUpdate: { [weak self] in\n"
        "                    self?.requestUpdateLayout?(false)\n"
        "                }\n"
        "            )\n"
        "        }\n",
        "avatar tint publish",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: published the avatar tint")


def _patch_avatar_placeholder(tg: Path) -> None:
    """Replace the coloured placeholder gradient with frosted glass, everywhere at once.

    A peer with no photo gets initials on one of Telegram's fixed colour gradients, drawn into
    an image by AvatarNode. Interface 2.0 wants those initials on glass instead -- in the chat
    list, in search, in the contact list and in the profile. All four draw through this one
    routine, so all four change together, and because it stays a drawn image there is no
    per-row effect view and no cost to scrolling.
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
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: frosted the avatar placeholders")


def _patch_avatar_expansion(tg: Path) -> None:
    """Keep the photo at full width while scrolling, and never expand one that is not there.

    Two halves of the same complaint. The header is built before the peer is loaded, so the
    Interface 2.0 flag alone cannot tell whether there is a photo to expand -- and expanding a
    profile that has none is what breaks its layout. The correction happens the moment the
    peer arrives. Separately, Telegram collapses the expanded photo as soon as the list scrolls
    a single point; Interface 2.0 leaves it expanded and simply lets it scroll away, which is
    what keeps the scroll native rather than pinning anything to the top.
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


def _patch_item_list_glass(tg: Path) -> None:
    """Put the real material behind the settings lists too, not just the profile.

    A blocks-style ItemList screen paints an opaque page and opaque rows on top of it. Interface
    2.0 keeps the page -- something has to be behind glass for glass to mean anything -- lays a
    pane of `GlassBackgroundView` over it, and lets the list scroll above that with a clear
    background. The rows are already translucent by then, because the glass list theme has
    replaced their fill, so what is left is cards on glass. This is the one file every settings
    screen in the app goes through, so all of them change together.
    """
    path = tg / "submodules/ItemListUI/Sources/ItemListControllerNode.swift"
    text = _read(path, "ItemListControllerNode.swift")
    if "aorusGlassBackgroundView" in text:
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
        "    // AorusGram: created on the first transition that reports a blocks-style list, so a\n"
        "    // screen opened with Interface 2.0 off never builds an effect view it will not show.\n"
        "    private var aorusGlassBackgroundView: GlassBackgroundView?\n",
        "list glass property",
    )
    # Both copies of the blocks branch: one runs on a theme change, the other when the style
    # itself changes. The anchor is the same text, so the same replacement is applied twice.
    blocks_old = (
        "                        case .blocks:\n"
        "                            self.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
        "                            self.listNode.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
        "                            self.leftOverlayNode.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
        "                            self.rightOverlayNode.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
    )
    blocks_new = (
        "                        case .blocks:\n"
        "                            // AorusGram: the page colour stays on this node's own layer,\n"
        "                            // which is what the glass pane above it refracts. The list and\n"
        "                            // the side gutters go clear so that pane is not painted over.\n"
        "                            let aorusListGlass = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "                            self.backgroundColor = transition.theme.list.blocksBackgroundColor\n"
        "                            self.listNode.backgroundColor = aorusListGlass ? UIColor.clear : transition.theme.list.blocksBackgroundColor\n"
        "                            self.leftOverlayNode.backgroundColor = aorusListGlass ? UIColor.clear : transition.theme.list.blocksBackgroundColor\n"
        "                            self.rightOverlayNode.backgroundColor = aorusListGlass ? UIColor.clear : transition.theme.list.blocksBackgroundColor\n"
    )
    text = _replace_once(text, blocks_old, blocks_new, "list glass colours on theme change")
    text = _replace_once(text, blocks_old, blocks_new, "list glass colours on style change")
    # The style is only known once a transition has been dequeued, and the first layout runs
    # before that, so the pane is installed from the transition side and merely resized from
    # the layout side.
    text = _replace_once(
        text,
        "    private func dequeueTransitions() {\n"
        "        while !self.enqueuedTransitions.isEmpty {\n"
        "            let transition = self.enqueuedTransitions.removeFirst()\n",
        "    // AorusGram: one pane for the whole page rather than one per row. A row is drawn by its\n"
        "    // own item node, of which there are dozens of kinds across the app, and an effect view\n"
        "    // per visible row would cost more than the look is worth. Behind the list and above the\n"
        "    // page colour is the one place that reaches all of them at once.\n"
        "    private func aorusUpdateListGlass(transition: ContainedViewLayoutTransition = .immediate) {\n"
        "        var isEnabled = UserDefaults.standard.bool(forKey: \"" + INTERFACE_V2_KEY + "\")\n"
        "        if let listStyle = self.listStyle {\n"
        "            if case .plain = listStyle {\n"
        "                isEnabled = false\n"
        "            }\n"
        "        } else {\n"
        "            isEnabled = false\n"
        "        }\n"
        "        guard isEnabled, let (aorusLayout, _, _) = self.validLayout else {\n"
        "            if let glassView = self.aorusGlassBackgroundView {\n"
        "                self.aorusGlassBackgroundView = nil\n"
        "                glassView.removeFromSuperview()\n"
        "            }\n"
        "            return\n"
        "        }\n"
        "        let glassFrame = CGRect(origin: CGPoint(), size: aorusLayout.size)\n"
        "        let glassView: GlassBackgroundView\n"
        "        if let current = self.aorusGlassBackgroundView {\n"
        "            glassView = current\n"
        "        } else {\n"
        "            glassView = GlassBackgroundView(frame: glassFrame)\n"
        "            glassView.isUserInteractionEnabled = false\n"
        "            self.aorusGlassBackgroundView = glassView\n"
        "            self.view.insertSubview(glassView, at: 0)\n"
        "        }\n"
        "        transition.updateFrame(view: glassView, frame: glassFrame)\n"
        "        glassView.update(\n"
        "            size: glassFrame.size,\n"
        "            cornerRadius: 0.0,\n"
        "            isDark: self.theme?.overallDarkAppearance ?? false,\n"
        "            tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "            isInteractive: false,\n"
        "            isVisible: true,\n"
        "            transition: ComponentTransition(transition)\n"
        "        )\n"
        "    }\n"
        "\n"
        "    private func dequeueTransitions() {\n"
        "        while !self.enqueuedTransitions.isEmpty {\n"
        "            let transition = self.enqueuedTransitions.removeFirst()\n",
        "list glass helper",
    )
    # Once per dequeued transition: the theme or the style may just have changed, and either
    # decides whether the pane belongs here and how dark it is.
    text = _replace_once(
        text,
        "            var options = ListViewDeleteAndInsertOptions()\n"
        "            if transition.firstTime {\n",
        "            self.aorusUpdateListGlass()\n"
        "\n"
        "            var options = ListViewDeleteAndInsertOptions()\n"
        "            if transition.firstTime {\n",
        "list glass transition hook",
    )
    text = _replace_once(
        text,
        "        let dequeue = self.validLayout == nil\n"
        "        self.validLayout = (layout, navigationBarHeight, additionalInsets)\n"
        "        if dequeue {\n"
        "            self.dequeueTransitions()\n"
        "        }\n",
        "        let dequeue = self.validLayout == nil\n"
        "        self.validLayout = (layout, navigationBarHeight, additionalInsets)\n"
        "        if dequeue {\n"
        "            self.dequeueTransitions()\n"
        "        }\n"
        "        // AorusGram: follows the page through rotation and split-view resizes.\n"
        "        self.aorusUpdateListGlass(transition: transition)\n",
        "list glass layout hook",
    )
    path.write_text(text, encoding="utf-8")
    print("InterfaceV2: put the settings lists on glass")


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


def _patch_build(tg: Path) -> None:
    _add_build_deps(
        tg / "submodules/UndoUI/BUILD",
        ["//submodules/TelegramUI/Components/GlassBackgroundComponent"],
        "UndoUI",
    )


def patch_interface_v2(tg: Path) -> None:
    """Interface 2.0, end to end.

    Runs after patch_profile_personalization, not before: the glass behind an action button is
    cornered from the round-button flag that patch inserts, and the section pane has to be put in
    place after the code that used to colour those sections has been pointed at a clear fill.
    """
    _patch_glass_theme(tg)
    _patch_item_list_theme(tg)
    _patch_profile_section_glass(tg)
    _patch_header_centering(tg)
    _patch_glass_action_buttons(tg)
    _patch_avatar_tint_publish(tg)
    _patch_avatar_placeholder(tg)
    _patch_avatar_expansion(tg)
    _patch_undo_glass(tg)
    _patch_header_button_set(tg)
    _patch_item_list_glass(tg)
    _patch_nav_button_glass(tg)
    _patch_build(tg)
