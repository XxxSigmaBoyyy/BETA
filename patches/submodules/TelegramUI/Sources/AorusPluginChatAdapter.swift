import Foundation
import UIKit
import ObjectiveC
import Postbox
import TelegramCore
import AccountContext
import SwiftSignalKit
import Display
import ChatPresentationInterfaceState
import ChatInterfaceState
import ChatControllerInteraction
import LocalizedPeerData
import AorusGramUI

// The chat controller, as a plugin can reach it.
//
// `AorusPluginChatBridge` declares what the open chat has to be able to do and holds whichever
// one is on screen; this is the other half — the part that knows what a chat controller is.
// It lives in TelegramUI because nothing below TelegramUI does, and it is deliberately thin:
// every method here is a call the controller already makes for itself somewhere else.
//
// It is attached when the chat appears and withdrawn when it leaves, so a plugin asking for
// "the current chat" between two chats is told there is none rather than handed the last one.

private var aorusPluginChatAdapterKey: UInt8 = 0

final class AorusPluginChatAdapter: NSObject, AorusPluginChatHost {
    private weak var controller: ChatControllerImpl?
    /// The composer text as of the last report. The interface state is updated for dozens of
    /// reasons that have nothing to do with typing, and an event per keystroke is only useful
    /// if it fires per keystroke.
    private var lastReportedText: String
    /// Set while this adapter is itself writing the draft, so a plugin that reacts to
    /// `inputChanged` by writing the composer does not drive itself in a loop.
    private var isWriting = false

    init(controller: ChatControllerImpl) {
        self.controller = controller
        self.lastReportedText = controller.presentationInterfaceState.interfaceState.effectiveInputState.inputText.string
        super.init()
    }

    private var liveController: ChatControllerImpl? {
        guard let controller = self.controller, controller.isNodeLoaded else { return nil }
        return controller
    }

    // MARK: - Identity

    var aorusPluginPeerId: Int64 {
        return self.controller?.chatLocation.peerId?.toInt64() ?? 0
    }

    var aorusPluginThreadId: Int64? {
        return self.controller?.chatLocation.threadId
    }

    var aorusPluginTitle: String {
        guard let controller = self.controller,
              let peer = controller.presentationInterfaceState.renderedPeer?.chatMainPeer else { return "" }
        return EnginePeer(peer).displayTitle(
            strings: controller.presentationInterfaceState.strings,
            displayOrder: controller.presentationInterfaceState.nameDisplayOrder
        )
    }

    var aorusPluginKind: String {
        guard let peer = self.controller?.presentationInterfaceState.renderedPeer?.chatMainPeer else { return "unknown" }
        switch EnginePeer(peer) {
        case let .user(user):
            return user.botInfo != nil ? "bot" : "user"
        case .legacyGroup:
            return "group"
        case let .channel(channel):
            if case .broadcast = channel.info { return "channel" }
            return "group"
        case .secretChat:
            return "secret"
        case .community:
            return "community"
        }
    }

    // MARK: - The composer

    func aorusPluginDraftText() -> String {
        return self.controller?.presentationInterfaceState.interfaceState.effectiveInputState.inputText.string ?? ""
    }

    func aorusPluginSetDraftText(_ text: String) {
        self.write(NSAttributedString(string: text))
    }

    func aorusPluginInsertText(_ text: String) {
        guard let controller = self.liveController else { return }
        let current = controller.presentationInterfaceState.interfaceState.effectiveInputState.inputText
        let updated = NSMutableAttributedString(attributedString: current)
        updated.append(NSAttributedString(string: text))
        self.write(updated)
    }

    func aorusPluginClearInput() {
        self.write(NSAttributedString(string: ""))
    }

    private func write(_ text: NSAttributedString) {
        guard let controller = self.liveController else { return }
        let caret = text.length
        self.isWriting = true
        controller.updateChatPresentationInterfaceState(animated: false, interactive: false) {
            $0.updatedInterfaceState {
                $0.withUpdatedComposeInputState(ChatTextInputState(inputText: text, selectionRange: caret ..< caret))
            }
        }
        self.isWriting = false
        // The write moved the composer, so the event says so and names itself as the cause.
        self.reportInputIfChanged(source: "plugin")
    }

    // MARK: - The conversation

    func aorusPluginSetTyping(_ enabled: Bool) {
        guard let controller = self.controller else { return }
        let space: PeerActivitySpace
        switch controller.chatLocation {
        case let .peer(peerId):
            space = PeerActivitySpace(peerId: peerId, category: .global)
        case let .replyThread(message):
            space = PeerActivitySpace(peerId: message.peerId, category: .thread(message.threadId))
        case .customChatContents:
            return
        }
        controller.context.account.updateLocalInputActivity(peerId: space, activity: .typingText, isPresent: enabled)
    }

    func aorusPluginMarkRead() {
        guard let controller = self.liveController,
              let message = controller.chatDisplayNode.historyNode.latestMessageInCurrentHistoryView() else { return }
        let _ = controller.context.engine.messages.applyMaxReadIndexInteractively(index: message.index).start()
    }

    func aorusPluginScrollToMessage(_ messageId: Int32) {
        guard let controller = self.liveController, let peerId = controller.chatLocation.peerId else { return }
        let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId)
        controller.navigateToMessage(
            messageLocation: .id(id, NavigateToMessageParams()),
            animated: true,
            forceInCurrentChat: true
        )
    }

    func aorusPluginVisibleMessages(limit: Int) -> [[String: Any]] {
        guard let controller = self.liveController else { return [] }
        var collected: [Message] = []
        var seen = Set<MessageId>()
        controller.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
            for message in itemNode.messages() where seen.insert(message.id).inserted {
                collected.append(message)
            }
        }
        // The list is rotated and the visible nodes come in layout order, which is not the
        // order anyone reads the chat in. Newest last, the same way `chats.history` answers.
        collected.sort { left, right in
            if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
            return left.id < right.id
        }
        if collected.count > limit {
            collected.removeFirst(collected.count - limit)
        }
        var remainingCharacters = 128_000
        return collected.map { message in
            let text = String(message.text.prefix(min(32_768, max(0, remainingCharacters))))
            remainingCharacters -= text.count
            var item: [String: Any] = [
                "id": NSNumber(value: message.id.id),
                "namespace": NSNumber(value: message.id.namespace),
                "peerId": String(message.id.peerId.toInt64()),
                "text": text,
                "date": NSNumber(value: message.timestamp),
                "incoming": NSNumber(value: message.flags.contains(.Incoming)),
                "hasMedia": NSNumber(value: !message.media.isEmpty),
            ]
            if let authorId = message.author?.id.toInt64() {
                item["senderId"] = String(authorId)
            }
            return item
        }
    }

    // MARK: - Reporting

    fileprivate func reportInputIfChanged(source: String) {
        guard let controller = self.controller else { return }
        let text = controller.presentationInterfaceState.interfaceState.effectiveInputState.inputText.string
        guard text != self.lastReportedText else { return }
        self.lastReportedText = text
        AorusPluginChatBridge.shared.reportInputChanged(self, text: text, source: source)
    }

    fileprivate var isWritingDraft: Bool {
        return self.isWriting
    }
}

extension ChatControllerImpl {
    private var aorusPluginChatAdapter: AorusPluginChatAdapter? {
        get { return objc_getAssociatedObject(self, &aorusPluginChatAdapterKey) as? AorusPluginChatAdapter }
        set { objc_setAssociatedObject(self, &aorusPluginChatAdapterKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The chat is on screen: it becomes the one a plugin means by "the current chat".
    func aorusPluginChatDidAppear() {
        let adapter = self.aorusPluginChatAdapter ?? AorusPluginChatAdapter(controller: self)
        self.aorusPluginChatAdapter = adapter
        AorusPluginChatBridge.shared.attach(adapter)
    }

    /// The chat is leaving. The bridge ignores this if another chat has already registered,
    /// which is what happens during a push.
    func aorusPluginChatWillDisappear() {
        guard let adapter = self.aorusPluginChatAdapter else { return }
        AorusPluginChatBridge.shared.detach(adapter)
    }

    /// The interface state changed for some reason. Only a changed composer is an event, and
    /// only from the chat that is registered.
    func aorusPluginChatStateUpdated() {
        guard let adapter = self.aorusPluginChatAdapter, !adapter.isWritingDraft else { return }
        adapter.reportInputIfChanged(source: "user")
    }
}
