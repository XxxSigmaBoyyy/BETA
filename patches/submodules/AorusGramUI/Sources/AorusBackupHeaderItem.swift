import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AnimatedStickerNode
import MediaResources
import AppBundle

// Every stock Telegram settings screen opens with a centred looping illustration
// above the first block (Devices, Auto-Delete, Passcode …). This is that header,
// built exactly like the upstream ones — GlobalAutoremoveHeaderItem for the
// animation-only layout, RecentSessionsHeaderItem for the playback handshake
// (autoplay + .still(.start) + a delayed play, so the first frame is on screen
// before the animation starts).
//
// The sticker source is resolved locally instead of importing
// TelegramAnimatedStickerNode: AnimatedStickerNodeLocalFileSource does nothing
// but look the .tgs up in the app bundle, and AorusGramUI already links
// AppBundle + AnimatedStickerNode, so this keeps the module's dependency set
// untouched.
private final class AorusHeaderTgsSource: AnimatedStickerNodeSource {
    let fitzModifier: EmojiFitzModifier? = nil
    let isVideo: Bool = false

    private let name: String

    init(name: String) {
        self.name = name
    }

    private var path: String? {
        if let path = getAppBundle().path(forResource: self.name, ofType: "tgs") {
            return path
        }
        return getAppBundle().path(forResource: self.name, ofType: "json")
    }

    func cachedDataPath(width: Int, height: Int) -> Signal<(String, Bool), NoError> {
        return .never()
    }

    func directDataPath(attemptSynchronously: Bool) -> Signal<String?, NoError> {
        return .single(self.path)
    }
}

final class AorusBackupHeaderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let animationName: String
    let sectionId: ItemListSectionId
    let tag: ItemListItemTag? = nil

    init(theme: PresentationTheme, animationName: String, sectionId: ItemListSectionId) {
        self.theme = theme
        self.animationName = animationName
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AorusBackupHeaderItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? AorusBackupHeaderItemNode else {
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply()
                    })
                }
            }
        }
    }
}

final class AorusBackupHeaderItemNode: ListViewItemNode, ItemListItemNode {
    private let animationNode: AnimatedStickerNode

    private var item: AorusBackupHeaderItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.animationNode = DefaultAnimatedStickerNodeImpl()

        super.init(layerBacked: false)

        self.addSubnode(self.animationNode)
    }

    func asyncLayout() -> (_ item: AorusBackupHeaderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let topInset: CGFloat = 128.0

            let contentSize = CGSize(width: params.width, height: topInset)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)

            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if strongSelf.item == nil {
                    strongSelf.animationNode.autoplay = true
                    strongSelf.animationNode.setup(source: AorusHeaderTgsSource(name: item.animationName), width: 256, height: 256, playbackMode: .still(.start), mode: .direct(cachePathPrefix: nil))
                    strongSelf.animationNode.visibility = true
                    Queue.mainQueue().after(0.3) {
                        strongSelf.animationNode.play(firstFrame: false, fromIndex: nil)
                    }
                }
                strongSelf.item = item

                let iconSize = CGSize(width: 128.0, height: 128.0)
                strongSelf.animationNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - iconSize.width) / 2.0), y: -10.0), size: iconSize)
                strongSelf.animationNode.updateLayout(size: iconSize)
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
