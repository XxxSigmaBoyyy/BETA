import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ComponentFlow

// MARK: - "Прочее" (Other) screen
//
// A spillover screen reachable from the AorusGram settings, holding optional /
// future features so the main settings list stays focused. Currently hosts the
// Local Premium toggle and the Fake Gifts manager.

// AorusGram: the base text style applied to everything you send.
//
// The identifiers and the defaults key are duplicated from AorusAutoFormat in TextFormat
// rather than imported: TextFormat sits below this module and pulling it in just to read
// one string would invert the dependency. scripts/verify_aorus_branding.py pins the two
// lists against each other so they cannot drift apart.
let aorusAutoFormatKey = "aorusgram_auto_format_style"
let aorusAutoFormatOff = "off"
let aorusAutoFormatStyles = ["bold", "italic", "monospace", "strikethrough", "underline", "spoiler"]

func aorusAutoFormatStyle() -> String {
    let stored = UserDefaults.standard.string(forKey: aorusAutoFormatKey) ?? aorusAutoFormatOff
    return aorusAutoFormatStyles.contains(stored) ? stored : aorusAutoFormatOff
}

/// Style names come from Telegram's own formatting menu, so the row reads with the exact
/// wording the user already sees when they format a selection by hand — in every language
/// Telegram ships, with nothing for us to translate or keep in sync.
func aorusAutoFormatLabel(_ style: String, _ strings: PresentationStrings) -> String {
    switch style {
    case "bold": return strings.TextFormat_Bold
    case "italic": return strings.TextFormat_Italic
    case "monospace": return strings.TextFormat_Monospace
    case "strikethrough": return strings.TextFormat_Strikethrough
    case "underline": return strings.TextFormat_Underline
    case "spoiler": return strings.TextFormat_Spoiler
    default: return AorusL10n(strings.baseLanguageCode).appBadgeOff
    }
}

private enum MiscSection: Int32 {
    case premium
    case fakeGifts
    case fakeStars
    case calls
    case autoReplyS
    case antiSearch
    case formattingPanelS
    case animatedWallpapersS
    case animatedBannerS
    case security
    case interfaceV2S
}

private struct MiscState: Equatable {
    var localPremium: Bool
    var fakeStars: Bool
    var fakeStarsAmount: String
    var autoReply: Bool
    var antiSearch: Bool
    var anonymousStickers: Bool
    var profileLink: Bool
    var profileLinkTargetPeerId: Int64
    var profileLinkTargetName: String
    var formattingPanel: Bool
    var autoFormatStyle: String
    var phoneSpoof: Bool
    var phoneSpoofNumber: String
    var mediaMetadata: Bool
    var linkProtection: Bool
    var linkProtectionRedirects: Bool
    var linkProtectionBlockFiles: Bool
    var chatLockEnabled: Bool
    var actionConfirmation: Bool
    var interfaceV2: Bool
}

private final class MiscArguments {
    let setLocalPremium: (Bool) -> Void
    let openFakeGifts: () -> Void
    let setFakeStars: (Bool) -> Void
    let setFakeStarsAmount: (String) -> Void
    let openVoiceTwin: () -> Void
    let openQuickReplies: () -> Void
    let setAutoReply: (Bool) -> Void
    let setAntiSearch: (Bool) -> Void
    let setAnonymousStickers: (Bool) -> Void
    let setProfileLink: (Bool) -> Void
    let selectProfileLinkSelf: () -> Void
    let selectProfileLinkPeer: () -> Void
    let setFormattingPanel: (Bool) -> Void
    let openAutoFormat: () -> Void
    let openAnimatedWallpapers: () -> Void
    let openAnimatedBanner: () -> Void
    let setPhoneSpoof: (Bool) -> Void
    let setPhoneSpoofNumber: (String) -> Void
    let randomizePhoneSpoof: () -> Void
    let setMediaMetadata: (Bool) -> Void
    let setLinkProtection: (Bool) -> Void
    let setLinkProtectionRedirects: (Bool) -> Void
    let setLinkProtectionBlockFiles: (Bool) -> Void
    let openChatLock: () -> Void
    let setActionConfirmation: (Bool) -> Void
    let setInterfaceV2: (Bool) -> Void

    init(setLocalPremium: @escaping (Bool) -> Void, openFakeGifts: @escaping () -> Void, setFakeStars: @escaping (Bool) -> Void, setFakeStarsAmount: @escaping (String) -> Void, openVoiceTwin: @escaping () -> Void, openQuickReplies: @escaping () -> Void, setAutoReply: @escaping (Bool) -> Void, setAntiSearch: @escaping (Bool) -> Void, setAnonymousStickers: @escaping (Bool) -> Void, setProfileLink: @escaping (Bool) -> Void, selectProfileLinkSelf: @escaping () -> Void, selectProfileLinkPeer: @escaping () -> Void, setFormattingPanel: @escaping (Bool) -> Void, openAutoFormat: @escaping () -> Void, openAnimatedWallpapers: @escaping () -> Void, openAnimatedBanner: @escaping () -> Void, setPhoneSpoof: @escaping (Bool) -> Void, setPhoneSpoofNumber: @escaping (String) -> Void, randomizePhoneSpoof: @escaping () -> Void, setMediaMetadata: @escaping (Bool) -> Void, setLinkProtection: @escaping (Bool) -> Void, setLinkProtectionRedirects: @escaping (Bool) -> Void, setLinkProtectionBlockFiles: @escaping (Bool) -> Void, openChatLock: @escaping () -> Void, setActionConfirmation: @escaping (Bool) -> Void, setInterfaceV2: @escaping (Bool) -> Void) {
        self.setLocalPremium = setLocalPremium
        self.openFakeGifts = openFakeGifts
        self.setFakeStars = setFakeStars
        self.setFakeStarsAmount = setFakeStarsAmount
        self.openVoiceTwin = openVoiceTwin
        self.openQuickReplies = openQuickReplies
        self.setAutoReply = setAutoReply
        self.setAntiSearch = setAntiSearch
        self.setAnonymousStickers = setAnonymousStickers
        self.setProfileLink = setProfileLink
        self.selectProfileLinkSelf = selectProfileLinkSelf
        self.selectProfileLinkPeer = selectProfileLinkPeer
        self.setFormattingPanel = setFormattingPanel
        self.openAutoFormat = openAutoFormat
        self.openAnimatedWallpapers = openAnimatedWallpapers
        self.openAnimatedBanner = openAnimatedBanner
        self.setPhoneSpoof = setPhoneSpoof
        self.setPhoneSpoofNumber = setPhoneSpoofNumber
        self.randomizePhoneSpoof = randomizePhoneSpoof
        self.setMediaMetadata = setMediaMetadata
        self.setLinkProtection = setLinkProtection
        self.setLinkProtectionRedirects = setLinkProtectionRedirects
        self.setLinkProtectionBlockFiles = setLinkProtectionBlockFiles
        self.openChatLock = openChatLock
        self.setActionConfirmation = setActionConfirmation
        self.setInterfaceV2 = setInterfaceV2
    }
}

private enum MiscEntry: ItemListNodeEntry {
    case premiumHeader(PresentationTheme, String)
    case localPremium(PresentationTheme, String, Bool)
    case premiumInfo(PresentationTheme, String)
    case fakeGifts(PresentationTheme, String)
    case fakeStarsHeader(PresentationTheme, String)
    case fakeStars(PresentationTheme, String, Bool)
    case fakeStarsCount(PresentationTheme, String, String)
    case fakeStarsInfo(PresentationTheme, String)
    case callsHeader(PresentationTheme, String)
    case voiceTwin(PresentationTheme, String)
    case autoReply(PresentationTheme, String, Bool)
    case antiSearchHeader(PresentationTheme, String)
    case antiSearch(PresentationTheme, String, Bool)
    case antiSearchInfo(PresentationTheme, String)
    case anonymousStickers(PresentationTheme, String, Bool)
    case anonymousStickersInfo(PresentationTheme, String)
    case profileLink(PresentationTheme, String, Bool)
    case profileLinkSelf(PresentationTheme, String, String)
    case profileLinkPeer(PresentationTheme, String, String)
    case profileLinkInfo(PresentationTheme, String)
    case formattingPanel(PresentationTheme, String, Bool)
    case autoFormat(PresentationTheme, String, String)
    case animatedWallpapers(PresentationTheme, String)
    case animatedBanner(PresentationTheme, String)
    case phoneSpoof(PresentationTheme, String, Bool)
    case phoneSpoofNumber(PresentationTheme, String, String)
    case phoneSpoofRandomize(PresentationTheme, String)
    case phoneSpoofInfo(PresentationTheme, String)
    case mediaMetadata(PresentationTheme, String, Bool)
    case mediaMetadataInfo(PresentationTheme, String)
    case securityHeader(PresentationTheme, String)
    case chatLock(PresentationTheme, String, String)
    case linkProtection(PresentationTheme, String, Bool)
    case linkProtectionRedirects(PresentationTheme, String, Bool)
    case linkProtectionBlockFiles(PresentationTheme, String, Bool)
    case linkProtectionInfo(PresentationTheme, String)
    case actionConfirmation(PresentationTheme, String, Bool)
    case actionConfirmationInfo(PresentationTheme, String)
    case interfaceV2Header(PresentationTheme, String)
    case interfaceV2(PresentationTheme, String, Bool)
    case interfaceV2Info(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .premiumHeader, .localPremium, .premiumInfo:
            return MiscSection.premium.rawValue
        case .fakeGifts:
            return MiscSection.fakeGifts.rawValue
        case .fakeStarsHeader, .fakeStars, .fakeStarsCount, .fakeStarsInfo:
            return MiscSection.fakeStars.rawValue
        case .callsHeader, .voiceTwin:
            return MiscSection.calls.rawValue
        case .autoReply:
            return MiscSection.autoReplyS.rawValue
        case .antiSearchHeader, .antiSearch, .antiSearchInfo, .anonymousStickers, .anonymousStickersInfo,
             .profileLink, .profileLinkSelf, .profileLinkPeer, .profileLinkInfo, .phoneSpoof, .phoneSpoofNumber,
             .phoneSpoofRandomize, .phoneSpoofInfo, .mediaMetadata, .mediaMetadataInfo:
            return MiscSection.antiSearch.rawValue
        case .formattingPanel, .autoFormat:
            return MiscSection.formattingPanelS.rawValue
        case .animatedWallpapers:
            return MiscSection.animatedWallpapersS.rawValue
        case .animatedBanner:
            return MiscSection.animatedBannerS.rawValue
        case .securityHeader, .linkProtection, .linkProtectionRedirects, .linkProtectionBlockFiles, .linkProtectionInfo, .chatLock,
             .actionConfirmation, .actionConfirmationInfo:
            return MiscSection.security.rawValue
        case .interfaceV2Header, .interfaceV2, .interfaceV2Info:
            return MiscSection.interfaceV2S.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .premiumHeader:    return 0
        case .localPremium:     return 1
        case .premiumInfo:      return 2
        case .fakeGifts:        return 10
        case .fakeStarsHeader:  return 20
        case .fakeStars:        return 21
        case .fakeStarsCount:   return 22
        case .fakeStarsInfo:    return 23
        case .callsHeader:      return 24
        case .voiceTwin:        return 25
        case .autoReply:        return 26
        case .antiSearchHeader: return 30
        case .antiSearch:       return 31
        case .antiSearchInfo:   return 32
        case .anonymousStickers:return 33
        case .anonymousStickersInfo: return 34
        case .profileLink:      return 35
        case .profileLinkSelf:  return 36
        case .profileLinkPeer:  return 37
        case .profileLinkInfo:  return 38
        case .phoneSpoof:       return 39
        case .phoneSpoofNumber: return 40
        case .phoneSpoofRandomize: return 41
        case .phoneSpoofInfo:   return 42
        case .mediaMetadata:    return 43
        case .mediaMetadataInfo:return 44
        case .formattingPanel:  return 46
        case .autoFormat:       return 49
        case .animatedWallpapers: return 47
        case .animatedBanner:   return 48
        case .securityHeader:   return 50
        case .linkProtection:   return 51
        case .linkProtectionRedirects: return 52
        case .linkProtectionBlockFiles: return 53
        case .linkProtectionInfo: return 54
        case .chatLock:         return 55
        case .actionConfirmation: return 56
        case .actionConfirmationInfo: return 57
        case .interfaceV2Header: return 60
        case .interfaceV2:      return 61
        case .interfaceV2Info:  return 62
        }
    }

    static func < (lhs: MiscEntry, rhs: MiscEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: MiscEntry, rhs: MiscEntry) -> Bool {
        switch lhs {
        case let .premiumHeader(lt, ls):
            if case let .premiumHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .localPremium(lt, ls, lv):
            if case let .localPremium(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .premiumInfo(lt, ls):
            if case let .premiumInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .fakeGifts(lt, ls):
            if case let .fakeGifts(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .fakeStarsHeader(lt, ls):
            if case let .fakeStarsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .fakeStars(lt, ls, lv):
            if case let .fakeStars(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .fakeStarsCount(lt, ls, lv):
            if case let .fakeStarsCount(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .fakeStarsInfo(lt, ls):
            if case let .fakeStarsInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .callsHeader(lt, ls):
            if case let .callsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .voiceTwin(lt, ls):
            if case let .voiceTwin(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .autoReply(lt, ls, lv):
            if case let .autoReply(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSearchHeader(lt, ls):
            if case let .antiSearchHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .antiSearch(lt, ls, lv):
            if case let .antiSearch(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSearchInfo(lt, ls):
            if case let .antiSearchInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .anonymousStickers(lt, ls, lv):
            if case let .anonymousStickers(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .anonymousStickersInfo(lt, ls):
            if case let .anonymousStickersInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .profileLink(lt, ls, lv):
            if case let .profileLink(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .profileLinkSelf(lt, ls, lv):
            if case let .profileLinkSelf(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .profileLinkPeer(lt, ls, lv):
            if case let .profileLinkPeer(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .profileLinkInfo(lt, ls):
            if case let .profileLinkInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .formattingPanel(lt, ls, lv):
            if case let .formattingPanel(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .autoFormat(lt, ls, lv):
            if case let .autoFormat(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .animatedWallpapers(lt, ls):
            if case let .animatedWallpapers(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .animatedBanner(lt, ls):
            if case let .animatedBanner(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .phoneSpoof(lt, ls, lv):
            if case let .phoneSpoof(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .phoneSpoofNumber(lt, ls, lv):
            if case let .phoneSpoofNumber(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .phoneSpoofRandomize(lt, ls):
            if case let .phoneSpoofRandomize(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .phoneSpoofInfo(lt, ls):
            if case let .phoneSpoofInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .mediaMetadata(lt, ls, lv):
            if case let .mediaMetadata(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .mediaMetadataInfo(lt, ls):
            if case let .mediaMetadataInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .securityHeader(lt, ls):
            if case let .securityHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .chatLock(lt, ls, lv):
            if case let .chatLock(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .linkProtection(lt, ls, lv):
            if case let .linkProtection(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .linkProtectionRedirects(lt, ls, lv):
            if case let .linkProtectionRedirects(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .linkProtectionBlockFiles(lt, ls, lv):
            if case let .linkProtectionBlockFiles(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .linkProtectionInfo(lt, ls):
            if case let .linkProtectionInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .actionConfirmation(lt, ls, lv):
            if case let .actionConfirmation(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .actionConfirmationInfo(lt, ls):
            if case let .actionConfirmationInfo(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .interfaceV2Header(lt, ls):
            if case let .interfaceV2Header(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .interfaceV2(lt, ls, lv):
            if case let .interfaceV2(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .interfaceV2Info(lt, ls):
            if case let .interfaceV2Info(rt, rs) = rhs { return lt === rt && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! MiscArguments
        switch self {
        case let .premiumHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .localPremium(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setLocalPremium($0) })
        case let .premiumInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .fakeGifts(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openFakeGifts)
        case let .fakeStarsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .fakeStars(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setFakeStars($0) })
        case let .fakeStarsCount(_, placeholder, value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                title: NSAttributedString(string: ""),
                text: value,
                placeholder: placeholder,
                type: .regular(capitalization: false, autocorrection: false),
                returnKeyType: .done,
                sectionId: section,
                textUpdated: { text in
                    args.setFakeStarsAmount(text)
                },
                shouldUpdateText: { text in
                    return text.allSatisfy { $0.isNumber }
                },
                action: {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            )
        case let .fakeStarsInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .callsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .voiceTwin(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openVoiceTwin)
        case let .autoReply(_, title, _):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openQuickReplies)
        case let .antiSearchHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .antiSearch(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setAntiSearch($0) })
        case let .antiSearchInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .anonymousStickers(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setAnonymousStickers($0) })
        case let .anonymousStickersInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .profileLink(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setProfileLink($0) })
        case let .profileLinkSelf(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: args.selectProfileLinkSelf)
        case let .profileLinkPeer(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, action: args.selectProfileLinkPeer)
        case let .profileLinkInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .formattingPanel(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setFormattingPanel($0) })
        case let .autoFormat(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, action: args.openAutoFormat)
        case let .animatedWallpapers(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openAnimatedWallpapers)
        case let .animatedBanner(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openAnimatedBanner)
        case let .phoneSpoof(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setPhoneSpoof($0) })
        case let .phoneSpoofNumber(_, placeholder, value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                title: NSAttributedString(string: ""),
                text: value,
                placeholder: placeholder,
                returnKeyType: .done,
                sectionId: section,
                textUpdated: { text in
                    args.setPhoneSpoofNumber(text)
                },
                action: {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            )
        case let .phoneSpoofRandomize(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, disclosureStyle: .none, action: args.randomizePhoneSpoof)
        case let .phoneSpoofInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .mediaMetadata(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setMediaMetadata($0) })
        case let .mediaMetadataInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .securityHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .chatLock(_, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: label, sectionId: section, style: .blocks, action: args.openChatLock)
        case let .linkProtection(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setLinkProtection($0) })
        case let .linkProtectionRedirects(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setLinkProtectionRedirects($0) })
        case let .linkProtectionBlockFiles(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setLinkProtectionBlockFiles($0) })
        case let .linkProtectionInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .actionConfirmation(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setActionConfirmation($0) })
        case let .actionConfirmationInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .interfaceV2Header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .interfaceV2(_, title, value):
            // A fixed blue rather than the theme accent: AorusGram's accent is purple, and a
            // purple BETA tag next to a purple switch stops reading as a tag at all.
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                titleBadgeComponent: AnyComponent(AorusBetaBadgeComponent(
                    text: "BETA",
                    color: UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
                )),
                value: value,
                sectionId: section,
                style: .blocks,
                updated: { args.setInterfaceV2($0) }
            )
        case let .interfaceV2Info(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        }
    }
}

private func miscEntries(state: MiscState, theme: PresentationTheme, strings: PresentationStrings) -> [MiscEntry] {
    var entries: [MiscEntry] = []

    entries.append(.premiumHeader(theme, aorusL("ПРЕМИУМ", "PREMIUM")))
    entries.append(.localPremium(theme, aorusL("Локальный премиум", "Local Premium"), state.localPremium))
    entries.append(.premiumInfo(theme, aorusL("Включает Telegram Premium локально на этом устройстве — функции работают только у вас.", "Enables Telegram Premium locally on this device — the features work only for you.")))

    entries.append(.fakeGifts(theme, aorusL("Фейковые подарки", "Fake Gifts")))

    entries.append(.fakeStarsHeader(theme, aorusL("ЗВЁЗДЫ", "STARS")))
    entries.append(.fakeStars(theme, aorusL("Фейковые звёзды", "Fake Stars"), state.fakeStars))
    // The amount row animates in/out with the toggle (the list uses animateChanges).
    if state.fakeStars {
        entries.append(.fakeStarsCount(theme, aorusL("Количество", "Amount"), state.fakeStarsAmount))
    }
    entries.append(.fakeStarsInfo(theme, aorusL("Показывает указанный баланс звёзд локально, только у вас. Реальные звёзды не создаются и не тратятся.", "Shows the entered Stars balance locally, only for you. No real stars are created or spent.")))

    // Voice Twin (Calls) moved to the main AorusGram screen. Auto-Reply stays
    // here as a separate headerless block.
    entries.append(.autoReply(theme, aorusL("Быстрые ответы", "Quick Replies"), state.autoReply))

    // ANTI-SEARCH header intentionally removed — the block stays, just untitled.
    entries.append(.antiSearch(theme, aorusL("АнтиПоиск", "AntiSearch"), state.antiSearch))
    entries.append(.antiSearchInfo(theme, aorusL("Заменяет только визуально идентичные буквы, чтобы текст выглядел так же, но хуже находился поиском.", "Swaps only visually identical letters so the text looks the same but is harder to match in search.")))
    entries.append(.anonymousStickers(theme, aorusL("Анонимные стикеры", "Anonymous Stickers"), state.anonymousStickers))
    entries.append(.anonymousStickersInfo(theme, aorusL("Отправляет ваши стикеры без ссылки на набор: клиент переупаковывает файл и убирает привязку к стикерпаку.", "Sends your stickers without a sticker-pack link: the client repacks the file and removes pack attribution.")))
    entries.append(.profileLink(theme, aorusL("Гиперссылка на профиль", "Profile Link"), state.profileLink))
    if state.profileLink {
        entries.append(.profileLinkSelf(theme, aorusL("Мой профиль", "My Profile"), state.profileLinkTargetPeerId == 0 ? (aorusL("Выбрано", "Selected")) : ""))
        entries.append(.profileLinkPeer(theme, aorusL("Чужой профиль", "Other Profile"), state.profileLinkTargetPeerId == 0 ? (aorusL("Выбрать", "Choose")) : state.profileLinkTargetName))
    }
    entries.append(.profileLinkInfo(theme, aorusL("Делает весь текст ваших исходящих сообщений кликабельным упоминанием выбранного профиля.", "Makes the whole text of your outgoing messages a clickable mention of the selected profile.")))
    entries.append(.phoneSpoof(theme, aorusL("Подмена номера", "Phone Spoofing"), state.phoneSpoof))
    if state.phoneSpoof {
        entries.append(.phoneSpoofNumber(theme, aorusL("Номер", "Number"), state.phoneSpoofNumber))
        entries.append(.phoneSpoofRandomize(theme, aorusL("Рандомизировать", "Randomize")))
    }
    entries.append(.phoneSpoofInfo(theme, aorusL("Когда бот просит номер телефона, клиент отправляет защищённый номер вместо настоящего.", "When a bot asks for your phone number, the client sends a protected number instead of your real one.")))
    entries.append(.mediaMetadata(theme, aorusL("Метаданные медиа", "Media Metadata"), state.mediaMetadata))
    entries.append(.mediaMetadataInfo(theme, aorusL("Добавляет пункт «Метаданные» в меню фото, видео и GIF и показывает доступные EXIF, GPS, камеру, контейнер и файл.", "Adds a Metadata item to photos, videos and GIFs and shows available EXIF, GPS, camera, container and file data.")))
    entries.append(.formattingPanel(theme, aorusL("Панель форматирования", "Formatting Panel"), state.formattingPanel))
    entries.append(.autoFormat(theme, aorusL("Авто-форматирование", "Auto-formatting"), aorusAutoFormatLabel(state.autoFormatStyle, strings)))
    entries.append(.animatedWallpapers(theme, aorusL("Анимированные обои", "Animated Wallpapers")))
    entries.append(.animatedBanner(theme, aorusL("Анимированный баннер", "Animated Banner")))

    entries.append(.securityHeader(theme, aorusL("БЕЗОПАСНОСТЬ", "SECURITY")))
    entries.append(.chatLock(theme, aorusL("Защита чатов", "Chat Protection"),
                             state.chatLockEnabled ? (aorusL("Вкл", "On")) : ""))
    entries.append(.linkProtection(theme, aorusL("Защита ссылок", "Link Protection"), state.linkProtection))
    if state.linkProtection {
        entries.append(.linkProtectionRedirects(theme, aorusL("Проверять редиректы", "Check Redirects"), state.linkProtectionRedirects))
        entries.append(.linkProtectionBlockFiles(theme, aorusL("Блокировать опасные файлы", "Block Dangerous Files"), state.linkProtectionBlockFiles))
    }
    entries.append(.linkProtectionInfo(theme, aorusL("Предупреждает о подмене доменов, Punycode, сокращателях, редиректах, опасных схемах и файлах до открытия ссылки.", "Warns about spoofed domains, Punycode, shorteners, redirects, dangerous schemes and files before opening a link.")))
    entries.append(.actionConfirmation(theme, aorusL("Подтверждение действий", "Action Confirmation"), state.actionConfirmation))
    entries.append(.actionConfirmationInfo(theme, aorusL("Спрашивает подтверждение перед звонком и перед отправкой записанного голосового или видеосообщения.", "Asks for confirmation before placing a call and before sending a recorded voice or video message.")))

    entries.append(.interfaceV2Header(theme, aorusL("ИНТЕРФЕЙС", "INTERFACE")))
    entries.append(.interfaceV2(theme, "Interface 2.0", state.interfaceV2))
    entries.append(.interfaceV2Info(theme, aorusL(
        "Стеклянный интерфейс.",
        "Glass interface."
    )))

    return entries
}

public func aorusMiscController(context: AccountContext, shortcutRoutes: AorusSettingsShortcutRoutes) -> ViewController {
    let accountId = context.account.id.int64
    let initialFakeStars = AorusFakeStarsStore.isEnabled
    let initialFakeStarsAmount = AorusFakeStarsStore.amount > 0 ? "\(AorusFakeStarsStore.amount)" : ""
    let initialProfileLinkTargetPeerId = Int64(UserDefaults.standard.string(forKey: "aorusgram_profile_link_target_peer_id") ?? "") ?? 0
    let initialState = MiscState(
        localPremium: AorusLocalPremium.isEnabled,
        fakeStars: initialFakeStars,
        fakeStarsAmount: initialFakeStarsAmount,
        autoReply: AorusGramManager.shared.autoReply,
        antiSearch: AorusAntiSearchStore.isEnabled,
        anonymousStickers: UserDefaults.standard.bool(forKey: "aorusgram_anonymous_stickers_enabled"),
        profileLink: UserDefaults.standard.bool(forKey: "aorusgram_profile_link_enabled"),
        profileLinkTargetPeerId: initialProfileLinkTargetPeerId,
        profileLinkTargetName: UserDefaults.standard.string(forKey: "aorusgram_profile_link_target_name") ?? "",
        formattingPanel: UserDefaults.standard.bool(forKey: "aorusgram_formatting_panel"),
        autoFormatStyle: aorusAutoFormatStyle(),
        phoneSpoof: AorusPhoneSpoofStore.isEnabled,
        phoneSpoofNumber: AorusPhoneSpoofStore.ensureNumber(),
        mediaMetadata: UserDefaults.standard.bool(forKey: "aorusgram_media_metadata_enabled"),
        linkProtection: AorusLinkProtection.isEnabled,
        linkProtectionRedirects: AorusLinkProtection.checksRedirects,
        linkProtectionBlockFiles: AorusLinkProtection.blocksDangerousFiles,
        chatLockEnabled: AorusChatLock.isEnabled(accountId: accountId),
        actionConfirmation: AorusActionConfirmation.isEnabled,
        interfaceV2: AorusInterfaceV2.isEnabled
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((MiscState) -> MiscState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    weak var weakController: ItemListController?
    let actionsDisposable = DisposableSet()
    let fakeStarsObserver = NotificationCenter.default.addObserver(
        forName: AorusFakeStarsStore.changedNotification,
        object: nil,
        queue: .main
    ) { _ in
        updateState { current in
            var next = current
            next.fakeStars = AorusFakeStarsStore.isEnabled
            let amount = AorusFakeStarsStore.amount
            next.fakeStarsAmount = amount > 0 ? "\(amount)" : ""
            return next
        }
    }

    let chatLockObserver = NotificationCenter.default.addObserver(
        forName: AorusChatLock.changedNotification,
        object: nil,
        queue: .main
    ) { notification in
        if let changedAccountId = (notification.object as? NSNumber)?.int64Value,
           changedAccountId != accountId {
            return
        }
        updateState { current in
            var next = current
            next.chatLockEnabled = AorusChatLock.isEnabled(accountId: accountId)
            return next
        }
    }
    actionsDisposable.add(ActionDisposable {
        NotificationCenter.default.removeObserver(fakeStarsObserver)
        NotificationCenter.default.removeObserver(chatLockObserver)
    })

    let arguments = MiscArguments(
        setLocalPremium: { value in
            AorusLocalPremium.setEnabled(value)
            updateState { current in
                var next = current
                next.localPremium = value
                return next
            }
        },
        openFakeGifts: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(aorusFakeGiftsController(context: context))
        },
        setFakeStars: { value in
            AorusFakeStarsStore.setEnabled(value)
            updateState { current in
                var next = current
                next.fakeStars = value
                return next
            }
        },
        setFakeStarsAmount: { text in
            // Keep digits only; an empty field means zero.
            let digits = text.filter { $0.isNumber }
            let amount = Int64(digits) ?? 0
            AorusFakeStarsStore.setAmount(amount)
            updateState { current in
                var next = current
                next.fakeStarsAmount = digits
                return next
            }
        },
        openVoiceTwin: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(voiceTwinController(context: context))
        },
        openQuickReplies: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(aorusQuickRepliesController(context: context))
        },
        setAutoReply: { value in
            AorusGramManager.shared.autoReply = value
            updateState { current in
                var next = current
                next.autoReply = value
                return next
            }
        },
        setAntiSearch: { value in
            AorusAntiSearchStore.setEnabled(value)
            updateState { current in
                var next = current
                next.antiSearch = value
                return next
            }
        },
        setAnonymousStickers: { value in
            UserDefaults.standard.set(value, forKey: "aorusgram_anonymous_stickers_enabled")
            updateState { current in
                var next = current
                next.anonymousStickers = value
                return next
            }
        },
        setProfileLink: { value in
            UserDefaults.standard.set(value, forKey: "aorusgram_profile_link_enabled")
            updateState { current in
                var next = current
                next.profileLink = value
                return next
            }
        },
        selectProfileLinkSelf: {
            UserDefaults.standard.removeObject(forKey: "aorusgram_profile_link_target_peer_id")
            UserDefaults.standard.removeObject(forKey: "aorusgram_profile_link_target_name")
            updateState { current in
                var next = current
                next.profileLinkTargetPeerId = 0
                next.profileLinkTargetName = ""
                return next
            }
        },
        selectProfileLinkPeer: {
            let selectionController = context.sharedContext.makeContactSelectionController(ContactSelectionControllerParams(
                context: context,
                autoDismiss: false,
                title: { strings in return strings.Contacts_Title }
            ))
            actionsDisposable.add((selectionController.result
            |> deliverOnMainQueue).start(next: { [weak selectionController] result in
                selectionController?.dismiss()
                if let (peers, _, _, _, _, _) = result, let first = peers.first, case let .peer(peer, _, _) = first {
                    let peerId = peer.id.toInt64()
                    let peerName = peer.compactDisplayTitle
                    UserDefaults.standard.set("\(peerId)", forKey: "aorusgram_profile_link_target_peer_id")
                    UserDefaults.standard.set(peerName, forKey: "aorusgram_profile_link_target_name")
                    updateState { current in
                        var next = current
                        next.profileLinkTargetPeerId = peerId
                        next.profileLinkTargetName = peerName
                        return next
                    }
                }
            }))
            weakController?.push(selectionController)
        },
        setFormattingPanel: { value in
            UserDefaults.standard.set(value, forKey: "aorusgram_formatting_panel")
            updateState { current in
                var next = current
                next.formattingPanel = value
                return next
            }
        },
        openAutoFormat: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            // A pushed screen rather than an action sheet: the list of styles is long enough
            // that a full screen reads better, and it matches the Font picker next to it.
            let screen = aorusAutoFormatController(context: context, onChange: { style in
                updateState { s in var n = s; n.autoFormatStyle = style; return n }
            })
            navigationController.pushViewController(screen)
        },
        openAnimatedWallpapers: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            AorusSettingsShortcutHighlight.request(.animatedWallpapers)
            navigationController.pushViewController(shortcutRoutes.animatedWallpapers())
        },
        openAnimatedBanner: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            AorusSettingsShortcutHighlight.request(.animatedBanner)
            navigationController.pushViewController(shortcutRoutes.animatedBanner())
        },
        setPhoneSpoof: { value in
            AorusPhoneSpoofStore.setEnabled(value)
            let number = AorusPhoneSpoofStore.ensureNumber()
            updateState { current in
                var next = current
                next.phoneSpoof = value
                next.phoneSpoofNumber = number
                return next
            }
        },
        setPhoneSpoofNumber: { text in
            let number = AorusPhoneSpoofStore.setNumber(text)
            updateState { current in
                var next = current
                next.phoneSpoofNumber = number
                return next
            }
        },
        randomizePhoneSpoof: {
            let number = AorusPhoneSpoofStore.randomize()
            updateState { current in
                var next = current
                next.phoneSpoofNumber = number
                return next
            }
        },
        setMediaMetadata: { value in
            UserDefaults.standard.set(value, forKey: "aorusgram_media_metadata_enabled")
            updateState { current in
                var next = current
                next.mediaMetadata = value
                return next
            }
        },
        setLinkProtection: { value in
            AorusLinkProtection.setEnabled(value)
            updateState { current in
                var next = current
                next.linkProtection = value
                return next
            }
        },
        setLinkProtectionRedirects: { value in
            AorusLinkProtection.setChecksRedirects(value)
            updateState { current in
                var next = current
                next.linkProtectionRedirects = value
                return next
            }
        },
        setLinkProtectionBlockFiles: { value in
            AorusLinkProtection.setBlocksDangerousFiles(value)
            updateState { current in
                var next = current
                next.linkProtectionBlockFiles = value
                return next
            }
        },
        openChatLock: {
            // The settings screen itself is protected: it can switch the feature off and
            // reveals which chats are protected, so it must sit behind the same gate.
            let present: () -> Void = {
                weakController?.push(aorusChatLockController(context: context))
            }
            if AorusChatLock.settingsRequireAuth(accountId: accountId) {
                AorusChatLock.authenticate(accountId: accountId, reason: aorusL("Разблокируйте настройки защиты чатов", "Unlock Chat Protection settings")) { success in
                    if success {
                        present()
                    }
                }
            } else {
                present()
            }
        },
        setActionConfirmation: { value in
            AorusActionConfirmation.isEnabled = value
            updateState { current in
                var next = current
                next.actionConfirmation = value
                return next
            }
        },
        setInterfaceV2: { value in
            AorusInterfaceV2.setEnabled(value)
            // Screens already on the stack keep the header and theme they were built with, so
            // the change only fully lands after a relaunch. The same pill every other
            // restart-requiring toggle in the fork uses -- text plus a button that actually
            // performs the restart -- instead of a toast that states the requirement and then
            // leaves the user to work out how to meet it.
            aorusPresentRestartNotice(context: context, controller: weakController)
            updateState { current in
                var next = current
                next.interfaceV2 = value
                return next
            }
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let entries = miscEntries(state: state, theme: presentationData.theme, strings: presentationData.strings)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(aorusL("Прочее", "Other")),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks
            )
            return (controllerState, (listState, arguments))
        }
        |> afterDisposed {
            actionsDisposable.dispose()
        }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
