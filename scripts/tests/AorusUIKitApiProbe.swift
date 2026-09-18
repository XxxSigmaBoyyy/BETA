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

@available(iOS 17.0, *)
func aorusProbeLift(_ image: UIImage, size: CGSize, menu: UIMenu) -> UITextItem.MenuConfiguration {
    // What a held formula is lifted on: a view of ours, which is where its colour comes from.
    let container = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height))
    container.backgroundColor = .black
    container.layer.cornerRadius = 12.0
    container.layer.cornerCurve = .continuous
    container.layer.masksToBounds = true
    let drawn = UIImageView(image: image)
    drawn.contentMode = .scaleAspectFit
    container.addSubview(drawn)
    return UITextItem.MenuConfiguration(preview: .view(container), menu: menu)
}

final class AorusProbeSaver: NSObject {
    // The callback UIKit makes when a save finishes, and the selector that names it.
    @objc func aorusDidSaveMathImage(_ image: UIImage,
                                     didFinishSavingWithError error: Error?,
                                     contextInfo: UnsafeRawPointer?) {
        UINotificationFeedbackGenerator().notificationOccurred(error == nil ? .success : .error)
    }

    func save(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self,
                                       #selector(aorusDidSaveMathImage(_:didFinishSavingWithError:contextInfo:)),
                                       nil)
    }
}

func aorusProbeSave(_ textView: UITextView, image: UIImage) {
    // Where a formula goes when it is saved, and where its own place on screen comes from.
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    guard let start = textView.position(from: textView.beginningOfDocument, offset: 0),
          let end = textView.position(from: start, offset: 1),
          let range = textView.textRange(from: start, to: end) else { return }
    _ = textView.firstRect(for: range)
    _ = textView.textColor
    _ = textView.font?.pointSize
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
