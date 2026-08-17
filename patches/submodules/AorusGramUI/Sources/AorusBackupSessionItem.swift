import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

// A blocks-style session card for the Account Backup screen, matching the
// reference Keychain-backup layout: avatar + username, "ID: <telegram id>",
// "Last backup: <date>", and a "Logged in / Logged out" badge on the trailing
// edge. The rounded-block background / separators / corner masking reuse the
// exact scaffolding Telegram's own ItemListPeerActionItem uses.
final class AorusBackupSessionItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let avatar: UIImage?
    let title: String
    let idText: String
    let dateText: String
    let badgeText: String
    let isLoggedIn: Bool
    let sectionId: ItemListSectionId
    let style: ItemListStyle
    let action: (() -> Void)?
    let tag: ItemListItemTag? = nil

    init(presentationData: ItemListPresentationData, avatar: UIImage?, title: String, idText: String, dateText: String, badgeText: String, isLoggedIn: Bool, sectionId: ItemListSectionId, style: ItemListStyle = .blocks, action: (() -> Void)? = nil) {
        self.presentationData = presentationData
        self.avatar = avatar
        self.title = title
        self.idText = idText
        self.dateText = dateText
        self.badgeText = badgeText
        self.isLoggedIn = isLoggedIn
        self.sectionId = sectionId
        self.style = style
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AorusBackupSessionItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(false) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AorusBackupSessionItemNode {
                let makeLayout = nodeValue.asyncLayout()
                var animated = true
                if case .None = animation {
                    animated = false
                }
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animated)
                        })
                    }
                }
            }
        }
    }

    var selectable: Bool {
        return self.action != nil
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action?()
    }
}

final class AorusBackupSessionItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    private let maskNode: ASImageNode

    private let avatarNode: ASImageNode
    private let titleNode: TextNode
    private let subtitleNode: TextNode
    private let detailNode: TextNode
    private let badgeNode: ASImageNode

    private let activateArea: AccessibilityAreaNode

    private var item: AorusBackupSessionItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        self.maskNode = ASImageNode()

        self.avatarNode = ASImageNode()
        self.avatarNode.isLayerBacked = true
        self.avatarNode.displaysAsynchronously = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .left
        self.titleNode.contentsScale = UIScreen.main.scale

        self.subtitleNode = TextNode()
        self.subtitleNode.isUserInteractionEnabled = false

        self.detailNode = TextNode()
        self.detailNode.isUserInteractionEnabled = false

        self.badgeNode = ASImageNode()
        self.badgeNode.isLayerBacked = true
        self.badgeNode.displaysAsynchronously = false

        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true

        self.activateArea = AccessibilityAreaNode()
        self.activateArea.accessibilityTraits = .staticText

        super.init(layerBacked: false)

        self.addSubnode(self.avatarNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
        self.addSubnode(self.detailNode)
        self.addSubnode(self.badgeNode)
        self.addSubnode(self.activateArea)
    }

    private static func badgeImage(text: String, textColor: UIColor, fillColor: UIColor) -> UIImage? {
        let font = Font.medium(13.0)
        let attributed = NSAttributedString(string: text, font: font, textColor: textColor)
        let textSize = attributed.boundingRect(with: CGSize(width: 240.0, height: 100.0), options: [.usesLineFragmentOrigin], context: nil).size
        let hPad: CGFloat = 8.0
        let vPad: CGFloat = 4.0
        let size = CGSize(width: ceil(textSize.width) + hPad * 2.0, height: ceil(textSize.height) + vPad * 2.0)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6.0)
            fillColor.setFill()
            path.fill()
            attributed.draw(at: CGPoint(x: hPad, y: vPad))
        }
    }

    func asyncLayout() -> (_ item: AorusBackupSessionItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, (Bool) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)
        let makeDetailLayout = TextNode.asyncLayout(self.detailNode)
        let currentItem = self.item

        return { item, params, neighbors in
            var updatedTheme: PresentationTheme?
            if currentItem?.presentationData.theme !== item.presentationData.theme {
                updatedTheme = item.presentationData.theme
            }

            let hasAvatar = item.avatar != nil
            let avatarSize: CGFloat = 40.0
            let avatarLeft: CGFloat = 16.0 + params.leftInset
            let textLeft: CGFloat = hasAvatar ? (avatarLeft + avatarSize + 12.0) : (16.0 + params.leftInset)
            let rightInset: CGFloat = 16.0 + params.rightInset

            // The badge's own fill decides its text, rather than white deciding it. Under
            // Interface 2.0 the accent colour a filled badge uses *is* the list's ink, which on a
            // dark page is white -- so white text on it left the "logged in" badge a blank pill,
            // which is what was reported. `ink(over:)` answers with whichever of the two reads.
            let badgeFill = item.isLoggedIn ? item.presentationData.theme.list.itemAccentColor : item.presentationData.theme.list.itemSecondaryTextColor.withAlphaComponent(0.12)
            let badgeImage = AorusBackupSessionItemNode.badgeImage(
                text: item.badgeText,
                textColor: item.isLoggedIn ? AorusGlassPane.ink(over: badgeFill) : item.presentationData.theme.list.itemSecondaryTextColor,
                fillColor: badgeFill
            )
            let badgeWidth = badgeImage?.size.width ?? 0.0
            let textRight = params.width - rightInset - (badgeWidth > 0 ? badgeWidth + 12.0 : 0.0)
            let textMaxWidth = max(40.0, textRight - textLeft)

            let titleFont = Font.semibold(16.0)
            let subtitleFont = Font.regular(14.0)
            let detailFont = Font.regular(13.0)
            let secondary = item.presentationData.theme.list.itemSecondaryTextColor

            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: item.presentationData.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: textMaxWidth, height: 100.0), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
            let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.idText, font: subtitleFont, textColor: secondary), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: textMaxWidth, height: 100.0), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
            let (detailLayout, detailApply) = makeDetailLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.dateText, font: detailFont, textColor: secondary), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: textMaxWidth, height: 100.0), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let verticalInset: CGFloat = 14.0
            let titleSpacing: CGFloat = 3.0
            let lineSpacing: CGFloat = 2.0
            let textBlockHeight = titleLayout.size.height + titleSpacing + subtitleLayout.size.height + lineSpacing + detailLayout.size.height
            let minHeight = hasAvatar ? (avatarSize + verticalInset * 2.0) : 0.0
            let contentHeight = max(minHeight, textBlockHeight + verticalInset * 2.0)
            let contentSize = CGSize(width: params.width, height: contentHeight)

            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size
            let separatorHeight = UIScreenPixel

            return (layout, { [weak self] animated in
                guard let strongSelf = self else { return }
                strongSelf.item = item

                strongSelf.activateArea.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: params.width - params.leftInset - params.rightInset, height: contentHeight))
                strongSelf.activateArea.accessibilityLabel = "\(item.title). \(item.idText). \(item.badgeText)"

                if updatedTheme != nil {
                    strongSelf.topStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
                    strongSelf.highlightedBackgroundNode.backgroundColor = item.presentationData.theme.list.itemHighlightedBackgroundColor
                }

                let _ = titleApply()
                let _ = subtitleApply()
                let _ = detailApply()

                let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.3, curve: .easeInOut) : .immediate

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                }

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    strongSelf.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    strongSelf.topStripeNode.isHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = textLeft
                    strongSelf.bottomStripeNode.isHidden = false
                default:
                    bottomStripeInset = 0.0
                    hasBottomCorners = true
                    strongSelf.bottomStripeNode.isHidden = hasCorners
                }

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.presentationData.theme, top: hasTopCorners, bottom: hasBottomCorners) : nil

                strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentHeight + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentHeight - separatorHeight), size: CGSize(width: layoutSize.width - bottomStripeInset, height: separatorHeight))
                strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -separatorHeight), size: CGSize(width: params.width, height: contentHeight + separatorHeight + separatorHeight))

                strongSelf.avatarNode.image = item.avatar
                strongSelf.avatarNode.isHidden = !hasAvatar
                if hasAvatar {
                    strongSelf.avatarNode.frame = CGRect(origin: CGPoint(x: avatarLeft, y: floor((contentHeight - avatarSize) / 2.0)), size: CGSize(width: avatarSize, height: avatarSize))
                }

                let textTop = floor((contentHeight - textBlockHeight) / 2.0)
                transition.updateFrame(node: strongSelf.titleNode, frame: CGRect(origin: CGPoint(x: textLeft, y: textTop), size: titleLayout.size))
                transition.updateFrame(node: strongSelf.subtitleNode, frame: CGRect(origin: CGPoint(x: textLeft, y: textTop + titleLayout.size.height + titleSpacing), size: subtitleLayout.size))
                transition.updateFrame(node: strongSelf.detailNode, frame: CGRect(origin: CGPoint(x: textLeft, y: textTop + titleLayout.size.height + titleSpacing + subtitleLayout.size.height + lineSpacing), size: detailLayout.size))

                strongSelf.badgeNode.image = badgeImage
                if let badgeImage = badgeImage {
                    strongSelf.badgeNode.frame = CGRect(origin: CGPoint(x: params.width - rightInset - badgeImage.size.width, y: floor((contentHeight - badgeImage.size.height) / 2.0)), size: badgeImage.size)
                }
            })
        }
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                if self.bottomStripeNode.supernode != nil {
                    self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: self.bottomStripeNode)
                } else {
                    self.insertSubnode(self.highlightedBackgroundNode, at: 0)
                }
            }
        } else {
            if self.highlightedBackgroundNode.supernode != nil {
                if animated {
                    self.highlightedBackgroundNode.layer.animateAlpha(from: self.highlightedBackgroundNode.alpha, to: 0.0, duration: 0.4, completion: { [weak self] completed in
                        if completed {
                            self?.highlightedBackgroundNode.removeFromSupernode()
                        }
                    })
                    self.highlightedBackgroundNode.alpha = 0.0
                } else {
                    self.highlightedBackgroundNode.removeFromSupernode()
                }
            }
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
