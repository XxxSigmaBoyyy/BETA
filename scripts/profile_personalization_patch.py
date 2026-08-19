"""In-place patches for AorusGram profile personalization on Telegram 12.9.2."""

from pathlib import Path

LICENSE_LOCK_KEY = "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04"

# Kept in step with AorusGlassProfileTint.key, which writes this value. The tab bar reads it
# straight from defaults because it cannot import AorusGramUI without closing a cycle in the
# build graph (ItemListUI -> HorizontalTabsComponent -> AorusGramUI -> ItemListUI).
_PROFILE_TAB_ACCENT_KEY = "aorusgram_profile_tab_accent"


def _replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"ProfilePersonalization: missing {label} anchor")
    return text.replace(old, new, 1)


def _guarded_background_geometry() -> str:
    return (
        "            // Cover Telegram's complete 2000 pt backing view. The media itself\n"
        "            // stays in the native cover viewport, while AorusGramUI provides a\n"
        "            // static edge guard for extreme pull-to-expand overscroll.\n"
        "            let aorusBackgroundFrame = CGRect(origin: .zero, size: bannerFrame.size)\n"
        "            self.aorusAnimatedProfileBackgroundView.contentFrame = CGRect(\n"
        "                x: -bannerInset,\n"
        "                y: bannerFrame.height - backgroundCoverSize.height,\n"
        "                width: backgroundCoverSize.width,\n"
        "                height: backgroundCoverSize.height\n"
        "            )\n"
    )


def _configured_background_sequence() -> str:
    return (
        _guarded_background_geometry()
        + "            // Prepare the first frame synchronously before inserting the view.\n"
        "            // This prevents Telegram's stock cover from winning one render pass.\n"
        "            if self.aorusAnimatedProfileBackgroundView.superview == nil {\n"
        "                self.aorusAnimatedProfileBackgroundView.frame = aorusBackgroundFrame\n"
        "                self.aorusAnimatedProfileBackgroundView.layoutIfNeeded()\n"
        "            }\n"
        "            self.aorusAnimatedProfileBackgroundView.configure(\n"
        "                viewerAccountId: aorusProfileAccountId,\n"
        "                targetId: aorusTargetProfileId,\n"
        "                visible: aorusTargetProfileId != nil\n"
        "            )\n"
        "            self.backgroundBannerView.insertSubview(self.aorusAnimatedProfileBackgroundView, aboveSubview: backgroundCoverView)\n"
        "            if additive {\n"
        "                transition.updateFrameAdditive(view: self.aorusAnimatedProfileBackgroundView, frame: aorusBackgroundFrame)\n"
        "            } else {\n"
        "                transition.updateFrame(view: self.aorusAnimatedProfileBackgroundView, frame: aorusBackgroundFrame)\n"
        "            }\n"
    )


def _legacy_order_background_sequence() -> str:
    return (
        "            self.aorusAnimatedProfileBackgroundView.configure(\n"
        "                viewerAccountId: aorusProfileAccountId,\n"
        "                targetId: aorusTargetProfileId,\n"
        "                visible: aorusTargetProfileId != nil\n"
        "            )\n"
        "            self.backgroundBannerView.insertSubview(self.aorusAnimatedProfileBackgroundView, aboveSubview: backgroundCoverView)\n"
        + _guarded_background_geometry()
        + "            if additive {\n"
        "                transition.updateFrameAdditive(view: self.aorusAnimatedProfileBackgroundView, frame: aorusBackgroundFrame)\n"
        "            } else {\n"
        "                transition.updateFrame(view: self.aorusAnimatedProfileBackgroundView, frame: aorusBackgroundFrame)\n"
        "            }\n"
    )


def _patch_profile_header(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: PeerInfoHeaderNode.swift is missing")
    text = path.read_text(encoding="utf-8")
    if "// AorusGram: animated profile background layer" in text:
        legacy_geometry = (
            "            // Keep the animated cover beyond every edge of Telegram's dynamic\n"
            "            // header frame. The parent clips it, so pull-to-expand and collapse\n"
            "            // transitions cannot reveal the stock cover underneath.\n"
            "            let aorusBackgroundVerticalBleed = max(96.0, min(240.0, backgroundCoverSize.height * 0.45))\n"
            "            let aorusBackgroundHorizontalBleed: CGFloat = 8.0\n"
            "            let aorusBackgroundFrame = CGRect(\n"
            "                x: -bannerInset - aorusBackgroundHorizontalBleed,\n"
            "                y: bannerFrame.height - backgroundCoverSize.height - aorusBackgroundVerticalBleed,\n"
            "                width: backgroundCoverSize.width + aorusBackgroundHorizontalBleed * 2.0,\n"
            "                height: backgroundCoverSize.height + aorusBackgroundVerticalBleed * 2.0\n"
            "            )\n"
        )
        guarded_geometry = _guarded_background_geometry()
        changed = False
        if legacy_geometry in text:
            text = text.replace(legacy_geometry, guarded_geometry, 1)
            changed = True
        legacy_order = _legacy_order_background_sequence()
        if legacy_order in text:
            text = text.replace(legacy_order, _configured_background_sequence(), 1)
            changed = True
        if changed:
            path.write_text(text, encoding="utf-8")
            print("ProfilePersonalization: upgraded cached profile first-frame guard")
        elif "Prepare the first frame synchronously" in text:
            print("ProfilePersonalization: PeerInfoHeaderNode already patched")
        else:
            raise RuntimeError("ProfilePersonalization: unknown cached animated-cover layout")
        return

    if "import AorusGramUI\n" not in text:
        text = _replace_once(text, "import UIKit\n", "import UIKit\nimport AorusGramUI\n", "profile header import")
    text = _replace_once(
        text,
        "    let backgroundCover = ComponentView<Empty>()\n",
        "    let backgroundCover = ComponentView<Empty>()\n"
        "    let aorusAnimatedProfileBackgroundView = AorusAnimatedProfileBackgroundView()\n",
        "profile header background property",
    )
    text = _replace_once(
        text,
        "        let avatarCornerRadius: CGFloat = isForum ? floor(avatarSize * 0.25) : avatarSize / 2.0\n",
        "        // AorusGram: rounded-square avatars in profile/settings previews\n"
        f"        let aorusSquareAvatars = !UserDefaults.standard.bool(forKey: \"{LICENSE_LOCK_KEY}\") && UserDefaults.standard.bool(forKey: \"aorusgram_square_avatars\")\n"
        "        let avatarCornerRadius: CGFloat = (isForum || aorusSquareAvatars) ? floor(avatarSize * 0.25) : avatarSize / 2.0\n",
        "profile header avatar radius",
    )

    anchor = (
        "            if additive {\n"
        "                transition.updateFrameAdditive(view: backgroundCoverView, frame: CGRect(origin: CGPoint(x: -bannerInset, y: bannerFrame.height - backgroundCoverSize.height), size: backgroundCoverSize))\n"
        "            } else {\n"
        "                transition.updateFrame(view: backgroundCoverView, frame: CGRect(origin: CGPoint(x: -bannerInset, y: bannerFrame.height - backgroundCoverSize.height), size: backgroundCoverSize))\n"
        "            }\n"
        "            if backgroundCoverAnimateIn {\n"
    )
    replacement = (
        "            if additive {\n"
        "                transition.updateFrameAdditive(view: backgroundCoverView, frame: CGRect(origin: CGPoint(x: -bannerInset, y: bannerFrame.height - backgroundCoverSize.height), size: backgroundCoverSize))\n"
        "            } else {\n"
        "                transition.updateFrame(view: backgroundCoverView, frame: CGRect(origin: CGPoint(x: -bannerInset, y: bannerFrame.height - backgroundCoverSize.height), size: backgroundCoverSize))\n"
        "            }\n"
        "\n"
        "            // AorusGram: animated profile background layer. Its normalized MP4\n"
        "            // has no audio track and never activates or changes AVAudioSession.\n"
        "            let aorusProfileAccountId = self.context.account.peerId.id._internalGetInt64Value()\n"
        "            let aorusTargetProfileId: Int64?\n"
        "            if let peer, case .user = peer {\n"
        "                aorusTargetProfileId = peer.id.id._internalGetInt64Value()\n"
        "            } else {\n"
        "                aorusTargetProfileId = nil\n"
        "            }\n"
        + _configured_background_sequence()
        + "            if backgroundCoverAnimateIn {\n"
    )
    text = _replace_once(text, anchor, replacement, "profile header cover frame")
    path.write_text(text, encoding="utf-8")
    print("ProfilePersonalization: patched PeerInfoHeaderNode")


def _patch_expanded_avatar_default(tg: Path) -> None:
    """Open a profile with the photo already at full width under Interface 2.0.

    This flips Telegram's own expanded state rather than drawing a replacement header.
    That distinction is the whole point: the carousel keeps swiping between photos, the
    image is the full-resolution one the gallery uses, the badges and the emoji in a name
    keep rendering, context menus keep their anchors, and the header still collapses with
    the scroll. A redrawn header has to reinvent every one of those, and the first attempt
    got all of them wrong.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    if not path.is_file():
        raise RuntimeError("ExpandedAvatar: PeerInfoHeaderNode.swift is missing")
    text = path.read_text(encoding="utf-8")
    if "// AorusGram: Interface 2.0 opens the photo at full width" in text:
        print("ExpandedAvatar: already patched")
        return
    text = _replace_once(
        text,
        "        self.isAvatarExpanded = avatarInitiallyExpanded\n",
        "        // AorusGram: Interface 2.0 opens the photo at full width straight away.\n"
        "        // Settings and media-only headers keep the stock behaviour: neither has a\n"
        "        // photo carousel to expand, so forcing the state there would only break\n"
        "        // their layout.\n"
        "        if !isSettings, !isMediaOnly, UserDefaults.standard.bool(forKey: \"aorusgram_interface_v2\") {\n"
        "            self.isAvatarExpanded = true\n"
        "        } else {\n"
        "            self.isAvatarExpanded = avatarInitiallyExpanded\n"
        "        }\n",
        "expanded avatar default",
    )
    path.write_text(text, encoding="utf-8")
    print("ExpandedAvatar: patched PeerInfoHeaderNode")


def _patch_round_action_buttons(tg: Path) -> None:
    """Draw the profile action row as circles of icons under Interface 2.0.

    The stock row is wide rounded rectangles stretched across the width with a caption
    under each icon. The reference design is four circles and no captions. Both the shape
    and the captions are decided inside the button node from the size it is handed, so the
    header only has to hand it a square and the node does the rest — no second button
    implementation, which is what keeps the context-menu anchors, the gesture handling and
    the icon animations working.
    """
    button = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderButtonNode.swift"
    if not button.is_file():
        raise RuntimeError("RoundButtons: PeerInfoHeaderButtonNode.swift is missing")
    text = button.read_text(encoding="utf-8")
    if "aorusIsRound" in text:
        print("RoundButtons: button node already patched")
    else:
        text = _replace_once(
            text,
            "        let iconSize = CGSize(width: 40.0, height: 40.0)\n",
            "        let iconSize = CGSize(width: 40.0, height: 40.0)\n"
            "        // AorusGram: a square means Interface 2.0 asked for a circle. Deriving it\n"
            "        // from the size keeps this the only button implementation there is.\n"
            "        let aorusIsRound = abs(size.width - size.height) < 0.5\n",
            "round button flag",
        )
        text = _replace_once(
            text,
            "        self.textNode.attributedText = NSAttributedString(string: text.lowercased(), font: Font.regular(11.0), textColor: .white)\n",
            "        // The circle carries the meaning on its own; the caption is what makes the\n"
            "        // stock row tall. Accessibility still gets the label below.\n"
            "        self.textNode.attributedText = aorusIsRound ? nil : NSAttributedString(string: text.lowercased(), font: Font.regular(11.0), textColor: .white)\n",
            "round button caption",
        )
        text = _replace_once(
            text,
            "        transition.updateCornerRadius(layer: self.backgroundView.layer, cornerRadius: min(16.0, backgroundFrame.height * 0.5))\n",
            "        transition.updateCornerRadius(layer: self.backgroundView.layer, cornerRadius: aorusIsRound ? backgroundFrame.height * 0.5 : min(16.0, backgroundFrame.height * 0.5))\n",
            "round button radius",
        )
        # With no caption underneath, the icon belongs in the middle rather than pinned to
        # the top edge where the label used to leave room for it.
        text = _replace_once(
            text,
            "        transition.updateFrame(node: self.iconNode, frame: CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: 1.0), size: iconSize))\n",
            "        let aorusIconY: CGFloat = aorusIsRound ? floor((size.height - iconSize.height) / 2.0) : 1.0\n"
            "        transition.updateFrame(node: self.iconNode, frame: CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: aorusIconY), size: iconSize))\n",
            "round button icon",
        )
        text = _replace_once(
            text,
            "            transition.updateFrame(view: animatedIconView, frame: CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: 1.0), size: iconSize))\n",
            "            transition.updateFrame(view: animatedIconView, frame: CGRect(origin: CGPoint(x: floor((size.width - iconSize.width) / 2.0), y: aorusIsRound ? floor((size.height - iconSize.height) / 2.0) : 1.0), size: iconSize))\n",
            "round button animated icon",
        )
        button.write_text(text, encoding="utf-8")
        print("RoundButtons: patched button node")

    header = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    head = header.read_text(encoding="utf-8")
    if "aorusRoundButtons" in head:
        print("RoundButtons: header row already patched")
        return
    head = _replace_once(
        head,
        "        let buttonWidth = (width - buttonSideInset * 2.0 + buttonSpacing) / CGFloat(buttonKeys.count) - buttonSpacing\n"
        "        let buttonSize = CGSize(width: buttonWidth, height: 58.0)\n"
        "        var buttonRightOrigin = CGPoint(x: width - buttonSideInset, y: backgroundHeight - bottomInset - 16.0 - buttonSize.height)\n",
        "        // AorusGram: Interface 2.0 lays the row out as centred circles instead of\n"
        "        // rectangles stretched edge to edge.\n"
        "        let aorusRoundButtons = !buttonKeys.isEmpty && UserDefaults.standard.bool(forKey: \"aorusgram_interface_v2\")\n"
        "        // 64pt is the design's diameter and the cap, not the answer: a profile with five\n"
        "        // buttons -- message, call, mute, search, more -- needs 352pt of row on a screen\n"
        "        // that may only have 288pt of it, and the fixed diameter is what made those\n"
        "        // profiles overflow their own header. Shrunk to fit instead, down to a floor that\n"
        "        // still holds a 40pt icon and a tappable target.\n"
        "        let aorusButtonCount = CGFloat(max(1, buttonKeys.count))\n"
        "        let aorusRoundButtonFit = (width - buttonSideInset * 2.0 - (aorusButtonCount - 1.0) * buttonSpacing) / aorusButtonCount\n"
        "        let aorusRoundButtonDiameter: CGFloat = max(44.0, min(64.0, floor(aorusRoundButtonFit)))\n"
        "        let buttonWidth = aorusRoundButtons ? aorusRoundButtonDiameter : ((width - buttonSideInset * 2.0 + buttonSpacing) / CGFloat(buttonKeys.count) - buttonSpacing)\n"
        "        let buttonSize = CGSize(width: buttonWidth, height: aorusRoundButtons ? aorusRoundButtonDiameter : 58.0)\n"
        "        let aorusRowWidth = CGFloat(buttonKeys.count) * buttonSize.width + CGFloat(max(0, buttonKeys.count - 1)) * buttonSpacing\n"
        "        var buttonRightOrigin = CGPoint(x: aorusRoundButtons ? floor((width + aorusRowWidth) / 2.0) : width - buttonSideInset, y: backgroundHeight - bottomInset - 16.0 - buttonSize.height)\n",
        "round button row",
    )
    header.write_text(head, encoding="utf-8")
    print("RoundButtons: patched header row")


def _patch_music_capsule(tg: Path) -> None:
    """Give the saved-music row the glass capsule the design asks for.

    The stock row is a full-width strip of text. The design is a pill that hugs the track
    name and sits centred under the buttons. Both come from the same component: dropping
    its minimum width lets it size to its content, and a rounded backing view behind it
    supplies the capsule. The component itself, its marquee and its tap action are
    untouched, so the row still opens the same screen it always did.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    if not path.is_file():
        raise RuntimeError("MusicCapsule: PeerInfoHeaderNode.swift is missing")
    text = path.read_text(encoding="utf-8")
    if "aorusMusicCapsule" in text:
        print("MusicCapsule: already patched")
        return
    if "import GlassBackgroundComponent\n" not in text:
        text = _replace_once(
            text,
            "import UIKit\n",
            "import UIKit\nimport GlassBackgroundComponent\n",
            "music capsule glass import",
        )

    text = _replace_once(
        text,
        "    let aorusAnimatedProfileBackgroundView = AorusAnimatedProfileBackgroundView()\n",
        "    let aorusAnimatedProfileBackgroundView = AorusAnimatedProfileBackgroundView()\n"
        "    // A pane of the system glass material, not a translucent white pill: the capsule sits\n"
        "    // over the avatar, and a flat white fill there is the fake glass Interface 2.0 exists\n"
        "    // to get rid of.\n"
        "    let aorusMusicCapsule = GlassBackgroundView(frame: CGRect())\n",
        "music capsule property",
    )
    # Zero minimum width: the component then reports the width its content actually needs,
    # which is what the capsule is sized from.
    text = _replace_once(
        text,
        "                        minSize: CGSize(width: backgroundFrame.width, height: musicHeight),\n",
        "                        minSize: CGSize(width: aorusInterfaceV2Enabled ? 0.0 : backgroundFrame.width, height: musicHeight),\n",
        "music capsule min size",
    )
    text = _replace_once(
        text,
        "            let musicFrame = CGRect(origin: CGPoint(x: 0.0, y:",
        "            let aorusMusicX: CGFloat = aorusInterfaceV2Enabled ? floor((backgroundFrame.width - musicSize.width) / 2.0) : 0.0\n"
        "            let musicFrame = CGRect(origin: CGPoint(x: aorusMusicX, y:",
        "music capsule frame",
    )
    text = _replace_once(
        text,
        "                if musicView.superview == nil {\n"
        "                    self.regularContentNode.view.addSubview(musicView)\n",
        "                if aorusInterfaceV2Enabled {\n"
        "                    // Inserted below the row rather than behind it as a sublayer so it\n"
        "                    // travels with the same additive transitions the row already uses.\n"
        "                    if self.aorusMusicCapsule.superview == nil {\n"
        "                        self.aorusMusicCapsule.isUserInteractionEnabled = false\n"
        "                        self.regularContentNode.view.addSubview(self.aorusMusicCapsule)\n"
        "                    }\n"
        "                    // A small pill, per the mockup: the row inside it is 16pt of 11pt type,\n"
        "                    // and 3pt of padding is what turns that into a capsule rather than into\n"
        "                    // the 38pt banner the first version drew across the bottom of the header.\n"
        "                    let aorusCapsuleFrame = musicFrame.insetBy(dx: -12.0, dy: -3.0)\n"
        "                    // Additive when the row is additive, and never the plain path while the\n"
        "                    // row takes the additive one. That mismatch is what made the capsule\n"
        "                    // slide out from under its own text on every scroll frame -- the row's\n"
        "                    // frame was being animated from its centre while the pill jumped\n"
        "                    // straight to the new one.\n"
        "                    if additive {\n"
        "                        musicTransition.updateFrameAdditiveToCenter(view: self.aorusMusicCapsule, frame: aorusCapsuleFrame)\n"
        "                    } else {\n"
        "                        musicTransition.updateFrame(view: self.aorusMusicCapsule, frame: aorusCapsuleFrame)\n"
        "                    }\n"
        "                    self.aorusMusicCapsule.update(\n"
        "                        size: aorusCapsuleFrame.size,\n"
        "                        cornerRadius: aorusCapsuleFrame.height * 0.5,\n"
        "                        isDark: true,\n"
        "                        tintColor: GlassBackgroundView.TintColor(kind: .clear),\n"
        "                        isInteractive: false,\n"
        "                        isVisible: true,\n"
        "                        transition: .immediate\n"
        "                    )\n"
        "                    // The row's own alpha, to the point of using the same two branches and\n"
        "                    // the same curve. Pinned at 1.0 the glass stayed behind as a bare\n"
        "                    // lozenge once the header collapsed the text out from inside it, which\n"
        "                    // is the artefact that showed while scrolling.\n"
        "                    if let _ = self.navigationTransition {\n"
        "                        transition.updateAlpha(layer: self.aorusMusicCapsule.layer, alpha: 1.0 - transitionFraction)\n"
        "                    } else {\n"
        "                        ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut).updateAlpha(layer: self.aorusMusicCapsule.layer, alpha: backgroundBannerAlpha)\n"
        "                    }\n"
        "                } else if self.aorusMusicCapsule.superview != nil {\n"
        "                    self.aorusMusicCapsule.removeFromSuperview()\n"
        "                }\n"
        "                if musicView.superview == nil {\n"
        "                    self.regularContentNode.view.addSubview(musicView)\n",
        "music capsule view",
    )
    # One flag for the whole music block, read once where the block begins.
    text = _replace_once(
        text,
        "        if let currentSavedMusic {\n",
        "        let aorusInterfaceV2Enabled = UserDefaults.standard.bool(forKey: \"aorusgram_interface_v2\")\n"
        "        if let currentSavedMusic {\n",
        "music capsule flag",
    )
    # The peer stops sharing a track, or the header is reused for one that never did: the row is
    # torn down here and the capsule has to go with it, or the glass stays on screen with nothing
    # inside it.
    text = _replace_once(
        text,
        "        } else {\n"
        "            if let musicBackground = self.musicBackground {\n",
        "        } else {\n"
        "            if self.aorusMusicCapsule.superview != nil {\n"
        "                self.aorusMusicCapsule.removeFromSuperview()\n"
        "            }\n"
        "            if let musicBackground = self.musicBackground {\n",
        "music capsule teardown",
    )
    path.write_text(text, encoding="utf-8")
    print("MusicCapsule: patched PeerInfoHeaderNode")


def _patch_call_type_sheet(tg: Path) -> None:
    """Ask which kind of call the phone button should place.

    Interface 2.0 shows one phone button where the stock header shows separate Call and
    Video buttons, so the choice has to happen somewhere. It happens in the sheet iOS users
    already expect from a phone button, and both answers go back through Telegram's own
    button actions -- the call is placed by exactly the code that placed it before.

    Each answer carries the glyph its own header button carries, at the leading edge with the
    title beside it (see `_patch_action_sheet_icon_rows`), so the two rows are told apart before
    they are read. The pane behind them is the system material Interface 2.0 puts under every
    sheet in the client, which is why there is no background of our own here.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    if not path.is_file():
        raise RuntimeError("CallSheet: PeerInfoHeaderNode.swift is missing")
    text = path.read_text(encoding="utf-8")
    if "aorusPresentCallTypeSheet" in text:
        print("CallSheet: already patched")
        return
    text = _replace_once(
        text,
        "        self.performButtonAction?(buttonNode.key, buttonNode, gesture)\n",
        "        // AorusGram: a long press still opens Telegram's own context menu, so the\n"
        "        // sheet is only for a plain tap.\n"
        "        if buttonNode.key == .call, gesture == nil, self.videoCallsEnabled,\n"
        "           UserDefaults.standard.bool(forKey: \"aorusgram_interface_v2\"),\n"
        "           self.aorusPresentCallTypeSheet() {\n"
        "            return\n"
        "        }\n"
        "        self.performButtonAction?(buttonNode.key, buttonNode, gesture)\n",
        "call sheet interception",
    )
    text = _replace_once(
        text,
        "    func initiateAvatarExpansion(gallery: Bool, first: Bool) {\n",
        "    /// Returns false when the sheet cannot be shown, so the caller falls back to the\n"
        "    /// stock action rather than leaving a dead button.\n"
        "    private func aorusPresentCallTypeSheet() -> Bool {\n"
        "        guard let presentationData = self.presentationData, let controller = self.controller else {\n"
        "            return false\n"
        "        }\n"
        "        let sheet = ActionSheetController(presentationData: presentationData)\n"
        "        sheet.setItemGroups([\n"
        "            ActionSheetItemGroup(items: [\n"
        "                ActionSheetButtonItem(title: aorusL(\"Аудиозвонок\", \"Audio Call\"), color: .accent, aorusIcon: UIImage(bundleImageName: \"Peer Info/ButtonCall\"), action: { [weak self, weak sheet] in\n"
        "                    sheet?.dismissAnimated()\n"
        "                    self?.performButtonAction?(.call, nil, nil)\n"
        "                }),\n"
        "                ActionSheetButtonItem(title: aorusL(\"Видеозвонок\", \"Video Call\"), color: .accent, aorusIcon: UIImage(bundleImageName: \"Peer Info/ButtonVideo\"), action: { [weak self, weak sheet] in\n"
        "                    sheet?.dismissAnimated()\n"
        "                    self?.performButtonAction?(.videoCall, nil, nil)\n"
        "                })\n"
        "            ]),\n"
        "            ActionSheetItemGroup(items: [\n"
        "                ActionSheetButtonItem(title: aorusL(\"Отмена\", \"Cancel\"), color: .accent, font: .bold, action: { [weak sheet] in\n"
        "                    sheet?.dismissAnimated()\n"
        "                })\n"
        "            ])\n"
        "        ])\n"
        "        controller.present(sheet, in: .window(.root))\n"
        "        return true\n"
        "    }\n"
        "\n"
        "    func initiateAvatarExpansion(gallery: Bool, first: Bool) {\n",
        "call sheet method",
    )
    path.write_text(text, encoding="utf-8")
    print("CallSheet: patched PeerInfoHeaderNode")


def _patch_profile_tabs_tint(tg: Path) -> None:
    """Let the profile tab bar paint its labels white while Interface 2.0 is on.

    Telegram's tab bar is already the glass capsule Interface 2.0 wants, so it is kept and
    recoloured rather than replaced — substituting a simpler control would cost tab reordering,
    context menus, badges, gift icons and the dozen-odd pane kinds it knows how to title.
    Both the regular and the selected copy of a tab are rendered from the same ItemComponent
    with the same colour, the selection being drawn by a lens moving across them; this makes
    the selected copy able to take a different one.
    """
    path = tg / "submodules/TelegramUI/Components/HorizontalTabsComponent/Sources/HorizontalTabsComponent.swift"
    if not path.is_file():
        raise RuntimeError("GlassProfileTabs: HorizontalTabsComponent.swift is missing")
    text = path.read_text(encoding="utf-8")
    if "aorusSelectedAccent" in text:
        print("GlassProfileTabs: HorizontalTabsComponent already patched")
        return

    # Read from shared defaults rather than by importing AorusGramUI. ItemListUI depends on
    # this module and AorusGramUI depends back on ItemListUI, so a module edge here closes a
    # cycle in the build graph and nothing links at all. The key is pinned against
    # AorusGlassProfileTint.key on the writing side.
    text = _replace_once(
        text,
        "import MultilineTextWithEntitiesComponent\n",
        "import MultilineTextWithEntitiesComponent\n"
        "\n"
        "// AorusGram: the accent Interface 2.0 gives the selected profile tab, or nil for stock.\n"
        f"private let aorusProfileTabAccentKey = \"{_PROFILE_TAB_ACCENT_KEY}\"\n"
        "\n"
        "private func aorusProfileTabAccent() -> UIColor? {\n"
        "    guard let value = UserDefaults.standard.object(forKey: aorusProfileTabAccentKey) as? Int else {\n"
        "        return nil\n"
        "    }\n"
        "    return UIColor(\n"
        "        red: CGFloat((value >> 16) & 0xff) / 255.0,\n"
        "        green: CGFloat((value >> 8) & 0xff) / 255.0,\n"
        "        blue: CGFloat(value & 0xff) / 255.0,\n"
        "        alpha: 1.0\n"
        "    )\n"
        "}\n",
        "tabs accent reader",
    )
    # Captured at init rather than read at draw time so that the component compares unequal
    # when the tint changes — otherwise ComponentFlow would reuse the view and the tab would
    # keep the previous profile's colour.
    text = _replace_once(
        text,
        "    let isSelected: Bool\n",
        "    let isSelected: Bool\n    let aorusSelectedAccent: UIColor?\n",
        "tabs accent property",
    )
    text = _replace_once(
        text,
        "        self.isSelected = isSelected\n",
        "        self.isSelected = isSelected\n        self.aorusSelectedAccent = aorusProfileTabAccent()\n",
        "tabs accent assignment",
    )
    text = _replace_once(
        text,
        "        if lhs.isSelected != rhs.isSelected {\n            return false\n        }\n",
        "        if lhs.isSelected != rhs.isSelected {\n            return false\n        }\n"
        "        if lhs.aorusSelectedAccent != rhs.aorusSelectedAccent {\n            return false\n        }\n",
        "tabs accent equality",
    )
    text = _replace_once(
        text,
        "                    .foregroundColor: component.theme.chat.inputPanel.panelControlColor\n"
        "                ], range: NSRange(location: 0, length: titleString.length))\n",
        "                    // AorusGram: the page's own ink under Interface 2.0, and the stock\n"
        "                    // colour whenever it is off. Ink rather than the avatar's colour on\n"
        "                    // purpose: the glass under these labels takes its look from the photo\n"
        "                    // already, and tinting the text as well is what made the first version\n"
        "                    // read as a coloured skin instead of as glass. The writing side sends\n"
        "                    // white over a dark page and near-black over a pale one, so a profile\n"
        "                    // whose photo ends in white paper still has readable tabs.\n"
        "                    .foregroundColor: component.aorusSelectedAccent.flatMap { accent in\n"
        "                        return component.isSelected ? accent : accent.withAlphaComponent(0.5)\n"
        "                    } ?? component.theme.chat.inputPanel.panelControlColor\n"
        "                ], range: NSRange(location: 0, length: titleString.length))\n",
        "tabs accent colour",
    )
    path.write_text(text, encoding="utf-8")
    # No BUILD dependency is added on purpose — see the reader comment above.
    print("GlassProfileTabs: patched HorizontalTabsComponent")


def _patch_profile_list_glass(tg: Path) -> None:
    """Restyle the peer-info list itself, instead of laying panels over it.

    Interface 2.0 keeps every row the screen already draws — the username, More, Add to
    Contacts, Block — and changes what they are made of: panes of glass on a page tinted from
    the avatar rather than opaque blocks on a flat theme background. One anchor covers every
    section, because every section container paints itself from the same two theme colours.
    """
    section_path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenItemSectionContainerNode.swift"
    if not section_path.is_file():
        raise RuntimeError("GlassProfileList: PeerInfoScreenItemSectionContainerNode.swift is missing")
    text = section_path.read_text(encoding="utf-8")
    if "AorusGlassProfileTint.listSectionColors" in text:
        print("GlassProfileList: section container already patched")
    else:
        if "import AorusGramUI\n" not in text:
            text = _replace_once(text, "import UIKit\n", "import UIKit\nimport AorusGramUI\n", "list section import")
        # Appended after the stock assignments rather than replacing them, and anchored on a
        # single line. A multi-line anchor has to match three consecutive lines byte for byte,
        # which is exactly the kind of thing an earlier patch or a reformat quietly breaks —
        # and a broken anchor here aborts the whole build before anything compiles.
        anchor = "        self.bottomSeparatorNode.backgroundColor = presentationData.theme.list.itemBlocksSeparatorColor\n"
        text = _replace_once(
            text,
            anchor,
            anchor
            + "        // AorusGram: under Interface 2.0 a section is glass over the tinted page,\n"
            "        // so the rows Telegram already draws take on the profile's own colours.\n"
            "        if let aorusColors = AorusGlassProfileTint.listSectionColors {\n"
            "            self.backgroundNode.backgroundColor = aorusColors.background\n"
            "            self.topSeparatorNode.backgroundColor = aorusColors.separator\n"
            "            self.bottomSeparatorNode.backgroundColor = aorusColors.separator\n"
            "        }\n",
            "list section colours",
        )
        section_path.write_text(text, encoding="utf-8")
        print("GlassProfileList: patched section container")

    screen_path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift"
    if not screen_path.is_file():
        raise RuntimeError("GlassProfileList: PeerInfoScreen.swift is missing")
    screen = screen_path.read_text(encoding="utf-8")
    if "AorusGlassProfileTint.pageBackgroundColor" in screen:
        print("GlassProfileList: screen background already patched")
        return
    if "import AorusGramUI\n" not in screen:
        screen = _replace_once(screen, "import UIKit\n", "import UIKit\nimport AorusGramUI\n", "screen Aorus import")
    # Only the update path is patched, never the initial assignment: at init the avatar has
    # not loaded, so the only tint available would be the previous profile's, which would
    # flash the wrong colour before the right one arrives.
    screen = _replace_once(
        screen,
        "    private func updateBackgroundColor() {\n",
        "    // AorusGram: the avatar itself, mirrored, stretched behind the entire screen.\n"
        "    //\n"
        "    // Telegram's expanded avatar is taller than the square photo, and the strip below it is\n"
        "    // the picture mirrored -- a replicator layer drawing a flipped copy, blurred at the join\n"
        "    // under a gradient that reaches 0.32 black. This carries that mirror the rest of the way\n"
        "    // instead of inventing a second effect: the whole photo, flipped, darkened by the same\n"
        "    // amount and blurred with Telegram's own kernel, then stretched over the screen. Linear\n"
        "    // filtering does the rest, for the price of a texture of thirty-six kilobytes.\n"
        "    //\n"
        "    // Found by tag rather than held in a property: this file is patched, and a stored\n"
        "    // property means an initialiser to patch as well. It is inserted at the very back, so\n"
        "    // the header, the list, the tabs and the panes all keep drawing over it. The tag is the\n"
        "    // tint's own, because the members pane looks this very view up to lay its own copy of\n"
        "    // the picture over exactly the same rectangle -- one rectangle drawn twice is the only\n"
        "    // arrangement with no seam in it, and two spellings of a tag is a seam waiting to be.\n"
        "    //\n"
        "    // The frame is reassigned on every call, not left to the autoresizing mask alone: this\n"
        "    // runs from containerLayoutUpdated, and the first call can land while the node still has\n"
        "    // empty bounds, where a proportional mask keeps a zero-sized view zero-sized forever.\n"
        "    private func aorusUpdatePageBackdrop(image: UIImage?) {\n"
        "        let aorusBackdropTag = AorusGlassProfileTint.backdropTag\n"
        "        var backdrop = self.view.subviews.first(where: { $0.tag == aorusBackdropTag }) as? UIImageView\n"
        "        guard let image else {\n"
        "            backdrop?.removeFromSuperview()\n"
        "            return\n"
        "        }\n"
        "        if backdrop == nil {\n"
        "            let imageView = UIImageView()\n"
        "            imageView.tag = aorusBackdropTag\n"
        "            imageView.isUserInteractionEnabled = false\n"
        "            imageView.contentMode = .scaleToFill\n"
        "            imageView.layer.magnificationFilter = .linear\n"
        "            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]\n"
        "            self.view.insertSubview(imageView, at: 0)\n"
        "            backdrop = imageView\n"
        "        }\n"
        "        if let backdrop, backdrop.frame != self.view.bounds {\n"
        "            backdrop.frame = self.view.bounds\n"
        "        }\n"
        "        if backdrop?.image !== image {\n"
        "            backdrop?.image = image\n"
        "        }\n"
        "    }\n"
        "\n"
        "    // AorusGram: claim the page slot for this profile, and answer with its own page colour.\n"
        "    //\n"
        "    // Everything drawn over a glass profile -- the header's labels and icons, the tab strip,\n"
        "    // the separators inside a section -- takes its ink from one shared slot, because the\n"
        "    // modules that need it sit below the one that samples the avatar and cannot import it.\n"
        "    // One slot, and the colour is per peer, so the profile being laid out claims it at the\n"
        "    // top of every pass. That is what makes a push between two profiles land on the right\n"
        "    // ink instead of the two overwriting each other frame by frame.\n"
        "    //\n"
        "    // A peer with no photo publishes the page it actually gets: the theme's own background.\n"
        "    // Its placeholder is a pane of glass, which has no colour to sample, so nothing is ever\n"
        "    // stored for it -- and leaving the previous profile's pale colour in the slot is exactly\n"
        "    // how a profile came out with near-black text and icons on a near-black page.\n"
        "    //\n"
        "    // Settings publishes too, and publishes the theme's background. It is not painted in an\n"
        "    // avatar's colour -- it is the reader's own list of options, not a profile -- but the slot\n"
        "    // is global, and a screen that stays silent is drawn in whatever the last profile left\n"
        "    // there. That is the whole of the report about Settings: rows in white text and rows in\n"
        "    // black text on one screen, differing by which profile had been opened before it, because\n"
        "    // its sections read the profile ink while everything else read the theme's.\n"
        "    @discardableResult\n"
        "    private func aorusUpdatePageColor() -> UIColor? {\n"
        "        guard AorusInterfaceV2.isEnabled else {\n"
        "            return nil\n"
        "        }\n"
        "        guard !self.isSettings else {\n"
        "            AorusGlassProfileTint.publishPageColor(self.presentationData.theme.list.blocksBackgroundColor)\n"
        "            return nil\n"
        "        }\n"
        "        let aorusPageColor = AorusGlassProfileTint.pageBackgroundColor(for: self.peerId.id._internalGetInt64Value())\n"
        "        AorusGlassProfileTint.publishPageColor(aorusPageColor ?? self.presentationData.theme.list.blocksBackgroundColor)\n"
        "        return aorusPageColor\n"
        "    }\n"
        "\n"
        "    private func updateBackgroundColor() {\n"
        "        // AorusGram: the page carries the avatar's colours the whole way down, so the\n"
        "        // list below the header continues the profile instead of meeting a flat\n"
        "        // background partway through it. Asked for by peer id, not read from one shared\n"
        "        // slot: during a push two profiles lay out on every frame of the animation, and a\n"
        "        // single slot would let each overwrite the other's colour.\n"
        "        if let aorusPageColor = self.aorusUpdatePageColor() {\n"
        "            self.backgroundColor = aorusPageColor\n"
        "            self.aorusUpdatePageBackdrop(image: AorusGlassProfileTint.pageBackgroundImage(for: self.peerId.id._internalGetInt64Value()))\n"
        "            return\n"
        "        }\n"
        "        self.aorusUpdatePageBackdrop(image: nil)\n",
        "screen background colour",
    )
    # The slot has to be claimed before the header reads it, and the header lays out ahead of
    # updateBackgroundColor in both passes that reach it -- containerLayoutUpdated draws the header
    # and never calls it, updateNavigation draws the header and then calls it. Published from the top
    # of both, so the ink a profile is drawn with is its own on the very first frame rather than one
    # frame behind, which on a push is the outgoing profile's.
    screen = _replace_once(
        screen,
        "    func containerLayoutUpdated(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition, additive: Bool = false) {\n"
        "        self.validLayout = (layout, navigationHeight)\n",
        "    func containerLayoutUpdated(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition, additive: Bool = false) {\n"
        "        self.validLayout = (layout, navigationHeight)\n"
        "        \n"
        "        // AorusGram: before anything on this screen is drawn, so it is drawn in this\n"
        "        // profile's ink and not in whatever the last one left in the slot.\n"
        "        self.aorusUpdatePageColor()\n",
        "page ink before layout",
    )
    screen = _replace_once(
        screen,
        "    fileprivate func updateNavigation(transition: ContainedViewLayoutTransition, additive: Bool, animateHeader: Bool) {\n"
        "        let offsetY = self.scrollNode.view.contentOffset.y\n",
        "    fileprivate func updateNavigation(transition: ContainedViewLayoutTransition, additive: Bool, animateHeader: Bool) {\n"
        "        // AorusGram: as in containerLayoutUpdated -- this pass redraws the header too, and\n"
        "        // does it before updateBackgroundColor at the end of it.\n"
        "        self.aorusUpdatePageColor()\n"
        "        \n"
        "        let offsetY = self.scrollNode.view.contentOffset.y\n",
        "page ink before navigation",
    )
    screen_path.write_text(screen, encoding="utf-8")
    print("GlassProfileList: patched screen background")


def _patch_avatar_renderer(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: avatar renderer is missing")
    text = path.read_text(encoding="utf-8")
    if "// AorusGram: square avatar story ring" in text:
        print("ProfilePersonalization: avatar renderer already patched")
        return

    text = _replace_once(
        text,
        "        self.avatarNode.setStoryStats(storyStats: storyStats, presentationParams: AvatarNode.StoryPresentationParams(\n"
        "            colors: colors,\n"
        "            lineWidth: 3.0,\n"
        "            inactiveLineWidth: 1.5,\n"
        "            forceRoundedRect: isForum\n",
        "        // AorusGram: square avatar story ring\n"
        f"        let aorusSquareAvatars = !UserDefaults.standard.bool(forKey: \"{LICENSE_LOCK_KEY}\") && UserDefaults.standard.bool(forKey: \"aorusgram_square_avatars\")\n"
        "        self.avatarNode.setStoryStats(storyStats: storyStats, presentationParams: AvatarNode.StoryPresentationParams(\n"
        "            colors: colors,\n"
        "            lineWidth: 3.0,\n"
        "            inactiveLineWidth: 1.5,\n"
        "            forceRoundedRect: isForum || aorusSquareAvatars\n",
        "avatar story ring",
    )
    text = _replace_once(
        text,
        "            var isForum = false\n"
        "            let avatarCornerRadius: CGFloat\n"
        "            if case let .channel(channel) = peer, channel.isForumOrMonoForum {\n"
        "                avatarCornerRadius = floor(avatarSize * 0.25)\n"
        "                isForum = true\n"
        "            } else {\n"
        "                avatarCornerRadius = avatarSize / 2.0\n"
        "            }\n",
        "            var isForum = false\n"
        "            if case let .channel(channel) = peer, channel.isForumOrMonoForum {\n"
        "                isForum = true\n"
        "            }\n"
        f"            let aorusSquareAvatars = !UserDefaults.standard.bool(forKey: \"{LICENSE_LOCK_KEY}\") && UserDefaults.standard.bool(forKey: \"aorusgram_square_avatars\")\n"
        "            let avatarCornerRadius: CGFloat = (isForum || aorusSquareAvatars) ? floor(avatarSize * 0.25) : avatarSize / 2.0\n",
        "avatar renderer radius",
    )
    text = _replace_once(
        text,
        "                            if isForum {\n"
        "                                maskPath = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: self.avatarNode.frame.size), cornerRadius: avatarCornerRadius)\n",
        "                            if isForum || aorusSquareAvatars {\n"
        "                                maskPath = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: self.avatarNode.frame.size), cornerRadius: avatarCornerRadius)\n",
        "avatar video mask",
    )
    path.write_text(text, encoding="utf-8")
    print("ProfilePersonalization: patched avatar renderer")


def _patch_editing_avatar(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoEditingAvatarNode.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: editing avatar renderer is missing")
    text = path.read_text(encoding="utf-8")
    if "// AorusGram: square avatar while editing" not in text:
        text = _replace_once(
            text,
            "        var isForum = false\n"
            "        let avatarCornerRadius: CGFloat\n"
            "        if case let .channel(channel) = peer, channel.isForumOrMonoForum {\n"
            "            isForum = true\n"
            "            avatarCornerRadius = floor(avatarSize * 0.25)\n"
            "        } else {\n"
            "            avatarCornerRadius = avatarSize / 2.0\n"
            "        }\n",
            "        var isForum = false\n"
            "        if case let .channel(channel) = peer, channel.isForumOrMonoForum {\n"
            "            isForum = true\n"
            "        }\n"
            "        // AorusGram: square avatar while editing\n"
            f"        let aorusSquareAvatars = !UserDefaults.standard.bool(forKey: \"{LICENSE_LOCK_KEY}\") && UserDefaults.standard.bool(forKey: \"aorusgram_square_avatars\")\n"
            "        let avatarCornerRadius: CGFloat = (isForum || aorusSquareAvatars) ? floor(avatarSize * 0.25) : avatarSize / 2.0\n",
            "editing avatar radius",
        )
        text = _replace_once(
            text,
            "                    if isForum {\n"
            "                        maskPath = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: self.avatarNode.frame.size), cornerRadius: avatarCornerRadius)\n",
            "                    if isForum || aorusSquareAvatars {\n"
            "                        maskPath = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: self.avatarNode.frame.size), cornerRadius: avatarCornerRadius)\n",
            "editing avatar video mask",
        )
        path.write_text(text, encoding="utf-8")
        print("ProfilePersonalization: patched editing avatar renderer")
    else:
        print("ProfilePersonalization: editing avatar renderer already patched")

    overlay_path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoEditingAvatarOverlayNode.swift"
    if not overlay_path.is_file():
        raise RuntimeError("ProfilePersonalization: editing avatar overlay is missing")
    overlay = overlay_path.read_text(encoding="utf-8")
    if "// AorusGram: square editing overlay" in overlay:
        print("ProfilePersonalization: editing avatar overlay already patched")
        return
    overlay = _replace_once(
        overlay,
        "        let clipStyle: AvatarNodeClipStyle\n"
        "        if case let .channel(channel) = peer, channel.isForumOrMonoForum {\n"
        "            clipStyle = .roundedRect\n"
        "        } else {\n"
        "            clipStyle = .round\n"
        "        }\n",
        "        // AorusGram: square editing overlay\n"
        f"        let aorusSquareAvatars = !UserDefaults.standard.bool(forKey: \"{LICENSE_LOCK_KEY}\") && UserDefaults.standard.bool(forKey: \"aorusgram_square_avatars\")\n"
        "        let clipStyle: AvatarNodeClipStyle\n"
        "        if case let .channel(channel) = peer, channel.isForumOrMonoForum {\n"
        "            clipStyle = .roundedRect\n"
        "        } else {\n"
        "            clipStyle = aorusSquareAvatars ? .roundedRect : .round\n"
        "        }\n",
        "editing avatar overlay clip",
    )
    overlay_path.write_text(overlay, encoding="utf-8")
    print("ProfilePersonalization: patched editing avatar overlay")


def _patch_profile_preview(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/Settings/PeerNameColorScreen/Sources/PeerNameColorProfilePreviewItem.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: profile preview is missing")
    text = path.read_text(encoding="utf-8")
    if "// AorusGram: animated background in profile preview" in text:
        print("ProfilePersonalization: profile preview already patched")
        return

    if "import AorusGramUI\n" not in text:
        text = _replace_once(text, "import UIKit\n", "import UIKit\nimport AorusGramUI\n", "profile preview import")
    text = _replace_once(
        text,
        "    private let background = ComponentView<Empty>()\n",
        "    private let background = ComponentView<Empty>()\n"
        "    private let aorusAnimatedBackground = AorusAnimatedProfileBackgroundView()\n",
        "profile preview background property",
    )
    text = _replace_once(
        text,
        "                    backgroundView.frame = coverFrame\n"
        "                }\n"
        "                \n"
        "                let clipStyle: AvatarNodeClipStyle\n",
        "                    backgroundView.frame = coverFrame\n"
        "\n"
        "                    // AorusGram: animated background in profile preview\n"
        "                    let aorusAccountId = item.context.account.peerId.id._internalGetInt64Value()\n"
        "                    self.aorusAnimatedBackground.configure(\n"
        "                        viewerAccountId: aorusAccountId,\n"
        "                        targetId: aorusAccountId,\n"
        "                        visible: item.peer?.id == item.context.account.peerId\n"
        "                    )\n"
        "                    self.view.insertSubview(self.aorusAnimatedBackground, aboveSubview: backgroundView)\n"
        "                    self.aorusAnimatedBackground.frame = coverFrame\n"
        "                }\n"
        "                \n"
        "                let clipStyle: AvatarNodeClipStyle\n",
        "profile preview background frame",
    )
    text = _replace_once(
        text,
        "                default:\n"
        "                    clipStyle = .round\n"
        "                }\n"
        "                self.avatarNode.setPeer(\n",
        "                default:\n"
        f"                    let aorusSquareAvatars = !UserDefaults.standard.bool(forKey: \"{LICENSE_LOCK_KEY}\") && UserDefaults.standard.bool(forKey: \"aorusgram_square_avatars\")\n"
        "                    clipStyle = aorusSquareAvatars ? .roundedRect : .round\n"
        "                }\n"
        "                self.avatarNode.setPeer(\n",
        "profile preview avatar clip",
    )
    path.write_text(text, encoding="utf-8")
    print("ProfilePersonalization: patched profile preview")


def _patch_personal_colors(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/Settings/PeerNameColorScreen/Sources/UserApperanceScreen.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: UserApperanceScreen.swift is missing")
    text = path.read_text(encoding="utf-8")
    if "// AorusGram: animated profile background controls" in text:
        print("ProfilePersonalization: Personal Colors controls already patched")
        return

    if "import AorusGramUI\n" not in text:
        text = _replace_once(text, "import UIKit\n", "import UIKit\nimport AorusGramUI\n", "Personal Colors Aorus import")
    if "import ListSwitchItemComponent\n" not in text:
        text = _replace_once(
            text,
            "import ListActionItemComponent\n",
            "import ListActionItemComponent\nimport ListSwitchItemComponent\n",
            "Personal Colors switch import",
        )

    controls = '''                // AorusGram: animated profile background controls
                let aorusProfileAccountId = component.context.account.peerId.id._internalGetInt64Value()
                let aorusL10n = AorusL10n(environment.strings.baseLanguageCode)
                let aorusAnimatedBackgroundEnabled = AorusAnimatedProfileBackgroundStore.isEnabled(accountId: aorusProfileAccountId)
                let aorusAnimatedBackgroundHasMedia = AorusAnimatedProfileBackgroundStore.hasMedia(accountId: aorusProfileAccountId)
                var aorusAnimatedProfileItems: [AnyComponentWithIdentity<Empty>] = [
                    AnyComponentWithIdentity(id: 100, component: AnyComponent(ListSwitchItemComponent(
                        theme: environment.theme,
                        title: aorusL10n.animatedProfileBackground,
                        value: aorusAnimatedBackgroundEnabled,
                        valueUpdated: { [weak self] value in
                            AorusAnimatedProfileBackgroundStore.setEnabled(value, accountId: aorusProfileAccountId) { [weak self] result in
                                self?.state?.updated(transition: .spring(duration: 0.4))
                                if case let .failure(error) = result,
                                   let controller = self?.environment?.controller() {
                                    AorusAnimatedProfileBackgroundFeedback.presentOperationError(
                                        from: controller,
                                        languageCode: environment.strings.baseLanguageCode,
                                        error: error
                                    )
                                }
                            }
                        },
                        tag: aorusAnimatedBackgroundTag
                    )))
                ]
                if aorusAnimatedBackgroundEnabled {
                    aorusAnimatedProfileItems.append(AnyComponentWithIdentity(id: 101, component: AnyComponent(ListActionItemComponent(
                        theme: environment.theme,
                        style: .glass,
                        title: AnyComponent(MultilineTextComponent(
                            text: .plain(NSAttributedString(
                                string: aorusL10n.chooseAnimatedProfileMedia,
                                font: Font.regular(presentationData.listsFontSize.baseDisplaySize),
                                textColor: environment.theme.list.itemAccentColor
                            )),
                            maximumNumberOfLines: 1
                        )),
                        icon: nil,
                        accessory: nil,
                        action: { [weak self] _ in
                            guard let self, let controller = self.environment?.controller() else { return }
                            AorusAnimatedProfileBackgroundPicker.present(
                                from: controller,
                                accountId: aorusProfileAccountId,
                                languageCode: environment.strings.baseLanguageCode,
                                completion: { [weak self] success in
                                    if success {
                                        self?.state?.updated(transition: .spring(duration: 0.4))
                                    }
                                }
                            )
                        }
                    ))))
                    if aorusAnimatedBackgroundHasMedia {
                        aorusAnimatedProfileItems.append(AnyComponentWithIdentity(id: 102, component: AnyComponent(AorusAnimatedProfileOpacityComponent(
                            theme: environment.theme,
                            title: aorusL10n.animatedProfileTransparency,
                            transparency: AorusAnimatedProfileBackgroundStore.transparency(accountId: aorusProfileAccountId),
                            valueUpdated: { [weak self] value, persist in
                                AorusAnimatedProfileBackgroundStore.setTransparency(value, accountId: aorusProfileAccountId, persist: persist)
                                if persist {
                                    self?.state?.updated(transition: .immediate)
                                }
                            }
                        ))))
                    }
                }

'''
    text = _replace_once(
        text,
        "                let profileColorSectionSize = self.profileColorSection.update(\n",
        controls + "                let profileColorSectionSize = self.profileColorSection.update(\n",
        "Personal Colors control insertion",
    )
    text = _replace_once(
        text,
        "                            )))\n"
        "                        ],\n"
        "                        displaySeparators: true,\n"
        "                        extendsItemHighlightToSection: false\n",
        "                            )))\n"
        "                        ] + aorusAnimatedProfileItems,\n"
        "                        displaySeparators: true,\n"
        "                        extendsItemHighlightToSection: false\n",
        "Personal Colors profile item list",
    )

    reset_controls = '''                var displayResetProfileColor = resolvedState.profileColor != nil || resolvedState.backgroundFileId != nil
                if case .starGift = resolvedState.emojiStatus?.content {
                    displayResetProfileColor = true
                }
                let aorusCanResetAnimatedBackground = aorusAnimatedBackgroundEnabled && aorusAnimatedBackgroundHasMedia
                let aorusDisplayResetProfileSection = displayResetProfileColor || aorusCanResetAnimatedBackground
                var aorusAnimatedResetItems: [AnyComponentWithIdentity<Empty>] = []
                if aorusCanResetAnimatedBackground {
                    aorusAnimatedResetItems.append(AnyComponentWithIdentity(id: 100, component: AnyComponent(ListActionItemComponent(
                        theme: environment.theme,
                        style: .glass,
                        title: AnyComponent(MultilineTextComponent(
                            text: .plain(NSAttributedString(
                                string: aorusL10n.resetAnimatedProfileBackground,
                                font: Font.regular(presentationData.listsFontSize.baseDisplaySize),
                                textColor: environment.theme.list.itemAccentColor
                            )),
                            maximumNumberOfLines: 1
                        )),
                        icon: nil,
                        accessory: nil,
                        action: { [weak self] _ in
                            AorusAnimatedProfileBackgroundStore.reset(accountId: aorusProfileAccountId) { [weak self] result in
                                self?.state?.updated(transition: .spring(duration: 0.4))
                                if case let .failure(error) = result,
                                   let controller = self?.environment?.controller() {
                                    AorusAnimatedProfileBackgroundFeedback.presentOperationError(
                                        from: controller,
                                        languageCode: environment.strings.baseLanguageCode,
                                        error: error
                                    )
                                }
                            }
                        }
                    ))))
                }

'''
    text = _replace_once(
        text,
        "                let profileResetColorSectionSize = self.profileResetColorSection.update(\n",
        reset_controls + "                let profileResetColorSectionSize = self.profileResetColorSection.update(\n",
        "Personal Colors reset insertion",
    )
    text = _replace_once(
        text,
        "                        items: [\n"
        "                            AnyComponentWithIdentity(id: 0, component: AnyComponent(ListActionItemComponent(\n",
        "                        items: (displayResetProfileColor ? [\n"
        "                            AnyComponentWithIdentity(id: 0, component: AnyComponent(ListActionItemComponent(\n",
        "Personal Colors reset item opening",
    )
    text = _replace_once(
        text,
        "                            )))\n"
        "                        ],\n"
        "                        displaySeparators: false,\n"
        "                        extendsItemHighlightToSection: true\n",
        "                            )))\n"
        "                        ] : []) + aorusAnimatedResetItems,\n"
        "                        displaySeparators: true,\n"
        "                        extendsItemHighlightToSection: true\n",
        "Personal Colors reset item closing",
    )
    text = _replace_once(
        text,
        "                var displayResetProfileColor = resolvedState.profileColor != nil || resolvedState.backgroundFileId != nil\n"
        "                if case .starGift = resolvedState.emojiStatus?.content {\n"
        "                    displayResetProfileColor = true\n"
        "                }\n"
        "                \n",
        "",
        "Personal Colors old reset visibility",
    )
    text = _replace_once(
        text,
        "scale: displayResetProfileColor ? 1.0 : 0.001",
        "scale: aorusDisplayResetProfileSection ? 1.0 : 0.001",
        "Personal Colors reset scale",
    )
    text = _replace_once(
        text,
        "alpha: displayResetProfileColor ? 1.0 : 0.0",
        "alpha: aorusDisplayResetProfileSection ? 1.0 : 0.0",
        "Personal Colors reset alpha",
    )
    text = _replace_once(
        text,
        "                if displayResetProfileColor {\n",
        "                if aorusDisplayResetProfileSection {\n",
        "Personal Colors reset height",
    )
    path.write_text(text, encoding="utf-8")
    print("ProfilePersonalization: patched Personal Colors controls")


def _patch_personal_colors_shortcut(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/Settings/PeerNameColorScreen/Sources/UserApperanceScreen.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: UserApperanceScreen.swift is missing")
    text = path.read_text(encoding="utf-8")
    marker = "// AorusGram: animated banner shortcut focus"
    if marker in text:
        print("ProfilePersonalization: animated banner shortcut already patched")
        return

    text = _replace_once(
        text,
        "private let useGiftTag = GenericComponentViewTag()\n",
        "private let useGiftTag = GenericComponentViewTag()\n"
        "private let aorusAnimatedBackgroundTag = GenericComponentViewTag()\n",
        "animated banner component tag",
    )
    text = _replace_once(
        text,
        "public enum UserAppearanceEntryTag {\n    case profile\n",
        "public enum UserAppearanceEntryTag {\n    case profile\n    case aorusAnimatedBackground\n",
        "animated banner focus tag",
    )
    text = _replace_once(
        text,
        "        private var isUpdating: Bool = false\n",
        "        private var isUpdating: Bool = false\n"
        "        private var didFocusAorusAnimatedBackground = false\n",
        "animated banner focus state",
    )
    text = _replace_once(
        text,
        "        case .profile, .profileAddIcons, .profileUseGift, nil:\n",
        "        case .profile, .profileAddIcons, .profileUseGift, .aorusAnimatedBackground, nil:\n",
        "animated banner initial section",
    )
    frame_anchor = (
        "                if let profileColorSectionView = self.profileColorSection.view {\n"
        "                    if profileColorSectionView.superview == nil {\n"
        "                        self.scrollView.addSubview(profileColorSectionView)\n"
        "                    }\n"
        "                    transition.setFrame(view: profileColorSectionView, frame: profileColorSectionFrame)\n"
        "                }\n"
    )
    focus_code = frame_anchor + (
        "                // AorusGram: animated banner shortcut focus\n"
        "                if !self.didFocusAorusAnimatedBackground,\n"
        "                   let controller = environment.controller() as? UserAppearanceScreen,\n"
        "                   case .aorusAnimatedBackground? = controller.focusOnItemTag,\n"
        "                   let targetView = self.profileColorSection.findTaggedView(tag: aorusAnimatedBackgroundTag),\n"
        "                   AorusSettingsShortcutHighlight.consume(.animatedBanner) {\n"
        "                    self.didFocusAorusAnimatedBackground = true\n"
        "                    Queue.mainQueue().after(0.1) { [weak self, weak targetView] in\n"
        "                        guard let self, let targetView else { return }\n"
        "                        let targetFrame = targetView.convert(targetView.bounds, to: self.scrollView)\n"
        "                        let maxOffset = max(0.0, self.scrollView.contentSize.height - self.scrollView.bounds.height)\n"
        "                        let targetOffset = min(maxOffset, max(0.0, targetFrame.midY - self.scrollView.bounds.height * 0.42))\n"
        "                        self.scrollView.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: true)\n"
        "                        Queue.mainQueue().after(0.35) { [weak targetView] in\n"
        "                            guard let targetView else { return }\n"
        "                            AorusSettingsShortcutHighlight.pulseRow(containing: targetView, color: environment.theme.list.itemAccentColor)\n"
        "                        }\n"
        "                    }\n"
        "                }\n"
    )
    text = _replace_once(text, frame_anchor, focus_code, "animated banner focus layout")
    path.write_text(text, encoding="utf-8")
    print("ProfilePersonalization: patched animated banner shortcut focus")


def _patch_list_switch_tag_support(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/ListSwitchItemComponent/Sources/ListSwitchItemComponent.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: ListSwitchItemComponent.swift is missing")
    text = path.read_text(encoding="utf-8")
    marker = "// AorusGram: component tag support"
    if marker in text:
        print("ProfilePersonalization: ListSwitch tag support already patched")
        return

    text = _replace_once(
        text,
        "    let valueUpdated: (Bool) -> Void\n",
        "    let valueUpdated: (Bool) -> Void\n"
        "    // AorusGram: component tag support\n"
        "    let tag: AnyObject?\n",
        "ListSwitch tag property",
    )
    text = _replace_once(
        text,
        "        value: Bool,\n        valueUpdated: @escaping (Bool) -> Void\n",
        "        value: Bool,\n        valueUpdated: @escaping (Bool) -> Void,\n        tag: AnyObject? = nil\n",
        "ListSwitch tag initializer parameter",
    )
    text = _replace_once(
        text,
        "        self.valueUpdated = valueUpdated\n",
        "        self.valueUpdated = valueUpdated\n        self.tag = tag\n",
        "ListSwitch tag assignment",
    )
    text = _replace_once(
        text,
        "        if lhs.value != rhs.value {\n            return false\n        }\n        return true\n",
        "        if lhs.value != rhs.value {\n            return false\n        }\n"
        "        if lhs.tag !== rhs.tag {\n            return false\n        }\n"
        "        return true\n",
        "ListSwitch tag equality",
    )
    text = _replace_once(
        text,
        "    public final class View: UIView {\n",
        "    public final class View: UIView, ComponentTaggedView {\n"
        "        public func matches(tag: Any) -> Bool {\n"
        "            guard let componentTag = self.component?.tag else { return false }\n"
        "            return componentTag === (tag as AnyObject)\n"
        "        }\n\n",
        "ListSwitch tagged view",
    )
    path.write_text(text, encoding="utf-8")
    print("ProfilePersonalization: patched ListSwitch tag support")


def _patch_settings_shortcut_routes(tg: Path) -> None:
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenSettingsActions.swift"
    if not path.is_file():
        raise RuntimeError("ProfilePersonalization: PeerInfoScreenSettingsActions.swift is missing")
    text = path.read_text(encoding="utf-8")

    for module in ("PeerNameColorScreen", "WallpaperGridScreen"):
        import_line = f"import {module}\n"
        if import_line not in text:
            anchor = "import AorusGramUI\n"
            if anchor not in text:
                raise RuntimeError("ProfilePersonalization: AorusGramUI import is missing from settings actions")
            text = text.replace(anchor, anchor + import_line, 1)

    marker = "shortcutRoutes: AorusSettingsShortcutRoutes("
    if marker not in text:
        old_case = (
            "        case .aorusGram:\n"
            "            push(aorusGramController(context: self.context))\n"
        )
        new_case = (
            "        case .aorusGram:\n"
            "            let context = self.context\n"
            "            let updatedPresentationData = self.controller?.updatedPresentationData\n"
            "            push(aorusGramController(\n"
            "                context: context,\n"
            "                shortcutRoutes: AorusSettingsShortcutRoutes(\n"
            "                    animatedWallpapers: {\n"
            "                        return ThemeGridController(context: context)\n"
            "                    },\n"
            "                    animatedBanner: {\n"
            "                        return UserAppearanceScreen(\n"
            "                            context: context,\n"
            "                            updatedPresentationData: updatedPresentationData,\n"
            "                            focusOnItemTag: .aorusAnimatedBackground\n"
            "                        )\n"
            "                    },\n"
            "                    connectionSettings: {\n"
            "                        return proxySettingsController(context: context)\n"
            "                    }\n"
            "                )\n"
            "            ))\n"
        )
        if old_case not in text:
            raise RuntimeError("ProfilePersonalization: AorusGram settings route anchor is missing")
        text = text.replace(old_case, new_case, 1)
        print("ProfilePersonalization: patched appearance shortcut routes")
    else:
        print("ProfilePersonalization: appearance shortcut routes already patched")

    path.write_text(text, encoding="utf-8")


def _patch_build(tg: Path) -> None:
    personal_colors_build = tg / "submodules/TelegramUI/Components/Settings/PeerNameColorScreen/BUILD"
    if not personal_colors_build.is_file():
        raise RuntimeError("ProfilePersonalization: PeerNameColorScreen BUILD is missing")
    text = personal_colors_build.read_text(encoding="utf-8")
    deps = [
        ("//submodules/AorusGramUI", "//submodules/AorusGramUI"),
        (
            "//submodules/TelegramUI/Components/ListSwitchItemComponent",
            "//submodules/TelegramUI/Components/ListSwitchItemComponent",
        ),
    ]
    missing = [label for marker, label in deps if marker not in text]
    if missing:
        anchor = "    deps = [\n"
        if anchor not in text:
            raise RuntimeError("ProfilePersonalization: PeerNameColorScreen BUILD deps anchor is missing")
        insertion = "".join(f'        "{dep}",\n' for dep in missing)
        personal_colors_build.write_text(text.replace(anchor, anchor + insertion, 1), encoding="utf-8")
        print("ProfilePersonalization: added PeerNameColorScreen dependencies")
    else:
        print("ProfilePersonalization: PeerNameColorScreen dependencies already present")

    peer_info_build = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/BUILD"
    if not peer_info_build.is_file():
        raise RuntimeError("ProfilePersonalization: PeerInfoScreen BUILD is missing")
    peer_info_text = peer_info_build.read_text(encoding="utf-8")
    peer_info_deps = [
        "//submodules/AorusGramUI",
        "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen",
        "//submodules/TelegramUI/Components/Settings/WallpaperGridScreen",
    ]
    missing_peer_info_deps = [dep for dep in peer_info_deps if f'"{dep}"' not in peer_info_text]
    if missing_peer_info_deps:
        anchor = "    deps = [\n"
        if anchor not in peer_info_text:
            raise RuntimeError("ProfilePersonalization: PeerInfoScreen BUILD deps anchor is missing")
        insertion = "".join(f'        "{dep}",\n' for dep in missing_peer_info_deps)
        peer_info_build.write_text(
            peer_info_text.replace(anchor, anchor + insertion, 1),
            encoding="utf-8",
        )
        print("ProfilePersonalization: added PeerInfoScreen dependencies")
    else:
        print("ProfilePersonalization: PeerInfoScreen dependencies already present")


def patch_profile_personalization(tg: Path) -> None:
    _patch_profile_header(tg)
    _patch_expanded_avatar_default(tg)
    _patch_round_action_buttons(tg)
    _patch_music_capsule(tg)
    _patch_call_type_sheet(tg)
    _patch_profile_tabs_tint(tg)
    _patch_profile_list_glass(tg)
    _patch_avatar_renderer(tg)
    _patch_editing_avatar(tg)
    _patch_profile_preview(tg)
    _patch_list_switch_tag_support(tg)
    _patch_personal_colors(tg)
    _patch_personal_colors_shortcut(tg)
    _patch_settings_shortcut_routes(tg)
    _patch_build(tg)
