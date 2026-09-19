import UIKit
import Foundation
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import SwiftSignalKit

// MARK: - AorusCode Compose Sheet
//
// Bottom sheet presented via long-press on the chat attachment button when
// AorusCode is enabled in AorusGram settings.
// The user writes a visible cover text and a secret message; on send, the
// pair is encoded into a zero-width steganographic payload by AorusStealthCodec
// and enqueued as a regular Telegram message. Non-AorusGram clients see only
// the cover text; AorusGram recipients reveal the secret under a spoiler.

public final class AorusCodeComposeViewController: UIViewController {

    // MARK: - State

    private let context: AccountContext
    private let peerId: PeerId
    /// The forum topic the compose sheet was opened from. A supergroup with topics rejects a
    /// message that names no topic, so sending without it is how the message silently never
    /// arrives; `nil` is an ordinary chat.
    private let threadId: Int64?
    private let isRu: Bool
    // AorusGram theme so this sheet matches the app (dark + accent) instead of
    // following the system light/dark appearance and a hardcoded orange accent.
    private let theme: PresentationTheme

    // MARK: - Views

    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let coverCard = UIView()
    private let coverHeaderLabel = UILabel()
    private let coverTextView = UITextView()
    private let coverPlaceholder = UILabel()
    private let secretCard = UIView()
    private let secretHeaderLabel = UILabel()
    private let secretTextView = UITextView()
    private let secretPlaceholder = UILabel()
    private let hintLabel = UILabel()
    private let sendButton = UIButton(type: .custom)

    private var scrollViewBottomConstraint: NSLayoutConstraint!

    // MARK: - Init

    public init(context: AccountContext, peerId: PeerId, threadId: Int64? = nil) {
        self.context = context
        self.peerId = peerId
        self.threadId = threadId
        self.isRu = AorusLang.current == .ru
        self.theme = context.sharedContext.currentPresentationData.with { $0 }.theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        registerKeyboardNotifications()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateSendEnabled()
        coverTextView.becomeFirstResponder()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Construction

    private func buildUI() {
        // Follow the AorusGram theme, and force the underlying trait to dark when the
        // theme is dark so any residual system-dynamic color / keyboard reads dark.
        if theme.overallDarkAppearance {
            overrideUserInterfaceStyle = .dark
        } else {
            overrideUserInterfaceStyle = .light
        }
        view.backgroundColor = theme.list.blocksBackgroundColor
        view.tintColor = theme.list.itemAccentColor

        // Title
        titleLabel.text = "AorusCode"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = theme.list.itemPrimaryTextColor
        view.addSubview(titleLabel)

        // Cancel
        cancelButton.setTitle(aorusL("Отмена", "Cancel"), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Separator
        let sep = UIView()
        sep.backgroundColor = theme.list.itemBlocksSeparatorColor
        view.addSubview(sep)

        // Scroll + content
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        // Cover card
        coverCard.backgroundColor = theme.list.itemBlocksBackgroundColor
        coverCard.layer.cornerRadius = 14
        coverCard.layer.cornerCurve = .continuous
        coverCard.clipsToBounds = true
        contentView.addSubview(coverCard)

        coverHeaderLabel.text = aorusL("Видимый текст", "Visible Text")
        coverHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        coverHeaderLabel.textColor = theme.list.itemSecondaryTextColor
        coverHeaderLabel.textAlignment = .left
        contentView.addSubview(coverHeaderLabel)

        configureTextView(coverTextView)
        coverTextView.delegate = self
        contentView.addSubview(coverTextView)
        configurePlaceholder(coverPlaceholder,
                             text: aorusL("Что увидят все...", "What everyone sees..."),
                             in: coverCard)

        // Secret card
        secretCard.backgroundColor = theme.list.itemBlocksBackgroundColor
        secretCard.layer.cornerRadius = 14
        secretCard.layer.cornerCurve = .continuous
        secretCard.clipsToBounds = true
        contentView.addSubview(secretCard)

        secretHeaderLabel.text = aorusL("Скрытое сообщение", "Hidden Message")
        secretHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        secretHeaderLabel.textColor = theme.list.itemAccentColor
        contentView.addSubview(secretHeaderLabel)

        configureTextView(secretTextView)
        secretTextView.delegate = self
        contentView.addSubview(secretTextView)
        configurePlaceholder(secretPlaceholder,
                             text: aorusL("Только для AorusGram...", "AorusGram users only..."),
                             in: secretCard)

        // Hint
        hintLabel.text = aorusL("Скрытое сообщение видят только пользователи AorusGram — под спойлером.", "Hidden message is only visible to AorusGram users — under a spoiler.")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = theme.list.itemSecondaryTextColor
        hintLabel.numberOfLines = 0
        contentView.addSubview(hintLabel)

        // Send button
        sendButton.setTitle(aorusL("Отправить", "Send"), for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.setTitleColor(UIColor(white: 1.0, alpha: 0.5), for: .disabled)
        sendButton.layer.cornerRadius = 14
        sendButton.layer.cornerCurve = .continuous
        sendButton.clipsToBounds = true
        sendButton.addTarget(self, action: #selector(onSend),        for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(sendHighlight), for: [.touchDown, .touchDragEnter])
        sendButton.addTarget(self, action: #selector(sendNormal),    for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        contentView.addSubview(sendButton)

        installConstraints(separator: sep)
    }

    private func configureTextView(_ tv: UITextView) {
        tv.font = .systemFont(ofSize: 16)
        tv.backgroundColor = .clear
        tv.textColor = theme.list.itemPrimaryTextColor
        tv.tintColor = theme.list.itemAccentColor
        tv.keyboardAppearance = theme.overallDarkAppearance ? .dark : .light
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.layer.cornerRadius = 14
        tv.layer.cornerCurve = .continuous
    }

    // A real placeholder label that sits behind the (transparent) text view, so
    // `textView.text` is always genuine user content — no placeholder/flag desync.
    private func configurePlaceholder(_ label: UILabel, text: String, in card: UIView) {
        label.text = text
        label.font = .systemFont(ofSize: 16)
        label.textColor = theme.list.itemPlaceholderTextColor
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    private func installConstraints(separator: UIView) {
        let m: CGFloat = 16
        let subviews: [UIView] = [titleLabel, cancelButton, separator,
                                   scrollView, contentView, coverHeaderLabel, coverCard,
                                   coverTextView, secretHeaderLabel, secretCard,
                                   secretTextView, hintLabel, sendButton]
        subviews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        scrollViewBottomConstraint = scrollView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 27),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancelButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),

            separator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollViewBottomConstraint,

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            // Cover
            coverHeaderLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: m),
            coverHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            coverCard.topAnchor.constraint(equalTo: coverHeaderLabel.bottomAnchor, constant: 6),
            coverCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            coverCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            coverTextView.topAnchor.constraint(equalTo: coverCard.topAnchor),
            coverTextView.leadingAnchor.constraint(equalTo: coverCard.leadingAnchor),
            coverTextView.trailingAnchor.constraint(equalTo: coverCard.trailingAnchor),
            coverTextView.bottomAnchor.constraint(equalTo: coverCard.bottomAnchor),
            coverTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),

            // Secret
            secretHeaderLabel.topAnchor.constraint(equalTo: coverCard.bottomAnchor, constant: m),
            secretHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            secretCard.topAnchor.constraint(equalTo: secretHeaderLabel.bottomAnchor, constant: 6),
            secretCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            secretCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            secretTextView.topAnchor.constraint(equalTo: secretCard.topAnchor),
            secretTextView.leadingAnchor.constraint(equalTo: secretCard.leadingAnchor),
            secretTextView.trailingAnchor.constraint(equalTo: secretCard.trailingAnchor),
            secretTextView.bottomAnchor.constraint(equalTo: secretCard.bottomAnchor),
            secretTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),

            hintLabel.topAnchor.constraint(equalTo: secretCard.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            sendButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 20),
            sendButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            sendButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            sendButton.heightAnchor.constraint(equalToConstant: 52),
            sendButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - Keyboard

    private func registerKeyboardNotifications() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
              let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else { return }

        let kbInView = view.convert(frame, from: view.window)
        let overlap = max(0, view.bounds.maxY - kbInView.minY)
        scrollViewBottomConstraint.constant = -(max(0, overlap - view.safeAreaInsets.bottom))

        UIView.animate(withDuration: duration,
                       delay: 0,
                       options: UIView.AnimationOptions(rawValue: curve << 16)) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Send state

    private var sendActiveColor: UIColor { theme.list.itemAccentColor }
    private var sendInactiveColor: UIColor { theme.list.itemDisabledTextColor }

    private func trimmed(_ tv: UITextView) -> String {
        (tv.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSendEnabled() {
        let hasSecret = !trimmed(secretTextView).isEmpty
        sendButton.isEnabled = hasSecret
        sendButton.backgroundColor = hasSecret ? sendActiveColor : sendInactiveColor
    }

    // MARK: - Actions

    @objc private func sendHighlight() {
        guard sendButton.isEnabled else { return }
        UIView.animate(withDuration: 0.08) { self.sendButton.alpha = 0.72 }
    }

    @objc private func sendNormal() {
        UIView.animate(withDuration: 0.2) { self.sendButton.alpha = 1.0 }
    }

    @objc private func onCancel() {
        dismiss(animated: true)
    }

    @objc private func onSend() {
        let cover = trimmed(coverTextView)
        let secret = trimmed(secretTextView)
        guard !secret.isEmpty else { return }

        let encoded = AorusStealthCodec.shared.encode(cover: cover, secret: secret)
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
            .message(
                text: encoded,
                attributes: [],
                inlineStickers: [:],
                mediaReference: nil,
                threadId: threadId,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
        ]).startStandalone()
        dismiss(animated: true)
    }
}

// MARK: - UITextViewDelegate

extension AorusCodeComposeViewController: UITextViewDelegate {

    public func textViewDidChange(_ textView: UITextView) {
        coverPlaceholder.isHidden = !(coverTextView.text ?? "").isEmpty
        secretPlaceholder.isHidden = !(secretTextView.text ?? "").isEmpty
        updateSendEnabled()
    }
}
