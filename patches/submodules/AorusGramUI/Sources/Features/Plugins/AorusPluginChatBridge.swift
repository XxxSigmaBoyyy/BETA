import Foundation
import UIKit

// The open chat, as a plugin can reach it.
//
// Everything a plugin does with the chat it is looking at has to go through the controller
// that is actually on screen, and that controller lives in TelegramUI — a module this one
// cannot import, because TelegramUI imports this one. So the shape of what is needed is
// declared here as a protocol, TelegramUI supplies an adapter that conforms to it, and the
// chat registers itself while it is on screen and withdraws when it leaves.
//
// The consequence is the one from the API documentation: chat calls answer while a chat is
// open and refuse the moment it is not. That is not a limitation to work around — it is
// what "the current chat" means.

/// What the open chat can do for a plugin. Implemented in TelegramUI by a small adapter
/// over the chat controller; nothing here knows what a chat controller is.
public protocol AorusPluginChatHost: AnyObject {
    var aorusPluginPeerId: Int64 { get }
    var aorusPluginThreadId: Int64? { get }
    var aorusPluginTitle: String { get }
    /// `user`, `group`, `channel` or `secret`.
    var aorusPluginKind: String { get }

    func aorusPluginDraftText() -> String
    func aorusPluginSetDraftText(_ text: String)
    func aorusPluginInsertText(_ text: String)
    func aorusPluginClearInput()
    func aorusPluginSetTyping(_ enabled: Bool)
    func aorusPluginMarkRead()
    func aorusPluginScrollToMessage(_ messageId: Int32)
    /// The messages on screen, newest last, as plain dictionaries ready to cross into
    /// JavaScript.
    func aorusPluginVisibleMessages(limit: Int) -> [[String: Any]]
}

/// The one place that knows which chat is open.
///
/// Reads and writes are confined to the main thread, which is also the only thread the
/// chat controller may be touched from, so the reference cannot go stale between the check
/// and the call.
public final class AorusPluginChatBridge {
    public static let shared = AorusPluginChatBridge()

    /// Posted when a chat appears or disappears, so the runtime can tell plugins.
    public static let openedNotification = Notification.Name("aorusgram.plugins.chatOpened")
    public static let closedNotification = Notification.Name("aorusgram.plugins.chatClosed")
    public static let inputChangedNotification = Notification.Name("aorusgram.plugins.chatInputChanged")
    /// A plugin added, changed or removed something it draws over the chat.
    public static let overlaysChangedNotification = Notification.Name("aorusgram.plugins.overlaysChanged")
    /// One of those things was tapped. Posted by whatever drew it; the runtime turns it into
    /// the plugin's `overlayAction`.
    public static let overlayTappedNotification = Notification.Name("aorusgram.plugins.overlayTapped")

    /// Reports a tap on an overlay. It goes through a notification rather than a direct call
    /// because the view that drew it is in TelegramUI and the runtime that owns the plugin is
    /// here, and this is the one direction the modules cannot call in.
    public static func reportOverlayTap(pluginId: String, overlayId: String, peerId: Int64?) {
        var info: [String: Any] = ["pluginId": pluginId, "overlayId": overlayId]
        if let peerId = peerId { info["peerId"] = String(peerId) }
        NotificationCenter.default.post(name: AorusPluginChatBridge.overlayTappedNotification, object: nil, userInfo: info)
    }

    private weak var host: AorusPluginChatHost?

    private init() {}

    /// The chat that is on screen. Nil between chats, which is the honest answer rather
    /// than the last one that happened to be open.
    public var current: AorusPluginChatHost? {
        assert(Thread.isMainThread)
        return host
    }

    public func attach(_ host: AorusPluginChatHost) {
        assert(Thread.isMainThread)
        self.host = host
        NotificationCenter.default.post(
            name: AorusPluginChatBridge.openedNotification,
            object: nil,
            userInfo: AorusPluginChatBridge.describe(host)
        )
    }

    public func detach(_ host: AorusPluginChatHost) {
        assert(Thread.isMainThread)
        // Only the chat that is actually registered may withdraw. Two chats overlap during
        // a push, and the one leaving must not remove the one that has just arrived.
        guard self.host === host else { return }
        let info: [String: Any] = ["peerId": String(host.aorusPluginPeerId)]
        self.host = nil
        NotificationCenter.default.post(name: AorusPluginChatBridge.closedNotification, object: nil, userInfo: info)
    }

    /// The composer text changed. `source` separates what the person typed from what a
    /// plugin itself just wrote, so a plugin that reacts to input cannot drive itself in a
    /// loop.
    public func reportInputChanged(_ host: AorusPluginChatHost, text: String, source: String) {
        assert(Thread.isMainThread)
        // Only the chat that is registered may report. A controller still in the stack but
        // no longer on screen keeps getting interface-state updates, and its composer is not
        // the one anybody is typing in.
        guard self.host === host else { return }
        NotificationCenter.default.post(
            name: AorusPluginChatBridge.inputChangedNotification,
            object: nil,
            userInfo: ["text": text, "source": source, "peerId": String(host.aorusPluginPeerId)]
        )
    }

    public static func describe(_ host: AorusPluginChatHost) -> [String: Any] {
        var info: [String: Any] = [
            "peerId": String(host.aorusPluginPeerId),
            "title": host.aorusPluginTitle,
            "kind": host.aorusPluginKind
        ]
        if let threadId = host.aorusPluginThreadId {
            info["threadId"] = String(threadId)
        }
        return info
    }
}
