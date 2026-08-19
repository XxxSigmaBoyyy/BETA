import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Interval slider

// Discrete snap points for performance sliders.
private let _aorusCacheIntervalPresets = [6, 24, 168, 720]       // hours
private let _aorusRAMIntervalPresets = [30, 60, 300, 900]        // seconds

// Format an hours value for the slider's trailing label.
// The number goes in after translation, not before: an interpolated string reaching
// aorusL() differs on every value and could never match a key in AorusL10nTable.
private func _aorusCacheIntervalText(_ hours: Int, isRu: Bool) -> String {
    if hours % 24 == 0 {
        let d = hours / 24
        return aorusL("%@ дн", "%@ d").replacingOccurrences(of: "%@", with: "\(d)")
    }
    return aorusL("%@ ч", "%@ h").replacingOccurrences(of: "%@", with: "\(hours)")
}

private func _aorusRAMIntervalText(_ seconds: Int, isRu: Bool) -> String {
    if seconds < 60 {
        return aorusL("%@ сек", "%@ sec").replacingOccurrences(of: "%@", with: "\(seconds)")
    }
    let minutes = seconds / 60
    return aorusL("%@ мин", "%@ min").replacingOccurrences(of: "%@", with: "\(minutes)")
}

/// A settings row that embeds a discrete UISlider for cleanup intervals.
private final class AorusIntervalSliderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let title: String
    let value: Int
    let presets: [Int]
    let valueText: (Int, Bool) -> String
    let sectionId: ItemListSectionId
    let requestsNoInset: Bool = false
    let updated: (Int) -> Void

    init(theme: PresentationTheme, title: String, value: Int,
         presets: [Int] = _aorusCacheIntervalPresets,
         valueText: @escaping (Int, Bool) -> String = _aorusCacheIntervalText,
         sectionId: ItemListSectionId, updated: @escaping (Int) -> Void) {
        self.theme = theme
        self.title = title
        self.value = value
        self.presets = presets
        self.valueText = valueText
        self.sectionId = sectionId
        self.updated = updated
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void,
                                  params: ListViewItemLayoutParams,
                                  synchronousLoads: Bool,
                                  previousItem: ListViewItem?,
                                  nextItem: ListViewItem?,
                                  completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AorusIntervalSliderItemNode()
            let (layout, apply) = node.asyncLayout()(
                self, params,
                itemListNeighbors(item: self,
                                  topItem: previousItem as? ItemListItem,
                                  bottomItem: nextItem as? ItemListItem))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { return (nil, { _ in apply() }) })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void,
                    node: @escaping () -> ListViewItemNode,
                    params: ListViewItemLayoutParams,
                    previousItem: ListViewItem?,
                    nextItem: ListViewItem?,
                    animation: ListViewItemUpdateAnimation,
                    completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AorusIntervalSliderItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(
                        self, params,
                        itemListNeighbors(item: self,
                                          topItem: previousItem as? ItemListItem,
                                          bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async { completion(layout, { _ in apply() }) }
                }
            }
        }
    }
}

private final class AorusIntervalSliderItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode  = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()

    private weak var titleLabel: UILabel?
    private weak var valueLabel: UILabel?
    private weak var sliderView: UISlider?

    private var item: AorusIntervalSliderItem?
    private var layoutParams: ListViewItemLayoutParams?

    init() {
        backgroundNode.isLayerBacked  = true
        topStripeNode.isLayerBacked   = true
        bottomStripeNode.isLayerBacked = true
        super.init(layerBacked: false)
        addSubnode(backgroundNode)
        addSubnode(topStripeNode)
        addSubnode(bottomStripeNode)
        addSubnode(maskNode)
    }

    // Symmetric fade: the row appears AND disappears with the same animation
    // when Auto-Clean Cache is toggled (previously the removal was instant).
    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
    }

    override func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
    }

    override func didLoad() {
        super.didLoad()

        let tl = UILabel()
        tl.font = .systemFont(ofSize: 17)
        view.addSubview(tl)
        titleLabel = tl

        let vl = UILabel()
        vl.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        vl.textAlignment = .right
        view.addSubview(vl)
        valueLabel = vl

        let sl = UISlider()
        sl.minimumValue = 0
        sl.maximumValue = 0
        sl.isContinuous = true
        sl.addTarget(self, action: #selector(sliderMoved(_:)), for: .valueChanged)
        sl.addTarget(self, action: #selector(sliderEnded(_:)),
                     for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(sl)
        sliderView = sl

        if let item = item { applyItem(item) }
        layoutSubviews()
    }

    private func applyItem(_ item: AorusIntervalSliderItem) {
        let isRu = UserDefaults.standard.string(forKey: "aorusgram_lang") == "ru"
        let idx = item.presets.firstIndex(of: item.value) ?? min(1, max(0, item.presets.count - 1))
        titleLabel?.text = item.title
        titleLabel?.textColor = item.theme.list.itemPrimaryTextColor
        valueLabel?.text = item.valueText(item.presets[idx], isRu)
        valueLabel?.textColor = item.theme.list.itemSecondaryTextColor
        sliderView?.maximumValue = Float(max(0, item.presets.count - 1))
        sliderView?.value = Float(idx)
        sliderView?.tintColor = item.theme.list.itemAccentColor
    }

    private func layoutSubviews() {
        guard let p = layoutParams else { return }
        let li = p.leftInset + 16
        let ri = p.rightInset + 16
        let w  = p.width
        titleLabel?.frame = CGRect(x: li,          y: 12, width: w - li - ri - 68, height: 22)
        valueLabel?.frame  = CGRect(x: w - ri - 66, y: 12, width: 62,              height: 22)
        sliderView?.frame  = CGRect(x: li - 4,      y: 38, width: w - li - ri + 8, height: 30)
    }

    @objc private func sliderMoved(_ sender: UISlider) {
        guard let item = item else { return }
        let idx = max(0, min(Int(sender.value.rounded()), item.presets.count - 1))
        sender.value = Float(idx)
        let isRu = UserDefaults.standard.string(forKey: "aorusgram_lang") == "ru"
        valueLabel?.text = item.valueText(item.presets[idx], isRu)
    }

    @objc private func sliderEnded(_ sender: UISlider) {
        guard let item = item else { return }
        let idx = max(0, min(Int(sender.value.rounded()), item.presets.count - 1))
        sender.value = Float(idx)
        item.updated(item.presets[idx])
    }

    func asyncLayout() -> (AorusIntervalSliderItem, ListViewItemLayoutParams, ItemListNeighbors)
        -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let sep = UIScreenPixel
            let contentSize = CGSize(width: params.width, height: 74)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, { [weak self] in
                guard let self = self else { return }
                self.item = item
                self.layoutParams = params

                self.backgroundNode.backgroundColor  = item.theme.list.itemBlocksBackgroundColor
                self.topStripeNode.backgroundColor    = item.theme.list.itemBlocksSeparatorColor
                self.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var topCorners = false, bottomCorners = false

                switch neighbors.top {
                case .sameSection(false): self.topStripeNode.isHidden = true
                default: topCorners = true; self.topStripeNode.isHidden = hasCorners
                }

                let bInset: CGFloat
                let bOff: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bInset = params.leftInset + 16; bOff = -sep
                    self.bottomStripeNode.isHidden = false
                default:
                    bInset = 0; bOff = 0; bottomCorners = true
                    self.bottomStripeNode.isHidden = hasCorners
                }

                self.maskNode.image = hasCorners
                    ? PresentationResourcesItemList.cornersImage(item.theme,
                                                                  top: topCorners,
                                                                  bottom: bottomCorners)
                    : nil

                let bgY = -min(insets.top, sep)
                let bgH = contentSize.height + min(insets.top, sep) + min(insets.bottom, sep)
                self.backgroundNode.frame   = CGRect(x: 0, y: bgY, width: params.width, height: bgH)
                self.maskNode.frame         = self.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0)
                self.topStripeNode.frame    = CGRect(x: 0, y: bgY, width: params.width, height: sep)
                self.bottomStripeNode.frame = CGRect(x: bInset,
                                                     y: contentSize.height + bOff,
                                                     width: params.width - bInset, height: sep)

                self.applyItem(item)
                self.layoutSubviews()
            })
        }
    }
}

// MARK: - Sections

private enum AorusSection: Int32 {
    case privacy
    case ai
    case performance
    case ui
    case tabs
    case deviceSpoof
    case bypass
    case antiSpoof
    case accountBackup
    case aorusCode
    case channel
    case editLocal
    case quickButtons
    case voiceMessages
    case videoMessages
    case calls
    case wall
    case misc
}

// MARK: - State

private struct AorusState: Equatable {
    var ghostMode: Bool
    var blockReadReceipts: Bool
    var hideTyping: Bool
    var saveDeletedMessages: Bool
    var saveEditedMessages: Bool
    var antiScreenshot: Bool
    var callRecording: Bool
    var voiceTranscription: Bool
    var translator: Bool
    var shareButton: Bool
    var videoMessagesRearCamera: Bool
    var deviceMicrophone: Bool
    var autoReply: Bool
    var downloadAccel: Bool
    var maxMediaQuality: Bool
    var antiSpamEnabled: Bool
    var performanceStatsEnabled: Bool
    var performanceShowUptime: Bool
    var performanceShowRAM: Bool
    var performanceShowCPU: Bool
    var performanceShowFPS: Bool
    var performanceShowBattery: Bool
    var performanceShowNetwork: Bool
    var performanceShowDisk: Bool
    var performanceShowThermal: Bool
    var performanceShowGraph: Bool
    var ramAutoClean: Bool
    var ramCleanInterval: Int
    var cacheAutoClean: Bool
    var cacheCleanInterval: Int
    var editLocally: Bool
    var userMessages: Bool
    var messageSeconds: Bool
    var doubleTapCopy: Bool
    var tripleTapDelete: Bool
    var glassUI: Bool
    var showStories: Bool
    var amoledMode: Bool
    var profileReportButton: Bool
    var hideCallsTab: Bool
    var hideContactsTab: Bool
    var hideSearchButton: Bool
    var hideTabTitles: Bool
    var compactTabBar: Bool
    var wallEnabled: Bool
    var siriShortcuts: Bool
    var appBadge: String
    var squareAvatars: Bool
    var antiSpoofDeleted: Bool
    var antiSpoofOnline: Bool
    var aorusCodeEnabled: Bool
    var spoofedDeviceName: String?
    var bypassSavePaid: Bool
    var bypassSaveViewOnce: Bool
    var bypassStoryDownload: Bool
}

// MARK: - Arguments

private final class AorusArguments {
    let set: (WritableKeyPath<AorusState, Bool>, Bool) -> Void
    let openChannel: () -> Void
    let openSubscription: () -> Void
    let clearCache: () -> Void
    let openAccountBackup: () -> Void
    let openMisc: () -> Void
    let openAntiSpamManage: () -> Void
    let openDeviceSpoof: () -> Void
    let openMasks: () -> Void
    let openVoiceTwin: () -> Void
    let openWallSettings: () -> Void
    let setRAMCleanInterval: (Int) -> Void
    let setCacheInterval: (Int) -> Void
    let openProxyDiagnostics: () -> Void // AORUS-DIAG
    let openConnectionSettings: () -> Void // AORUS-CONN
    let openAppBadgePicker: () -> Void
    let openFont: () -> Void

    init(set: @escaping (WritableKeyPath<AorusState, Bool>, Bool) -> Void,
         openChannel: @escaping () -> Void,
         openSubscription: @escaping () -> Void,
         clearCache: @escaping () -> Void,
         openAccountBackup: @escaping () -> Void,
         openMisc: @escaping () -> Void,
         openAntiSpamManage: @escaping () -> Void,
         openDeviceSpoof: @escaping () -> Void,
         openMasks: @escaping () -> Void,
         openVoiceTwin: @escaping () -> Void,
         openWallSettings: @escaping () -> Void,
         setRAMCleanInterval: @escaping (Int) -> Void,
         setCacheInterval: @escaping (Int) -> Void,
         openProxyDiagnostics: @escaping () -> Void, // AORUS-DIAG
         openConnectionSettings: @escaping () -> Void, // AORUS-CONN
         openAppBadgePicker: @escaping () -> Void,
         openFont: @escaping () -> Void) {
        self.set = set
        self.openChannel = openChannel
        self.openSubscription = openSubscription
        self.clearCache = clearCache
        self.openAccountBackup = openAccountBackup
        self.openMisc = openMisc
        self.openAntiSpamManage = openAntiSpamManage
        self.openDeviceSpoof = openDeviceSpoof
        self.openMasks = openMasks
        self.openVoiceTwin = openVoiceTwin
        self.openWallSettings = openWallSettings
        self.setRAMCleanInterval = setRAMCleanInterval
        self.setCacheInterval = setCacheInterval
        self.openProxyDiagnostics = openProxyDiagnostics // AORUS-DIAG
        self.openConnectionSettings = openConnectionSettings // AORUS-CONN
        self.openAppBadgePicker = openAppBadgePicker
        self.openFont = openFont
    }
}

// MARK: - Entries

private enum AorusEntry: ItemListNodeEntry {
    case privacyHeader(PresentationTheme, String)
    case ghostMode(PresentationTheme, String, Bool)
    case saveDeletedMessages(PresentationTheme, String, Bool)
    case saveEditedMessages(PresentationTheme, String, Bool)
    case clearDeletedCache(PresentationTheme, String)
    case antiScreenshot(PresentationTheme, String, Bool)
    case callRecording(PresentationTheme, String, Bool)

    case aiHeader(PresentationTheme, String)
    case voiceTranscription(PresentationTheme, String, Bool)
    case translator(PresentationTheme, String, Bool)
    case autoReply(PresentationTheme, String, Bool)

    case callsHeader(PresentationTheme, String)
    case masks(PresentationTheme, String)
    case voiceTwin(PresentationTheme, String)
    case wallHeader(PresentationTheme, String)
    case wallEnabled(PresentationTheme, String, Bool)
    case wallSettings(PresentationTheme, String)

    case perfHeader(PresentationTheme, String)
    case downloadAccel(PresentationTheme, String, Bool)
    case maxMediaQuality(PresentationTheme, String, Bool)
    case antiSpam(PresentationTheme, String, Bool)
    case antiSpamManage(PresentationTheme, String)
    case performanceStats(PresentationTheme, String, Bool)
    case performanceUptime(PresentationTheme, String, Bool)
    case performanceRAM(PresentationTheme, String, Bool)
    case performanceCPU(PresentationTheme, String, Bool)
    case performanceFPS(PresentationTheme, String, Bool)
    case performanceBattery(PresentationTheme, String, Bool)
    case performanceNetwork(PresentationTheme, String, Bool)
    case performanceDisk(PresentationTheme, String, Bool)
    case performanceThermal(PresentationTheme, String, Bool)
    case performanceGraph(PresentationTheme, String, Bool)
    case ramAutoClean(PresentationTheme, String, Bool)
    case ramInterval(PresentationTheme, String, Int)
    case cacheAutoClean(PresentationTheme, String, Bool)
    case cacheInterval(PresentationTheme, String, Int)

    case uiHeader(PresentationTheme, String)
    case glassUI(PresentationTheme, String, Bool)
    case amoledMode(PresentationTheme, String, Bool)
    case profileReportButton(PresentationTheme, String, Bool)
    case hideCallsTab(PresentationTheme, String, Bool)
    case hideContactsTab(PresentationTheme, String, Bool)
    case siriShortcuts(PresentationTheme, String, Bool)
    case appBadge(PresentationTheme, String, String)
    case squareAvatars(PresentationTheme, String, Bool)
    case customFont(PresentationTheme, String)
    case showStories(PresentationTheme, String, Bool)

    case tabsHeader(PresentationTheme, String)
    case hideSearchButton(PresentationTheme, String, Bool)
    case hideTabTitles(PresentationTheme, String, Bool)
    case compactTabBar(PresentationTheme, String, Bool)

    case editLocalHeader(PresentationTheme, String)
    case shareButton(PresentationTheme, String, Bool)
    case videoMessagesHeader(PresentationTheme, String)
    case videoMessagesRearCamera(PresentationTheme, String, Bool)
    case voiceMessagesHeader(PresentationTheme, String)
    case deviceMicrophone(PresentationTheme, String, Bool)
    case messagesDoubleCopy(PresentationTheme, String, Bool)
    case messagesTripleDelete(PresentationTheme, String, Bool)
    case editLocalEnabled(PresentationTheme, String, Bool)
    case userMessagesEnabled(PresentationTheme, String, Bool)
    case messageSeconds(PresentationTheme, String, Bool)

    case antiSpoofHeader(PresentationTheme, String)
    case antiSpoofDeleted(PresentationTheme, String, Bool)
    case antiSpoofOnline(PresentationTheme, String, Bool)

    case accountBackupHeader(PresentationTheme, String)
    case accountBackup(PresentationTheme, String)
    case misc(PresentationTheme, String)

    case aorusCodeHeader(PresentationTheme, String)
    case aorusCodeEnabled(PresentationTheme, String, Bool)

    case deviceSpoofHeader(PresentationTheme, String)
    case deviceSpoof(PresentationTheme, String, String)

    case bypassHeader(PresentationTheme, String)
    case bypassSavePaid(PresentationTheme, String, Bool)
    case bypassSaveViewOnce(PresentationTheme, String, Bool)
    case bypassStoryDownload(PresentationTheme, String, Bool)

    case subscription(PresentationTheme, String)
    case officialChannel(PresentationTheme, String)
    case proxyDiagnostics(PresentationTheme, String) // AORUS-DIAG
    case connectionSettings(PresentationTheme, String) // AORUS-CONN

    var section: ItemListSectionId {
        switch self {
        case .privacyHeader, .ghostMode, .saveDeletedMessages, .saveEditedMessages, .clearDeletedCache, .antiScreenshot, .callRecording:
            return AorusSection.privacy.rawValue
        case .aiHeader, .autoReply:
            return AorusSection.ai.rawValue
        case .callsHeader, .masks, .voiceTwin:
            return AorusSection.calls.rawValue
        case .wallHeader, .wallEnabled, .wallSettings:
            return AorusSection.wall.rawValue
        case .perfHeader, .downloadAccel, .maxMediaQuality, .antiSpam, .antiSpamManage, .performanceStats, .performanceUptime, .performanceRAM,
             .performanceCPU, .performanceFPS, .performanceBattery, .performanceNetwork,
             .performanceDisk, .performanceThermal, .performanceGraph, .ramAutoClean,
             .ramInterval, .cacheAutoClean, .cacheInterval:
            return AorusSection.performance.rawValue
        case .uiHeader, .glassUI, .amoledMode, .profileReportButton, .siriShortcuts, .appBadge, .squareAvatars, .customFont, .showStories:
            return AorusSection.ui.rawValue
        case .tabsHeader, .hideContactsTab, .hideCallsTab, .hideSearchButton, .hideTabTitles, .compactTabBar:
            return AorusSection.tabs.rawValue
        case .editLocalHeader, .messagesDoubleCopy, .messagesTripleDelete, .editLocalEnabled, .userMessagesEnabled, .messageSeconds:
            return AorusSection.editLocal.rawValue
        case .translator, .voiceTranscription, .shareButton:
            return AorusSection.quickButtons.rawValue
        case .videoMessagesHeader, .videoMessagesRearCamera:
            return AorusSection.videoMessages.rawValue
        case .voiceMessagesHeader, .deviceMicrophone:
            return AorusSection.voiceMessages.rawValue
        case .deviceSpoofHeader, .deviceSpoof:
            return AorusSection.deviceSpoof.rawValue
        case .bypassHeader, .bypassSavePaid, .bypassSaveViewOnce, .bypassStoryDownload:
            return AorusSection.bypass.rawValue
        case .antiSpoofHeader, .antiSpoofDeleted, .antiSpoofOnline:
            return AorusSection.antiSpoof.rawValue
        case .accountBackupHeader, .accountBackup:
            return AorusSection.accountBackup.rawValue
        case .misc:
            return AorusSection.misc.rawValue
        case .aorusCodeHeader, .aorusCodeEnabled:
            return AorusSection.aorusCode.rawValue
        case .subscription, .officialChannel, .proxyDiagnostics, .connectionSettings: // AORUS-DIAG
            return AorusSection.channel.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .privacyHeader:        return 0
        case .ghostMode:            return 1
        case .saveDeletedMessages:  return 4
        case .saveEditedMessages:   return 5
        case .clearDeletedCache:    return 6
        case .antiScreenshot:       return 7
        case .callRecording:        return 8
        case .aiHeader:             return 10
        case .autoReply:            return 16
        case .perfHeader:           return 20
        case .downloadAccel:        return 21
        case .maxMediaQuality:      return 22
        case .antiSpam:             return 23
        case .antiSpamManage:       return 24
        case .performanceStats:     return 25
        case .performanceUptime:    return 26
        case .performanceRAM:       return 27
        case .performanceCPU:       return 28
        case .performanceFPS:       return 29
        case .performanceBattery:   return 30
        case .performanceNetwork:   return 31
        case .performanceDisk:      return 32
        case .performanceThermal:   return 33
        case .performanceGraph:     return 34
        case .ramAutoClean:         return 35
        case .ramInterval:          return 36
        case .cacheAutoClean:       return 37
        case .cacheInterval:        return 38
        case .uiHeader:             return 50
        case .glassUI:              return 51
        case .amoledMode:           return 52
        case .profileReportButton:  return 53
        case .hideCallsTab:         return 63
        case .hideContactsTab:      return 62
        case .siriShortcuts:        return 56
        case .appBadge:             return 57
        case .squareAvatars:        return 58
        case .showStories:          return 59
        case .customFont:           return 60
        case .tabsHeader:           return 61
        case .hideSearchButton:     return 64
        case .hideTabTitles:        return 65
        case .compactTabBar:        return 66
        case .editLocalHeader:      return 67
        case .messagesDoubleCopy:   return 68
        case .messagesTripleDelete: return 69
        case .editLocalEnabled:     return 70
        case .userMessagesEnabled:  return 71
        case .messageSeconds:       return 72
        case .translator:           return 73
        case .voiceTranscription:   return 74
        case .shareButton:          return 75
        case .voiceMessagesHeader:  return 76
        case .deviceMicrophone:     return 77
        case .videoMessagesHeader:  return 78
        case .videoMessagesRearCamera: return 79
        case .callsHeader:          return 80
        case .masks:                return 81
        case .voiceTwin:            return 82
        case .wallHeader:           return 83
        case .wallEnabled:          return 84
        case .wallSettings:         return 85
        case .deviceSpoofHeader:    return 86
        case .deviceSpoof:          return 87
        case .bypassHeader:         return 88
        case .bypassSavePaid:       return 89
        case .bypassSaveViewOnce:   return 90
        case .bypassStoryDownload:  return 91
        case .antiSpoofHeader:      return 92
        case .antiSpoofDeleted:     return 93
        case .antiSpoofOnline:      return 94
        case .accountBackupHeader:  return 95
        case .accountBackup:        return 96
        case .misc:                 return 97
        case .aorusCodeHeader:      return 100
        case .aorusCodeEnabled:     return 101
        case .subscription:         return 106
        case .officialChannel:      return 107
        case .connectionSettings:   return 116 // AORUS-CONN — above the diagnostics row
        case .proxyDiagnostics:     return 117 // AORUS-DIAG
        }
    }

    static func < (lhs: AorusEntry, rhs: AorusEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: AorusEntry, rhs: AorusEntry) -> Bool {
        switch lhs {
        case let .privacyHeader(lt, ls):
            if case let .privacyHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .ghostMode(lt, ls, lv):
            if case let .ghostMode(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .saveDeletedMessages(lt, ls, lv):
            if case let .saveDeletedMessages(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .saveEditedMessages(lt, ls, lv):
            if case let .saveEditedMessages(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .clearDeletedCache(lt, ls):
            if case let .clearDeletedCache(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .antiScreenshot(lt, ls, lv):
            if case let .antiScreenshot(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .callRecording(lt, ls, lv):
            if case let .callRecording(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .aiHeader(lt, ls):
            if case let .aiHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .voiceTranscription(lt, ls, lv):
            if case let .voiceTranscription(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .translator(lt, ls, lv):
            if case let .translator(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .autoReply(lt, ls, lv):
            if case let .autoReply(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .callsHeader(lt, ls):
            if case let .callsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .masks(lt, ls):
            if case let .masks(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .voiceTwin(lt, ls):
            if case let .voiceTwin(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .wallHeader(lt, ls):
            if case let .wallHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .wallEnabled(lt, ls, lv):
            if case let .wallEnabled(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .wallSettings(lt, ls):
            if case let .wallSettings(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .perfHeader(lt, ls):
            if case let .perfHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .downloadAccel(lt, ls, lv):
            if case let .downloadAccel(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .maxMediaQuality(lt, ls, lv):
            if case let .maxMediaQuality(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpam(lt, ls, lv):
            if case let .antiSpam(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpamManage(lt, ls):
            if case let .antiSpamManage(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .performanceStats(lt, ls, lv):
            if case let .performanceStats(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceUptime(lt, ls, lv):
            if case let .performanceUptime(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceRAM(lt, ls, lv):
            if case let .performanceRAM(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceCPU(lt, ls, lv):
            if case let .performanceCPU(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceFPS(lt, ls, lv):
            if case let .performanceFPS(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceBattery(lt, ls, lv):
            if case let .performanceBattery(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceNetwork(lt, ls, lv):
            if case let .performanceNetwork(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceDisk(lt, ls, lv):
            if case let .performanceDisk(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceThermal(lt, ls, lv):
            if case let .performanceThermal(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .performanceGraph(lt, ls, lv):
            if case let .performanceGraph(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .ramAutoClean(lt, ls, lv):
            if case let .ramAutoClean(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .ramInterval(lt, ls, lv):
            if case let .ramInterval(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .cacheAutoClean(lt, ls, lv):
            if case let .cacheAutoClean(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .cacheInterval(lt, ls, lv):
            if case let .cacheInterval(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }  // Int ==
        case let .uiHeader(lt, ls):
            if case let .uiHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .glassUI(lt, ls, lv):
            if case let .glassUI(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .amoledMode(lt, ls, lv):
            if case let .amoledMode(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .profileReportButton(lt, ls, lv):
            if case let .profileReportButton(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .hideCallsTab(lt, ls, lv):
            if case let .hideCallsTab(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .hideContactsTab(lt, ls, lv):
            if case let .hideContactsTab(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .siriShortcuts(lt, ls, lv):
            if case let .siriShortcuts(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .appBadge(lt, ls, lv):
            if case let .appBadge(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .squareAvatars(lt, ls, lv):
            if case let .squareAvatars(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .customFont(lt, ls):
            if case let .customFont(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .showStories(lt, ls, lv):
            if case let .showStories(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .tabsHeader(lt, ls):
            if case let .tabsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .hideSearchButton(lt, ls, lv):
            if case let .hideSearchButton(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .hideTabTitles(lt, ls, lv):
            if case let .hideTabTitles(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .compactTabBar(lt, ls, lv):
            if case let .compactTabBar(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .editLocalHeader(lt, ls):
            if case let .editLocalHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .shareButton(lt, ls, lv):
            if case let .shareButton(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .videoMessagesHeader(lt, ls):
            if case let .videoMessagesHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .videoMessagesRearCamera(lt, ls, lv):
            if case let .videoMessagesRearCamera(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .voiceMessagesHeader(lt, ls):
            if case let .voiceMessagesHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .deviceMicrophone(lt, ls, lv):
            if case let .deviceMicrophone(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .messagesDoubleCopy(lt, ls, lv):
            if case let .messagesDoubleCopy(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .messagesTripleDelete(lt, ls, lv):
            if case let .messagesTripleDelete(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .editLocalEnabled(lt, ls, lv):
            if case let .editLocalEnabled(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .userMessagesEnabled(lt, ls, lv):
            if case let .userMessagesEnabled(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .messageSeconds(lt, ls, lv):
            if case let .messageSeconds(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpoofHeader(lt, ls):
            if case let .antiSpoofHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .antiSpoofDeleted(lt, ls, lv):
            if case let .antiSpoofDeleted(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpoofOnline(lt, ls, lv):
            if case let .antiSpoofOnline(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .accountBackupHeader(lt, ls):
            if case let .accountBackupHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .accountBackup(lt, ls):
            if case let .accountBackup(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .misc(lt, ls):
            if case let .misc(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .aorusCodeHeader(lt, ls):
            if case let .aorusCodeHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .aorusCodeEnabled(lt, ls, lv):
            if case let .aorusCodeEnabled(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .deviceSpoofHeader(lt, ls):
            if case let .deviceSpoofHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .deviceSpoof(lt, ls, lv):
            if case let .deviceSpoof(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .bypassHeader(lt, ls):
            if case let .bypassHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .bypassSavePaid(lt, ls, lv):
            if case let .bypassSavePaid(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .bypassSaveViewOnce(lt, ls, lv):
            if case let .bypassSaveViewOnce(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .bypassStoryDownload(lt, ls, lv):
            if case let .bypassStoryDownload(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .subscription(lt, ls):
            if case let .subscription(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .officialChannel(lt, ls):
            if case let .officialChannel(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .proxyDiagnostics(lt, ls): // AORUS-DIAG
            if case let .proxyDiagnostics(rt, rs) = rhs { return lt === rt && ls == rs } // AORUS-DIAG
        case let .connectionSettings(lt, ls): // AORUS-CONN
            if case let .connectionSettings(rt, rs) = rhs { return lt === rt && ls == rs } // AORUS-CONN
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! AorusArguments
        switch self {
        case let .privacyHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .ghostMode(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.ghostMode, $0) })
        case let .saveDeletedMessages(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.saveDeletedMessages, $0) })
        case let .saveEditedMessages(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.saveEditedMessages, $0) })
        case let .clearDeletedCache(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .destructive, alignment: .natural, sectionId: section, style: .blocks, action: args.clearCache)
        case let .antiScreenshot(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiScreenshot, $0) })
        case let .callRecording(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.callRecording, $0) })
        case let .aiHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .voiceTranscription(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.voiceTranscription, $0) })
        case let .translator(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.translator, $0) })
        case let .shareButton(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.shareButton, $0) })
        case let .videoMessagesHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .videoMessagesRearCamera(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.videoMessagesRearCamera, $0) })
        case let .voiceMessagesHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .deviceMicrophone(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.deviceMicrophone, $0) })
        case let .autoReply(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.autoReply, $0) })
        case let .callsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .masks(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openMasks)
        case let .voiceTwin(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openVoiceTwin)
        case let .wallHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .wallEnabled(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.wallEnabled, $0) })
        case let .wallSettings(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openWallSettings)
        case let .perfHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .downloadAccel(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.downloadAccel, $0) })
        case let .maxMediaQuality(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.maxMediaQuality, $0) })
        case let .antiSpam(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiSpamEnabled, $0) })
        case let .antiSpamManage(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openAntiSpamManage)
        case let .performanceStats(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceStatsEnabled, $0) })
        case let .performanceUptime(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowUptime, $0) })
        case let .performanceRAM(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowRAM, $0) })
        case let .performanceCPU(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowCPU, $0) })
        case let .performanceFPS(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowFPS, $0) })
        case let .performanceBattery(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowBattery, $0) })
        case let .performanceNetwork(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowNetwork, $0) })
        case let .performanceDisk(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowDisk, $0) })
        case let .performanceThermal(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowThermal, $0) })
        case let .performanceGraph(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.performanceShowGraph, $0) })
        case let .ramAutoClean(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.ramAutoClean, $0) })
        case let .ramInterval(theme, title, value):
            return AorusIntervalSliderItem(theme: theme, title: title, value: value,
                                           presets: _aorusRAMIntervalPresets,
                                           valueText: _aorusRAMIntervalText,
                                           sectionId: section, updated: args.setRAMCleanInterval)
        case let .cacheAutoClean(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.cacheAutoClean, $0) })
        case let .cacheInterval(theme, title, value):
            return AorusIntervalSliderItem(theme: theme, title: title, value: value,
                                           sectionId: section, updated: args.setCacheInterval)
        case let .uiHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .glassUI(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.glassUI, $0) })
        case let .amoledMode(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.amoledMode, $0) })
        case let .profileReportButton(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.profileReportButton, $0) })
        case let .hideCallsTab(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.hideCallsTab, !$0) })
        case let .hideContactsTab(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.hideContactsTab, !$0) })
        case let .siriShortcuts(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.siriShortcuts, $0) })
        case let .appBadge(_, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: label, sectionId: section, style: .blocks, action: args.openAppBadgePicker)
        case let .squareAvatars(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.squareAvatars, $0) })
        case let .customFont(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openFont)
        case let .showStories(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.showStories, $0) })
        case let .tabsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .hideSearchButton(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.hideSearchButton, !$0) })
        case let .hideTabTitles(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.hideTabTitles, !$0) })
        case let .compactTabBar(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.compactTabBar, $0) })
        case let .editLocalHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .messagesDoubleCopy(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.doubleTapCopy, $0) })
        case let .messagesTripleDelete(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.tripleTapDelete, $0) })
        case let .editLocalEnabled(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.editLocally, $0) })
        case let .userMessagesEnabled(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.userMessages, $0) })
        case let .messageSeconds(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.messageSeconds, $0) })
        case let .antiSpoofHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .antiSpoofDeleted(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiSpoofDeleted, $0) })
        case let .antiSpoofOnline(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiSpoofOnline, $0) })
        case let .accountBackupHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .accountBackup(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openAccountBackup)
        case let .misc(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openMisc)
        case let .aorusCodeHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .aorusCodeEnabled(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.aorusCodeEnabled, $0) })
        case let .deviceSpoofHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .deviceSpoof(_, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: label, sectionId: section, style: .blocks, action: args.openDeviceSpoof)
        case let .bypassHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .bypassSavePaid(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.bypassSavePaid, $0) })
        case let .bypassSaveViewOnce(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.bypassSaveViewOnce, $0) })
        case let .bypassStoryDownload(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.bypassStoryDownload, $0) })
        case let .subscription(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: args.openSubscription)
        case let .officialChannel(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: args.openChannel)
        case let .proxyDiagnostics(_, title): // AORUS-DIAG
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: args.openProxyDiagnostics) // AORUS-DIAG
        case let .connectionSettings(_, title): // AORUS-CONN
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: args.openConnectionSettings) // AORUS-CONN
        }
    }
}

// MARK: - Entries builder

// Display label for the currently-selected notch badge.
private func appBadgeLabel(_ id: String, _ l10n: AorusL10n) -> String {
    switch id {
    case "titanium": return l10n.appBadgeTitanium
    case "atunnel":  return l10n.appBadgeATunnel
    case "off":      return l10n.appBadgeOff
    default:         return l10n.appBadgeAorus
    }
}

private func aorusEntries(state: AorusState, theme: PresentationTheme, l10n: AorusL10n) -> [AorusEntry] {
    // Privacy section: exactly three rows.
    //   1. Ghost Mode — combined toggle that hides online + typing + read receipts
    //      (the per-feature sub-flags blockReadReceipts/hideTyping are still in state
    //       but no longer surfaced; source patches gate on aorusgram_ghost_mode only).
    //   2. Deleted Messages — preserves incoming deletes/edits inline in chat.
    //   3. Hide Screen While Recording — renamed from the ambiguous «Screenshot Protection».
    // A small destructive 'Clear Deleted Cache' action sits between (2) and (3) and
    // wipes preserved postbox rows accumulated by the source patches.
    // All visible strings are localized via AorusL10n (RU/EN, follows Telegram language).
    var entries: [AorusEntry] = [
        .privacyHeader(theme, l10n.privacyHeader),
        .ghostMode(theme, l10n.ghostMode, state.ghostMode),
        .saveDeletedMessages(theme, l10n.deletedMessages, state.saveDeletedMessages),
        .saveEditedMessages(theme, l10n.editedMessages, state.saveEditedMessages),
        .clearDeletedCache(theme, l10n.clearDeletedCache),
        .antiScreenshot(theme, l10n.antiScreenshot, state.antiScreenshot),
        .callRecording(theme, l10n.callRecording, state.callRecording),

        .perfHeader(theme, l10n.perfHeader),
        .downloadAccel(theme, l10n.downloadAccel, state.downloadAccel),
        .maxMediaQuality(theme, l10n.maxMediaQuality, state.maxMediaQuality),
        .antiSpam(theme, l10n.antiSpam, state.antiSpamEnabled),
        .performanceStats(theme, l10n.performanceStats, state.performanceStatsEnabled),
        // Detailed metric switches, RAM auto-clean and cache auto-clean are appended
        // below so they animate in/out directly under their parent toggles.

        .uiHeader(theme, l10n.uiHeader),
        .glassUI(theme, l10n.glassUI, state.glassUI),
        .amoledMode(theme, l10n.amoledMode, state.amoledMode),
        .profileReportButton(theme, l10n.profileReportButton, state.profileReportButton),
        .siriShortcuts(theme, l10n.siriShortcuts, state.siriShortcuts),
        .appBadge(theme, l10n.appBadge, appBadgeLabel(state.appBadge, l10n)),
        .squareAvatars(theme, l10n.squareAvatars, state.squareAvatars),
        .showStories(theme, l10n.showStories, state.showStories),
        .customFont(theme, l10n.customFont),

        .tabsHeader(theme, l10n.tabsHeader),
        // These two switches reflect tab PRESENCE: on = tab shown.
        .hideContactsTab(theme, l10n.hideContactsTab, !state.hideContactsTab),
        .hideCallsTab(theme, l10n.hideCallsTab, !state.hideCallsTab),
        // Search switch reflects PRESENCE: on = button shown (stored hide flag inverted).
        .hideSearchButton(theme, l10n.hideSearchButton, !state.hideSearchButton),
        // Names switch reflects PRESENCE: on = names shown (stored hide flag inverted).
        .hideTabTitles(theme, l10n.hideTabTitles, !state.hideTabTitles),
        .compactTabBar(theme, l10n.compactTabBar, state.compactTabBar),

        .editLocalHeader(theme, l10n.messagesHeader),
        .messagesDoubleCopy(theme, l10n.doubleTapCopy, state.doubleTapCopy),
        .messagesTripleDelete(theme, l10n.tripleTapDelete, state.tripleTapDelete),
        .editLocalEnabled(theme, l10n.editLocally, state.editLocally),
        .userMessagesEnabled(theme, l10n.userMessagesInGroup, state.userMessages),
        .messageSeconds(theme, l10n.messageSeconds, state.messageSeconds),

        // Unnamed block directly under Messages: the three quick message buttons.
        .translator(theme, l10n.quickTranslateButton, state.translator),
        .voiceTranscription(theme, l10n.quickTranscribeButton, state.voiceTranscription),
        .shareButton(theme, l10n.quickShareButton, state.shareButton),

        .voiceMessagesHeader(theme, l10n.voiceMessagesHeader),
        .deviceMicrophone(theme, l10n.deviceMicrophone, state.deviceMicrophone),

        .videoMessagesHeader(theme, l10n.videoMessagesHeader),
        .videoMessagesRearCamera(theme, l10n.videoMessagesRearCamera, state.videoMessagesRearCamera),

        // Calls block (Voice Twin) — moved here from Other.
        .callsHeader(theme, l10n.callsHeader),
        .masks(theme, l10n.videoMasks),
        .voiceTwin(theme, l10n.voiceTwin),

        .wallHeader(theme, l10n.wallHeader),
        .wallEnabled(theme, l10n.wallEnabled, state.wallEnabled),
        .wallSettings(theme, l10n.wallSettings),

        .deviceSpoofHeader(theme, l10n.deviceSpoofHeader),
        .deviceSpoof(theme, l10n.deviceSpoof, state.spoofedDeviceName ?? l10n.deviceSpoofOff),

        .bypassHeader(theme, l10n.bypassHeader),
        .bypassSavePaid(theme, l10n.bypassSavePaid, state.bypassSavePaid),
        .bypassSaveViewOnce(theme, l10n.bypassSaveViewOnce, state.bypassSaveViewOnce),
        .bypassStoryDownload(theme, l10n.bypassStoryDownload, state.bypassStoryDownload),

        .antiSpoofHeader(theme, l10n.antiSpoofHeader),
        .antiSpoofDeleted(theme, l10n.antiSpoofDeleted, state.antiSpoofDeleted),
        .antiSpoofOnline(theme, l10n.antiSpoofOnline, state.antiSpoofOnline),

        .accountBackupHeader(theme, l10n.accountBackupHeader),
        .accountBackup(theme, l10n.accountBackup),

        .misc(theme, l10n.misc),

        .aorusCodeHeader(theme, l10n.aorusCodeHeader),
        .aorusCodeEnabled(theme, l10n.aorusCode, state.aorusCodeEnabled),

        .subscription(theme, l10n.subscription),
        .officialChannel(theme, l10n.officialChannel),
        .connectionSettings(theme, l10n.connectionSettings), // AORUS-CONN
        .proxyDiagnostics(theme, l10n.proxyDiagnostics), // AORUS-DIAG
    ]

    if state.antiSpamEnabled, let idx = entries.firstIndex(where: {
        if case .antiSpam = $0 { return true }; return false
    }) {
        entries.insert(.antiSpamManage(theme, aorusL("Управление", "Manage")), at: idx + 1)
    }

    if state.performanceStatsEnabled, let idx = entries.firstIndex(where: {
        if case .performanceStats = $0 { return true }; return false
    }) {
        entries.insert(contentsOf: [
            .performanceUptime(theme, l10n.performanceUptime, state.performanceShowUptime),
            .performanceRAM(theme, l10n.performanceRAM, state.performanceShowRAM),
            .performanceCPU(theme, l10n.performanceCPU, state.performanceShowCPU),
            .performanceFPS(theme, l10n.performanceFPS, state.performanceShowFPS),
            .performanceBattery(theme, l10n.performanceBattery, state.performanceShowBattery),
            .performanceNetwork(theme, l10n.performanceNetwork, state.performanceShowNetwork),
            .performanceDisk(theme, l10n.performanceDisk, state.performanceShowDisk),
            .performanceThermal(theme, l10n.performanceThermal, state.performanceShowThermal),
            .performanceGraph(theme, l10n.performanceGraph, state.performanceShowGraph),
        ], at: idx + 1)
    }

    if let idx = entries.firstIndex(where: {
        if case .performanceStats = $0 { return true }; return false
    }) {
        var insertAt = idx + 1
        var scanningMetrics = true
        while scanningMetrics && insertAt < entries.count {
            switch entries[insertAt] {
            case .performanceUptime, .performanceRAM, .performanceCPU, .performanceFPS, .performanceBattery,
                 .performanceNetwork, .performanceDisk, .performanceThermal, .performanceGraph:
                insertAt += 1
            default:
                scanningMetrics = false
            }
        }
        entries.insert(.ramAutoClean(theme, l10n.ramAutoClean, state.ramAutoClean), at: insertAt)
    }

    if state.ramAutoClean, let idx = entries.firstIndex(where: {
        if case .ramAutoClean = $0 { return true }; return false
    }) {
        entries.insert(.ramInterval(theme, l10n.ramCleanInterval, state.ramCleanInterval), at: idx + 1)
    }

    if let idx = entries.firstIndex(where: {
        if case .ramAutoClean = $0 { return true }; return false
    }) {
        let insertAt = state.ramAutoClean ? idx + 2 : idx + 1
        entries.insert(.cacheAutoClean(theme, l10n.cacheAutoClean, state.cacheAutoClean), at: insertAt)
    }

    // The cache cleanup-interval slider only appears once cache auto-clean is switched on.
    if state.cacheAutoClean, let idx = entries.firstIndex(where: {
        if case .cacheAutoClean = $0 { return true }; return false
    }) {
        entries.insert(.cacheInterval(theme, l10n.cacheInterval, state.cacheCleanInterval), at: idx + 1)
    }

    return entries
}

// MARK: - Public factory

public func aorusGramController(context: AccountContext, shortcutRoutes: AorusSettingsShortcutRoutes) -> ViewController {
    // License gate: opening the AorusGram settings while the subscription is locked
    // routes to the purchase/subscription screen instead (LicenseGate handles the
    // notification). Fail-open — an active user (flag absent/false) is never affected.
    // The global lock already blocks entry when expired; this covers a bypassed lock.
    if UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04") {
        NotificationCenter.default.post(
            name: NSNotification.Name("aorusgram.openSubscriptionManagement"), object: nil)
    }
    let mgr   = AorusGramManager.shared
    let spoof = AntiSpoofManager.shared
    let stealth = AorusStealthCodec.shared

    let initialState = AorusState(
        ghostMode:          mgr.ghostMode,
        blockReadReceipts:  mgr.blockReadReceipts,
        hideTyping:         mgr.hideTyping,
        saveDeletedMessages: mgr.saveDeletedMessages,
        saveEditedMessages:  mgr.saveEditedMessages,
        antiScreenshot:     mgr.antiScreenshot,
        callRecording:      mgr.callRecording,
        voiceTranscription: mgr.voiceTranscription,
        translator:         mgr.translator,
        shareButton:        mgr.shareButton,
        videoMessagesRearCamera: mgr.videoMessagesRearCamera,
        deviceMicrophone:   mgr.deviceMicrophone,
        autoReply:          mgr.autoReply,
        downloadAccel:      mgr.downloadAccel,
        maxMediaQuality:    mgr.maxMediaQuality,
        antiSpamEnabled:    mgr.antiSpamEnabled,
        performanceStatsEnabled: mgr.performanceStatsEnabled,
        performanceShowUptime:   mgr.performanceShowUptime,
        performanceShowRAM:      mgr.performanceShowRAM,
        performanceShowCPU:      mgr.performanceShowCPU,
        performanceShowFPS:      mgr.performanceShowFPS,
        performanceShowBattery:  mgr.performanceShowBattery,
        performanceShowNetwork:  mgr.performanceShowNetwork,
        performanceShowDisk:     mgr.performanceShowDisk,
        performanceShowThermal:  mgr.performanceShowThermal,
        performanceShowGraph:    mgr.performanceShowGraph,
        ramAutoClean:       mgr.ramAutoClean,
        ramCleanInterval:   mgr.ramCleanInterval,
        cacheAutoClean:     mgr.cacheAutoClean,
        cacheCleanInterval: mgr.cacheCleanInterval,
        editLocally:        mgr.editLocally,
        userMessages:       mgr.userMessagesInGroup,
        messageSeconds:     mgr.messageSeconds,
        doubleTapCopy:      mgr.doubleTapCopy,
        tripleTapDelete:    mgr.tripleTapDelete,
        glassUI:            mgr.glassUI,
        showStories:        UserDefaults.standard.object(forKey: "aorusgram_show_stories") as? Bool ?? true,
        amoledMode:         mgr.amoledMode,
        profileReportButton: mgr.profileReportButton,
        hideCallsTab:       mgr.hideCallsTab,
        hideContactsTab:    mgr.hideContactsTab,
        hideSearchButton:    mgr.hideSearchButton,
        hideTabTitles:       mgr.hideTabTitles,
        compactTabBar:       mgr.compactTabBar,
        wallEnabled:        mgr.wallEnabled,
        siriShortcuts:      mgr.siriShortcuts,
        appBadge:           UserDefaults.standard.string(forKey: "aorusgram_app_badge") ?? "aorusgram",
        squareAvatars:      mgr.squareAvatars,
        antiSpoofDeleted:   spoof.antiSpoofDeleted,
        antiSpoofOnline:    spoof.antiSpoofOnline,
        aorusCodeEnabled:   stealth.isEnabled,
        spoofedDeviceName:  UserDefaults.standard.string(forKey: "aorusgram_spoofed_device"),
        bypassSavePaid:     UserDefaults.standard.object(forKey: "aorusgram_bypass_save_paid") as? Bool ?? true,
        bypassSaveViewOnce: UserDefaults.standard.object(forKey: "aorusgram_bypass_view_once") as? Bool ?? true,
        bypassStoryDownload: UserDefaults.standard.object(forKey: "aorusgram_bypass_story_dl") as? Bool ?? true
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue   = Atomic(value: initialState)

    let updateState: ((AorusState) -> AorusState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    // Weak reference so openChannel can navigate using the controller's nav stack
    weak var weakController: ItemListController?

    let arguments = AorusArguments(
        set: { keyPath, value in
            updateState { current in
                var next = current
                next[keyPath: keyPath] = value
                return next
            }
            // Persist to managers based on which key changed
            let s = stateValue.with { $0 }
            mgr.ghostMode           = s.ghostMode
            mgr.blockReadReceipts   = s.blockReadReceipts
            mgr.hideTyping          = s.hideTyping
            mgr.saveDeletedMessages = s.saveDeletedMessages
            mgr.saveEditedMessages  = s.saveEditedMessages
            mgr.antiScreenshot      = s.antiScreenshot
            mgr.callRecording       = s.callRecording
            mgr.voiceTranscription  = s.voiceTranscription
            mgr.translator          = s.translator
            mgr.shareButton         = s.shareButton
            mgr.videoMessagesRearCamera = s.videoMessagesRearCamera
            mgr.deviceMicrophone    = s.deviceMicrophone
            mgr.autoReply           = s.autoReply
            mgr.downloadAccel       = s.downloadAccel
            mgr.maxMediaQuality     = s.maxMediaQuality
            mgr.antiSpamEnabled     = s.antiSpamEnabled
            mgr.performanceStatsEnabled = s.performanceStatsEnabled
            mgr.performanceShowUptime   = s.performanceShowUptime
            mgr.performanceShowRAM      = s.performanceShowRAM
            mgr.performanceShowCPU      = s.performanceShowCPU
            mgr.performanceShowFPS      = s.performanceShowFPS
            mgr.performanceShowBattery  = s.performanceShowBattery
            mgr.performanceShowNetwork  = s.performanceShowNetwork
            mgr.performanceShowDisk     = s.performanceShowDisk
            mgr.performanceShowThermal  = s.performanceShowThermal
            mgr.performanceShowGraph    = s.performanceShowGraph
            mgr.ramAutoClean       = s.ramAutoClean
            mgr.ramCleanInterval   = s.ramCleanInterval
            mgr.cacheAutoClean      = s.cacheAutoClean
            mgr.cacheCleanInterval  = s.cacheCleanInterval
            mgr.editLocally         = s.editLocally
            mgr.userMessagesInGroup = s.userMessages
            mgr.messageSeconds      = s.messageSeconds
            mgr.doubleTapCopy       = s.doubleTapCopy
            mgr.tripleTapDelete     = s.tripleTapDelete
            mgr.glassUI             = s.glassUI
            mgr.amoledMode          = s.amoledMode
            mgr.profileReportButton = s.profileReportButton
            mgr.hideCallsTab        = s.hideCallsTab
            mgr.hideContactsTab     = s.hideContactsTab
            mgr.hideSearchButton    = s.hideSearchButton
            mgr.hideTabTitles       = s.hideTabTitles
            mgr.compactTabBar       = s.compactTabBar
            mgr.wallEnabled         = s.wallEnabled
            mgr.siriShortcuts       = s.siriShortcuts
            mgr.squareAvatars       = s.squareAvatars
            spoof.antiSpoofDeleted  = s.antiSpoofDeleted
            spoof.antiSpoofOnline   = s.antiSpoofOnline
            stealth.isEnabled       = s.aorusCodeEnabled
            UserDefaults.standard.set(s.bypassSavePaid,      forKey: "aorusgram_bypass_save_paid")
            UserDefaults.standard.set(s.bypassSaveViewOnce,  forKey: "aorusgram_bypass_view_once")
            UserDefaults.standard.set(s.bypassStoryDownload, forKey: "aorusgram_bypass_story_dl")
            UserDefaults.standard.set(s.showStories, forKey: "aorusgram_show_stories")
            // Glass effects are read once when the nav bar / input panel / HUD build
            // their layers, so toggling only fully applies (everywhere) after a restart.
            if keyPath == \AorusState.glassUI {
                NotificationCenter.default.post(name: NSNotification.Name("aorusgram_settings_changed"), object: nil)
                aorusPresentRestartNotice(context: context, controller: weakController)
            }
            // The chat-list stories strip re-reads this key on every layout, so posting
            // this notification makes the chat list re-lay-out and apply the change live —
            // no restart needed.
            if keyPath == \AorusState.showStories {
                NotificationCenter.default.post(name: NSNotification.Name("aorusgram_settings_changed"), object: nil)
            }
            if keyPath == \AorusState.wallEnabled {
                UserDefaults.standard.set(s.wallEnabled, forKey: "aorusgram_wall_enabled")
                NotificationCenter.default.post(
                    name: NSNotification.Name("aorusgram_wall_visibility_changed"),
                    object: NSNumber(value: s.wallEnabled)
                )
            }
            // AMOLED re-runs the presentation pipeline via aorusAmoledTrigger, which listens
            // for this notification. Posting it here makes every visible controller — including
            // THIS settings screen — re-theme to true-black immediately, with no restart.
            if keyPath == \AorusState.amoledMode {
                NotificationCenter.default.post(name: NSNotification.Name("aorusgram_settings_changed"), object: nil)
            }
        },
        openChannel: {
            // Resolve @aorusgram and navigate to the channel inside AorusGram.
            // `weakController` is referenced directly (no capture list) so the
            // closure reads the value assigned after it is created — capturing
            // `[weak weakController]` would freeze the nil it holds right now.
            // Browser fallback only if the nav stack is genuinely unavailable.
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                context.sharedContext.applicationBindings.openUrl("https://t.me/aorusgram")
                return
            }
            let _ = (context.engine.peers.resolvePeerByName(name: "aorusgram", referrer: nil)
            |> deliverOnMainQueue).start(next: { result in
                guard case let .result(peer) = result, let peer = peer else { return }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                    navigationController: navigationController,
                    context: context,
                    chatLocation: .peer(peer)
                ))
            })
        },
        openSubscription: {
            // The license gate (AorusGram core) owns the subscription UI; just signal it.
            NotificationCenter.default.post(
                name: NSNotification.Name("aorusgram.openSubscriptionManagement"), object: nil)
        },
        clearCache: {
            let stored = (UserDefaults.standard.array(forKey: "aorusgram_preserved_msgs") as? [[String: Int64]]) ?? []
            let showDone: () -> Void = {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                let alert = UIAlertController(
                    title: aorusL("Кэш успешно очищен", "Cache cleared"),
                    message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: aorusL("Готово", "Done"), style: .default))
                weakController?.present(alert, animated: true)
            }
            let ids: [MessageId] = stored.compactMap { entry in
                guard let p = entry["peerId"], let m = entry["msgId"], let ns = entry["namespace"] else { return nil }
                return MessageId(peerId: PeerId(p), namespace: Int32(ns), id: Int32(m))
            }
            guard !ids.isEmpty else { showDone(); return }
            let _ = (context.account.postbox.transaction { transaction -> Void in
                transaction.deleteMessages(ids, forEachMedia: { _ in })
            } |> deliverOnMainQueue).start(completed: {
                UserDefaults.standard.removeObject(forKey: "aorusgram_preserved_msgs")
                showDone()
            })
        },
        openAccountBackup: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(accountBackupController(context: context))
        },
        openMisc: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(aorusMiscController(context: context, shortcutRoutes: shortcutRoutes))
        },
        openAntiSpamManage: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(aorusAntiSpamController(context: context))
        },
        openDeviceSpoof: {
            guard let navigationController = weakController?.navigationController as? NavigationController else {
                return
            }
            let currentModel = UserDefaults.standard.string(forKey: "aorusgram_spoofed_device")
            let currentSystemVersion = UserDefaults.standard.string(forKey: "aorusgram_spoofed_sysver")
            let deviceController = aorusDeviceSpoofController(
                context: context,
                initialModel: currentModel,
                initialSystemVersion: currentSystemVersion,
                selectionChanged: { model, systemVersion in
                    let previousModel = UserDefaults.standard.string(forKey: "aorusgram_spoofed_device")
                    let previousVersion = UserDefaults.standard.string(forKey: "aorusgram_spoofed_sysver")
                    guard previousModel != model || previousVersion != systemVersion else {
                        return
                    }
                    if let model, let systemVersion {
                        UserDefaults.standard.set(model, forKey: "aorusgram_spoofed_device")
                        UserDefaults.standard.set(systemVersion, forKey: "aorusgram_spoofed_sysver")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "aorusgram_spoofed_device")
                        UserDefaults.standard.removeObject(forKey: "aorusgram_spoofed_sysver")
                    }
                    updateState { state in
                        var updated = state
                        updated.spoofedDeviceName = model
                        return updated
                    }
                    let visibleController =
                        navigationController.topViewController as? ViewController
                        ?? weakController
                    aorusPresentRestartNotice(
                        context: context,
                        controller: visibleController
                    )
                }
            )
            navigationController.pushViewController(deviceController)
        },
        openMasks: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(aorusMasksController(context: context))
        },
        openVoiceTwin: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(voiceTwinController(context: context))
        },
        openWallSettings: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(aorusWallSettingsController(context: context))
        },
        setRAMCleanInterval: { seconds in
            AorusGramManager.shared.ramCleanInterval = seconds
            updateState { s in var n = s; n.ramCleanInterval = seconds; return n }
        },
        setCacheInterval: { hours in
            AorusGramManager.shared.cacheCleanInterval = hours
            updateState { s in var n = s; n.cacheCleanInterval = hours; return n }
        },
        openProxyDiagnostics: { // AORUS-DIAG
            // Telegram's NavigationController is node-based (ASDisplayNode) and only
            // accepts Display.ViewController instances — pushing a plain UIViewController
            // crashes at runtime. So the ATunnel page is shown modally inside a standard
            // UIKit UINavigationController (same UIKit-present path used for the alerts
            // above), which fully sidesteps Telegram's custom navigation stack.
            guard let controller = weakController else { return }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isRu = AorusLang.resolve(presentationData.strings.baseLanguageCode) == .ru
            let vc = ATunnelStatusViewController(theme: presentationData.theme, isRu: isRu)
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            controller.present(nav, animated: true)
        },
        openConnectionSettings: { // AORUS-CONN
            // Telegram's own Proxy screen, pushed onto the same stack it is pushed onto from
            // Data and Storage. It is a real Display.ViewController, so unlike the diagnostics
            // page above it needs no UIKit modal — the screen itself is built by SettingsUI and
            // handed in as a route, because SettingsUI depends on this module and not the reverse.
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(shortcutRoutes.connectionSettings())
        },
        openAppBadgePicker: {
            guard let controller = weakController else { return }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
            let current = UserDefaults.standard.string(forKey: "aorusgram_app_badge") ?? "aorusgram"

            let sheet = ActionSheetController(presentationData: presentationData)
            let options: [(String, String)] = [
                ("aorusgram", l10n.appBadgeAorus),
                ("titanium",  l10n.appBadgeTitanium),
                ("atunnel",   l10n.appBadgeATunnel),
                ("off",       l10n.appBadgeOff),
            ]
            let optionItems: [ActionSheetButtonItem] = options.map { id, name in
                return ActionSheetButtonItem(title: name, color: .accent, font: id == current ? .bold : .default, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    UserDefaults.standard.set(id, forKey: "aorusgram_app_badge")
                    NotificationCenter.default.post(
                        name: NSNotification.Name("aorusgram_app_badge_changed"), object: nil)
                    updateState { s in var n = s; n.appBadge = id; return n }
                })
            }
            sheet.setItemGroups([
                ActionSheetItemGroup(items: optionItems),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                    })
                ])
            ])
            controller.present(sheet, in: .window(.root))
        },
        openFont: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            AorusSettingsShortcutHighlight.request(.font)
            navigationController.pushViewController(aorusFontPickerController(context: context))
        }
    )

    // Combine the settings state with the LIVE presentation-data signal (not a one-shot
    // snapshot) so the screen re-themes the instant the theme changes — e.g. when AMOLED is
    // toggled, aorusAmoledTrigger re-emits presentationData and this screen goes true-black
    // immediately, with no need to leave and re-enter.
    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
        |> deliverOnMainQueue
        |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
            // The derived theme, not the raw one. Every row Telegram itself draws reaches it
            // through ItemListPresentationData's convenience init; the rows in this file are our
            // own ListViewItems and take a PresentationTheme directly, so they have to ask for it
            // here. Handed the raw theme they paint an opaque card -- which is what put a grey
            // block behind the interval sliders on top of the pane of glass behind the section.
            let entries = aorusEntries(state: state, theme: presentationData.theme.aorusGlassListTheme, l10n: l10n)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("AorusGram"),
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

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
