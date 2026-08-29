import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ContextUI
import AccountContext
import TelegramPresentationData
import SwiftSignalKit
import AppBundle

// The AorusAI message actions are a native Telegram context menu: the row in the message
// menu pushes another level of the same menu, with Telegram's own rows, icons, section
// headers, back row and dismissal. Nothing here draws a surface of its own.
//
// Depth is not a problem: `ContextControllerActionsStackNode` lays out every container in
// its stack and only gives the top two a non-zero alpha, and the extracted presentation
// node's scroll view sizes itself to the actions, so a long level scrolls instead of
// running off the screen.

/// The grey band that titles a group of rows.
///
/// Telegram ships `SectionTitleContextItem` for this, in a module TelegramUI does not
/// depend on; the node is small enough that owning it here is cheaper than adding a
/// build dependency to a module we do not patch.
final class AorusAISectionTitleContextItem: ContextMenuCustomItem {
    let text: String

    init(text: String) {
        self.text = text
    }

    func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return AorusAISectionTitleContextItemNode(presentationData: presentationData, item: self)
    }
}

private final class AorusAISectionTitleContextItemNode: ASDisplayNode, ContextMenuCustomNode {
    private let backgroundNode: ASDisplayNode
    private let textNode: ImmediateTextNode

    var needsSeparator: Bool {
        return false
    }

    var needsPadding: Bool {
        return false
    }

    init(presentationData: PresentationData, item: AorusAISectionTitleContextItem) {
        let textFont = Font.regular(presentationData.listsFontSize.baseDisplaySize * 12.0 / 17.0)

        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isAccessibilityElement = false
        self.backgroundNode.backgroundColor = presentationData.theme.contextMenu.sectionSeparatorColor

        self.textNode = ImmediateTextNode()
        self.textNode.isAccessibilityElement = false
        self.textNode.isUserInteractionEnabled = false
        self.textNode.displaysAsynchronously = false
        self.textNode.attributedText = NSAttributedString(string: item.text, font: textFont, textColor: presentationData.theme.contextMenu.secondaryColor)
        self.textNode.maximumNumberOfLines = 1

        super.init()

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.textNode)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let sideInset: CGFloat = 18.0 + 4.0
        let textSize = self.textNode.updateLayout(CGSize(width: max(1.0, constrainedWidth - sideInset * 2.0), height: .greatestFiniteMagnitude))
        // 28pt of band plus the 10pt gap that separates it from the group above.
        let height: CGFloat = 10.0 + 28.0
        return (CGSize(width: textSize.width + sideInset * 2.0, height: height), { size, transition in
            let verticalOrigin = floor((size.height - 10.0 - textSize.height) / 2.0)
            transition.updateFrameAdditive(node: self.textNode, frame: CGRect(origin: CGPoint(x: sideInset, y: verticalOrigin), size: textSize))
            transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: max(0.0, size.height - 10.0))))
        })
    }

    func updateTheme(presentationData: PresentationData) {
        self.backgroundNode.backgroundColor = presentationData.theme.contextMenu.sectionSeparatorColor
        let textFont = Font.regular(presentationData.listsFontSize.baseDisplaySize * 12.0 / 17.0)
        self.textNode.attributedText = NSAttributedString(
            string: self.textNode.attributedText?.string ?? "",
            font: textFont,
            textColor: presentationData.theme.contextMenu.secondaryColor
        )
    }

    func canBeHighlighted() -> Bool {
        return false
    }

    func updateIsHighlighted(isHighlighted: Bool) {
    }

    func performAction() {
    }
}

private func aorusAIMenuBackItem(strings: PresentationStrings) -> ContextMenuItem {
    return .action(ContextMenuActionItem(text: strings.Common_Back, textColor: .primary, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
    }, iconPosition: .left, action: { c, _ in
        c?.popItems()
    }))
}

private func aorusAIMenuTextLayout(hint: String?) -> ContextMenuActionItemTextLayout {
    if let hint, !hint.isEmpty {
        return .secondLineWithValue(hint)
    }
    return .singleLine
}

/// One row. A row with children pushes another level; a leaf closes the menu and runs.
private func aorusAIMenuItem(
    _ item: AorusAIMessageMenu.Item,
    strings: PresentationStrings,
    run: @escaping (String) -> Void
) -> ContextMenuItem {
    let iconName = item.icon
    let icon: (PresentationTheme) -> UIImage? = { theme in
        return generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.contextMenu.primaryColor)
    }
    let children = item.children
    if children.isEmpty {
        let id = item.id
        return .action(ContextMenuActionItem(
            text: item.title,
            textLayout: aorusAIMenuTextLayout(hint: item.hint),
            icon: icon,
            action: { c, _ in
                c?.dismiss(completion: {
                    run(id)
                })
            }
        ))
    }
    let title = item.title
    return .action(ContextMenuActionItem(
        text: item.title,
        textLayout: aorusAIMenuTextLayout(hint: item.hint),
        icon: icon,
        action: { c, _ in
            var subItems: [ContextMenuItem] = []
            subItems.append(aorusAIMenuBackItem(strings: strings))
            subItems.append(.custom(AorusAISectionTitleContextItem(text: title), false))
            for child in children {
                subItems.append(aorusAIMenuItem(child, strings: strings, run: run))
            }
            c?.pushItems(items: .single(ContextController.Items(content: .list(subItems))))
        }
    ))
}

/// The level the "ИИ-компаньон" row of the message context menu pushes.
///
/// This is the whole surface the host patch needs: the generated code hands the message
/// over and pushes these items, so the actions, their grouping and their navigation all
/// live in this module instead of inside TelegramUI.
public func aorusAIMessageMenuItems(
    context: AccountContext,
    navigationController: NavigationController?,
    peerId: Int64,
    messageNamespace: Int32,
    messageId: Int32,
    authorPeerId: Int64?,
    text: String
) -> Signal<ContextController.Items, NoError> {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let languageCode = strings.baseLanguageCode

    // The author's name is only needed by the action that eventually runs, so it is
    // resolved then rather than held up in front of the menu.
    let run: (String) -> Void = { id in
        guard let navigationController else { return }
        aorusAIResolveAuthorName(context: context, authorPeerId: authorPeerId) { authorName in
            AorusAIMessageMenu.run(
                id: id,
                context: context,
                navigationController: navigationController,
                reference: AorusAIReferencedMessage(
                    peerId: peerId,
                    messageNamespace: messageNamespace,
                    messageId: messageId,
                    authorPeerId: authorPeerId,
                    authorName: authorName,
                    text: text
                )
            )
        }
    }

    var items: [ContextMenuItem] = []
    items.append(aorusAIMenuBackItem(strings: strings))
    for group in AorusAIMessageMenu.groups(languageCode: languageCode) {
        if let title = group.title, !title.isEmpty {
            items.append(.custom(AorusAISectionTitleContextItem(text: title), false))
        } else {
            items.append(.separator)
        }
        for item in group.items {
            items.append(aorusAIMenuItem(item, strings: strings, run: run))
        }
    }
    items.append(.separator)
    items.append(aorusAIMenuItem(AorusAIMessageMenu.footerItem, strings: strings, run: run))

    return .single(ContextController.Items(content: .list(items)))
}
