#!/usr/bin/env python3
"""Post-branding checks for CI (telegram-ios tree after aorus_branding + icon fill + PlistBuddy)."""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


def main() -> None:
    tg = Path(sys.argv[1]).resolve()
    err: list[str] = []

    here = Path(__file__).resolve().parent
    branding_source = (here / "aorus_branding.py").read_text(encoding="utf-8")
    for marker in (
        "patch_tgcalls_v2_set_proxy(tg)",
        "patch_tgcalls_reflector_socks5_udp(tg)",
    ):
        if branding_source.count(marker) != 1:
            err.append(f"CallTransport: expected exactly one active invocation of {marker}")
    if "    patch_tgcalls_reflector_socks5(tg)" in branding_source:
        err.append("CallTransport: legacy reflector TCP SOCKS5 patch is enabled")

    candidates = [
        tg.parent / "aorusgram" / "patches" / "assets" / "AorusGramAppIcon.png",
        Path("aorusgram/patches/assets/AorusGramAppIcon.png"),
        here.parent / "patches" / "assets" / "AorusGramAppIcon.png",
    ]
    master = next((p for p in candidates if p.is_file()), candidates[0])
    if not master.is_file():
        err.append("Missing aorusgram/patches/assets/AorusGramAppIcon.png")
    elif master.stat().st_size < 50_000:
        err.append("Master icon file suspiciously small")
    else:
        try:
            from PIL import Image

            im = Image.open(master)
            if im.size != (1024, 1024):
                err.append(f"Master icon must be 1024x1024, got {im.size}")
        except ImportError:
            pass

    # This legacy crop overlay is a transparency mask. A previous PNG-normalizing
    # step converted its 1-bit tRNS image to opaque grayscale, so the transparent
    # center rendered as a solid black rectangle over the photo editor.
    crop_corners = (
        tg
        / "submodules"
        / "LegacyComponents"
        / "Resources"
        / "LegacyComponentsResources.bundle"
        / "PhotoEditorCropCorners@2x.png"
    )
    if crop_corners.is_file():
        try:
            from PIL import Image

            crop_image = Image.open(crop_corners)
            if "A" not in crop_image.getbands():
                err.append("PhotoEditorCropCorners: alpha channel was lost during PNG normalization")
            elif crop_image.getchannel("A").getextrema()[0] != 0:
                err.append("PhotoEditorCropCorners: crop mask has no transparent pixels")
        except ImportError:
            pass
    else:
        err.append("PhotoEditorCropCorners: legacy crop overlay resource is missing")
    plist_path = tg / "Telegram" / "Telegram-iOS" / "Info.plist"
    with plist_path.open("rb") as f:
        pl = plistlib.load(f)
    for k in pl:
        if isinstance(k, str) and k.startswith("CFBundleIcons"):
            name = pl[k].get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
            if name != "AppIconLLC":
                err.append(f"{k} primary CFBundleIconName expected AppIconLLC, got {name!r}")
    schemes = pl.get("CFBundleURLTypes", [{}])[0].get("CFBundleURLSchemes", [])
    if schemes != ["aorusgram"]:
        err.append(f"First CFBundleURLSchemes expected ['aorusgram'], got {schemes}")

    if pl.get("CFBundleDisplayName") != "Aorusgram":
        err.append(f"CFBundleDisplayName expected Aorusgram, got {pl.get('CFBundleDisplayName')!r}")
    if pl.get("CFBundleName") != "Aorusgram":
        err.append(f"CFBundleName expected Aorusgram, got {pl.get('CFBundleName')!r}")
    if pl.get("UIFileSharingEnabled") is True:
        err.append("Info.plist: the whole Documents directory must not be exposed in Files.app")
    if pl.get("LSSupportsOpeningDocumentsInPlace") is True:
        err.append("Info.plist: in-place access must not expose the whole Documents directory")

    ad = tg / "submodules" / "TelegramUI" / "Sources" / "AppDelegate.swift"
    t = ad.read_text(encoding="utf-8")
    if "AorusgramGroupFallback" not in t:
        err.append("AppDelegate: missing App Group sandbox fallback (AltStore / no shared container)")
    if "self.nativeWindow = window\n        self.window?.makeKeyAndVisible()" not in t:
        err.append("AppDelegate: missing early makeKeyAndVisible after window wiring")
    # Accept either the legacy guard pattern or the improved hasAppGroup pattern
    has_url_guard = (
        "if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) != nil" in t
        or "hasAppGroup" in t
    )
    if not has_url_guard:
        err.append("AppDelegate: missing URLSession App Group guard (hasAppGroup or containerURL check)")

    build_path = tg / "Telegram" / "BUILD"
    if build_path.is_file():
        bt = build_path.read_text(encoding="utf-8")
        needle = "<key>CFBundleDisplayName</key>\n    <string>Telegram</string>"
        if needle in bt:
            err.append("Telegram/BUILD: CFBundleDisplayName still Telegram (Bazel plist_fragment not patched)")
        want_scheme = (
            "<key>CFBundleURLSchemes</key>\n            <array>\n                <string>aorusgram</string>\n            </array>"
        )
        if want_scheme not in bt:
            err.append("Telegram/BUILD: primary URL scheme should be aorusgram (UrlTypesInfoPlist template)")

    # Keep Telegram's native frame-based WindowHost implementation. This is an upstream
    # lifecycle primitive and should not be replaced by a branding-time scene override.
    nw = tg / "submodules" / "Display" / "Source" / "NativeWindowHostView.swift"
    if nw.is_file():
        nt = nw.read_text(encoding="utf-8")
        if "let window = NativeWindow(frame: UIScreen.main.bounds)" not in nt:
            err.append("NativeWindowHostView: stock frame-based NativeWindow constructor is missing")
        if "override init(windowScene: UIWindowScene)" in nt or "window = NativeWindow(windowScene: windowScene)" in nt:
            err.append("NativeWindowHostView: unexpected branding-time UIWindowScene override is present")

    chat_input = (
        tg
        / "submodules"
        / "TelegramUI"
        / "Components"
        / "Chat"
        / "ChatTextInputPanelNode"
        / "Sources"
        / "ChatTextInputPanelNode.swift"
    )
    if chat_input.is_file():
        chat_text = chat_input.read_text(encoding="utf-8")
        if "self.textInputNode?.textView" in chat_text:
            err.append("ChatTextInputPanelNode: removed legacy textInputNode API is still referenced")
        if "let cover = self.text" not in chat_text:
            err.append("AorusCode: cover text is not read through the current ChatTextInputPanelNode API")
        if "reserve voice button in initial text-node insets" not in chat_text:
            err.append("VoiceToText: initial text-node insets do not reserve the voice button")
        if "keep liquid-glass composer clear of its outer buttons" not in chat_text:
            err.append("VoiceToText: composer side-gap correction is missing")
        if "let aorusOuterActionSpacing: CGFloat" not in chat_text:
            err.append("VoiceToText: outer action spacing correction is missing")
        if "onClipboard: { [weak self] in self?.aorusPresentClipboard() }" not in chat_text:
            err.append("FormattingPanel: clipboard action is not wired")
        if "private func aorusPresentClipboard()" not in chat_text:
            err.append("FormattingPanel: native clipboard presenter is missing")
        if "model.canClearFormatting" not in chat_text or "chatTextInputClearFormattingAttributes(fullInputState)" not in chat_text:
            err.append("FormattingPanel: clear button state is not driven by native formatting attributes")
        if "self?.aorusUpdateToolbarSelectionState()" not in chat_text:
            err.append("FormattingPanel: formatting actions do not refresh the clear-button state")
        if "aorusMediaInputIsActive" not in chat_text:
            err.append("FormattingPanel: toolbar is not hidden for emoji/sticker media input")
        if "onTranslator: { [weak self] in self?.aorusToggleComposerTranslator() }" not in chat_text:
            err.append("ComposerTranslator: toolbar action is not wired")
        if "context.engine.messages.translate(text: text, toLang: targetLanguage)" not in chat_text:
            err.append("ComposerTranslator: Telegram native translation API is not used")
        if "DispatchQueue.main.asyncAfter(deadline: .now() + 0.35" not in chat_text or "aorusTranslationRevision" not in chat_text:
            err.append("ComposerTranslator: debounce or stale-result protection is missing")
        if "self.aorusTranslatorExpanded ? 142.0 : 44.0" not in chat_text:
            err.append("ComposerTranslator: formatting panel height is not dynamic")
        if "theme.chat.inputPanel.panelControlAccentColor" not in chat_text or "model.themeAccentColor = accentColor" not in chat_text:
            err.append("ComposerTranslator: active controls do not follow Telegram's current chat theme")
        if "private var aorusTranslatorExpanded: Bool" not in chat_text:
            err.append("ComposerTranslator: UIKit layout state is not synchronized with the SwiftUI model")
        if "self.updateHeight(true)" not in chat_text or "only lays out this node and discards its new height" not in chat_text:
            err.append("ComposerTranslator: expansion does not notify Telegram's parent input-panel layout")
        if "withAnimation(.easeInOut(duration: 0.16))" not in chat_text:
            err.append("ComposerTranslator: SwiftUI state is not synchronized with the native height animation")
        if "DispatchQueue.main.asyncAfter(deadline: .now() + 0.12)" in chat_text:
            err.append("ComposerTranslator: delayed collapse still causes a second layout pass")
        if "leftInset - self.leftMenuInset" not in chat_text:
            err.append("FormattingPanel: bot-menu inset incorrectly shifts the full-width toolbar")
        if "self.isFocused || aorusTranslatorIsExpanded" not in chat_text:
            err.append("ComposerTranslator: panel does not survive focus transfer to its text field")
        if "self.aorusTranslationDisposable?.dispose()" not in chat_text:
            err.append("ComposerTranslator: request cancellation is missing")
        if "AorusGram: dismiss keyboard when media recording starts" not in chat_text or "strongSelf.ensureUnfocused()" not in chat_text:
            err.append("MediaRecording: keyboard is not dismissed at the native recording start callback")
    else:
        err.append("VoiceToText: ChatTextInputPanelNode.swift is missing")

    timestamp_status = (
        tg
        / "submodules"
        / "TelegramUI"
        / "Components"
        / "Chat"
        / "ChatMessageDateAndStatusNode"
        / "Sources"
        / "StringForMessageTimestampStatus.swift"
    )
    if not timestamp_status.is_file():
        err.append("MessageSeconds: central timestamp formatter is missing")
    else:
        timestamp_text = timestamp_status.read_text(encoding="utf-8")
        if timestamp_text.count("aorusgram_feature_message_seconds") != 5:
            err.append("MessageSeconds: all five central timestamp call sites must use the setting")
        if timestamp_text.count("withSeconds: UserDefaults.standard.bool") != 5:
            err.append("MessageSeconds: Telegram's locale-aware formatter is not used consistently")

    multipart_fetch = tg / "submodules" / "TelegramCore" / "Sources" / "Network" / "MultipartFetch.swift"
    if not multipart_fetch.is_file():
        err.append("DownloadAccelerator: MultipartFetch.swift is missing")
    else:
        multipart_text = multipart_fetch.read_text(encoding="utf-8")
        accelerator_line = (
            'self.parallelParts = UserDefaults.standard.bool(forKey: '
            '"aorusgram_feature_download_accel") ? 16 : 8'
        )
        if multipart_text.count(accelerator_line) != 1:
            err.append("DownloadAccelerator: large-file MTProto concurrency patch is missing or duplicated")
        if "self.defaultPartSize = 512 * 1024" not in multipart_text:
            err.append("DownloadAccelerator: Telegram's native large-file part size changed")

    spoof_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusDeviceSpoofController.swift"
    if not spoof_controller.is_file():
        err.append("DeviceSpoof: native settings controller is missing")
    else:
        spoof_text = spoof_controller.read_text(encoding="utf-8")
        for marker in (
            "animateChanges: true",
            "aorusDeviceStableId",
            "Add Custom Device",
            "ItemListCheckboxItem",
            "aorusAddCustomDeviceController",
            "AorusSpoofPlatform.allCases",
            "deleteCustom",
            'UIImage(systemName: "trash.fill")',
        ):
            if marker not in spoof_text:
                err.append(f"DeviceSpoof: screen invariant is missing {marker}")
        if "UIAlertController" in spoof_text:
            err.append("DeviceSpoof: custom device editor regressed to an alert")
        if 'title: "\\(device.model) · \\(device.systemVersion)"' in spoof_text:
            err.append("DeviceSpoof: device rows must not append the OS version")

    aorus_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusGramController.swift"
    if aorus_controller.is_file():
        aorus_controller_text = aorus_controller.read_text(encoding="utf-8")
        if "navigationController.topViewController as? ViewController" not in aorus_controller_text:
            err.append("DeviceSpoof: restart notice is not anchored to the visible controller")

    formatting_toolbar = (
        tg
        / "submodules"
        / "TelegramUI"
        / "Components"
        / "Chat"
        / "ChatTextInputPanelNode"
        / "Sources"
        / "AorusInputToolbar.swift"
    )
    if formatting_toolbar.is_file():
        toolbar_text = formatting_toolbar.read_text(encoding="utf-8")
        clipboard_index = toolbar_text.find("clipboardButton()")
        code_index = toolbar_text.find('formatButton(systemName: "chevron.left.forwardslash.chevron.right"')
        if clipboard_index < 0 or code_index < 0 or clipboard_index > code_index:
            err.append("FormattingPanel: clipboard button must be immediately before Code")
        if "@Published var canClearFormatting" not in toolbar_text or "clearFormattingButton()" not in toolbar_text:
            err.append("FormattingPanel: clear-formatting button does not expose disabled/enabled state")
        if 'UIImage(bundleImageName: "Chat/Context Menu/Translate")' not in toolbar_text:
            err.append("ComposerTranslator: Telegram's native translation glyph is not used")
        if "@Published var themeAccentColor: UIColor" not in toolbar_text or ".accentColor(Color(self.model.themeAccentColor))" not in toolbar_text:
            err.append("ComposerTranslator: SwiftUI controls do not inherit the current Telegram theme accent")
        if ".transition(.move(edge: .top)" in toolbar_text or ".padding(.vertical, 8)" in toolbar_text:
            err.append("ComposerTranslator: obsolete double animation or overflowing toolbar padding remains")
        if ".scale(scale: 0.985, anchor: .top)" not in toolbar_text or ".animation(.easeInOut(duration: 0.16)" not in toolbar_text:
            err.append("ComposerTranslator: panel open/close transition is missing")
        spoiler_index = toolbar_text.find('formatButton(systemName: "eye.slash"')
        translator_index = toolbar_text.find("translatorButton()")
        bold_index = toolbar_text.find('formatButton(systemName: "bold"')
        if spoiler_index < 0 or translator_index < 0 or bold_index < 0 or not (spoiler_index < translator_index < bold_index):
            err.append("ComposerTranslator: button must be directly after Spoiler")
        if "AorusTranslationLanguagePicker" not in toolbar_text or "Search Languages" not in toolbar_text:
            err.append("ComposerTranslator: searchable language picker is missing")
        if 'sourceLanguageCode = AorusTranslationLanguage' not in toolbar_text or '?? "auto"' not in toolbar_text or '?? "en"' not in toolbar_text:
            err.append("ComposerTranslator: automatic source or English target defaults are missing")
        if "localizedName(for code:" not in toolbar_text or "localizedString(forLanguageCode:" not in toolbar_text:
            err.append("ComposerTranslator: full localized language names are missing")
    else:
        err.append("FormattingPanel: AorusInputToolbar.swift is missing")

    account_state = tg / "submodules" / "TelegramCore" / "Sources" / "State" / "AccountStateManagementUtils.swift"
    if account_state.is_file():
        account_text = account_state.read_text(encoding="utf-8")
        if "let aorusIsBotPeer = (transaction.getPeer(mid.peerId) as? TelegramUser)?.botInfo != nil" not in account_text:
            err.append("AntiSpam: prefilter does not exclude bot chats")
        if "((transaction.getPeer(mid.peerId) as? TelegramUser)?.botInfo == nil)" not in account_text:
            err.append("AntiSpam: incoming eligibility does not exclude bot chats")
    else:
        err.append("AntiSpam: AccountStateManagementUtils.swift is missing")

    quick_replies = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusQuickRepliesController.swift"
    if quick_replies.is_file():
        quick_text = quick_replies.read_text(encoding="utf-8")
        if "Queue.mainQueue().after(0.12)" in quick_text or "Queue.mainQueue().after(0.16)" in quick_text:
            err.append("QuickReplies: delayed two-phase list mutation reintroduces jumping rows")
        if quick_text.count("override func updateAnimationDuration() -> Double?") < 2:
            err.append("QuickReplies: input/reply animation timing overrides are missing")
        if "next.replies.append(QRReply(id: next.nextId, text: draft))" not in quick_text:
            err.append("QuickReplies: reply commit is not an atomic state update")
    else:
        err.append("QuickReplies: AorusQuickRepliesController.swift is missing")

    aorus_manager = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusGramManager.swift"
    if not aorus_manager.is_file():
        err.append("ProfilePersonalization: AorusGramManager.swift is missing")
    else:
        manager_text = aorus_manager.read_text(encoding="utf-8")
        if "var squareAvatars: Bool" not in manager_text or 'forKey: "aorusgram_square_avatars"' not in manager_text:
            err.append("ProfilePersonalization: square-avatar setting is not persisted/mirrored")

    animated_profile = tg / "submodules" / "AorusGramUI" / "Sources" / "Features" / "UI" / "AorusAnimatedProfileBackground.swift"
    if not animated_profile.is_file():
        err.append("ProfilePersonalization: animated profile background implementation is missing")
    else:
        animated_text = animated_profile.read_text(encoding="utf-8")
        if "AorusAnimatedProfileBackgroundStore" not in animated_text or "AorusAnimatedProfileBackgroundPicker" not in animated_text:
            err.append("ProfilePersonalization: animated background storage/picker is incomplete")
        if "AVSampleBufferDisplayLayer" not in animated_text or "AVAssetReaderTrackOutput" not in animated_text:
            err.append("ProfilePersonalization: video-only looping renderer is incomplete")
        if "AVQueuePlayer" in animated_text or "AVPlayerLooper" in animated_text:
            err.append("ProfilePersonalization: AVPlayer playback can activate the shared audio session")
        if "AVAudioSession" in animated_text or "withMediaType: .audio" in animated_text:
            err.append("ProfilePersonalization: profile background must not create an audio track/session")
        if "prepareForLifecyclePause" not in animated_text or "rendererHasDisplayedFrame" not in animated_text:
            err.append("ProfilePersonalization: foreground/background poster continuity is incomplete")
        if "canPreserveCurrentVisual" not in animated_text or "teardownRenderer(clearVisuals:" not in animated_text:
            err.append("ProfilePersonalization: same-banner visual continuity is incomplete")
        if "lastPlaybackRequest" not in animated_text or "self.updatePlayback()" not in animated_text:
            err.append("ProfilePersonalization: post-layout playback recovery is incomplete")
        if "remoteRefreshTimer" not in animated_text or "requestCurrentRemoteBanner(force: true)" not in animated_text:
            err.append("ProfilePersonalization: visible remote banners do not refresh live")
        if "stableMediaViewportHeight" not in animated_text or "viewportFrame.height - mediaHeight" not in animated_text:
            err.append("ProfilePersonalization: animated banner can still rescale during profile overscroll")
        if "self.backdropView.frame = self.bounds" not in animated_text:
            err.append("ProfilePersonalization: full-height overscroll guard is not preserved")
        if "let guardSize = CGSize(width: 8.0, height: 24.0)" not in animated_text or ".resizableImage(" in animated_text:
            err.append("ProfilePersonalization: overscroll guard can still stretch banner details into artifacts")
        if "guard seconds <= 30.0" not in animated_text or "guard totalDuration <= 30.0" not in animated_text:
            err.append("ProfilePersonalization: video/GIF duration must be capped at 30 seconds")
        if 'sourceType as String == "com.compuserve.gif"' not in animated_text:
            err.append("ProfilePersonalization: imported images are not validated as GIF")
        if "maximumEncodedBytes = 5_750_000" not in animated_text or "AVAssetExportPresetLowQuality" not in animated_text:
            err.append("ProfilePersonalization: imported media is not bounded below the banner API upload limit")
        required_crop_markers = [
            "AorusAnimatedProfileMediaGalleryController",
            "PHAsset.fetchAssets(with: .video",
            ".smartAlbumAnimated",
            "asset.duration <= 30.0",
            'sourceType as String == "com.compuserve.gif"',
            "AorusAnimatedProfileCropController",
            "static let aspectRatio: CGFloat = 16.0 / 9.0",
            "static let outputSize = CGSize(width: 1280.0, height: 720.0)",
            "AVMutableVideoComposition()",
            "exporter.videoComposition = videoComposition",
            "let croppedImage = image.cropping(to: sourceCrop)",
            "videoOnlyPreviewAsset",
        ]
        for marker in required_crop_markers:
            if marker not in animated_text:
                err.append(f"ProfilePersonalization: filtered banner crop flow is missing {marker}")
        if "PHPickerViewController" in animated_text or "UIImagePickerController" in animated_text:
            err.append("ProfilePersonalization: unfiltered system media picker is still used for banners")
        if "self.showHUD()" not in animated_text or "private func hideHUD()" not in animated_text:
            err.append("ProfilePersonalization: banner gallery loading has no immediate user feedback")
        reset_start = animated_text.find("private static func resetLocally(accountId: Int64)")
        reset_end = animated_text.find("fileprivate static func installProcessedFile", reset_start)
        reset_body = animated_text[reset_start:reset_end] if reset_start != -1 and reset_end != -1 else ""
        if 'UserDefaults.standard.set(true, forKey: key(enabledPrefix, accountId: accountId))' not in reset_body:
            err.append("ProfilePersonalization: resetting media incorrectly disables the banner feature")
        if "self.exportVideoAsset(asset, to: destination)" not in animated_text:
            err.append("ProfilePersonalization: iCloud-backed video import has no AVAsset export fallback")

    banner_service = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Profile" / "AorusBannerService.swift"
    if not banner_service.is_file():
        err.append("ProfilePersonalization: public banner service is missing")
    else:
        banner_text = banner_service.read_text(encoding="utf-8")
        required_banner_markers = [
            "X-Aorus-Telegram-Id",
            "X-Aorus-Body-Sha256",
            "AorusBannerPublicationMode",
            "lookupCompletions",
            "URLSessionConfiguration.ephemeral",
            "tracks(withMediaType: .audio).isEmpty",
            "LicenseKeyProvider.withLicenseHmacKey",
        ]
        for marker in required_banner_markers:
            if marker not in banner_text:
                err.append(f"ProfilePersonalization: banner service is missing {marker}")
        if "forceRefresh: Bool = false" not in banner_text or "if !forceRefresh," not in banner_text:
            err.append("ProfilePersonalization: forced banner version refresh is missing")
        if r".download-\(UUID().uuidString).mp4" not in banner_text or "sourceURL: retainedURL" not in banner_text:
            err.append("ProfilePersonalization: remote banner download is not retained beyond URLSession completion")
        if "BANNER_HMAC_KEY" in banner_text or "__AORUS_BANNER_KEY" in banner_text:
            err.append("ProfilePersonalization: banner key material must not be stored in source")

    video_message_camera = tg / "submodules" / "TelegramUI" / "Components" / "VideoMessageCameraScreen" / "Sources" / "VideoMessageCameraScreen.swift"
    if not video_message_camera.is_file():
        err.append("VideoMessagesRearCamera: VideoMessageCameraScreen.swift is missing")
    else:
        video_message_camera_text = video_message_camera.read_text(encoding="utf-8")
        if "rear camera for video messages (native initial state)" not in video_message_camera_text:
            err.append("VideoMessagesRearCamera: native initial camera state patch is missing")
        if "let isFrontPosition = !aorusStartWithRearCamera" not in video_message_camera_text:
            err.append("VideoMessagesRearCamera: preview and camera state are not synchronized")
        if "? .back : self.cameraState.position" in video_message_camera_text:
            err.append("VideoMessagesRearCamera: legacy configuration-only override is still present")

    camera_core = tg / "submodules" / "Camera" / "Sources" / "Camera.swift"
    if not camera_core.is_file():
        err.append("VideoMessagesRearCamera: Camera.swift is missing")
    else:
        camera_core_text = camera_core.read_text(encoding="utf-8")
        if "synchronize round-video recorder position" not in camera_core_text or "output.markPositionChange(position: configuration.position)" not in camera_core_text:
            err.append("VideoMessagesRearCamera: recorder source is not synchronized with preview position")

    profile_header = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "Sources" / "PeerInfoHeaderNode.swift"
    avatar_renderer = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "Sources" / "PeerInfoAvatarTransformContainerNode.swift"
    editing_avatar = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "Sources" / "PeerInfoEditingAvatarNode.swift"
    editing_overlay = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "Sources" / "PeerInfoEditingAvatarOverlayNode.swift"
    profile_preview = tg / "submodules" / "TelegramUI" / "Components" / "Settings" / "PeerNameColorScreen" / "Sources" / "PeerNameColorProfilePreviewItem.swift"
    personal_colors = tg / "submodules" / "TelegramUI" / "Components" / "Settings" / "PeerNameColorScreen" / "Sources" / "UserApperanceScreen.swift"
    profile_sentinels = [
        (profile_header, "AorusGram: animated profile background layer"),
        (avatar_renderer, "AorusGram: square avatar story ring"),
        (editing_avatar, "AorusGram: square avatar while editing"),
        (editing_overlay, "AorusGram: square editing overlay"),
        (profile_preview, "AorusGram: animated background in profile preview"),
        (personal_colors, "AorusGram: animated profile background controls"),
    ]
    for profile_path, sentinel in profile_sentinels:
        if not profile_path.is_file():
            err.append(f"ProfilePersonalization: {profile_path.name} is missing")
        elif sentinel not in profile_path.read_text(encoding="utf-8"):
            err.append(f"ProfilePersonalization: {profile_path.name} patch is missing")
    if profile_header.is_file() and "aorusAnimatedProfileBackgroundView.contentFrame" not in profile_header.read_text(encoding="utf-8"):
        err.append("ProfilePersonalization: full-height animated cover guard is missing")
    if profile_header.is_file():
        profile_header_text = profile_header.read_text(encoding="utf-8")
        if "Prepare the first frame synchronously" not in profile_header_text:
            err.append("ProfilePersonalization: first-frame stock-cover guard is missing")
        geometry_index = profile_header_text.find("self.aorusAnimatedProfileBackgroundView.frame = aorusBackgroundFrame")
        configure_index = profile_header_text.find("self.aorusAnimatedProfileBackgroundView.configure(")
        insert_index = profile_header_text.find("self.backgroundBannerView.insertSubview(self.aorusAnimatedProfileBackgroundView")
        if min(geometry_index, configure_index, insert_index) < 0 or not geometry_index < configure_index < insert_index:
            err.append("ProfilePersonalization: animated view must be sized before configure/insertion")
        if "content: .universalImage(image: aorusImg" not in profile_header_text:
            err.append("Badges: profile badge must use Telegram's native UndoOverlay UI")
        if "let aorusToastSize" not in profile_header_text or "size: aorusToastSize" not in profile_header_text:
            err.append("Badges: profile toast icon must preserve the badge aspect ratio")
        if "AorusBadgeToast.present" in profile_header_text:
            err.append("Badges: legacy custom profile toast is still wired")

    badge_source = tg / "submodules" / "AorusBadge" / "Sources" / "AorusBadge.swift"
    if not badge_source.is_file():
        err.append("Badges: AorusBadge.swift is missing")
    else:
        badge_text = badge_source.read_text(encoding="utf-8")
        if "Гл. Администратор AorusGram" not in badge_text or "является жопой" in badge_text:
            err.append("Badges: administrator badge text is not production-ready")
        if "peerName) —" in badge_text:
            err.append("Badges: administrator toast must not include the peer nickname")

    animated_background = tg / "submodules" / "AorusGramUI" / "Sources" / "Features" / "UI" / "AorusAnimatedProfileBackground.swift"
    if animated_background.is_file():
        animated_background_text = animated_background.read_text(encoding="utf-8")
        lifecycle_resume_guard = "self.lastPlaybackRequest = false\n        self.renderer?.setPlaying(false)"
        if lifecycle_resume_guard not in animated_background_text:
            err.append("ProfilePersonalization: animated background lifecycle resume guard is missing")

    aorus_l10n = tg / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusL10n.swift"
    if aorus_l10n.is_file():
        aorus_l10n_text = aorus_l10n.read_text(encoding="utf-8")
        if 't("Анимированный баннер", "Animated Banner")' not in aorus_l10n_text:
            err.append("ProfilePersonalization: animated banner title is not localized consistently")
        if 't("Сбросить анимированный баннер", "Reset Animated Banner")' not in aorus_l10n_text:
            err.append("ProfilePersonalization: animated banner reset title is not localized consistently")

    personal_colors_build = tg / "submodules" / "TelegramUI" / "Components" / "Settings" / "PeerNameColorScreen" / "BUILD"
    if personal_colors_build.is_file():
        personal_colors_build_text = personal_colors_build.read_text(encoding="utf-8")
        if "//submodules/AorusGramUI" not in personal_colors_build_text or "ListSwitchItemComponent" not in personal_colors_build_text:
            err.append("ProfilePersonalization: Personal Colors BUILD dependencies are incomplete")
    else:
        err.append("ProfilePersonalization: PeerNameColorScreen BUILD is missing")

    if personal_colors.is_file():
        personal_colors_text = personal_colors.read_text(encoding="utf-8")
        if "AorusGram: animated banner shortcut focus" not in personal_colors_text or "aorusAnimatedBackgroundTag" not in personal_colors_text:
            err.append("SettingsShortcuts: animated banner focus/highlight patch is missing")
        if "let targetView = self.profileColorSection.findTaggedView(tag: aorusAnimatedBackgroundTag)" not in personal_colors_text:
            err.append("SettingsShortcuts: animated banner focus must wait for the exact toggle view")
        if "let aorusCanResetAnimatedBackground = aorusAnimatedBackgroundEnabled && aorusAnimatedBackgroundHasMedia" not in personal_colors_text:
            err.append("ProfilePersonalization: animated banner reset must require an enabled stored banner")
        if "if aorusCanResetAnimatedBackground {" not in personal_colors_text:
            err.append("ProfilePersonalization: disabled animated banner still exposes its reset action")
        if "aorusAnimatedBackgroundEnabled || aorusAnimatedBackgroundHasMedia" in personal_colors_text:
            err.append("ProfilePersonalization: reset button must stay hidden until banner media exists")

    list_switch_source = tg / "submodules" / "TelegramUI" / "Components" / "ListSwitchItemComponent" / "Sources" / "ListSwitchItemComponent.swift"
    if not list_switch_source.is_file() or "AorusGram: component tag support" not in list_switch_source.read_text(encoding="utf-8"):
        err.append("SettingsShortcuts: ListSwitch component tag support is missing")

    peer_info_build = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "BUILD"
    if not peer_info_build.is_file():
        err.append("ProfilePersonalization: PeerInfoScreen BUILD is missing")
    else:
        peer_info_build_text = peer_info_build.read_text(encoding="utf-8")
        if "//submodules/AorusGramUI" not in peer_info_build_text:
            err.append("ProfilePersonalization: PeerInfoScreen AorusGramUI dependency is missing")
        if "//submodules/TelegramUI/Components/Settings/WallpaperGridScreen" not in peer_info_build_text:
            err.append("SettingsShortcuts: PeerInfoScreen wallpaper dependency is missing")
        if "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen" not in peer_info_build_text:
            err.append("SettingsShortcuts: PeerInfoScreen appearance dependency is missing")

    peer_info_actions = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "Sources" / "PeerInfoScreenSettingsActions.swift"
    if not peer_info_actions.is_file():
        err.append("SettingsShortcuts: PeerInfoScreenSettingsActions.swift is missing")
    else:
        peer_info_actions_text = peer_info_actions.read_text(encoding="utf-8")
        if "shortcutRoutes: AorusSettingsShortcutRoutes(" not in peer_info_actions_text:
            err.append("SettingsShortcuts: appearance routes are not passed to AorusGram")
        if "ThemeGridController(context: context)" not in peer_info_actions_text:
            err.append("SettingsShortcuts: native wallpaper route is missing")
        if "focusOnItemTag: .aorusAnimatedBackground" not in peer_info_actions_text:
            err.append("SettingsShortcuts: animated banner route is missing")

    font_picker = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusFontPickerController.swift"
    if not font_picker.is_file():
        err.append("SettingsShortcuts: font picker is missing")
    else:
        font_picker_text = font_picker.read_text(encoding="utf-8")
        if "highlightFontBlock" not in font_picker_text or "highlightFirstFont" in font_picker_text:
            err.append("SettingsShortcuts: font shortcut must highlight the complete font block")

    display_font = tg / "submodules" / "Display" / "Source" / "Font.swift"
    if display_font.is_file() and 'if designKey == "monospace"' not in display_font.read_text(encoding="utf-8"):
        err.append("CustomFont: formatting panel monospace must override the selected client font")

    aorus_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusGramController.swift"
    misc_controller_shortcuts = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusMiscController.swift"
    for controller_path in (aorus_controller, misc_controller_shortcuts):
        if not controller_path.is_file():
            err.append(f"SettingsShortcuts: {controller_path.name} is missing")
        elif "shortcutRoutes: AorusSettingsShortcutRoutes? = nil" in controller_path.read_text(encoding="utf-8"):
            err.append(f"SettingsShortcuts: {controller_path.name} must require non-optional routes")

    wallpaper_grid = tg / "submodules" / "TelegramUI" / "Components" / "Settings" / "WallpaperGridScreen" / "Sources" / "ThemeGridControllerNode.swift"
    if not wallpaper_grid.is_file() or "AorusGram: animated wallpaper shortcut highlight" not in wallpaper_grid.read_text(encoding="utf-8"):
        err.append("SettingsShortcuts: animated wallpaper highlight patch is missing")

    mask_processor = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "AorusVideoMaskProcessor.swift"
    if not mask_processor.is_file():
        err.append("VideoMasks: AorusVideoMaskProcessor.swift is missing")
    else:
        mask_text = mask_processor.read_text(encoding="utf-8")
        if "RenderSnapshot" not in mask_text or "private let stateLock" not in mask_text or "VNDetectFaceLandmarksRequest" not in mask_text:
            err.append("VideoMasks: stable Vision/render state pipeline is incomplete")
        if "processingLock.try()" in mask_text:
            err.append("VideoMasks: lock contention can still emit unmasked video frames")
        if "detectionQueue.async" not in mask_text or "detectionInFlight" not in mask_text:
            err.append("VideoMasks: face detection must stay off the WebRTC capture thread")
        if "processCallFrame(" not in mask_text or "callRenderQueue.async" not in mask_text or "callRenderInFlight" not in mask_text:
            err.append("VideoMasks: call compositor still blocks Telegram's native camera preview")
        if "publishesPreview: false,\n                        realtimeTracking: true" not in mask_text:
            err.append("VideoMasks: calls still publish unused local preview updates or lost realtime tracking")
        if "aorusgram_video_mask_call_phase" not in mask_text or "needsPreparedFrame" not in mask_text or "needsActiveRefresh" not in mask_text:
            err.append("VideoMasks: pre-answer compositor still competes with the native local preview")
        if "lastCallRenderTime" not in mask_text or "renderInterval" not in mask_text:
            err.append("VideoMasks: outgoing call-mask renderer has no bounded refresh cadence")
        if "private let detectionContext" not in mask_text or "self.detectionContext.createCGImage" not in mask_text:
            err.append("VideoMasks: Vision proxy generation can still block outgoing camera delivery")
        detection_schedule_start = mask_text.find("if snapshot.needsDetection {")
        pose_guard_start = mask_text.find("guard let pose = snapshot.pose", detection_schedule_start)
        if detection_schedule_start == -1 or pose_guard_start == -1 or "makeDetectionFrame" in mask_text[detection_schedule_start:pose_guard_start]:
            err.append("VideoMasks: Vision proxy work still runs synchronously in the capture callback")
        if "private let poolLock" not in mask_text or "isPlausible" not in mask_text or "FrameGeometry" not in mask_text:
            err.append("VideoMasks: output-buffer isolation or pose outlier rejection is missing")
        if "processingEnabled" not in mask_text or "deactivateTrackingIfNeeded" not in mask_text:
            err.append("VideoMasks: enable/disable tracking lifecycle reset is missing")
        if "shouldDiscardUnmaskedVideoFrame" not in mask_text or "hasRenderedMaskedFrame" not in mask_text:
            err.append("VideoMasks: initial masked-frame recording latch is missing")
        if "let result = self.processingEnabled && !self.hasRenderedMaskedFrame" not in mask_text:
            err.append("VideoMasks: recording gate must close only before the first masked frame")
        if "DetectionFrame" not in mask_text or "VNImageRequestHandler(cgImage:" not in mask_text:
            err.append("VideoMasks: Vision must own an immutable camera-frame snapshot")
        if "roundVideoBack" not in mask_text or "roundVideoFront" not in mask_text or "publishesPreview" not in mask_text:
            err.append("VideoMasks: front and rear round-video streams are not isolated")
        if "CIPerspectiveTransform" not in mask_text or "observation.yaw" not in mask_text or "landmarks?.leftEye" not in mask_text:
            err.append("VideoMasks: landmark-anchored perspective tracking is incomplete")
        if "AorusVideoMaskAssets" not in mask_text or "custom-mask.png" not in mask_text:
            err.append("VideoMasks: PNG asset/custom-mask loading is incomplete")
        if 'Self.customPreset + ":"' not in mask_text or "customMaskURL(for preset:" not in mask_text:
            err.append("VideoMasks: named custom-mask loading is incomplete")
        if "Vision's face box can end above the visible jaw" not in mask_text:
            err.append("VideoMasks: full-face mask coverage geometry is missing")
        if ".cropped(to: image.extent)" not in mask_text:
            err.append("VideoMasks: transformed masks can expand the frame and produce black borders")

    mask_assets = tg / "submodules" / "AorusGram" / "Resources" / "VideoMasks"
    expected_mask_assets = {"skull.png", "cyber.png", "oni.png", "phantom.png", "chrome.png", "aurora.png", "neoncat.png"}
    if not mask_assets.is_dir() or not expected_mask_assets.issubset({path.name for path in mask_assets.glob("*.png")}):
        err.append("VideoMasks: generated PNG mask assets are incomplete")

    mask_overlay = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "AorusVideoMaskOverlayView.swift"
    if not mask_overlay.is_file():
        err.append("VideoMasks: local preview overlay implementation is missing")
    else:
        overlay_text = mask_overlay.read_text(encoding="utf-8")
        if "self.preset != preset || self.imageView.image == nil" not in overlay_text:
            err.append("VideoMasks: local preview must reuse its cached artwork")
        if "updateMaskFrame(animated: true)" in overlay_text or "shouldRasterize = true" in overlay_text:
            err.append("VideoMasks: local preview reintroduces delayed/rasterized tracking")
        if "self.isOpaque = false" not in overlay_text or "self.imageView.isOpaque = false" not in overlay_text:
            err.append("VideoMasks: local call overlay can render transparent pixels as black")
        if "self.imageView.layer.transform = CATransform3DIdentity" not in overlay_text or "CATransform3DRotate" in overlay_text:
            err.append("VideoMasks: local call overlay can freeze the native preview through 3D flattening")

    camera_output = tg / "submodules" / "Camera" / "Sources" / "CameraOutput.swift"
    if not camera_output.is_file():
        err.append("VideoMasks: CameraOutput.swift is missing")
    else:
        camera_output_text = camera_output.read_text(encoding="utf-8")
        if "stream-isolated round-video mask" not in camera_output_text or "sourcePosition == .front" not in camera_output_text:
            err.append("VideoMasks: round-video source streams are not isolated by physical camera")
        if "synchronouslyAcquireInitialPose" in camera_output_text:
            err.append("VideoMasks: CameraOutput still blocks capture on synchronous Vision detection")
        if "discard unmasked recording frames" not in camera_output_text or "if shouldRecordSampleBuffer {" not in camera_output_text:
            err.append("VideoMasks: unmasked round-video frames can still reach the recorder")
        if "processor.shouldDiscardUnmaskedVideoFrame" not in camera_output_text:
            err.append("VideoMasks: CameraOutput is not connected to the masked-frame latch")

    mask_editor = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusMaskEditorController.swift"
    if not mask_editor.is_file():
        err.append("VideoMasks: custom mask editor is missing")
    else:
        editor_text = mask_editor.read_text(encoding="utf-8")
        if "renderedImage()" not in editor_text or "setBlendMode(stroke.erasing ? .clear : .normal)" not in editor_text:
            err.append("VideoMasks: custom mask drawing/eraser pipeline is incomplete")
        if "AorusMaskLayer" not in editor_text or "UIImagePickerController" not in editor_text or "addText(" not in editor_text:
            err.append("VideoMasks: layered photo/text mask editor is incomplete")
        if "AorusCustomMaskStore" not in editor_text or "Mask Name" not in editor_text:
            err.append("VideoMasks: named custom-mask persistence is incomplete")
        if "UIPinchGestureRecognizer" not in editor_text or "UIRotationGestureRecognizer" not in editor_text or "movingPhoto" not in editor_text:
            err.append("VideoMasks: custom photo/text transforms are incomplete")
        if "context.addEllipse(in: faceClip)" not in editor_text:
            err.append("VideoMasks: imported photos must be clipped to the face template")
        if "static func delete(_ record: AorusCustomMaskRecord)" not in editor_text:
            err.append("VideoMasks: custom-mask deletion storage is incomplete")
        if "maximumZoomScale = 4.0" not in editor_text or "pinchStartTextSize" not in editor_text:
            err.append("VideoMasks: precision canvas/text zoom is incomplete")
        if "Keep an explicitly selected text item active" not in editor_text:
            err.append("VideoMasks: selected text does not support canvas-wide pinch")
        if "disablesInteractiveTransitionGestureRecognizerNow = { true }" not in editor_text:
            err.append("VideoMasks: editor must block swipe-back while drawing")
        if "override func gestureRecognizerShouldBegin" not in editor_text:
            err.append("VideoMasks: canvas gesture gate must override UIView's implementation")

    misc_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusMiscController.swift"
    if not misc_controller.is_file():
        err.append("PhoneSpoof: AorusMiscController.swift is missing")
    else:
        misc_text = misc_controller.read_text(encoding="utf-8")
        if "returnKeyType: .done" not in misc_text or "#selector(UIResponder.resignFirstResponder)" not in misc_text:
            err.append("PhoneSpoof: Return must apply the number and dismiss the keyboard")
        if "shouldUpdateText: { text in" not in misc_text or "text.allSatisfy { $0.isNumber }" not in misc_text:
            err.append("FakeStars: Return input must remain numeric-only")
        if "AorusFakeStarsStore.changedNotification" not in misc_text:
            err.append("FakeStars: settings amount does not observe local purchases")

    fake_store = tg / "submodules" / "TelegramCore" / "Sources" / "AorusFakeGiftsStore.swift"
    if not fake_store.is_file():
        err.append("FakeStars: local gift store is missing")
    else:
        fake_store_text = fake_store.read_text(encoding="utf-8")
        required_store_markers = (
            "public var ownerPeerId: Int64",
            "public var instanceId: Int64",
            "public var purchasedLocally: Bool",
            "public static func ownProfileGifts()",
            "public static func remove(instanceId: Int64)",
            "storedOwner == 0 && !isEnabled",
            "public static func recordLocalGiftMessage",
            "public static func recordLocalPremiumMessage",
            "public static func spend(_ value: Int64)",
            "public static func setProfileVisibility(reference: StarGiftReference",
            "public static func transfer(reference: StarGiftReference",
            "public static func updateCollectionOrder(collectionId: Int32",
            "public static func isWorn(reference: StarGiftReference)",
        )
        if any(marker not in fake_store_text for marker in required_store_markers):
            err.append("FakeStars: local balance/gift persistence pipeline is incomplete")
        if "where gifts[index].ownerPeerId == 0" not in fake_store_text:
            err.append("FakeGifts: own-profile mutations are not isolated from recipient gifts")
        if "Keep every regular purchase as its own local instance" not in fake_store_text:
            err.append("FakeGifts: repeated regular purchases are not stored independently")
        if 'dict["fromPeerId"] = ["iv": renderedSenderPeerId]' not in fake_store_text:
            err.append("FakeGifts: edited sender is not reflected by regular gift wrappers")
        if '"savedToProfile": stored.showInProfile' not in fake_store_text:
            err.append("FakeGifts: hidden local gifts do not expose Telegram's native savedToProfile state")
        if "let ownGifts = all().filter { $0.ownerPeerId == 0 }" not in fake_store_text:
            err.append("FakeGifts: hidden own-profile gifts are removed instead of remaining manageable")
        if "if !normalized.showInProfile" not in fake_store_text or "normalized.pinnedToTop = false" not in fake_store_text:
            err.append("FakeGifts: local manager can leave a hidden gift pinned")
        if "if value {\n                gifts[index].showInProfile = true" not in fake_store_text:
            err.append("FakeGifts: pinning a hidden local gift does not restore profile visibility")
        if "senderPeer.id.toInt64() == renderedSenderPeerId" not in fake_store_text or "fromPeer: senderPeer" not in fake_store_text:
            err.append("FakeGifts: non-anonymous local purchases do not resolve their sender peer")
        # A collectible bought with local Stars has to deliver the same card a real purchase does:
        # into the recipient's chat, or into Saved Messages when the buyer gifts themselves.
        # Returning early here is what left the purchase as a bare toast.
        if "action = .starGiftUnique(gift: ownedGift, isUpgrade: false, isTransferred: false, savedToProfile: true" not in fake_store_text:
            err.append("FakeGifts: a local collectible purchase does not deliver its gift card")
        fake_gift_view = (
            tg
            / "submodules"
            / "TelegramUI"
            / "Components"
            / "Gifts"
            / "GiftViewScreen"
            / "Sources"
            / "GiftViewScreen.swift"
        )
        fake_gift_view_text = fake_gift_view.read_text(encoding="utf-8") if fake_gift_view.is_file() else ""
        if "if let aorusToggle = controller?.togglePinnedToTop" not in fake_gift_view_text:
            err.append("FakeGifts: local Pin/Unpin no longer uses the established toggle route")
        fake_gifts_list = (
            tg
            / "submodules"
            / "TelegramUI"
            / "Components"
            / "PeerInfo"
            / "PeerInfoVisualMediaPaneNode"
            / "Sources"
            / "GiftsListView.swift"
        )
        fake_gifts_list_text = fake_gifts_list.read_text(encoding="utf-8") if fake_gifts_list.is_file() else ""
        if "private var aorusSenderPeer: EnginePeer?" not in fake_gifts_list_text or "senderPeer: self.aorusSenderPeer" not in fake_gifts_list_text:
            err.append("FakeGifts: profile UI does not attach the loaded sender to local regular gifts")
        if (
            "stargifts_pinned_to_top_limit" not in fake_gifts_list_text
            or "self.pinnedReferences.count >= self.maxPinnedCount" not in fake_gifts_list_text
            or "AorusFakeGiftsStore.setPinned(reference: reference, pinnedToTop)" not in fake_gifts_list_text
            or "self.displayUnpinScreen?(product" not in fake_gifts_list_text
            or "// AorusGram: native detail Hide/Show for local fake gifts" not in fake_gifts_list_text
            or "AorusFakeGiftsStore.updateCollectionOrder(collectionId: collectionId" not in fake_gifts_list_text
            or "let serverOrderedReferences = orderedReferences.filter" not in fake_gifts_list_text
        ):
            err.append("FakeGifts: detail Hide/Show or native Pin/Unpin replacement route is incomplete")
        fake_gifts_pane = (
            tg
            / "submodules"
            / "TelegramUI"
            / "Components"
            / "PeerInfo"
            / "PeerInfoVisualMediaPaneNode"
            / "Sources"
            / "PeerInfoGiftsPaneNode.swift"
        )
        fake_gifts_pane_text = fake_gifts_pane.read_text(encoding="utf-8") if fake_gifts_pane.is_file() else ""
        if (
            "// AorusGram: local fake gift context Pin/Unpin" not in fake_gifts_pane_text
            or "// AorusGram: native mixed-gift replacement screen" not in fake_gifts_pane_text
            or "AorusFakeGiftsStore.setPinned(reference: reference, pinnedToTop)" not in fake_gifts_pane_text
            or "AorusFakeGiftsStore.updatePinnedReferences(updatedPinnedGifts" not in fake_gifts_pane_text
            or "let serverPinnedReferences = updatedPinnedGifts.filter" not in fake_gifts_pane_text
            or "profileGifts.updateStarGiftPinnedToTop(reference: reference, pinnedToTop: pinnedToTop)" not in fake_gifts_pane_text
            or "self.displayUnpinScreen(gift: gift)" not in fake_gifts_pane_text
        ):
            err.append("FakeGifts: native mixed local/server pin replacement is incomplete")
        context_action_markers = (
            "// AorusGram: local fake gift context Wear/TakeOff",
            "// AorusGram: local fake gift context Hide/Show",
            "// AorusGram: local fake gift context Transfer",
            "AorusFakeGiftsStore.setProfileVisibility(reference: reference, added)",
            "AorusFakeGiftsStore.transfer(reference: reference, gift: gift.gift",
            "profileGifts.updateStarGiftAddedToProfile(reference: reference, added: added)",
            "return profileGifts.transferStarGift(prepaid: transferStars == 0, reference: reference, peerId: peerId)",
        )
        if any(marker not in fake_gifts_pane_text for marker in context_action_markers):
            err.append("FakeGifts: long-press Wear/Hide/Transfer routes are incomplete or replace native gift behavior")
        if (
            "strings.Gift_View_Header_TakeOff" not in fake_gifts_pane_text
            or "AorusFakeGiftsStore.isWorn(reference:" not in fake_gifts_pane_text
            or "setEmojiStatus(file: nil, expirationDate: nil)" not in fake_gifts_pane_text
        ):
            err.append("FakeGifts: long-press Wear action does not reflect or clear the local worn state")
        if "case let .slug(slug)" not in fake_store_text:
            err.append("FakeGifts: collectible slug references cannot resolve to local gifts")
        if 'dict["transferStars"] = 0' not in fake_store_text:
            err.append("FakeGifts: local collectibles do not expose Telegram's native Transfer button")
        if (
            "preservePurchasedCollectibleProvenance" not in fake_store_text
            or "if stored.purchasedLocally, let storedGift = stored.gift, case .unique = storedGift" not in fake_store_text
        ):
            err.append("FakeGifts: collectible purchases replace immutable original gift provenance")
        if (
            "// AorusGram: native header Transfer for local fake gifts" not in fake_gifts_list_text
            or "AorusFakeGiftsStore.transfer(reference: reference, gift: product.gift" not in fake_gifts_list_text
            or "return self.profileGifts.transferStarGift(prepaid: prepaid, reference: reference, peerId: peerId)" not in fake_gifts_list_text
        ):
            err.append("FakeGifts: native Transfer header is not routed locally without replacing Telegram's server route")
        fake_gift_view = (
            tg
            / "submodules"
            / "TelegramUI"
            / "Components"
            / "Gifts"
            / "GiftViewScreen"
            / "Sources"
            / "GiftViewScreen.swift"
        )
        fake_gift_view_text = fake_gift_view.read_text(encoding="utf-8") if fake_gift_view.is_file() else ""
        if (
            "if let _ = arguments.transferStars {" not in fake_gift_view_text
            or "presentationData.strings.Gift_View_Context_Transfer" not in fake_gift_view_text
        ):
            err.append("FakeGifts: Telegram's native Transfer overflow action is missing")
        if "StarsContext.State.Transaction.Flags = [.isLocal" in fake_store_text:
            err.append("FakeStars: completed local transactions are incorrectly non-interactive")
        if "if gift != nil { flags.insert(.isGift) }" not in fake_store_text:
            err.append("FakeStars: transaction type flags do not distinguish StarGift from Premium")
        if "revenueGraph: serverStats?.revenueGraph ?? .Empty" not in fake_store_text:
            err.append("FakeStars: native server revenue graph is replaced by local spending data")
        if "public static func statisticsGraph(" in fake_store_text:
            err.append("FakeStars: obsolete custom spending graph is still generated")

    gift_setup = tg / "submodules" / "TelegramUI" / "Components" / "Gifts" / "GiftSetupScreen" / "Sources" / "GiftSetupScreen.swift"
    if not gift_setup.is_file() or "AorusGram: local-only Stars purchase" not in gift_setup.read_text(encoding="utf-8"):
        err.append("FakeStars: native gift/Premium purchase hook is missing")

    gift_buy = tg / "submodules" / "TelegramUI" / "Components" / "Gifts" / "GiftViewScreen" / "Sources" / "GiftViewBuyGift.swift"
    if not gift_buy.is_file() or "AorusGram: local-only collectible purchase" not in gift_buy.read_text(encoding="utf-8"):
        err.append("FakeStars: native collectible purchase hook is missing")

    fake_gifts_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusFakeGiftsController.swift"
    fake_gift_manage_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusFakeGiftManageController.swift"
    fake_gifts_controller_text = fake_gifts_controller.read_text(encoding="utf-8") if fake_gifts_controller.is_file() else ""
    if "AorusFakeGiftsStore.ownProfileGifts()" not in fake_gifts_controller_text:
        err.append("FakeGifts: recipient gifts can leak into the manager list")
    if (
        "genericGift.title?.trimmingCharacters" not in fake_gifts_controller_text
        or 'return (aorusL("Подарок", "Gift"), nil)' not in fake_gifts_controller_text
        or 'genericGift.id)' in fake_gifts_controller_text
    ):
        err.append("FakeGifts: regular gift list does not use Telegram titles without exposing internal ids")
    if not fake_gift_manage_controller.is_file() or "AorusFakeGiftsStore.ownProfileGifts()" not in fake_gift_manage_controller.read_text(encoding="utf-8"):
        err.append("FakeGifts: recipient gifts can leak into the manager editor")
    elif "AorusFakeGiftsStore.remove(instanceId: giftInstanceId)" not in fake_gift_manage_controller.read_text(encoding="utf-8"):
        err.append("FakeGifts: manager does not remove the selected gift instance")

    masks_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusMasksController.swift"
    if not masks_controller.is_file():
        err.append("VideoMasks: mask preset controller is missing")
    else:
        masks_controller_text = masks_controller.read_text(encoding="utf-8")
        if "AorusMaskPresetItemNode: ItemListRevealOptionsItemNode" not in masks_controller_text or "trash.fill" not in masks_controller_text:
            err.append("VideoMasks: custom-mask swipe deletion is incomplete")

    camera_output = tg / "submodules" / "Camera" / "Sources" / "CameraOutput.swift"
    if not camera_output.is_file() or "AorusGram: real-time video mask" not in camera_output.read_text(encoding="utf-8"):
        err.append("VideoMasks: round-video capture hook is missing")
    camera_preview = tg / "submodules" / "Camera" / "Sources" / "CameraPreviewView.swift"
    if not camera_preview.is_file() or "AorusGram: local round-video mask preview" not in camera_preview.read_text(encoding="utf-8"):
        err.append("VideoMasks: local round-video preview overlay is missing")

    call_capturer = tg / "submodules" / "TgVoipWebrtc" / "tgcalls" / "tgcalls" / "platform" / "darwin" / "VideoCameraCapturer.mm"
    if not call_capturer.is_file():
        err.append("VideoMasks: WebRTC camera capturer is missing")
    else:
        call_text = call_capturer.read_text(encoding="utf-8")
        if "AorusGram: real-time outgoing call mask" not in call_text:
            err.append("VideoMasks: outgoing call frame hook is missing")
        if "libyuv::ARGBToI420" not in call_text:
            err.append("VideoMasks: BGRA-to-WebRTC converter is missing")
        if 'int32_t orientation, int32_t mirrored' not in call_text or "@import AorusGram" in call_text:
            err.append("VideoMasks: module-free C bridge is missing")
        if "keep native call preview responsive under mask load" not in call_text or "alwaysDiscardsLateVideoFrames = YES" not in call_text:
            err.append("VideoMasks: outgoing mask processing can still backpressure the native call preview")
    call_preview = tg / "submodules" / "TgVoipWebrtc" / "tgcalls" / "tgcalls" / "platform" / "darwin" / "VideoCaptureView.mm"
    if not call_preview.is_file():
        err.append("VideoMasks: native call preview source is missing")
    else:
        call_preview_text = call_preview.read_text(encoding="utf-8")
        if any(token in call_preview_text for token in (
            "AorusGram: local call mask preview",
            "AorusVideoMaskCreateOverlayView",
            "_aorusMaskOverlayView",
            "AorusGram.AorusVideoMaskOverlayView",
        )):
            err.append("VideoMasks: local call preview still runs the duplicate mask overlay")
        if "[AVCaptureVideoPreviewLayer class]" not in call_preview_text:
            err.append("VideoMasks: local call preview no longer uses Telegram's native preview layer")

    presentation_call = tg / "submodules" / "TelegramCallsUI" / "Sources" / "PresentationCall.swift"
    if not presentation_call.is_file():
        err.append("VideoMasks: PresentationCall.swift is missing")
    else:
        presentation_call_text = presentation_call.read_text(encoding="utf-8")
        if "publish video-mask call phase" not in presentation_call_text or presentation_call_text.count('UserDefaults.standard.set(2, forKey: "aorusgram_video_mask_call_phase")') < 2:
            err.append("VideoMasks: Telegram call lifecycle is not connected to the mask compositor")
        if 'UserDefaults.standard.set(0, forKey: "aorusgram_video_mask_call_phase")' not in presentation_call_text:
            err.append("VideoMasks: call-mask phase is not cleared after calls and conferences")

    login_phone_entry = tg / "submodules" / "AuthorizationUI" / "Sources" / "AuthorizationSequencePhoneEntryController.swift"
    if not login_phone_entry.is_file():
        err.append("LoginBackupKey: phone-entry controller is missing")
    else:
        login_phone_entry_text = login_phone_entry.read_text(encoding="utf-8")
        if "private func aorusInstallBackupKeyButton()" not in login_phone_entry_text:
            err.append("LoginBackupKey: persistent backup-key installer is missing")
        if "!self.otherAccountPhoneNumbers.1.isEmpty || AorusLoginBackupPickerController.hasBackup()" not in login_phone_entry_text:
            err.append("LoginBackupKey: add-account flow is not guaranteed to expose the backup entry")
        if login_phone_entry_text.count("self.aorusInstallBackupKeyButton()") < 3:
            err.append("LoginBackupKey: key is not restored after navigation/layout updates")
        if "private var aorusBackupPickerPresented = false" not in login_phone_entry_text:
            err.append("LoginBackupKey: picker/passkey presentation guard is missing")
        if "guard !self.aorusBackupPickerPresented else { return }" not in login_phone_entry_text:
            err.append("LoginBackupKey: async passkey result can race the backup picker")
        if "isAddingAccount: !self.otherAccountPhoneNumbers.1.isEmpty" not in login_phone_entry_text:
            err.append("LoginBackupKey: add-account mode is not passed to the backup picker")

    login_backup_picker = tg / "submodules" / "AuthorizationUI" / "Sources" / "AorusLoginBackupPicker.swift"
    if not login_backup_picker.is_file():
        err.append("LoginBackupKey: backup picker source is missing")
    else:
        login_backup_picker_text = login_backup_picker.read_text(encoding="utf-8")
        if "No saved accounts yet" not in login_backup_picker_text:
            err.append("LoginBackupKey: empty backup state is missing")
        if "aorusgram_login_backup_selected_account_id" not in login_backup_picker_text:
            err.append("LoginBackupKey: selected backup account is not persisted")
        if "aorusgram_login_backup_add_account" not in login_backup_picker_text:
            err.append("LoginBackupKey: add-account restore mode is not persisted")

    account_backup_manager = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Accounts" / "AccountBackupManager.swift"
    if not account_backup_manager.is_file():
        err.append("LoginBackupKey: account backup manager is missing")
    else:
        account_backup_text = account_backup_manager.read_text(encoding="utf-8")
        for marker, message in (
            ("prepareRestore(selectedAccountId:", "selected-account restore is missing"),
            ("mergeIntoExisting", "add-account merge mode is missing"),
            ("mergedAtomicStateData", "Telegram account-state merge is missing"),
            ("applyPendingAccountMerge", "pending add-account merge is not applied at launch"),
        ):
            if marker not in account_backup_text:
                err.append(f"LoginBackupKey: {message}")

    if "selectedAccountId: selectedAccountId" not in t or "mergeIntoExisting: isAddingAccount" not in t:
        err.append("LoginBackupKey: AppDelegate ignores the selected account or add-account mode")

    # AorusGramBootstrap must run before Telegram creates either an authorized or
    # unauthorized account.  The latter owns the phone/code authorization network,
    # so moving this call below AccountManager would allow a cold-login connection
    # to be created before the fail-closed VLESS requirement is published.
    bootstrap_call = "AorusGramBootstrap.shared.setup(accountPath: rootPath)"
    encryption_anchor = "let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters"
    account_manager_anchor = "let accountManager = AccountManager"
    shared_context_anchor = "SharedAccountContextImpl("
    if bootstrap_call not in t:
        err.append("AppDelegate: missing AorusGramBootstrap.shared.setup() call (feature initialisation)")
    else:
        bootstrap_position = t.index(bootstrap_call)
        for anchor, message in (
            (encryption_anchor, "bootstrap no longer follows encryption/root-path setup"),
            (account_manager_anchor, "bootstrap runs after AccountManager; cold-login VLESS can be bypassed"),
            (shared_context_anchor, "bootstrap runs after SharedAccountContext; cold-login VLESS can be bypassed"),
        ):
            if anchor not in t:
                err.append(f"AppDelegate: source drift, missing ordering anchor {anchor}")
            elif anchor == encryption_anchor and t.index(anchor) > bootstrap_position:
                err.append(f"AppDelegate: {message}")
            elif anchor != encryption_anchor and bootstrap_position > t.index(anchor):
                err.append(f"AppDelegate: {message}")

    # Login completion is event-driven. Fixed launch delays miss users who finish
    # phone/code authorization later and leave the new authorized Network attached
    # to the closed bootstrap endpoint forever.
    for marker in (
        "AorusGram: publish the exact authorized-context transition",
        "self.contextValue = context",
        "AorusRealityManager.shared.ensureRunning()",
        'NSNotification.Name("aorusgram.activeAccountId")',
    ):
        if marker not in t:
            err.append(f"RealityProxy: authorized-account handoff is missing {marker}")
    if "for aorusDelay in [2.0, 5.0, 12.0, 30.0]" in t:
        err.append("RealityProxy: authorized-account handoff still depends on launch timers")
    handoff_assignment = t.find("            self.contextValue = context\n")
    handoff_sentinel = t.find("AorusGram: publish the exact authorized-context transition", handoff_assignment)
    handoff_restart = t.find("AorusRealityManager.shared.ensureRunning()", handoff_sentinel)
    if handoff_assignment < 0 or handoff_sentinel < handoff_assignment or handoff_restart < handoff_sentinel:
        err.append("RealityProxy: authorized-account VLESS handoff is not attached after contextValue assignment")

    license_provider = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Subscription" / "LicenseKeyProvider.swift"
    if not license_provider.is_file():
        err.append("LicenseKeyProvider.swift is missing")
    else:
        license_text = license_provider.read_text(encoding="utf-8")
        if "/*__AORUS_LICENSE_KEY_OBFUSCATED__*/" in license_text:
            err.append("LicenseKeyProvider: build-time key was not injected")
        if "keyChunks" in license_text:
            err.append("LicenseKeyProvider: legacy committed key material is present")
        if "/* AORUS-BUILD-KEY-INJECTED */" not in license_text:
            err.append("LicenseKeyProvider: trusted build-time injection sentinel is missing")

    proxy_manager = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Network" / "AorusProxyManager.swift"
    if not proxy_manager.is_file():
        err.append("AorusProxyManager.swift is missing")
    else:
        proxy_text = proxy_manager.read_text(encoding="utf-8")
        if "/*__AORUS_PROXY_KEY_OBFUSCATED__*/" in proxy_text:
            err.append("AorusProxyManager: build-time proxy key was not injected")
        if "/* AORUS-BUILD-PROXY-KEY-INJECTED */" not in proxy_text:
            err.append("AorusProxyManager: trusted build-time proxy injection sentinel is missing")
        if "URLSession.shared.dataTask(with: request)" in proxy_text:
            err.append("AorusProxyManager: getProxy bypasses the protected API session")
        for marker in (
            "URLSessionConfiguration.ephemeral",
            "delegate: AorusPinnedSessionDelegate.shared",
            "apiSession.dataTask(with: signedRequest)",
            'forHTTPHeaderField: "X-Aorus-Device-Key"',
            'forHTTPHeaderField: "X-Aorus-Device-Proof"',
            "AorusRealityDeviceIdentity.proof",
            "AorusRealityEnvelopeVerifier.decode",
            "worker.schema == 2",
            "(1 ... 300).contains(worker.ttl)",
            'mtprotoUnhealthyKey = "aorusgram_proxy_unhealthy_since"',
            'mtprotoConnectionStateKey = "aorusgram_vless_connection_state"',
            "mtprotoStallThreshold",
            "penalizedEndpoints[endpointKey(activeEndpoint)]",
        ):
            if marker not in proxy_text:
                err.append(f"AorusProxyManager: protected dynamic provision invariant is missing {marker}")
        for forbidden in (
            "ProxyKeychain",
            "ProxyVault",
            "AorusProxyConfig",
            "AorusProxyCandidate",
            "AorusCallProxyConfig",
        ):
            if forbidden in proxy_text:
                err.append(f"AorusProxyManager: legacy persisted/static proxy path remains {forbidden}")

    mt_tcp_connection = tg / "submodules" / "MtProtoKit" / "Sources" / "MTTcpConnection.m"
    if not mt_tcp_connection.is_file():
        err.append("MTProxyAntiDPI: MTTcpConnection.m is missing")
    else:
        mt_tcp_text = mt_tcp_connection.read_text(encoding="utf-8")
        for marker in (
            "generate_ml_kem_public_key",
            "HelloGenerationCommandMlKemKey",
            "HelloGenerationCommandBeginChoice",
            "MTCreateSafariClientHello",
        ):
            if marker not in mt_tcp_text:
                err.append(f"MTProxyAntiDPI: current Safari ClientHello marker is missing {marker}")

    network_source = tg / "submodules" / "TelegramCore" / "Sources" / "Network" / "Network.swift"
    if network_source.is_file():
        network_text = network_source.read_text(encoding="utf-8")
        for marker in (
            'dictionary(forKey: "71d447f8-9128-4d18-b63c-ec11ef43ba26")',
            'dictionary(forKey: "b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca")',
            "aorusRequirementPid?.int32Value == aorusCurrentPid",
            "aorusPid.int32Value == aorusCurrentPid",
            'Bundle.main.bundleURL.pathExtension.lowercased() == "appex"',
            'MTSocksProxySettings(ip: "127.0.0.1"',
            "port: 38190",
            "secret: nil",
        ):
            if marker not in network_text:
                err.append(f"RealityProxy: loopback bridge is missing {marker}")
        for forbidden in (
            "aorusSecret.insert(0xdd, at: 0)",
            "aorusIsPadded",
        ):
            if forbidden in network_text:
                err.append(f"MTProxyAntiDPI: legacy dd downgrade path remains {forbidden}")
        # initializedNetwork() is shared by authorized accounts and by both
        # UnauthorizedAccount creation paths.  Keep the system proxy mutation before
        # MTContext construction so phone-number and code requests cannot escape it.
        proxy_marker = "AorusGram: system proxy overrides any user setting"
        context_anchor = "let context = MTContext"
        if proxy_marker not in network_text:
            err.append("RealityProxy: system proxy injection marker is missing")
        elif context_anchor not in network_text:
            err.append("RealityProxy: Network.swift source drift, MTContext anchor is missing")
        elif network_text.index(proxy_marker) > network_text.index(context_anchor):
            err.append("RealityProxy: system proxy is applied after MTContext creation")

    account_source = tg / "submodules" / "TelegramCore" / "Sources" / "Account" / "Account.swift"
    if not account_source.is_file():
        err.append("RealityProxy: Account.swift is missing")
    else:
        account_text = account_source.read_text(encoding="utf-8")
        for marker in (
            'aorusgram_proxy_config_updated',
            'aorusgram_vless_connection_state',
            '"since": aorusStateSince',
            'aorusConnectionState = "online"',
            'aorusConnectionState = aorusProxyHasIssues ? "proxy_issue" : "connecting"',
            'network.dropConnectionStatus()',
        ):
            if marker not in account_text:
                err.append(f"RealityProxy: runtime enforcement is missing {marker}")
        unauthorized_start = account_text.find("public class UnauthorizedAccount")
        unauthorized_end = account_text.find("func accountNetworkUsageInfoPath", unauthorized_start)
        if unauthorized_start < 0 or unauthorized_end < 0:
            err.append("RealityProxy: UnauthorizedAccount source boundaries are missing")
        else:
            unauthorized_text = account_text[unauthorized_start:unauthorized_end]
            for marker in (
                "AorusGram: hot-apply REALITY to the unauthorized login network",
                "private var aorusProxyObserver: NSObjectProtocol?",
                "private var aorusConnectionStatusDisposable: Disposable?",
                'NSNotification.Name("aorusgram_proxy_config_updated")',
                "network.context.updateApiEnvironment",
                "network.connectionStatus.start",
                '"aorusgram_vless_unauthorized_connection_state"',
                '"since": since',
                "network.dropConnectionStatus()",
                "withUpdatedSocksProxySettings(updated)",
                "NotificationCenter.default.removeObserver(aorusProxyObserver)",
                "self.aorusConnectionStatusDisposable?.dispose()",
            ):
                if marker not in unauthorized_text:
                    err.append(f"RealityProxy: cold-login hot-apply is missing {marker}")
            for forbidden in (
                '"aorusgram_vless_connection_state"',
                '"aorusgram_proxy_unhealthy_since"',
            ):
                if forbidden in unauthorized_text:
                    err.append(f"RealityProxy: cold-login state can overwrite authorized watchdog {forbidden}")
        # Telegram's phone/code screen uses UnauthorizedAccount.  Guard both the
        # persisted-unauthorized and first-account branches against upstream drift.
        if account_text.count("return initializedNetwork(accountId: id") < 3:
            err.append("RealityProxy: Account.swift no longer exposes all initializedNetwork account paths")
        if account_text.count(".unauthorized(UnauthorizedAccount(") < 2:
            err.append("RealityProxy: one of the cold-login UnauthorizedAccount paths is missing")

    call_context = tg / "submodules" / "TelegramVoip" / "Sources" / "OngoingCallContext.swift"
    call_context_text = call_context.read_text(encoding="utf-8") if call_context.is_file() else ""
    if "AorusGram: additive proxied TCP reflector" in call_context_text:
        err.append("CallProxyUDP: obsolete forced TCP media patch is still present")
    for legacy_marker in (
        "AorusGramCallLogs",
        "AorusGram call diagnostics schema:",
        "aorusWriteBoundedCallLog",
        "aorusAppendCallDiagnostic",
    ):
        if legacy_marker in call_context_text:
            err.append(f"CallProxyUDP: removed call-log code is still present {legacy_marker}")

    call_proxy = tg / "submodules" / "TelegramCallsUI" / "Sources" / "AorusCallProxy.swift"
    call_proxy_text = call_proxy.read_text(encoding="utf-8") if call_proxy.is_file() else ""
    for marker in (
        "aorusgram_call_proxy_diagnostics",
        'status: "reality_required_not_ready"',
        'status: "direct_without_subscription"',
        'status: "reality_ready"',
        'udp: "xudp"',
        'host: "127.0.0.1"',
        'aorusRealityEndpointKey = "71d447f8-9128-4d18-b63c-ec11ef43ba26"',
        'aorusRealityRequirementKey = "b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca"',
        "aorusClosedProxyPort",
        'requirementPid = requirement?["pid"] as? NSNumber',
        "requirementPid?.int32Value == currentPid",
        "required?.boolValue == true",
    ):
        if marker not in call_proxy_text:
            err.append(f"CallProxyREALITY: provisioning invariant is missing {marker}")

    web_tunnel = tg / "submodules" / "WebUI" / "Sources" / "AorusWebTunnel.swift"
    web_tunnel_text = web_tunnel.read_text(encoding="utf-8") if web_tunnel.is_file() else ""
    for marker in (
        'aorusTunnelRequirementKey = "b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca"',
        'let pid = requirement["pid"] as? NSNumber',
        "pid.int32Value == ProcessInfo.processInfo.processIdentifier",
        "return required.boolValue",
    ):
        if marker not in web_tunnel_text:
            err.append(f"WebTunnelREALITY: process-bound requirement invariant is missing {marker}")

    atunnel_status = tg / "submodules" / "AorusGramUI" / "Sources" / "ATunnelStatusViewController.swift"
    atunnel_status_text = atunnel_status.read_text(encoding="utf-8") if atunnel_status.is_file() else ""
    for marker in (
        "processBoundTunnelState()",
        'UserDefaults(suiteName: "ng.session.store")',
        'requirement?["pid"] as? NSNumber',
        "requirementPID == currentPID",
        'requirement?["required"] as? NSNumber',
        'endpoint?["pid"] as? NSNumber',
        "endpointPID == currentPID",
        "currentTunnelBlocked()",
    ):
        if marker not in atunnel_status_text:
            err.append(f"ATunnelDiagnostics: process-bound invariant is missing {marker}")

    reality_profile = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Network" / "AorusRealityProfile.swift"
    reality_manager = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Network" / "AorusRealityManager.swift"
    reality_proxy = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Network" / "AorusProxyManager.swift"
    if not reality_profile.is_file() or not reality_manager.is_file() or not reality_proxy.is_file():
        err.append("RealityProxy: embedded core sources are missing")
    else:
        reality_profile_text = reality_profile.read_text(encoding="utf-8")
        reality_manager_text = reality_manager.read_text(encoding="utf-8")
        reality_proxy_text = reality_proxy.read_text(encoding="utf-8")
        for marker in (
            "AorusRealityEnvelopeVerifier",
            "Curve25519.Signing.PublicKey",
            "AorusRealityDeviceIdentity",
            "ecdsaSignatureMessageX962SHA256",
            "envelope.requestNonce",
        ):
            if marker not in reality_profile_text:
                err.append(f"RealityProxy: dynamic profile invariant is missing {marker}")
        for forbidden in (
            "AorusRealityProfileProvider",
            "__AORUS_REALITY_PROFILE_",
            "AORUS-BUILD-REALITY-PROFILE-INJECTED",
        ):
            if forbidden in reality_profile_text:
                err.append(f"RealityProxy: static profile path remains {forbidden}")
        for marker in (
            "import LibXray",
            '"runXrayFromJson"',
            '"packetEncoding": "xudp"',
            '"security": "reality"',
            'publishRequirement(required: authorizationAllowsTunnel)',
            '"required": required',
            "AorusSessionMetrics.metricFlag",
            "waitForCoreAndLocalSocks(",
            "localSocksIsReady(port:",
            "realityPreflight(port:",
            "telegramPreflightTargets",
            "reality_preflight_ready",
            "reality_preflight_failed",
            "local_socks_connect_timeout",
            "local_socks_negotiation_timeout",
            "reality_connect_timeout",
            "var isRemotePathFailure: Bool",
            "case .tunnelConnectFailed, .tunnelConnectTimedOut:",
            "socksConnectRequest(host:",
            "aorusgram_reality_bootstrap_trace",
            "profileDidVerify()",
            "recordEndpointProbe(priority:",
            "bridge_tcp_reachable",
            "profile_applied",
            "realityEndpointDidFail(endpoint)",
            "rankedEndpoints.remove(at: index)",
            "rankedEndpoints.append(endpoint)",
            "rankedEndpoints = [endpoint] + rankedEndpoints.filter",
            "Data([0x05, 0x01, 0x00])",
            "Data([0x05, 0x00])",
            "waitForCoreStop()",
            "restartRetryDelays",
            "scheduleRestartRetryLocked()",
            "cancelRestartRetryLocked(resetAttempt: true)",
            "let endpointOrder = rankedEndpoints.isEmpty ? profile.validEndpoints : rankedEndpoints",
            "let activeEndpoint = self.activeEndpoint",
            "nextRanked.contains(activeEndpoint)",
            "previousCredential == profile.credential",
            # Selection speed. One preflight budget cannot both sweep candidates cheaply and
            # wait out a slow radio, so there are three, and only the endpoints that ran out
            # of time earn the patient retry. Collapsing them back to one figure is how a
            # blocked bridge became half a minute of a client that looks offline.
            "preflightFastTimeout",
            "preflightPatientTimeout",
            "preflightConfirmTimeout",
            "case slowRemotePath",
            "for endpoint in slowEndpoints",
            "localPortIsAvailable(localPort)",
            # A watchdog failover has to be able to move: without this the core defends the
            # endpoint it was called about, because its own preflight still passes.
            "reselectEndpoint: Bool = false",
            "!reselectEndpoint,",
        ):
            if marker not in reality_manager_text:
                err.append(f"RealityProxy: core invariant is missing {marker}")
        for marker in (
            # Start on the signed order, measure afterwards. Ranking before the first apply()
            # leaves Telegram with no route for the whole sweep, which is the cold start that
            # never receives a login code.
            "provisionalOrder(profile.validEndpoints)",
            "defendActive: false",
            "rememberGoodEndpoint(endpoint)",
            "reselectEndpoint: reselectEndpoint",
            "reprobeCurrentProfile(reselectEndpoint: true)",
            # Nothing to fail over to is the state this watchdog exists for, not a reason to
            # give up on it.
            "AorusRealityManager.shared.ensureRunning()",
        ):
            if marker not in reality_proxy_text:
                err.append(f"RealityProxy: recovery invariant is missing {marker}")
        provisional_index = reality_proxy_text.find("apply(profile: profile, rankedEndpoints: provisional)")
        sweep_index = reality_proxy_text.find("rankEndpoints(profile.validEndpoints, defendActive: false)")
        if provisional_index < 0 or sweep_index < 0 or sweep_index < provisional_index:
            err.append("RealityProxy: endpoint ranking runs before Telegram is given a route")
        keep_start = reality_manager_text.find("if previousCredential == profile.credential")
        keep_end = reality_manager_text.find('self.recordDiagnostic(stage: "profile_applied")', keep_start)
        keep_block = reality_manager_text[keep_start:keep_end]
        if "let preflight = self.realityPreflight(" not in keep_block or "canKeepRunning = preflight == .ready" not in keep_block:
            err.append("RealityProxy: active endpoint can survive reranking without a fresh full preflight")
        for marker in (
            "AorusRealityManager.shared.profileDidVerify()",
            "AorusRealityManager.shared.recordEndpointProbe(",
            "func realityEndpointDidFail(_ endpoint:",
            "penalizedEndpoints[endpointKey(endpoint)]",
        ):
            if marker not in reality_proxy_text:
                err.append(f"RealityProxy: provisioner trace invariant is missing {marker}")
        preflight_index = reality_manager_text.find("let preflight = realityPreflight(")
        publish_index = reality_manager_text.find("publishEndpoint(port: localPort)", preflight_index)
        if preflight_index < 0 or publish_index < 0 or publish_index < preflight_index:
            err.append("RealityProxy: endpoint can be published before full tunnel preflight")
        if 'normalizedAddress != "0.0.0.0"' not in reality_profile_text:
            err.append("RealityProxy: endpoint validation accepts an unspecified address")

    # The runtime integrity guard must not leak what it is. It was defeated once because
    # every jailbreak path and framework name shipped as a plain literal and the type and
    # methods were named after what they detect — `strings | grep -i cydia|frida` found the
    # lot. The generator obfuscates the literals and neutralises the symbol names; pin that
    # so a hand-edit cannot quietly reintroduce a give-away.
    guard_src = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "Security" / "AorusTamperGuard.swift"
    guard_app = Path(__file__).parent.parent / "AorusGram" / "Sources" / "Security" / "AorusTamperGuard.swift"
    for guard in (guard_src, guard_app):
        if not guard.is_file():
            err.append(f"TamperGuard: {guard.name} is missing")
            continue
        gtext = guard.read_text(encoding="utf-8")
        if "GENERATED by scripts/gen_tamper_guard.py" not in gtext:
            err.append(f"TamperGuard: {guard} is not the generated file — run gen_tamper_guard.py")
        # No plaintext indicator may appear as a Swift string literal (comments are fine —
        # they are stripped at compile). Scan only for the telltale words inside quotes and
        # in identifier positions.
        code_lines = [ln for ln in gtext.splitlines() if not ln.lstrip().startswith("//")]
        code = "\n".join(code_lines)
        for leak in ("Cydia", "MobileSubstrate", "frida", "Frida", "jailbreak", "Jailbreak",
                     "ellekit", "cynject", "AorusTamperGuard", "isFridaDetected", "markFrida",
                     "Powered by Claude", "AORUS-AUTH"):
            if leak in code:
                err.append(f"TamperGuard: {guard.name} leaks '{leak}' outside comments")
    # The two modules differ by design: only AorusGram has the accumulator. The UI copy must
    # not reference it (that type does not exist in its module — it would fail to compile).
    if guard_app.is_file() and "AorusSessionCounter.shared.increment()" not in guard_app.read_text(encoding="utf-8"):
        err.append("TamperGuard: the app copy no longer feeds the accumulator")
    if guard_src.is_file() and "AorusSessionCounter" in guard_src.read_text(encoding="utf-8"):
        err.append("TamperGuard: the UI copy references the accumulator, which does not exist in its module")

    aorus_build = tg / "submodules" / "AorusGram" / "BUILD"
    aorus_build_text = aorus_build.read_text(encoding="utf-8") if aorus_build.is_file() else ""
    for marker in ("apple_static_xcframework_import", 'name = "LibXray"', '":LibXray"'):
        if marker not in aorus_build_text:
            err.append(f"RealityProxy: Bazel libXray import is missing {marker}")
    xray_info = tg / "submodules" / "AorusGram" / "ThirdParty" / "LibXray.xcframework" / "Info.plist"
    if not xray_info.is_file():
        err.append("RealityProxy: pinned LibXray.xcframework was not staged")

    call_log_export = tg / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusCallLogsExport.swift"
    if call_log_export.exists():
        err.append("CallLogsExport: removed exporter source is still present")

    presentation_call_manager = (
        tg / "submodules" / "TelegramCallsUI" / "Sources" / "PresentationCallManager.swift"
    )
    presentation_call_text = (
        presentation_call_manager.read_text(encoding="utf-8")
        if presentation_call_manager.is_file()
        else ""
    )
    if "ignore the per-user useForCalls toggle" not in presentation_call_text:
        err.append("CallProxyUDP: active proxy is no longer forced for calls")

    native_networking = (
        tg
        / "submodules"
        / "TgVoipWebrtc"
        / "tgcalls"
        / "tgcalls"
        / "v2"
        / "NativeNetworkingImpl.cpp"
    )
    native_networking_text = native_networking.read_text(encoding="utf-8") if native_networking.is_file() else ""
    if "AorusGram: apply SOCKS5 proxy to the port allocator" not in native_networking_text:
        err.append("CallProxyUDP: v2 port allocator does not receive the SOCKS5 proxy")
    if "AorusGram: keep UDP reflector relay enabled for SOCKS5" not in native_networking_text:
        err.append("CallProxyUDP: proxied reflector UDP remains disabled")

    reflector_port = (
        tg
        / "submodules"
        / "TgVoipWebrtc"
        / "tgcalls"
        / "tgcalls"
        / "v2"
        / "ReflectorPort.cpp"
    )
    reflector_text = reflector_port.read_text(encoding="utf-8") if reflector_port.is_file() else ""
    for marker in (
        "AorusGram SOCKS5 UDP diagnostics schema: 3",
        "class AorusSocks5UdpProxySocket final",
        "SOCKS5 UDP ASSOCIATE",
        "proxy().type == rtc::ProxyType::PROXY_SOCKS5",
        "first UDP payload sent",
        "first UDP payload received",
        "rejected relay datagram source=",
        "malformed relay datagram reason=",
        "controlPeer=",
        "pre-handshake queue",
        "unexpectedRelayPackets",
        "malformedPackets",
        "LogSummary",
    ):
        if marker not in reflector_text:
            err.append(f"CallProxyUDP: reflector transport is missing {marker}")
    if "class AorusSocks5ProxySocket" in reflector_text:
        err.append("CallProxyUDP: obsolete TCP SOCKS5 reflector wrapper is still present")
    # The relay is the in-process VLESS core, so it answers on loopback. A media
    # socket bound to the interface address cannot reach it, and the failure is
    # silent — the call negotiates and carries nothing. Pin the bind decision.
    for marker in (
        "const bool aorusProxyIsLocal = aorusUsesSocks5 && proxy().address.IsLoopbackIP();",
        "? rtc::SocketAddress(proxy().address.ipaddr(), 0)",
        "socket_factory()->CreateUdpSocket(aorusUdpBindAddress, min_port(), max_port());",
    ):
        if marker not in reflector_text:
            err.append(f"CallProxyUDP: loopback media bind is missing {marker}")
    if "CreateUdpSocket(rtc::SocketAddress(Network()->GetBestIP(), 0), min_port(), max_port())" in reflector_text:
        err.append("CallProxyUDP: media socket still binds unconditionally to the interface address")

    chat_lock = tg / "submodules" / "AorusGramUI" / "Sources" / "Features" / "Privacy" / "AorusChatLock.swift"
    chat_lock_text = chat_lock.read_text(encoding="utf-8") if chat_lock.is_file() else ""
    for marker in (
        "enabledKey(accountId:",
        "peersKey(accountId:",
        "aorusChatLockIsProtected(_ accountId:",
        "aorusChatLockAuthenticate(_ accountId:",
        "completion(false)",
    ):
        if marker not in chat_lock_text:
            err.append(f"ChatProtection: account-scoped fail-closed invariant is missing {marker}")

    chat_list_controller = tg / "submodules" / "ChatListUI" / "Sources" / "ChatListController.swift"
    chat_list_controller_text = chat_list_controller.read_text(encoding="utf-8") if chat_list_controller.is_file() else ""
    if "aorusChatLockRequiresAuth(strongSelf.context.account.id.int64, aorusPeer.id.toInt64())" not in chat_list_controller_text:
        err.append("ChatProtection: preview gate must reuse Telegram's unwrapped strongSelf")
    if "AorusGram: Chat Lock — never reveal" in chat_list_controller_text and "guard let self else" in chat_list_controller_text[
        chat_list_controller_text.find("AorusGram: Chat Lock — never reveal"):
        chat_list_controller_text.find("AorusGram: Chat Lock — never reveal") + 500
    ]:
        err.append("ChatProtection: preview gate introduces a duplicate self unwrap")

    chat_search = tg / "submodules" / "ChatListUI" / "Sources" / "ChatListSearchListPaneNode.swift"
    chat_search_text = chat_search.read_text(encoding="utf-8") if chat_search.is_file() else ""
    if "aorusChatLockRequiresAuth(context.account.id.int64, aorusMessageId.peerId.toInt64())" not in chat_search_text:
        err.append("ChatProtection: search filter must use the captured non-optional account context")
    if "aorusChatLockRequiresAuth(self.context.account.id.int64, aorusMessageId.peerId.toInt64())" in chat_search_text:
        err.append("ChatProtection: search filter dereferences optional self")

    chat_list_item = tg / "submodules" / "ChatListUI" / "Sources" / "Node" / "ChatListItem.swift"
    chat_list_item_text = chat_list_item.read_text(encoding="utf-8") if chat_list_item.is_file() else ""
    for marker in (
        "AorusGram: Chat Protection — hide drafts while locked",
        "draftState = aorusHideProtectedDraft ? nil : draftStateValue",
        "mediaDraftContentType = aorusHideProtectedDraft ? nil : peerData.mediaDraftContentType",
    ):
        if marker not in chat_list_item_text:
            err.append(f"ChatProtection: locked chat rows can still leak drafts — missing {marker}")

    # The retired Chat Summary must not leave a switch, state flag, localization, feature
    # identifier, or compiled manager behind in the copied AorusGram module.
    aorusgram_root = tg / "submodules" / "AorusGramUI" / "Sources"
    retired_summary_tokens = ("chatSummary", "chat_summary", "Chat Summary", "Сводка чата")
    if aorusgram_root.is_dir():
        for swift_path in aorusgram_root.rglob("*.swift"):
            swift_text = swift_path.read_text(encoding="utf-8")
            for token in retired_summary_tokens:
                if token in swift_text:
                    err.append(f"ChatSummary: retired feature token remains in {swift_path.name}: {token}")
    if (aorusgram_root / "Features" / "AI" / "ChatSummaryManager.swift").exists():
        err.append("ChatSummary: retired manager is still compiled")

    recent_sticker_paths = (
        tg / "submodules" / "TelegramCore" / "Sources" / "State" / "SynchronizeRecentlyUsedMediaOperations.swift",
        tg / "submodules" / "TelegramCore" / "Sources" / "State" / "ApplyUpdateMessage.swift",
        tg / "submodules" / "TelegramCore" / "Sources" / "State" / "AccountStateManagementUtils.swift",
    )
    for recent_path in recent_sticker_paths:
        recent_text = recent_path.read_text(encoding="utf-8") if recent_path.is_file() else ""
        if "AorusGram: unlimited recent stickers" not in recent_text:
            err.append(f"RecentStickers: unlimited-history marker missing from {recent_path.name}")
        for line in recent_text.splitlines():
            if "CloudRecentStickers" in line and "removeTailIfCountExceeds: 20" in line:
                err.append(f"RecentStickers: stock 20-item limit remains in {recent_path.name}")
    managed_recent = tg / "submodules" / "TelegramCore" / "Sources" / "State" / "ManagedRecentStickers.swift"
    managed_recent_text = managed_recent.read_text(encoding="utf-8") if managed_recent.is_file() else ""
    for marker in (
        "AorusGram: hash only Telegram's cloud window",
        "itemIds = Array(itemIds.prefix(20))",
        "AorusGram: unlimited recent stickers — retain the local tail",
        "transaction.getOrderedListItems(collectionId: collectionId)",
        "mergedIds.insert(localId).inserted",
    ):
        if marker not in managed_recent_text:
            err.append(f"RecentStickers: cloud synchronization can truncate local history — missing {marker}")

    clipboard_history = tg / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusClipboardHistory.swift"
    clipboard_text = clipboard_history.read_text(encoding="utf-8") if clipboard_history.is_file() else ""
    for marker in (
        "clipboard-history.json",
        "completeUntilFirstUserAuthentication",
        "maxStoredBytes",
        "retention:",
    ):
        if marker not in clipboard_text:
            err.append(f"ClipboardHistory: protected bounded storage is missing {marker}")

    wall = tg / "submodules" / "TelegramUI" / "Sources" / "AorusWall.swift"
    wall_text = wall.read_text(encoding="utf-8") if wall.is_file() else ""
    for marker in (
        "title: AorusL10n.current.wallRefresh",
        'image: UIImage(systemName: "gearshape")',
        "private func aorusFilledHouseTabImage(color: UIColor)",
        'UIImage(systemName: "house.fill", withConfiguration: configuration)',
        "context.cgContext.setBlendMode(.clear)",
        "controller.tabBarItem.image = aorusFilledHouseTabImage(",
        "controller.tabBarItem.selectedImage = aorusFilledHouseTabImage(",
        # The tab bar draws plain images with `tintColor: nil` (only Lottie-backed stock tabs
        # get themed), so the house must be rendered in the theme colour and refreshed when
        # the theme changes — otherwise it stays the inherited tint (white) forever.
        "tabBarTheme.iconColor",
        "tabBarTheme.selectedIconColor",
    ):
        if marker not in wall_text:
            err.append(f"Wall: stable native header/tab integration is missing {marker}")
    for marker in (
        "recommendedChannels(peerId: nil)",
        "for peerId in peerIds",
        "addAdditionalPreloadHistoryPeerId(peerId: peerId)",
        "transaction.aorusWallMessages(",
        "private var expansionPreloadDisposable = DisposableSet()",
        "self.expansionPreloadDisposable = DisposableSet()",
        "self?.expansionPreloadDisposable.remove(preload)",
        "discoveredRecommendationPeerIds",
        "private static let subscribedScanBatch = 24",
        "private static let recommendedScanBatch = 24",
        "private static let maxExpansionAdditions = 8",
        "private static let minimumHealthySourceCount = 8",
        "currentSourceCounts",
        "var candidatesByRank:",
        "appendTier(prioritySources)",
        "messages.sort(by: { $0.index < $1.index })",
        "removingExactCrossChannelTextDuplicates",
        "groups[Data(message.text.utf8), default: []]",
        "Set(group.map { $0.id.peerId }).count > 1",
        "messages = self.removingExactCrossChannelTextDuplicates(",
        "preserving: preserveCurrent ? Set(self.currentMessageIds) : []",
        "return self.observedMessageIds.union(self.previousVisibleMessageIds)",
        "!self.viewportMessageIds.contains(message.id)",
        # topUp derives the frontier once and reuses it for both gates and the request —
        # readerFrontier walks the whole feed, and asking for it three times per top-up was
        # pure waste. The invariant that matters is that the page is requested at the
        # reader's frontier, not the expression it was spelled with.
        # Reactions and poll votes are the reader's own action and must publish at once;
        # a bare stableVersion bump is a view counter and is batched, because every publish
        # costs a full-feed diff on the main thread.
        "let aorusIsUrgent = existingReactions != updatedReactions || pollDidChange",
        "if didChangeUrgently {",
        "self.queue.after(Impl.deferredContentPublishDelay)",
        # Trimming must never reach the rows around the viewport.
        "!aorusProtectedIds.contains(message.id)",
        "private static let trimSafetyMargin = 80",
        "let frontier = self.readerFrontier",
        "guard let requestedFrontier = frontier else {",
        "collectPage(frontier: requestedFrontier, span: span)",
        "appendableMessages.removeAll(where: { !($0.index < appendFrontier) })",
        "func settingsDidChange()",
        "self.updateRecommendationsIfNeeded(forceRefresh: true)",
        "let pollDidChange: Bool",
        "pollDidChange = !existingPoll.isEqual(to: updatedPoll)",
        "|| pollDidChange",
    ):
        if marker not in wall_text:
            err.append(f"Wall: recommendation/top-to-bottom pipeline is missing {marker}")
    for forbidden in (
        "transaction.scanTopMessages(",
        "private let expansionPreloadDisposable = DisposableSet()",
        "for peerId in Set(peerIds) {",
        "page.sort(by: { $0.index > $1.index })",
    ):
        if forbidden in wall_text:
            err.append(f"Wall: obsolete pagination/ranking path is still present {forbidden}")

    # An excluded channel must be gone from every stage, not merely filtered out of a page:
    # it may not be recommended, preloaded, or used as a seed for similar channels.
    for marker in (
        "func applyExclusions()",
        "seedPool = seedPool.filter { !self.isExcluded($0) }",
        "!self.discoveredRecommendationPeerIds.contains($0) && !self.isExcluded($0)",
        "let filtered = current.filter { !excluded.contains($0.id.peerId.toInt64()) }",
        "self.applyMessages(filtered, updateType: .Generic, preserveCurrent: false)",
        "self.applyExclusions()",
    ):
        if marker not in wall_text:
            err.append(f"Wall: channel exclusions are not enforced across sources — missing {marker}")
    if "self?.reload()" in wall_text:
        err.append("Wall: settings observer still rebuilds the feed and can teleport the viewport")
    if "transaction.scanTopMessages(" in wall_text or "badgeScanBudget" in wall_text:
        err.append("Wall: badge must use the rendered Wall snapshot, not a global Postbox scan")
    if "badgeTimer" in wall_text:
        err.append("Wall: redundant periodic badge timer is still present")
    for marker in (
        "private func publishCurrentBadge()",
        "self.currentMessageIds.count - self.markedInCurrentView.count",
    ):
        if marker not in wall_text:
            err.append(f"Wall: single-source badge publication is missing {marker}")

    account_details = tg / "submodules" / "AorusGramUI" / "Sources" / "AccountDetailsController.swift"
    account_details_text = account_details.read_text(encoding="utf-8") if account_details.is_file() else ""
    for marker in (
        'value.split(separator: ".")',
        "private enum AorusPeerNoteStore",
        "private func aorusNoteEditorController(",
        "peerKey: Int64",
        "registrationDate: String?",
        "valuePromise.set(value.modify { _ in normalized })",
        "let secondsPerId = (last.1 - previous.1) / Double(idSpan)",
        "var persistedToFile = false",
    ):
        if marker not in account_details_text:
            err.append(f"AccountDetails: official registration date / peer notes are missing {marker}")
    for forbidden in (
        "valuePromise.set(value.swap(",
        "Telegram не предоставил месяц регистрации",
        "Telegram did not provide a registration month",
    ):
        if forbidden in account_details_text:
            err.append(f"AccountDetails: stale note/date fallback remains {forbidden}")

    peer_info_items = tg / "submodules" / "TelegramUI" / "Components" / "PeerInfo" / "PeerInfoScreen" / "Sources" / "PeerInfoProfileItems.swift"
    peer_info_items_text = peer_info_items.read_text(encoding="utf-8") if peer_info_items.is_file() else ""
    if peer_info_items_text.count("// AorusGram: account details v2") != 3:
        err.append("AccountDetails: expected one current injection for user, channel and group")
    for marker in (
        "let aorusPeerKey =",
        "let aorusRegistrationDate: String? =",
        "peerStatusSettings?.registrationDate",
        "peerKey: aorusPeerKey",
        "registrationDate: aorusRegistrationDate",
    ):
        if marker not in peer_info_items_text:
            err.append(f"AccountDetails: PeerInfo integration is missing {marker}")

    wall_settings = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusWallSettingsController.swift"
    wall_settings_text = wall_settings.read_text(encoding="utf-8") if wall_settings.is_file() else ""
    if wall_settings_text.count("object: NSNumber(value: accountId)") < 4:
        err.append("Wall: settings notifications are not scoped to their account")

    # Translations are keyed by the English string, so a key that no longer matches a literal
    # in the source silently falls back to English and the language looks half-done. Check each
    # table against its source, including the %@ placeholders.
    # The source list is discovered, not hardcoded: a new screen that calls aorusL() has to
    # land in the table automatically, otherwise the first time anyone forgets, six languages
    # quietly fall back to English and nothing complains.
    aorusgram_ui = tg / "submodules" / "AorusGramUI" / "Sources"
    aorus_module = tg / "submodules" / "AorusGram" / "Sources"
    subscription_dir = aorus_module / "Features" / "Subscription"
    aorusgram_ui_sources = sorted(aorusgram_ui.rglob("*.swift")) if aorusgram_ui.is_dir() else []
    for swift_file in sorted((tg / "submodules").rglob("*.swift")):
        if "AorusGramUI" in swift_file.parts:
            continue
        if "aorusL(" in swift_file.read_text(encoding="utf-8", errors="replace"):
            aorusgram_ui_sources.append(swift_file)
    subscription_sources = [subscription_dir / "SubscriptionL10n.swift"]
    if aorus_module.is_dir():
        subscription_sources += [
            p for p in sorted(aorus_module.rglob("*.swift")) if "SubL10n.t(" in p.read_text(encoding="utf-8", errors="replace")
        ]
    # The patch script writes strings straight into Telegram's own files. Reading them from
    # the script rather than from the patched tree keeps the check honest either way: if a
    # patch silently failed to apply, its keys must still be present, not reported stale.
    branding_source = Path(__file__).with_name("aorus_branding.py")
    injected_literals: set[str] = set()
    if branding_source.is_file():
        branding_body = branding_source.read_text(encoding="utf-8")
        injected_literals = {
            match.group(2)
            for match in re.finditer(
                # No closing paren in the pattern: aorusL also takes an explicit language
                # as a third argument, and requiring ')' would drop those keys and then
                # report them stale.
                r'aorusL\(\\?"((?:[^"\\]|\\.)*?)\\?"\s*,\s*\\?"((?:[^"\\]|\\.)*?)\\?"', branding_body
            )
        } - {"{en}"}
        # Some injections build the Russian side from a Python variable, so only the English
        # literal is visible in the script text: aorusL(\"" + ru_title + "\", \"Transfer Gift\").
        injected_literals |= {
            match.group(1)
            for match in re.finditer(r'\+\s*"\\",\s*\\"((?:[^"\\]|\\.)*?)\\"\)', branding_body)
        }
        icons = re.search(r"ICONS = \[(.*?)\n    \]", branding_body, re.S)
        if icons:
            injected_literals |= {
                english
                for _, _, english, _ in re.findall(
                    r'\("([^"]*)",\s*"([^"]*)",\s*"([^"]*)",\s*(True|False)\)', icons.group(1)
                )
            }

    # aorusGramL() is the AorusGram module's public front door, used by the strings patched
    # into AppDelegate; its literals live in the script, not in a tracked source file.
    aorus_gram_injected: set[str] = set()
    if branding_source.is_file():
        aorus_gram_injected = {
            match.group(2)
            for match in re.finditer(
                r'aorusGramL\(\\?"((?:[^"\\]|\\.)*?)\\?"\s*,\s*\\?"((?:[^"\\]|\\.)*?)\\?"',
                branding_body,
            )
        }

    translation_pairs = (
        (
            "subscription",
            subscription_sources,
            subscription_dir / "SubscriptionL10nTable.swift",
            aorus_gram_injected,
        ),
        (
            "AorusGramUI",
            aorusgram_ui_sources,
            aorusgram_ui / "Core" / "AorusL10nTable.swift",
            injected_literals,
        ),
    )
    for area, src_paths, tbl_path, extra_literals in translation_pairs:
        present = [p for p in src_paths if p.is_file()]
        if not present or not tbl_path.is_file():
            continue
        tbl_text = tbl_path.read_text(encoding="utf-8")
        # Both the per-screen `t(ru, en)` helpers and the free `aorusL(ru, en)` used by the
        # converted inline call sites resolve through the same table.
        english_literals = set()
        for src_path in present:
            src_body = src_path.read_text(encoding="utf-8")
            for pattern in (
                # t(ru, en) on the per-screen helpers, the free aorusL(ru, en), SubL10n.t()
                # in the AorusGram module and title(ru, en, isRu) in the metadata screen all
                # resolve through one table. AccountBackupManager's localized() deliberately
                # does not: that file must stay byte-identical across two modules, so it
                # carries its own table and is excluded here.
                r'\b(?:t|aorusL|title)\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"',
                # AorusLinkProtection carries its risk texts as ru:/en: template pairs and
                # feeds them to aorusL() at display time.
                r'\bru:\s*"((?:[^"\\]|\\.)*)"\s*,\s*\n?\s*en:\s*"((?:[^"\\]|\\.)*)"',
            ):
                english_literals |= {
                    match.group(2) for match in re.finditer(pattern, src_body, re.S)
                }
        english_literals |= extra_literals
        for literal in english_literals:
            if "\\(" in literal:
                err.append(
                    f"Language: {area} string is interpolated before translation, "
                    f"its key can never match — {literal}"
                )
        for name, body in re.findall(
            r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", tbl_text, re.S
        ):
            ordered = re.findall(r'^\s*"((?:[^"\\]|\\.)*)":', body, re.M)
            # A repeated key in a Swift dictionary literal is not a compile error — it traps
            # at launch with "Dictionary literal contains duplicate keys".
            for repeated in sorted({k for k in ordered if ordered.count(k) > 1}):
                err.append(f"Language: {name} {area} table lists {repeated!r} twice")
            keys = set(ordered)
            for missing in sorted(english_literals - keys):
                err.append(f"Language: {name} {area} translation is missing {missing!r}")
            for stale in sorted(keys - english_literals):
                err.append(f"Language: {name} {area} table has a stale key {stale!r}")
            # A value that drops a placeholder renders "Active until" with no date at all.
            # Strings carrying two values number them %1 and %2 instead of repeating %@.
            for key, value in re.findall(
                r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', body, re.M
            ):
                for token in ("%@", "%1", "%2", "%3"):
                    if key.count(token) != value.count(token):
                        err.append(
                            f"Language: {name} {area} translation of {key!r} loses its {token} placeholder"
                        )

    # A multi-line quote must reach the server as one BlockQuote entity. Upstream splits it
    # per line and its own merge pass cannot join the pieces, so the fix has to be present:
    # without it every quote of more than one line is sent as a stack of one-line quotes.
    entities_file = tg / "submodules" / "TextFormat" / "Sources" / "GenerateTextEntities.swift"
    if entities_file.is_file():
        entities_text = entities_file.read_text(encoding="utf-8")
        for marker in ("aorusQuotesJoin", "aorusQuoteText.character(at: lower) == 0x0a"):
            if marker not in entities_text:
                err.append(f"BlockQuote: multi-line quotes are still split — missing {marker}")
        # The upstream loop opens with `if case .BlockQuote` and breaks out after the first
        # one; the fix opens with `guard case .BlockQuote ... else { continue scan }`. The
        # neighbouring .Pre loop has the same shape and must not be matched, so pin the
        # blockquote line itself rather than the shared `break scan`.
        if "if case .BlockQuote = entities[i].type {" in entities_text:
            err.append("BlockQuote: the upstream merge pass still stops at the first quote")

    # The picker is a leaf module and carries its own copy of the nine strings it shows,
    # generated from AorusL10nTable. Re-check the two agree: a translation fixed in the main
    # phrase book but not regenerated here would leave the call screen showing the old wording,
    # and nothing else in the build would notice.
    mask_strings = Path(__file__).parent.parent / "patches" / "submodules" / "AorusMaskPicker" / "Sources" / "AorusMaskStrings.swift"
    main_table = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusL10nTable.swift"
    if mask_strings.is_file() and main_table.is_file():
        picker_text = mask_strings.read_text(encoding="utf-8")
        table_text = main_table.read_text(encoding="utf-8")
        wanted = {
            "_button": "Mask", "skull": "Crystal Skull", "cyber": "Cyber Visor",
            "oni": "Oni Mask", "phantom": "Phantom", "chrome": "Liquid Chrome",
            "aurora": "Aurora", "neonCat": "Neon Cat", "custom": "My Mask",
        }
        raw_codes = {"zhHans": "zh-hans", "zhHant": "zh-hant"}
        picker_tables = {
            m.group(1): dict(re.findall(r'^\s*"([\w_]+)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', m.group(2), re.M))
            for m in re.finditer(r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", picker_text, re.S)
        }
        for name, body in re.findall(r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", table_text, re.S):
            source = dict(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', body, re.M))
            mirrored = picker_tables.get(name)
            if mirrored is None:
                err.append(f"MaskPicker: AorusMaskStrings has no {name} table — regenerate it")
                continue
            for key, english in wanted.items():
                if source.get(english) != mirrored.get(key):
                    err.append(
                        f"MaskPicker: {name} {english!r} differs between AorusL10nTable and "
                        f"AorusMaskStrings — regenerate the picker's table"
                    )
        missing_codes = [c for c in raw_codes.values() if f'"{c}": ' not in picker_text]
        if missing_codes:
            err.append(f"MaskPicker: AorusMaskStrings is missing language codes {missing_codes}")

        # Russian and English never reach AorusL10nTable — they are written inline at the call
        # site — so the loop above cannot see them. Check them against that inline source, or a
        # reworded Russian mask name would drift here unnoticed.
        inline_source = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusL10n.swift"
        if inline_source.is_file():
            inline_text = inline_source.read_text(encoding="utf-8")
            picker_ru = picker_tables.get("ru", {})
            picker_en = dict(re.findall(
                r'^\s*"([\w_]+)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$',
                re.search(r"static let english: \[String: String\] = \[(.*?)\n    \]", picker_text, re.S).group(1)
                if re.search(r"static let english: \[String: String\] = \[(.*?)\n    \]", picker_text, re.S) else "",
                re.M))
            for key, english in wanted.items():
                match = re.search(r't\("((?:[^"\\]|\\.)*)",\s*"%s"\)' % re.escape(english), inline_text)
                if match is None:
                    err.append(f"MaskPicker: no inline source for {english!r} — the generator cannot run")
                elif picker_ru.get(key) != match.group(1):
                    err.append(f"MaskPicker: Russian {english!r} differs from AorusL10n — regenerate the picker's table")
                if picker_en.get(key) != english:
                    err.append(f"MaskPicker: English {english!r} differs in AorusMaskStrings — regenerate the picker's table")

    # Mini apps are the one surface with its own network stack: WKWebView never sees the
    # proxy TelegramCore is pointed at. All four parts have to land or the mini app quietly
    # becomes the only traffic leaving on a direct route, which nothing else would catch.
    web_tunnel = tg / "submodules" / "WebUI" / "Sources" / "AorusWebTunnel.swift"
    web_tunnel_strings = tg / "submodules" / "WebUI" / "Sources" / "AorusWebTunnelStrings.swift"
    if not web_tunnel.is_file():
        err.append("WebAppTunnel: AorusWebTunnel.swift was not copied into WebUI")
    else:
        web_tunnel_text = web_tunnel.read_text(encoding="utf-8")
        for marker in (
            '"71d447f8-9128-4d18-b63c-ec11ef43ba26"',
            '"b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca"',
            "aorusTunnelClosedPort = 38190",
            "proxyConfigurations = [proxy]",
            "ProxyConfiguration(socksv5Proxy:",
            "pid.int32Value == ProcessInfo.processInfo.processIdentifier",
        ):
            if marker not in web_tunnel_text:
                err.append(f"WebAppTunnel: helper is missing {marker}")
        # A verdict that cannot be read has to keep the tunnel on, exactly like the
        # network and call layers. Flipping either default silently reopens direct routes.
        for marker in (
            'let required = requirement["required"] as? NSNumber else {\n        return true\n    }',
            "?? aorusTunnelClosedPort",
        ):
            if marker not in web_tunnel_text:
                err.append(f"WebAppTunnel: fail-closed default is missing {marker}")
    if not web_tunnel_strings.is_file():
        err.append("WebAppTunnel: AorusWebTunnelStrings.swift was not copied into WebUI")
    web_view_path = tg / "submodules" / "WebUI" / "Sources" / "WebAppWebView.swift"
    web_view_text = web_view_path.read_text(encoding="utf-8") if web_view_path.is_file() else ""
    if "aorusWebTunnelApply(to: configuration)" not in web_view_text:
        err.append("WebAppTunnel: the mini app web view is not pointed at the tunnel")
    web_controller_path = tg / "submodules" / "WebUI" / "Sources" / "WebAppController.swift"
    web_controller_text = web_controller_path.read_text(encoding="utf-8") if web_controller_path.is_file() else ""
    if "if !aorusWebTunnelAllowsMiniApps() {" not in web_controller_text:
        err.append("WebAppTunnel: the mini app load is not gated on an applicable tunnel")

    # Same drift rule as the picker: WebUI cannot import AorusGramUI, so it carries its own
    # generated copy of the one message it shows. Regenerate with gen_module_strings.py.
    web_strings_src = Path(__file__).parent.parent / "patches" / "submodules" / "WebUI" / "Sources" / "AorusWebTunnelStrings.swift"
    if web_strings_src.is_file() and main_table.is_file():
        web_text = web_strings_src.read_text(encoding="utf-8")
        english = "Mini apps need iOS 17 or later while the tunnel is on."
        web_tables = {
            m.group(1): dict(re.findall(r'^\s*"([\w_]+)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', m.group(2), re.M))
            for m in re.finditer(r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", web_text, re.S)
        }
        for name, body in re.findall(r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", main_table.read_text(encoding="utf-8"), re.S):
            source = dict(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', body, re.M))
            mirrored = web_tables.get(name)
            if mirrored is None:
                err.append(f"WebAppTunnel: AorusWebTunnelStrings has no {name} table — run gen_module_strings.py")
            elif source.get(english) != mirrored.get("unavailable"):
                err.append(
                    f"WebAppTunnel: {name} differs between AorusL10nTable and "
                    f"AorusWebTunnelStrings — run gen_module_strings.py"
                )
        inline_source = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusL10n.swift"
        if inline_source.is_file():
            match = re.search(r't\("((?:[^"\\]|\\.)*)",\s*"%s"\)' % re.escape(english), inline_source.read_text(encoding="utf-8"))
            if match is None:
                err.append("WebAppTunnel: no inline source for the mini app message — the generator cannot run")
            elif web_tables.get("ru", {}).get("unavailable") != match.group(1):
                err.append("WebAppTunnel: Russian differs from AorusL10n — run gen_module_strings.py")

    # The connection title has to say what is actually happening. Stock Telegram cannot:
    # the tunnel never reaches ProxySettings, so it writes plain "Connecting" whether the
    # core is coming up, the servers are gone, or there is no signal.
    conn_helper = tg / "submodules" / "ChatListUI" / "Sources" / "AorusConnectionStatus.swift"
    conn_strings_tree = tg / "submodules" / "ChatListUI" / "Sources" / "AorusConnectionStrings.swift"
    if not conn_helper.is_file():
        err.append("ConnectionTitle: AorusConnectionStatus.swift was not copied into ChatListUI")
    else:
        conn_text = conn_helper.read_text(encoding="utf-8")
        for marker in (
            '"b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca"',
            '"aorusgram_proxy_unhealthy_since"',
            'let pid = requirement["pid"] as? NSNumber',
            "pid.int32Value == ProcessInfo.processInfo.processIdentifier",
            "aorusUnhealthyThreshold: Double = 8.0",
            'AorusConnectionStrings.localized("failed")',
            'AorusConnectionStrings.localized("connecting")',
        ):
            if marker not in conn_text:
                err.append(f"ConnectionTitle: helper is missing {marker}")
    if not conn_strings_tree.is_file():
        err.append("ConnectionTitle: AorusConnectionStrings.swift was not copied into ChatListUI")
    chat_list_path = tg / "submodules" / "ChatListUI" / "Sources" / "ChatListController.swift"
    chat_list_text = chat_list_path.read_text(encoding="utf-8") if chat_list_path.is_file() else ""
    # Two sites: the root chat list and the per-folder one. Missing either leaves one
    # screen saying "Connecting" while the other names the proxy.
    routed = chat_list_text.count("aorusConnectingTitle(fallback: presentationData.strings.State_Connecting)")
    if routed != 2:
        err.append(f"ConnectionTitle: expected 2 routed connecting titles, found {routed}")

    # Same drift rule as the other generated tables.
    conn_strings_src = Path(__file__).parent.parent / "patches" / "submodules" / "ChatListUI" / "Sources" / "AorusConnectionStrings.swift"
    if conn_strings_src.is_file() and main_table.is_file():
        conn_src_text = conn_strings_src.read_text(encoding="utf-8")
        conn_wanted = {"connecting": "Connecting to proxy\u2026", "failed": "Can't connect to proxy"}
        conn_tables = {
            m.group(1): dict(re.findall(r'^\s*"([\w_]+)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', m.group(2), re.M))
            for m in re.finditer(r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", conn_src_text, re.S)
        }
        for name, body in re.findall(r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]", main_table.read_text(encoding="utf-8"), re.S):
            source = dict(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)",\s*$', body, re.M))
            mirrored = conn_tables.get(name)
            if mirrored is None:
                err.append(f"ConnectionTitle: AorusConnectionStrings has no {name} table — run gen_module_strings.py")
                continue
            for key, english in conn_wanted.items():
                if source.get(english) != mirrored.get(key):
                    err.append(
                        f"ConnectionTitle: {name} {english!r} differs between AorusL10nTable and "
                        f"AorusConnectionStrings — run gen_module_strings.py"
                    )
        inline_conn = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusL10n.swift"
        if inline_conn.is_file():
            inline_conn_text = inline_conn.read_text(encoding="utf-8")
            for key, english in conn_wanted.items():
                match = re.search(r't\("((?:[^"\\]|\\.)*)",\s*"%s"\)' % re.escape(english), inline_conn_text)
                if match is None:
                    err.append(f"ConnectionTitle: no inline source for {english!r} — the generator cannot run")
                elif conn_tables.get("ru", {}).get(key) != match.group(1):
                    err.append(f"ConnectionTitle: Russian {english!r} differs from AorusL10n — run gen_module_strings.py")

    # Search by Telegram ID: the helper has to be in the tree and the search pane has to
    # actually call it, or a numeric query silently goes back to finding nothing.
    id_search = tg / "submodules" / "ChatListUI" / "Sources" / "AorusPeerIdSearch.swift"
    if not id_search.is_file():
        err.append("PeerIdSearch: AorusPeerIdSearch.swift was not copied into ChatListUI")
    else:
        id_search_text = id_search.read_text(encoding="utf-8")
        for marker in (
            "func aorusPeerIdCandidates(for query: String)",
            "func aorusMergeIdSearch(",
            "maximumTelegramPeerId: Int64 = 0x00ff_ffff_ffff_ffff",
            "Namespaces.Peer.CloudUser",
            "Namespaces.Peer.CloudChannel",
            "Namespaces.Peer.CloudGroup",
        ):
            if marker not in id_search_text:
                err.append(f"PeerIdSearch: helper is missing {marker}")
    search_pane = tg / "submodules" / "ChatListUI" / "Sources" / "ChatListSearchListPaneNode.swift"
    search_pane_text = search_pane.read_text(encoding="utf-8") if search_pane.is_file() else ""
    if "foundRemotePeers = aorusMergeIdSearch(engine: context.engine, query: query, into: foundRemotePeers)" not in search_pane_text:
        err.append("PeerIdSearch: the search pane does not merge id results")

    # Auto-formatting: the store, the send hook and the settings row all have to line up,
    # and the style vocabulary is duplicated across two modules that cannot import each
    # other — so pin the two lists against each other rather than trusting they match.
    auto_format = tg / "submodules" / "TextFormat" / "Sources" / "AorusAutoFormat.swift"
    if not auto_format.is_file():
        err.append("AutoFormat: AorusAutoFormat.swift was not copied into TextFormat")
    else:
        auto_format_text = auto_format.read_text(encoding="utf-8")
        for marker in (
            'styleKey = "aorusgram_auto_format_style"',
            'public static let styles = ["bold", "italic", "monospace", "strikethrough", "underline", "spoiler"]',
            "func aorusApplyBaseTextStyle(",
        ):
            if marker not in auto_format_text:
                err.append(f"AutoFormat: store is missing {marker}")
        if "entities.filter { $0.type != type }" not in auto_format_text:
            err.append("AutoFormat: outgoing base style can duplicate an existing entity of the same type")
    entities_path = tg / "submodules" / "TextFormat" / "Sources" / "GenerateTextEntities.swift"
    entities_source = entities_path.read_text(encoding="utf-8") if entities_path.is_file() else ""
    if "entities = aorusApplyBaseTextStyle(to: entities, length: text.length)" not in entities_source:
        err.append("AutoFormat: outgoing entities do not carry the base style")
    # The live half: without it the composer shows plain text under an active style, which
    # reads as the setting being broken even though the sent message is correct.
    live_style = tg / "submodules" / "TelegramUI" / "Components" / "Chat" / "ChatInputTextNode" / "Sources" / "AorusBaseStyle.swift"
    if not live_style.is_file():
        err.append("AutoFormat: AorusBaseStyle.swift was not copied into ChatInputTextNode")
    else:
        live_style_text = live_style.read_text(encoding="utf-8")
        for marker in (
            'private let aorusBaseStyleKey = "aorusgram_auto_format_style"',
            "func aorusApplyBaseStyle(to textView: UITextView)",
            "ChatTextInputAttributes.bold",
            "ChatTextInputAttributes.spoiler",
        ):
            if marker not in live_style_text:
                err.append(f"AutoFormat: live composer helper is missing {marker}")
        # Must mutate storage in place and stand down during IME composition — a full
        # attributedText reassignment on every keystroke cancels marked-text input.
        if "textView.markedTextRange != nil" not in live_style_text:
            err.append("AutoFormat: live styling does not guard against IME marked text")
        if "storage.addAttribute(key" not in live_style_text:
            err.append("AutoFormat: live styling no longer mutates storage in place")
        if "aorusManagedBaseStyle" not in live_style_text or "storage.removeAttribute(key" not in live_style_text:
            err.append("AutoFormat: live styling cannot clean up its managed style after disable/change")
    rich_node = tg / "submodules" / "TelegramUI" / "Components" / "Chat" / "ChatInputTextNode" / "Sources" / "ChatRichTextInputNode.swift"
    rich_node_text = rich_node.read_text(encoding="utf-8") if rich_node.is_file() else ""
    # Injected into the concrete refreshTextInputAttributes, right before fonts are re-derived.
    if "aorusApplyBaseStyle(to: self.textInputNodeImpl.textView)" not in rich_node_text:
        err.append("AutoFormat: the composer does not draw the base style while typing")
    if rich_node_text.count("aorusApplyBaseStyle(to: self.textInputNodeImpl.textView)") > 1:
        err.append("AutoFormat: base-style stamp injected more than once")

    misc = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "AorusMiscController.swift"
    if misc.is_file():
        misc_text = misc.read_text(encoding="utf-8")
        for marker in (
            'let aorusAutoFormatKey = "aorusgram_auto_format_style"',
            'let aorusAutoFormatStyles = ["bold", "italic", "monospace", "strikethrough", "underline", "spoiler"]',
            "case .autoFormat:       return 49",
            "aorusAutoFormatController(context: context, onChange:",
        ):
            if marker not in misc_text:
                err.append(f"AutoFormat: settings screen is missing {marker}")
        # The row opens a pushed screen, not an action sheet.
        if "ActionSheetController(presentationData: presentationData)\n            // \"Off\" is only offered" in misc_text:
            err.append("AutoFormat: settings row still opens the old action sheet")
    auto_format_screen = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "AorusAutoFormatController.swift"
    if not auto_format_screen.is_file():
        err.append("AutoFormat: AorusAutoFormatController.swift is missing")
    elif "public func aorusAutoFormatController(context: AccountContext" not in auto_format_screen.read_text(encoding="utf-8"):
        err.append("AutoFormat: the picker screen entry point is missing")
        # AorusGramUI cannot import TextFormat, so the store's type must never be named
        # here — it compiles nowhere and the failure is a wall of inference errors that
        # point everywhere except the one line at fault.
        if "AorusAutoFormat." in misc_text:
            err.append("AutoFormat: settings screen references AorusAutoFormat, which it cannot import")

    # The mask strip has three moving parts that must all land: the leaf module has to be
    # in the tree, the call screen has to link it, and the button has to exist. Any one of
    # them silently missing means the button never appears and nobody notices until a user
    # reports it, so each is checked separately.
    mask_module = tg / "submodules" / "AorusMaskPicker" / "Sources" / "AorusMaskPickerView.swift"
    if not mask_module.is_file():
        err.append("MaskPicker: AorusMaskPicker module was not copied into the tree")
    call_build = tg / "submodules" / "TelegramUI" / "Components" / "Calls" / "CallScreen" / "BUILD"
    if call_build.is_file() and "//submodules/AorusMaskPicker:AorusMaskPicker" not in call_build.read_text(encoding="utf-8"):
        err.append("MaskPicker: CallScreen BUILD is missing the AorusMaskPicker dep")
    group_view = tg / "submodules" / "TelegramUI" / "Components" / "Calls" / "CallScreen" / "Sources" / "Components" / "ButtonGroupView.swift"
    if group_view.is_file():
        group_text = group_view.read_text(encoding="utf-8")
        for marker in ("case mask(isActive: Bool)", "AorusMaskPickerView.buttonIcon()", "aorusButtonRowTop"):
            if marker not in group_text:
                err.append(f"MaskPicker: ButtonGroupView is missing {marker}")
        # Five buttons overflow at the stock metrics; if these ever go back to `let`
        # the row is clipped rather than resized.
        if "var buttonSize: CGFloat = 56.0" not in group_text:
            err.append("MaskPicker: the call button row is no longer resizable for five buttons")
    call_screen = tg / "submodules" / "TelegramUI" / "Components" / "Calls" / "CallScreen" / "Sources" / "PrivateCallScreen.swift"
    if call_screen.is_file():
        call_text = call_screen.read_text(encoding="utf-8")
        for marker in ("aorusToggleMaskPicker", "AorusMaskCatalogue.isEnabled", "AorusMaskPickerView.panelHeight"):
            if marker not in call_text:
                err.append(f"MaskPicker: PrivateCallScreen is missing {marker}")

    # The Wall's media reclaim has three parts in three files, and a break in any one of them
    # is silent: the sweep simply stops freeing anything and storage grows again. Pin each.
    wall_store = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "AorusWallSettingsController.swift"
    if wall_store.is_file() and "func noteDisplayedMessages" not in wall_store.read_text(encoding="utf-8"):
        err.append("WallCache: AorusWallSettingsStore no longer records the posts the Wall displayed")
    cache_manager = Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "Features" / "UI" / "AorusCacheManager.swift"
    if cache_manager.is_file():
        cache_manager_text = cache_manager.read_text(encoding="utf-8")
        for marker in ("registerWallMediaCleanup(accountId:", "wallMediaCleanups.values"):
            if marker not in cache_manager_text:
                err.append(f"WallCache: account-scoped auto-clean is missing {marker}")
    wall_source = Path(__file__).parent.parent / "patches" / "submodules" / "TelegramUI" / "Sources" / "AorusWall.swift"
    if wall_source.is_file():
        wall_text = wall_source.read_text(encoding="utf-8")
        for marker in (
            "aorusInstallWallCacheCleanup",
            "noteDisplayedMessages",
            "clearStorage(\n",
            "aorusVisibleInstances",
            "aorusUpdateVisibility(self, isVisible:",
        ):
            if marker not in wall_text:
                err.append(f"WallCache: AorusWall.swift is missing {marker}")
        if wall_text.count("guard !AorusWallChatContents.aorusIsAnyWallVisible else") < 2:
            err.append("WallCache: visibility must be checked both before and after the async Postbox lookup")

    # "none" is spelled out in three modules that cannot import one another: the processor
    # that skips compositing, the picker that offers the entry, and the settings screen that
    # restores a real mask when the feature is switched back on. If one is reworded the mask
    # silently never comes back, so pin them together.
    off_sources = [
        (Path(__file__).parent.parent / "AorusGram" / "Sources" / "Features" / "AorusVideoMaskProcessor.swift",
         'static let offPreset = "none"'),
        (Path(__file__).parent.parent / "patches" / "submodules" / "AorusMaskPicker" / "Sources" / "AorusMaskCatalogue.swift",
         'static let offKey = "none"'),
        (Path(__file__).parent.parent / "patches" / "submodules" / "AorusGramUI" / "Sources" / "AorusMasksController.swift",
         'videoMaskPreset == "none"'),
    ]
    for source, marker in off_sources:
        if source.is_file() and marker not in source.read_text(encoding="utf-8"):
            err.append(f"MaskPicker: {source.name} no longer agrees on the off-mask value ({marker})")

    # Round videos get the same strip, hosted by two components injected into the camera
    # screen. The button is easy to lose silently — it only appears when masks are on — so
    # each piece is pinned separately, as on the call side.
    rv_screen = tg / "submodules" / "TelegramUI" / "Components" / "VideoMessageCameraScreen" / "Sources" / "VideoMessageCameraScreen.swift"
    if rv_screen.is_file():
        rv_text = rv_screen.read_text(encoding="utf-8")
        for marker in (
            "final class AorusMaskButtonComponent: Component",
            "final class AorusMaskPickerComponent: Component",
            "var aorusMaskPickerVisible = false",
            "Child(AorusMaskPickerComponent.self)",
            "AorusMaskCatalogue.isEnabled",
        ):
            if marker not in rv_text:
                err.append(f"MaskPickerRV: VideoMessageCameraScreen is missing {marker}")
    rv_build = tg / "submodules" / "TelegramUI" / "Components" / "VideoMessageCameraScreen" / "BUILD"
    if rv_build.is_file() and "//submodules/AorusMaskPicker:AorusMaskPicker" not in rv_build.read_text(encoding="utf-8"):
        err.append("MaskPickerRV: VideoMessageCameraScreen BUILD is missing the AorusMaskPicker dep")

    # The same quote must also be ONE box in the composer. The input keeps a structural
    # ChatInputContent and derives its attributed string from it, and upstream gives every
    # quoted paragraph its own block — which leaves the newline between them unattributed and
    # draws a box per line while the user types, whatever the send path does afterwards.
    conversion_file = tg / "submodules" / "TextFormat" / "Sources" / "ChatInputContentConversion.swift"
    if conversion_file.is_file():
        conversion_text = conversion_file.read_text(encoding="utf-8")
        for marker in ("var aorusOpenQuote: Int? = nil", "aorusMerged.append(.paragraph("):
            if marker not in conversion_text:
                err.append(f"InputQuote: composer quotes are still split per line — missing {marker}")

    # AccountBackupManager must stay byte-identical across the core and UI modules, so it
    # carries its own table instead of reaching for either module's. Nothing else checks it,
    # and a message added without an entry would silently show English.
    backup_manager = tg / "submodules" / "AorusGramUI" / "Sources" / "Features" / "Accounts" / "AccountBackupManager.swift"
    if backup_manager.is_file():
        backup_text = backup_manager.read_text(encoding="utf-8")
        backup_keys = {
            match.group(2)
            for match in re.finditer(
                r'localized\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"', backup_text, re.S
            )
        }
        backup_tables = re.findall(r'"(\w\w)": \[\n(.*?)\n        \],', backup_text, re.S)
        if len(backup_tables) < 6:
            err.append("Language: AccountBackupManager is missing translation tables")
        for lang, table_body in backup_tables:
            ordered = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', table_body, re.M)
            for repeated in sorted({k for k in ordered if ordered.count(k) > 1}):
                err.append(f"Language: AccountBackupManager {lang} lists {repeated!r} twice")
            present = set(ordered)
            for missing in sorted(backup_keys - present):
                err.append(f"Language: AccountBackupManager {lang} is missing {missing!r}")

    # AorusGram and AorusGramUI ship 21 byte-identical files, so a file that imports both
    # sees every shared public symbol twice. AppDelegate uses several of them and already
    # imports AorusGram; its strings go through aorusGramL instead.
    app_delegate = tg / "submodules" / "TelegramUI" / "Sources" / "AppDelegate.swift"
    if app_delegate.is_file():
        app_delegate_text = app_delegate.read_text(encoding="utf-8")
        if "import AorusGramUI" in app_delegate_text:
            err.append("Language: AppDelegate imports AorusGramUI — shared symbols become ambiguous")
        if "aorusL(" in "\n".join(l.split("//")[0] for l in app_delegate_text.split("\n")):
            err.append("Language: AppDelegate calls aorusL() — it must use aorusGramL()")

    # aorusL() lives in AorusGramUI. A file that calls it without the import, or in a package
    # without the Bazel dep, is a link error 40 minutes into the build — catch it here.
    for swift_file in sorted((tg / "submodules").rglob("*.swift")):
        body = swift_file.read_text(encoding="utf-8", errors="replace")
        # Comments mention the helper by name; only real call sites need the dep.
        code = "\n".join(line.split("//")[0] for line in body.split("\n"))
        if "aorusL(" not in code and "AorusLang." not in code:
            continue
        parts = swift_file.parts
        if "AorusGramUI" in parts:
            continue
        if "import AorusGramUI" not in body:
            err.append(f"Language: {swift_file.name} calls aorusL() without importing AorusGramUI")
        package = swift_file.parent
        while package != tg and not (package / "BUILD").is_file():
            package = package.parent
        build_file = package / "BUILD"
        if not build_file.is_file():
            err.append(f"Language: {swift_file.name} calls aorusL() but its package has no BUILD")
        elif "//submodules/AorusGramUI" not in build_file.read_text(encoding="utf-8"):
            err.append(
                f"Language: {swift_file.name} calls aorusL() but "
                f"{package.relative_to(tg)} has no AorusGramUI dep"
            )

    # Everything AorusGram shows follows the language selected inside Telegram. The device
    # language may only ever be a fallback for a fresh install that has no account yet, so a
    # bare Locale lookup with no Telegram key ahead of it is a regression.
    lang_bridge = tg / "submodules" / "TelegramUI" / "Sources" / "AppDelegate.swift"
    lang_bridge_text = lang_bridge.read_text(encoding="utf-8") if lang_bridge.is_file() else ""
    if 'forKey: "aorusgram_lang_code"' not in lang_bridge_text:
        err.append("Language: the full Telegram language code is no longer published")

    sub_l10n = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Subscription" / "SubscriptionL10n.swift"
    sub_l10n_text = sub_l10n.read_text(encoding="utf-8") if sub_l10n.is_file() else ""
    for marker in ('static var telegramLanguageCode: String?', "telegramLanguageCode\n"):
        if marker.strip() not in sub_l10n_text:
            err.append("Language: subscription screens no longer follow the Telegram language")
            break

    aorus_l10n = tg / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusL10n.swift"
    aorus_l10n_text = aorus_l10n.read_text(encoding="utf-8") if aorus_l10n.is_file() else ""
    for marker in ('public static var telegramCode: String?', "if let code = telegramCode {"):
        if marker not in aorus_l10n_text:
            err.append(f"Language: AorusL10n does not prefer the Telegram language — missing {marker}")

    # Action confirmation: the prompt must sit at the single choke point for each action, and
    # the original bodies must survive under their aorusPerform... names.
    action_confirm = tg / "submodules" / "AorusGramUI" / "Sources" / "Security" / "AorusActionConfirmation.swift"
    action_confirm_text = action_confirm.read_text(encoding="utf-8") if action_confirm.is_file() else ""
    for marker in (
        "public enum AorusActionConfirmation",
        "aorusgram_action_confirmation",
        "public func aorusConfirmCall(",
        "public func aorusConfirmGroupCall(",
        "public func aorusConfirmRecordedMessage(",
    ):
        if marker not in action_confirm_text:
            err.append(f"ActionConfirm: confirmation module is missing {marker}")
    if "as? Bool) ?? true" not in action_confirm_text:
        err.append("ActionConfirm: the feature must default to on")

    branding_script = Path(__file__).with_name("aorus_branding.py")
    branding_text = branding_script.read_text(encoding="utf-8") if branding_script.is_file() else ""
    for marker in (
        "let aorusEditIsSticker = aorusEditMsg.media.contains",
        "file.isSticker || file.isAnimatedSticker || file.isVideoSticker",
        "if !aorusEditIsSticker",
    ):
        if marker not in branding_text:
            err.append(f"EditLocally: sticker context-menu guard is missing {marker}")

    audio_session = tg / "submodules" / "TelegramAudio" / "Sources" / "ManagedAudioSession.swift"
    audio_session_text = audio_session.read_text(encoding="utf-8") if audio_session.is_file() else ""
    for marker in (
        "// AorusGram: built-in device microphone preference",
        "aorusApplyDeviceMicrophone(for type: ManagedAudioSessionType)",
        'UserDefaults.standard.bool(forKey: "aorusgram_device_microphone")',
        "self.aorusApplyDeviceMicrophone(for: type)",
        "DeviceMicrophone: restored Telegram input routing",
    ):
        if marker not in audio_session_text:
            err.append(f"DeviceMicrophone: central audio route patch is missing {marker}")

    aorus_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusGramController.swift"
    aorus_controller_text = aorus_controller.read_text(encoding="utf-8") if aorus_controller.is_file() else ""
    for marker in (
        ".hideTabTitles(theme, l10n.hideTabTitles, !state.hideTabTitles)",
        "args.set(\\.hideTabTitles, !$0)",
        ".voiceMessagesHeader(theme, l10n.voiceMessagesHeader)",
        ".deviceMicrophone(theme, l10n.deviceMicrophone, state.deviceMicrophone)",
    ):
        if marker not in aorus_controller_text:
            err.append(f"AorusSettings: tab-name/device-microphone UI is missing {marker}")

    for relative_path in (
        "submodules/AorusGramUI/Sources/UI/Messaging/AorusVoiceToText.swift",
        "submodules/AorusGramUI/Sources/UI/Settings/VoiceTranscriberView.swift",
    ):
        recorder = tg / relative_path
        recorder_text = recorder.read_text(encoding="utf-8") if recorder.is_file() else ""
        for marker in (
            'UserDefaults.standard.bool(forKey: "aorusgram_device_microphone")',
            ".portType == .builtInMic",
            "session.setPreferredInput(builtInMicrophone)",
            "session.setPreferredInput(nil)",
        ):
            if marker not in recorder_text:
                err.append(f"DeviceMicrophone: custom recorder {relative_path} is missing {marker}")

    action_context = tg / "submodules" / "TelegramUI" / "Sources" / "AccountContext.swift"
    action_context_text = action_context.read_text(encoding="utf-8") if action_context.is_file() else ""
    for marker in (
        "private func aorusPerformRequestCall(",
        "private func aorusPerformJoinGroupCall(",
        "private func aorusPerformJoinConferenceCall(",
    ):
        if marker not in action_context_text:
            err.append(f"ActionConfirm: call entry point is not gated — missing {marker}")

    action_recording = (
        tg / "submodules" / "TelegramUI" / "Sources" / "Chat" / "ChatControllerMediaRecording.swift"
    )
    action_recording_text = (
        action_recording.read_text(encoding="utf-8") if action_recording.is_file() else ""
    )
    for marker in (
        "func aorusPerformDismissMediaRecorder(",
        "func aorusPerformSendMediaRecording(",
        "func aorusSendRecordedMessageWhenReady(",
    ):
        if marker not in action_recording_text:
            err.append(f"ActionConfirm: recorded-message send is not gated — missing {marker}")

    misc = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusMiscController.swift"
    misc_text = misc.read_text(encoding="utf-8") if misc.is_file() else ""
    for marker in ("case actionConfirmation(", "AorusActionConfirmation.isEnabled = value"):
        if marker not in misc_text:
            err.append(f"ActionConfirm: the Security toggle is missing {marker}")

    wall_settings = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusWallSettingsController.swift"
    wall_settings_text = wall_settings.read_text(encoding="utf-8") if wall_settings.is_file() else ""
    for marker in (
        "private static var seenCache:",
        "private static var excludedCache:",
        "func seenMessageIds(accountId: Int64) -> Set<MessageId>",
        "appendSeenJournalLocked(newValues, accountId: accountId)",
        "writeSeenSnapshotLocked(entry, accountId: accountId)",
    ):
        if marker not in wall_settings_text:
            err.append(f"Wall: settings store caching is missing {marker}")
    if "return Set(UserDefaults.standard.stringArray(" in wall_settings_text:
        err.append("Wall: seen lookups are reading UserDefaults on every call again")

    postbox = tg / "submodules" / "Postbox" / "Sources" / "Postbox.swift"
    postbox_text = postbox.read_text(encoding="utf-8") if postbox.is_file() else ""
    for marker in (
        "public func aorusWallMessages(",
        "from: before",
        "to: MessageIndex.lowerBound(peerId: peerId, namespace: namespace)",
    ):
        if marker not in postbox_text:
            err.append(f"Wall: cursor-based Postbox pagination is missing {marker}")
    if postbox_text.count("public func aorusWallMessages(") != 1:
        err.append("Wall: cursor-based Postbox pagination must be injected exactly once")

    wall_title = tg / "submodules" / "TelegramUI" / "Sources" / "ChatControllerContentData.swift"
    wall_title_text = wall_title.read_text(encoding="utf-8") if wall_title.is_file() else ""
    if "customChatContents as? AorusWallChatContents" not in wall_title_text or "content: .text(aorusWall.title)" not in wall_title_text:
        err.append("Wall: native centered chat title is not connected to AorusWallChatContents")

    wall_account_context = tg / "submodules" / "AccountContext" / "Sources" / "ChatController.swift"
    wall_account_context_text = wall_account_context.read_text(encoding="utf-8") if wall_account_context.is_file() else ""
    for marker in ("var aorusIsWall: Bool { get }", "public extension ChatCustomContentsProtocol"):
        if marker not in wall_account_context_text:
            err.append(f"Wall: shared custom-content marker is missing {marker}")

    wall_contents = tg / "submodules" / "TelegramUI" / "Sources" / "AorusWall.swift"
    wall_contents_text = wall_contents.read_text(encoding="utf-8") if wall_contents.is_file() else ""
    if "public let aorusIsWall = true" not in wall_contents_text:
        err.append("Wall: AorusWallChatContents does not expose the shared Wall marker")
    for marker in (
        "existingReactions != updatedReactions",
        "aorusgram.wallExcludePeerRequested",
        "AorusWallSettingsStore.addExcludedPeer(peerId, accountId: accountId)",
    ):
        if marker not in wall_contents_text:
            err.append(f"Wall: live reaction/exclusion pipeline is missing {marker}")

    wall_node = tg / "submodules" / "TelegramUI" / "Sources" / "ChatControllerNode.swift"
    wall_node_text = wall_node.read_text(encoding="utf-8") if wall_node.is_file() else ""
    if "AorusGram: Wall top-to-bottom history" not in wall_node_text:
        err.append("Wall: history is not configured for top-to-bottom reading")
    if "AorusGram: Wall has no bottom-navigation button" not in wall_node_text:
        err.append("Wall: native scroll-to-bottom controls are still visible")

    wall_controller = tg / "submodules" / "TelegramUI" / "Sources" / "ChatController.swift"
    wall_controller_text = wall_controller.read_text(encoding="utf-8") if wall_controller.is_file() else ""
    for marker in ("aorusWallAllowsQuickReaction", "aorusWallAllowsMenuReaction"):
        if marker not in wall_controller_text:
            err.append(f"Wall: recommended-channel reaction route is missing {marker}")
    for marker in (
        "var liveResult = Set<MessageId>()",
        "var readableResult = Set<MessageId>()",
        "return (live: liveResult, readable: readableResult)",
    ):
        if marker not in wall_controller_text:
            err.append(f"Wall: live reactions are still coupled to read tracking — missing {marker}")

    wall_bubble = tg / "submodules" / "TelegramUI" / "Components" / "Chat" / "ChatMessageBubbleItemNode" / "Sources" / "ChatMessageBubbleItemNode.swift"
    wall_bubble_text = wall_bubble.read_text(encoding="utf-8") if wall_bubble.is_file() else ""
    if "contents is AorusWallChatContents" in wall_bubble_text:
        err.append("Wall: bubble component illegally depends on TelegramUI's concrete AorusWallChatContents type")
    if "contents.aorusIsWall" not in wall_bubble_text:
        err.append("Wall: bubble component does not use the shared Wall marker")
    for marker in (
        "aorusWallExcludeSwipe",
        ".aorusWallExclude",
        "aorusgram.wallExcludePeerRequested",
        '"peerTitle": item.message.peers[item.message.id.peerId].map { EnginePeer($0).compactDisplayTitle }',
    ):
        if marker not in wall_bubble_text:
            err.append(f"Wall: swipe-to-exclude route is missing {marker}")

    for marker in (
        "import UndoUI",
        "private weak var navigationController: ViewController?",
        "Канал «%@» добавлен в исключения",
        # The channel title is substituted after translation — interpolating it first made
        # the string differ on every toast, so it could never match a key in the table.
        "Channel “%@” added to exclusions",
        "content: .succeed(text: text, timeout: nil, customUndoText: nil)",
        # The toast is presented in .window(.root), whose insets are the safe area only — the
        # tab bar belongs to the tab controller, not the window. elevatedLayout must therefore
        # be true so the 49pt tab-bar height is added exactly once; with false the toast sits
        # underneath the tab bar, and with .current as the container it would be counted twice.
        "elevatedLayout: true",
        "in: .window(.root)",
    ):
        if marker not in wall_contents_text:
            err.append(f"Wall: exclusion toast is missing {marker}")

    wall_swipe_node = (
        tg
        / "submodules"
        / "TelegramUI"
        / "Components"
        / "Chat"
        / "ChatMessageSwipeToReplyNode"
        / "Sources"
        / "ChatMessageSwipeToReplyNode.swift"
    )
    wall_swipe_text = wall_swipe_node.read_text(encoding="utf-8") if wall_swipe_node.is_file() else ""
    for marker in (
        "case aorusWallExclude",
        "context.setStrokeColor(UIColor.systemRed.cgColor)",
        "context.strokeEllipse(in:",
        "context.addLine(to:",
        "self.backgroundNode = NavigationBackgroundNode(color: fillColor, enableBlur: enableBlur)",
        "if backgroundNode?.hasExtraBubbleBackground() == true",
    ):
        if marker not in wall_swipe_text:
            err.append(f"Wall: crossed-circle exclusion swipe icon is missing {marker}")
    for forbidden in (
        "let aorusWallExcludeStyle: Bool",
        "color: aorusWallExcludeStyle ? .systemRed : fillColor",
        'UIImage(systemName: "nosign"',
        ".withTintColor(.white, renderingMode: .alwaysOriginal)",
        "if !aorusWallExcludeStyle, backgroundNode?.hasExtraBubbleBackground() == true",
    ):
        if forbidden in wall_swipe_text:
            err.append(f"Wall: exclusion swipe must retain Telegram's original background — found {forbidden}")

    wall_context_menu = tg / "submodules" / "TelegramUI" / "Sources" / "Chat" / "ChatControllerOpenMessageContextMenu.swift"
    wall_context_menu_text = wall_context_menu.read_text(encoding="utf-8") if wall_context_menu.is_file() else ""
    for marker in ("aorusWallAllowsContextReaction", "aorusWallAllowsSelectedReaction"):
        if marker not in wall_context_menu_text:
            err.append(f"Wall: recommended-channel context reaction route is missing {marker}")

    wall_bubble = (
        tg
        / "submodules"
        / "TelegramUI"
        / "Components"
        / "Chat"
        / "ChatMessageBubbleItemNode"
        / "Sources"
        / "ChatMessageBubbleItemNode.swift"
    )
    wall_bubble_text = wall_bubble.read_text(encoding="utf-8") if wall_bubble.is_file() else ""
    for marker in (
        "aorusWallShareButtonNode",
        "aorusWallShareButtonPressed",
        "aorusForceShare: true",
    ):
        if marker not in wall_bubble_text:
            err.append(f"Wall: translate/share/navigate stack is missing {marker}")

    app_context = tg / "submodules" / "TelegramUI" / "Sources" / "ApplicationContext.swift"
    app_context_text = app_context.read_text(encoding="utf-8") if app_context.is_file() else ""
    if "aorusgram_wall_visibility_changed" not in app_context_text:
        err.append("Wall: live tab visibility observer is missing")
    if "private var aorusLastWallEnabled" not in app_context_text:
        err.append("Wall: live tab visibility state property is missing")
    if "guard wallEnabled != strongSelf.aorusLastWallEnabled" in app_context_text:
        err.append("Wall: stale cached visibility guard can ignore disabling the tab")

    # AorusGram tab controls must change the native component's composition and
    # measured height, then trigger the existing root-controller rebuild live.
    aorus_controller = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusGramController.swift"
    aorus_controller_text = aorus_controller.read_text(encoding="utf-8") if aorus_controller.is_file() else ""
    for marker in (
        "case tabs",
        ".tabsHeader(theme, l10n.tabsHeader)",
        ".hideContactsTab(theme, l10n.hideContactsTab",
        ".hideCallsTab(theme, l10n.hideCallsTab",
        ".hideSearchButton(theme, l10n.hideSearchButton",
        ".hideTabTitles(theme, l10n.hideTabTitles",
        ".compactTabBar(theme, l10n.compactTabBar",
        "updated: { args.set(\\.hideSearchButton, !$0) }",
    ):
        if marker not in aorus_controller_text:
            err.append(f"TabBarVisibility: settings section is missing {marker}")

    aorus_manager = tg / "submodules" / "AorusGramUI" / "Sources" / "AorusGramManager.swift"
    aorus_manager_text = aorus_manager.read_text(encoding="utf-8") if aorus_manager.is_file() else ""
    for marker in (
        'forKey: "aorusgram_hide_search_button"',
        'forKey: "aorusgram_hide_tab_titles"',
        'forKey: "aorusgram_compact_tab_bar"',
        '"hideSearchButton":',
        '"hideTabTitles":',
        '"compactTabBar":',
    ):
        if marker not in aorus_manager_text:
            err.append(f"TabBarVisibility: persisted setting is missing {marker}")

    tab_component = (
        tg / "submodules" / "TelegramUI" / "Components" / "TabBarComponent"
        / "Sources" / "TabBarComponent.swift"
    )
    tab_component_text = tab_component.read_text(encoding="utf-8") if tab_component.is_file() else ""
    for marker in (
        "public let hideTitles: Bool",
        "component.hideTitles ? 48.0 : 56.0",
        "component.isCompact || component.hideTitle",
        "component.hideTitle ? floor((availableSize.height - iconSize.height) * 0.5)",
        "public let compactPanel: Bool",
        "component.compactPanel ? min(availableItemsWidth",
        "let itemWeightNorm: CGFloat = layoutItemsWidth / unboundItemWidthSum",
        "CGPoint(x: size.width - searchSize.width",
    ):
        if marker not in tab_component_text:
            err.append(f"TabBarVisibility: native compact layout is missing {marker}")

    tab_node = tg / "submodules" / "TabBarUI" / "Sources" / "TabBarContollerNode.swift"
    tab_node_text = tab_node.read_text(encoding="utf-8") if tab_node.is_file() else ""
    for marker in (
        'aorusgram_hide_search_button") ? nil',
        'hideTitles: UserDefaults.standard.bool(forKey: "aorusgram_hide_tab_titles")',
        'compactPanel: UserDefaults.standard.bool(forKey: "aorusgram_compact_tab_bar")',
    ):
        if marker not in tab_node_text:
            err.append(f"TabBarVisibility: tab composition is missing {marker}")

    tab_controller = tg / "submodules" / "TabBarUI" / "Sources" / "TabBarController.swift"
    tab_controller_text = tab_controller.read_text(encoding="utf-8") if tab_controller.is_file() else ""
    if tab_controller_text.count("AorusGram: compact tab titles") != 2:
        err.append("TabBarVisibility: temporary controller insets are not aligned at both sites")
    for marker in (
        "private var aorusLastHideSearch",
        "private var aorusLastHideTabTitles",
        "private var aorusLastCompactTabBar",
        "hideSearch != strongSelf.aorusLastHideSearch",
        "hideTabTitles != strongSelf.aorusLastHideTabTitles",
        "compactTabBar != strongSelf.aorusLastCompactTabBar",
    ):
        if marker not in app_context_text:
            err.append(f"TabBarVisibility: live refresh is missing {marker}")

    account_context = tg / "submodules" / "TelegramUI" / "Sources" / "AccountContext.swift"
    account_context_text = account_context.read_text(encoding="utf-8") if account_context.is_file() else ""
    for marker in (
        "private var aorusLocalPremiumObserver: NSObjectProtocol?",
        'Notification.Name("aorusgram_local_premium_changed")',
        "private func aorusRefreshLocalPremiumState()",
        "self.userLimitsConfigurationDisposable?.dispose()",
        "self.audioTranscriptionTrialDisposable?.dispose()",
    ):
        if marker not in account_context_text:
            err.append(f"LocalPremium: live AccountContext refresh is missing {marker}")

    local_premium = tg / "submodules" / "AorusGramUI" / "Sources" / "Core" / "AorusLocalPremium.swift"
    local_premium_text = local_premium.read_text(encoding="utf-8") if local_premium.is_file() else ""
    for marker in (
        'Notification.Name("aorusgram_local_premium_changed")',
        "NotificationCenter.default.post(name: changedNotification",
        'Notification.Name("aorusgram_settings_changed")',
    ):
        if marker not in local_premium_text:
            err.append(f"LocalPremium: live setting notification is missing {marker}")

    subscription_config = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Subscription" / "SubscriptionConfig.swift"
    if not subscription_config.is_file():
        err.append("SubscriptionConfig.swift is missing")
    else:
        config_text = subscription_config.read_text(encoding="utf-8")
        if "static let requireSignedResponse = true" not in config_text:
            err.append("SubscriptionConfig: signed license responses must be mandatory")
        public_key = re.search(r'responseSigningPublicKeyHex\s*=\s*"([0-9a-fA-F]+)"', config_text)
        if public_key is None or len(public_key.group(1)) != 64:
            err.append("SubscriptionConfig: Ed25519 response public key must be 32 bytes")
        for host in ("license.aorusgram.com", "api.aorusgram.com"):
            if f'"{host}": protectedAPISPKIPins' not in config_text:
                err.append(f"SubscriptionConfig: SPKI pin set is missing for {host}")
        if len(re.findall(r'"[A-Za-z0-9+/]{43}="', config_text)) < 3:
            err.append("SubscriptionConfig: protected API SPKI rotation set is incomplete")

    pinning_delegate = tg / "submodules" / "AorusGram" / "Sources" / "Features" / "Subscription" / "AorusPinnedSessionDelegate.swift"
    if not pinning_delegate.is_file():
        err.append("AorusPinnedSessionDelegate.swift is missing")
    else:
        pinning_text = pinning_delegate.read_text(encoding="utf-8")
        for marker in (
            "SubscriptionConfig.pinnedSPKIHashesByHost[host]",
            "SecTrustEvaluateWithError",
            "completionHandler(.cancelAuthenticationChallenge, nil)",
        ):
            if marker not in pinning_text:
                err.append(f"AorusPinnedSessionDelegate: fail-closed pinning is missing {marker}")

    glass_components = tg / "submodules" / "AorusGramUI" / "Sources" / "UI" / "GlassMorphism" / "GlassMorphismComponents.swift"
    if not glass_components.is_file():
        err.append("GlassEffects: component implementation is missing")
    elif 'AorusGram_feature_glass_ui' in glass_components.read_text(encoding="utf-8"):
        err.append("GlassEffects: invalid settings key casing")
    elif 'aorusgram_feature_glass_ui' not in glass_components.read_text(encoding="utf-8"):
        err.append("GlassEffects: switch is not connected to glass components")
    elif "@AppStorage" in glass_components.read_text(encoding="utf-8"):
        err.append("GlassEffects: AppStorage is unavailable at the iOS 13 deployment target")

    # Interface 2.0. Each patch already raises when its anchor moves, so what is checked here is
    # the other failure: a pass that reported success against a file the build does not compile,
    # or an "already present" short-circuit hiding a half-applied edit from a previous run.
    interface_v2_expectations = (
        (
            "submodules/TelegramPresentationData/Sources/PresentationTheme.swift",
            (
                "aorusGlassListTheme",
                "aorusGlassProfileTheme",
                "AorusGlassThemeCache",
                "blockMarker",
                # The page ink: one source for the name, the status, the header glyphs and the
                # selected tab, so a pale photo cannot leave white text on a white page.
                "profilePageKey",
                "profilePageInk",
                "profilePageScrim",
                # The profile's personal-channel row is a real ChatListItem, so its greys come from
                # theme.chatList and not theme.list -- it needs its own derivation.
                "theme.chatList.withUpdated",
            ),
        ),
        # cornersImage returns nil under Interface 2.0. Those wedges are an opaque overlay painted
        # in the page colour, not a mask, so over glass they are exactly the black corners the
        # blocks used to show.
        (
            "submodules/TelegramPresentationData/Sources/Resources/PresentationResourcesItemList.swift",
            ("aorusNoCornerWedges",),
        ),
        ("submodules/ItemListUI/Sources/ItemListItem.swift", ("theme.aorusGlassListTheme",)),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenItemSectionContainerNode.swift",
            ("aorusGlassBackgroundView", "import GlassBackgroundComponent"),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift",
            (
                "aorusCentredHeader",
                "publishAvatarTint",
                "aorusHidesButtonsBlur",
                "aorusScrollingHeader",
                "aorusOverlayPalette",
                # The palette that actually runs: the photo is permanently expanded under
                # Interface 2.0, so the expandedAvatar* branch is the one every profile with a
                # picture takes, and it has to be inked like the other two.
                "aorusOverlayInk",
                # The photo stands still and the capsule under it is the small one, lifted clear of
                # the join between the picture and the page.
                "aorusStaticAvatar",
                "aorusCompactMusic",
                # The pill is placed against the bottom of the button row, not the bottom of the
                # photo: an action button pushes that row down by its own height, and a pill measured
                # off the header's edge went under the buttons on exactly those profiles.
                "aorusButtonsBottom",
                "aorusMusicPillTop",
                "insetBy(dx: -12.0, dy: -3.0)",
                # The pill takes the row's own frame path and the row's own alpha. Pinned at 1.0 and
                # moved non-additively it slid out from under its text and stayed behind as a bare
                # lozenge, which is what "becomes an artefact while scrolling" was.
                "updateFrameAdditiveToCenter(view: self.aorusMusicCapsule",
                "updateAlpha(layer: self.aorusMusicCapsule.layer, alpha: backgroundBannerAlpha)",
                "// AorusGram: Interface 2.0 opens the photo at full width",
                # The rating shield sits on the page next to the name, where the accent-coloured
                # one it draws by default disappears into whatever the avatar happened to be.
                "aorusWhiteShield",
                # One phone button stands where the stock header shows Call and Video, so the tap
                # has to ask which one. Both answers go back through performButtonAction, which is
                # the same code the two stock buttons ran.
                "aorusPresentCallTypeSheet",
            ),
        ),
        # The members tab of a group or channel. It paints its own background and fades the list
        # into it, both in the theme's own colours, which is the black the tab showed while the
        # page around it carried the avatar's.
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/Panes/PeerInfoMembersPane.swift",
            (
                "aorusUpdateGlass",
                "aorusPageFillView",
                "aorusGlassProfileTheme",
                "import GlassBackgroundComponent",
            ),
        ),
        (
            "submodules/TelegramUI/Components/MultiScaleTextNode/Sources/MultiScaleTextNode.swift",
            ("aorusTextOriginX",),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderButtonNode.swift",
            ("aorusGlassBackground", "import GlassBackgroundComponent", "AorusGlassPane.profilePageInk"),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift",
            (
                "aorusPublishAvatarTint",
                # The photo stays open when a tab is tapped, which is eight separate collapse sites
                # all asking one shared test. Spelled out in full so that renaming the test without
                # updating the sites fails here.
                "aorusKeepsAvatarExpandedNow",
                # The page is the photo's own lower half stretched behind the whole screen, not one
                # flat colour: a colour alone met the picture in a visible line.
                "aorusUpdatePageBackdrop",
                "AorusGlassProfileTint.pageBackgroundImage",
                # One slot holds the ink for every module that draws over the page and cannot import
                # the sampler. The profile being laid out claims it at the top of both layout
                # passes; leaving the previous peer's colour there is how a profile came out
                # near-black on near-black.
                "aorusUpdatePageColor",
                "AorusGlassProfileTint.publishPageColor",
            ),
        ),
        (
            "submodules/AvatarNode/Sources/AvatarNode.swift",
            ("aorusPlaceholderColors", "aorusLetterColor", "aorusHasGlassBackdrop"),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoAvatarTransformContainerNode.swift",
            ("aorusUpdateGlassPlaceholder", "aorusHasGlassBackdrop", "import GlassBackgroundComponent"),
        ),
        (
            "submodules/Display/Source/ActionSheetTheme.swift",
            ("aorusGlassSheet",),
        ),
        (
            "submodules/Display/Source/ActionSheetItemGroupNode.swift",
            ("UIGlassEffect(style: .regular)",),
        ),
        # A sheet row can carry a glyph at its leading edge with the title beside it. The call-type
        # sheet is the only caller, and without the row the two answers are two lines of text.
        (
            "submodules/Display/Source/ActionSheetButtonItem.swift",
            ("aorusIcon", "aorusIconNode"),
        ),
        # The music player opened from a profile. Four opaque fills (the list, the two side strips
        # and the header) plus the controls panel are all replaced by one pane spanning the sheet,
        # so a fill left behind here is an opaque slab over the glass.
        (
            "submodules/TelegramUI/Sources/OverlayAudioPlayerControllerNode.swift",
            (
                "aorusPlayerBackgroundView",
                "aorusUpdatePlayerGlass",
                "import GlassBackgroundComponent",
                "aorusListFill",
                "aorusFrameFill",
            ),
        ),
        # The panel under the transport controls draws its own fill and shadow in two generators;
        # both have to decline to draw. The "Add to Profile" button takes the page's own ink.
        (
            "submodules/TelegramUI/Sources/OverlayAudioPlayerControlsNode.swift",
            ("aorusPlayerInk", "aorusButtonInk", "self.scrubberNode.aorusWaveStyle"),
        ),
        # The playback position reads as a wave rather than a bar: both copies are drawn at the
        # laid-out width and pinned to the same edge, so the crests line up and clipping the played
        # copy horizontally still reads as progress.
        (
            "submodules/MediaPlayer/Sources/MediaPlayerScrubbingNode.swift",
            ("public var aorusWaveStyle", "aorusWaveImage", "aorusUpdateWave"),
        ),
        (
            "submodules/UndoUI/Sources/UndoOverlayControllerNode.swift",
            ("aorusGlassToast", "import GlassBackgroundComponent"),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift",
            ("aorusForcedButtons",),
        ),
        (
            "submodules/ItemListUI/Sources/ItemListControllerNode.swift",
            (
                "aorusUpdateListGlass",
                "aorusGlassPanes",
                "AorusGlassPane.blockMarker",
                "import GlassBackgroundComponent",
            ),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNavigationButtonContainerNode.swift",
            ("aorusPlainNavGlass",),
        ),
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoPaneContainerNode.swift",
            ("aorusPlainPanes", "kind: aorusPlainPanes ? .clear : .panel"),
        ),
        # The newer half of Settings lays its sections out with components rather than with
        # ItemListItems, so it never passes through ItemListControllerNode. Without this the gifts,
        # stars and business screens keep flat cards while everything around them is glass.
        (
            "submodules/TelegramUI/Components/ListSectionComponent/Sources/ListSectionComponent.swift",
            ("aorusUsesGlass", "aorusGlassView", "import GlassBackgroundComponent"),
        ),
        # The band under the profile tabs. This pane paints its own opaque background and fades
        # the list into it, both in the theme's blocks colour, which is the black the gifts tab
        # used to show under a tinted page.
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoVisualMediaPaneNode/Sources/PeerInfoGiftsPaneNode.swift",
            ("aorusContinuesPage",),
        ),
        # The header calls this with photo:/photoCount:, so a stale copy of the table here would
        # only surface as a missing-argument error deep inside a CI compile.
        (
            "submodules/AorusGramUI/Sources/UI/GlassMorphism/AorusGlassProfileTint.swift",
            (
                "photoCount: Int",
                "sampledColors",
                "pageKey",
                # The page continues the one row of the photo the header ends on, sampled through
                # the same shading the header lays over it. That row is not the bottom of the
                # picture: the strip below the square is the picture mirrored, hinged four points
                # up and stretched threefold, so the row to match is (tail + 4) / 3 above the edge.
                # Sampling anywhere else, or forgetting the shading, is what left the page meeting
                # the picture in a visible line.
                "bottomBandSample",
                "mirrorDepth",
                "mirroredTail",
                "bandShadow",
                # The stretched backdrop, and the flag that keeps it from being sampled off the
                # round centre-cropped fallback avatar.
                "pageBackgroundImage",
                "isFullPhoto",
                # A peer with no photo has no band to sample, so the colour its letter avatar is
                # drawn from is published instead. Without this the page stays black and the whole
                # profile disappears into it.
                "publishPageColor",
                # The page is blurred with Telegram's own thumbnail blur, and with the fifteen
                # points the header itself uses converted into the sample's pixels. Spending them
                # as pixels is a kernel half the width of the sample -- the flat wash that was
                # reported as "too blurred".
                "sampleBlurRadius",
                "ImageBlur.blurredImage(sampled, radius: AorusGlassProfileTint.sampleBlurRadius)",
            ),
        ),
        # The chat's navigation bar keeps the pane behind the back button and loses the two that
        # Interface 2.0 has no use for: the one behind the name and status, and the one behind the
        # avatar or the ghost-mode badge that replaces it.
        (
            "submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleView.swift",
            ("aorusHidesTitleGlass", "isVisible: !aorusHidesTitleGlass"),
        ),
        # The title view a chat actually installs is ChatNavigationBarTitleView, whose pane belongs
        # to the ChatTitleComponent inside it -- the file above is the older view. Hiding only that
        # one is why the capsule under the name outlived the build that took the avatar's away.
        # Here the pane owns the two lines of text, so it is dropped through the component's own
        # no-background branch rather than hidden with them still inside it.
        (
            "submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleComponent.swift",
            ("aorusHidesTitlePill", "let displayBackground: Bool = !aorusHidesTitlePill"),
        ),
        (
            "submodules/TelegramUI/Components/NavigationBarImpl/Sources/NavigationBarImpl.swift",
            (
                "aorusHidesCustomButtonGlass",
                "singleCustomNode != nil",
                # isVisible and not isHidden: the bar button is a subview of this container's own
                # contentView, so hiding the container took the avatar and the ghost badge with it.
                "isVisible: !aorusHidesCustomButtonGlass",
            ),
        ),
        # The avatar/ghost item carries a pill of its own inside the bar's right-hand pane, so both
        # have to go or the capsule survives the one that was hidden.
        (
            "submodules/TelegramUI/Sources/ChatController.swift",
            ("aorusHidesNavCapsule",),
        ),
        # The menu a *tap* on a username opens is the older ContextMenuNode, which paints a flat
        # grey rectangle unless it is told it is blurred. Both files, because the flag and the
        # material it selects live one in each.
        (
            "submodules/Display/Source/ContextMenuContainerNode.swift",
            ("aorusGlassMenu", "UIGlassEffect(style: .regular)"),
        ),
        (
            "submodules/TelegramUI/Components/ContextMenuScreen/Sources/ContextMenuNode.swift",
            (
                "aorusBlurredMenu",
                "ContextMenuContainerNode(isBlurred: aorusBlurredMenu",
                # A rasterized fade would flatten the material into a grey slab.
                "if !self.blurred {",
            ),
        ),
        # And in a profile the old menu is not shown at all: what a tap on a username opens sits
        # inches from the long-press menu on the same row, so it is presented through the same
        # controller. All five branches, or the one left behind is the one that gets tapped.
        (
            "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenOpenPeerInfoContextMenu.swift",
            (
                "aorusPresentTapMenu",
                "AorusTapMenuLocationSource",
                "import ContextUI",
                "!self.aorusPresentTapMenu(actions: actions",
                "self?.aorusPresentTapMenu(actions: actions",
                "!self.aorusPresentTapMenu(actions: aorusTapActions",
            ),
        ),
    )
    # AorusGram's own screens build rows out of ListViewItem subclasses that take a
    # PresentationTheme directly, so they never pass through the ItemListPresentationData
    # initializer the glass theme is injected into. Every one of them has to ask for the derived
    # theme by hand, and a new screen that forgets to is a grey card sitting on a pane of glass --
    # which is exactly how the broken sliders got shipped once.
    for name in (
        "AorusGramController.swift",
        "AorusAntiSpamController.swift",
        "AorusQuickRepliesController.swift",
        "AorusFontPickerController.swift",
        "AorusMasksController.swift",
        "AorusDeviceSpoofController.swift",
        "AccountBackupController.swift",
    ):
        source = tg / "submodules/AorusGramUI/Sources" / name
        if not source.is_file():
            err.append(f"InterfaceV2: AorusGramUI/{name} is missing")
        elif "aorusGlassListTheme" not in source.read_text(encoding="utf-8"):
            err.append(f"InterfaceV2: AorusGramUI/{name} does not use the glass list theme")

    # Session backup ships as two screens: a SwiftUI port that draws its own opaque cards, and an
    # ItemList in .blocks style that gets real glass for free from ItemListControllerNode. The port
    # cannot be turned into glass without rewriting it, so under Interface 2.0 the factory has to
    # pick the list -- and with the switch off it has to keep picking the port.
    backup_controller = tg / "submodules/AorusGramUI/Sources/AccountBackupController.swift"
    if backup_controller.is_file():
        backup_text = backup_controller.read_text(encoding="utf-8")
        if "!AorusInterfaceV2.isEnabled" not in backup_text:
            err.append("InterfaceV2: the backup screen still opens its opaque SwiftUI port")
        if "accountBackupControllerLegacy" not in backup_text:
            err.append("InterfaceV2: the backup screen has no glass list to fall back to")

    # The transparency slider in the profile's Personal Colors section is a Component rather than a
    # row, and the section it sits in already draws one pane for all of its items, so this one has
    # to paint nothing at all instead of asking for the derived theme.
    opacity_component = tg / "submodules/AorusGramUI/Sources/Features/UI/AorusAnimatedProfileBackground.swift"
    if not opacity_component.is_file():
        err.append("InterfaceV2: AorusAnimatedProfileBackground.swift is missing")
    elif "AorusInterfaceV2.isEnabled ? UIColor.clear" not in opacity_component.read_text(encoding="utf-8"):
        err.append("InterfaceV2: the profile transparency slider still paints an opaque card")

    for relative_path, markers in interface_v2_expectations:
        target = tg / relative_path
        if not target.is_file():
            err.append(f"InterfaceV2: {relative_path} is missing")
            continue
        target_text = target.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in target_text:
                err.append(f"InterfaceV2: {relative_path} is missing {marker}")

    undo_build = tg / "submodules" / "UndoUI" / "BUILD"
    if not undo_build.is_file():
        err.append("InterfaceV2: UndoUI BUILD is missing")
    elif "//submodules/TelegramUI/Components/GlassBackgroundComponent" not in undo_build.read_text(encoding="utf-8"):
        err.append("InterfaceV2: UndoUI cannot see GlassBackgroundComponent")

    # Upstream already declares this edge, which is why no pass adds it; checked here so that an
    # upstream bump dropping it fails on this line instead of a hundred lines into swiftc.
    item_list_build = tg / "submodules" / "ItemListUI" / "BUILD"
    if not item_list_build.is_file():
        err.append("InterfaceV2: ItemListUI BUILD is missing")
    elif "//submodules/TelegramUI/Components/GlassBackgroundComponent" not in item_list_build.read_text(encoding="utf-8"):
        err.append("InterfaceV2: ItemListUI cannot see GlassBackgroundComponent")

    if formatting_toolbar.is_file():
        toolbar_text = formatting_toolbar.read_text(encoding="utf-8")
        if 'aorusgram_feature_glass_ui' not in toolbar_text:
            err.append("GlassEffects: formatting toolbar ignores the setting")
        if "@AppStorage" in toolbar_text:
            err.append("GlassEffects: formatting toolbar uses iOS 14-only AppStorage")

    performance_hud = tg / "submodules" / "AorusGramUI" / "Sources" / "Features" / "UI" / "AorusPerformanceHUDManager.swift"
    if not performance_hud.is_file() or "updateGlassAppearance(enabled: settings.glassUI)" not in performance_hud.read_text(encoding="utf-8"):
        err.append("GlassEffects: performance HUD ignores the setting")

    # ICloudResources must stay upstream-stock. A prior rewrite read the picked URL
    # through NSFileCoordinator and bookmarked the coordinator's presented URL instead
    # of the picker's security-scoped one; the bookmark then failed to re-open its scope
    # at upload time, so the copy produced nothing and the file silently never sent.
    # Stock bookmarks the security-scoped URL, which re-opens — proven by Swiftgram on the
    # same third-party certificate — so any reappearance of the coordinator rewrite is a
    # regression, not an improvement.
    document_resources = tg / "submodules" / "ICloudResources" / "Sources" / "ICloudResources.swift"
    document_resources_text = document_resources.read_text(encoding="utf-8") if document_resources.is_file() else ""
    for regression_marker in (
        "AorusGram: coordinate user-selected documents through Files providers",
        "descriptionWithUrl(accessIntent.url)",
    ):
        if regression_marker in document_resources_text:
            err.append(f"DocumentPicker: coordinator rewrite is back — it breaks uploads ({regression_marker})")

    document_size_gate_marker = "AorusGram: let Telegram validate the selected document size"
    document_size_gate_files = (
        tg / "submodules" / "TelegramUI" / "Sources" / "ChatControllerOpenAttachmentMenu.swift",
        tg / "submodules" / "TelegramUI" / "Components" / "Stories" / "StoryContainerScreen" / "Sources" / "StoryItemSetContainerViewSendMessage.swift",
    )
    for document_size_gate_file in document_size_gate_files:
        document_size_gate_text = document_size_gate_file.read_text(encoding="utf-8") if document_size_gate_file.is_file() else ""
        if document_size_gate_marker not in document_size_gate_text:
            err.append(f"DocumentPicker: local file-size gate remains in {document_size_gate_file.name}")
        if "item.fileSize > Int64(premiumLimits.maxUploadFileParts)" in document_size_gate_text:
            err.append(f"DocumentPicker: premium file-size check remains in {document_size_gate_file.name}")
        if "let (accountPeer, limits, premiumLimits) = result" in document_size_gate_text:
            err.append(f"DocumentPicker: removed file-size gate left unused limit bindings in {document_size_gate_file.name}")

    # BGTask identifier in plist
    bgtask_key = "BGTaskSchedulerPermittedIdentifiers"
    bgtask_val = "com.aorusgram.dmc.sync"
    bgtask_ok = bgtask_key in pl and bgtask_val in pl.get(bgtask_key, [])
    if not bgtask_ok:
        err.append(f"Info.plist: missing {bgtask_key} = [{bgtask_val}] (required for deleted-messages BGTask)")

    xc = (tg / "Telegram" / "Telegram-iOS" / "Config-AppStoreLLC.xcconfig").read_text(encoding="utf-8")
    if "APP_NAME=Aorusgram" not in xc:
        err.append("Config-AppStoreLLC.xcconfig missing APP_NAME=Aorusgram")

    if err:
        print("VERIFY FAILED:", file=sys.stderr)
        for e in err:
            print(" ", e, file=sys.stderr)
        sys.exit(1)
    print("verify_aorus_branding: OK")


if __name__ == "__main__":
    main()
