import Foundation
import UIKit

// The UIKit the AI chat leans on, checked against the real SDK.
//
// `AorusAIMention.swift` and `AorusAIControllers.swift` name Telegram's modules, so neither can
// be type-checked on its own: the preflight can only parse them, and a method that does not
// exist parses perfectly. Every such call is repeated here, against the same iOS SDK the app is
// built with, so a name that is wrong fails in seconds instead of an hour.
//
// The delegate methods are here for a second reason. An optional protocol method whose signature
// is one label out is not an error — it is a method nobody ever calls, and the feature simply
// does nothing. Swift does say so, as a "nearly matches" warning, so this file is compiled with
// warnings as errors and every delegate method the chat implements is declared here exactly as
// it is declared there.
//
// This file is compiled and thrown away. It is not part of the app.

@available(iOS 17.0, *)
func aorusProbeTextItem(_ item: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
    let range: NSRange = item.range
    guard case let .textAttachment(attachment) = item.content else {
        return UITextItem.MenuConfiguration(menu: defaultMenu)
    }
    _ = range
    _ = attachment
    return UITextItem.MenuConfiguration(menu: UIMenu(children: [UIAction(title: "x") { _ in }]))
}

func aorusProbeSelectLine(_ textView: UITextView, range: NSRange) {
    // Selecting the line a formula sits on.
    let text = textView.textStorage.string as NSString
    let line = text.lineRange(for: range)
    textView.becomeFirstResponder()
    textView.selectedRange = line
}

func aorusProbeHolding(_ textView: UITextView, table: UITableView) -> Bool {
    // Whether the reader is holding a selection, and finding the cell a text view sits in.
    let held = textView.selectedRange.length > 0
    let inCell = table.visibleCells.contains { textView.isDescendant(of: $0) }
    return held && inCell
}

/// Every delegate method the AI chat implements, with the signatures it implements them with.
final class AorusProbeTextViewDelegate: NSObject, UITextViewDelegate {
    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        return UITextItem.MenuConfiguration(menu: defaultMenu)
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        return defaultAction
    }

    @available(iOS 16.0, *)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        return UIMenu(children: suggestedActions)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        _ = textView.selectedRange.length
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        return interaction == .invokeDefaultAction
    }
}
