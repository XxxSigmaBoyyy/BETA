import Foundation
import UIKit

// The UIKit calls the AI chat makes that only the hour-long build would otherwise check.
//
// `AorusAIMention.swift` and `AorusAIControllers.swift` name Telegram's modules, so neither can
// be type-checked on its own: the preflight can only parse them, and a method that does not
// exist parses perfectly. Every such call the two of them make against a recent SDK is repeated
// here, against the same iOS SDK the app is built with — so a name that is wrong, a label that
// moved, or an API that is newer than it is remembered to be fails in seconds.
//
// This file is compiled and thrown away. It is not part of the app.

@available(iOS 17.0, *)
func aorusProbeTextItem(_ item: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
    // The range of the pressed item, and what kind of item it is.
    let range: NSRange = item.range
    guard case let .textAttachment(attachment) = item.content else {
        return UITextItem.MenuConfiguration(menu: defaultMenu)
    }
    _ = range
    _ = attachment
    return UITextItem.MenuConfiguration(menu: UIMenu(children: [UIAction(title: "x") { _ in }]))
}

@available(iOS 16.0, *)
func aorusProbeEditMenu(_ textView: UITextView, range: NSRange) {
    // Selecting a line and opening the text menu over it.
    let text = textView.textStorage.string as NSString
    let line = text.lineRange(for: range)
    textView.becomeFirstResponder()
    textView.selectedRange = line
    guard let interaction = textView.editMenuInteraction else { return }
    guard let start = textView.position(from: textView.beginningOfDocument, offset: line.location),
          let end = textView.position(from: start, offset: line.length),
          let selection = textView.textRange(from: start, to: end) else { return }
    let rect = textView.firstRect(for: selection)
    interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
                                                              sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
}

@available(iOS 16.0, *)
func aorusProbeEditMenuForText(_ suggested: [UIMenuElement]) -> UIMenu? {
    return UIMenu(children: suggested + [UIAction(title: "x") { _ in }])
}
