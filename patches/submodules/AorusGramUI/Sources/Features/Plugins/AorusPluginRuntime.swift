import Foundation
import UIKit
import Postbox
import TelegramCore
import AccountContext
import SwiftSignalKit
import Display
import TelegramPresentationData
import ContextUI
import QuickLook
import AorusGram

/// The entitlement verdict for the plugin runtime, read once and re-read only when it can
/// have changed.
///
/// `AorusPluginEntitlement.isAllowed` walks the licence stack: two UserDefaults reads, the
/// session counter and a signed offline snapshot. That is the right check, and it was being
/// made on *every* call a plugin makes across the boundary — every `console.log`, every
/// storage write, every timer tick. It is a disk-backed read in the hot path of a scripting
/// runtime, and the answer cannot change between two lines of the same script.
///
/// So it is answered from a cache with a short life. A lapse is noticed within a second,
/// which is the same guarantee the rest of the app gives, and nothing pays for it per call.
enum AorusPluginEntitlement {
    private static let lock = NSLock()
    private static var cached: Bool = false
    private static var checkedAt: Date = .distantPast

    static var isAllowed: Bool {
        lock.lock()
        let now = Date()
        if now.timeIntervalSince(checkedAt) < 1.0 {
            let value = cached
            lock.unlock()
            return value
        }
        lock.unlock()
        let value = AorusLicenseAccess.isAllowed
        lock.lock()
        cached = value
        checkedAt = now
        lock.unlock()
        return value
    }

    /// Forget the cached answer. Called when the app comes back to the foreground and when
    /// the licence state is published, so a change is seen at once rather than within the
    /// window above.
    static func invalidate() {
        lock.lock()
        checkedAt = .distantPast
        lock.unlock()
    }
}

public final class AorusPluginRuntimeManager {
    public static let shared = AorusPluginRuntimeManager()

    private let lock = NSLock()
    private var context: AccountContext?
    private var host: AorusPluginTelegramHost?
    private var sandboxes: [String: AorusPluginSandbox] = [:]
    private var schemas: [String: [AorusPluginSettingField]] = [:]
    private var pages: [String: [AorusPluginUIPage]] = [:]
    private var settingsShortcuts: [String: [AorusPluginSettingsShortcut]] = [:]
    private var contextActions: [String: [AorusPluginContextAction]] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {}

    public func configure(context: AccountContext) {
        lock.lock()
        let unchanged = self.context === context
        let previous = unchanged ? [] : Array(sandboxes.values)
        let previousHost = unchanged ? nil : self.host
        if !unchanged {
            sandboxes.removeAll()
            schemas.removeAll()
            pages.removeAll()
            settingsShortcuts.removeAll()
            contextActions.removeAll()
            self.context = context
            self.host = AorusPluginTelegramHost(context: context, manager: self)
        }
        lock.unlock()
        guard !unchanged else { return }
        previous.forEach { sandbox in
            previousHost?.clearPluginState(sandbox.manifest.id)
            sandbox.stop()
        }
        publishIntegrationsChanged()
        installObservers()
        reloadAutostart()
    }

    public func reloadAutostart() {
        guard let host = currentHost() else { return }
        guard AorusPluginEntitlement.isAllowed else {
            stopAll()
            return
        }
        let records = AorusPluginStore.shared.list().compactMap { AorusPluginStore.shared.load(id: $0.id) }
        let desired = records.filter { $0.manifest.isEnabled && $0.manifest.autostart }
        // Autostart decides what is launched when the account runtime appears. It must not
        // stop an enabled plugin that the person started manually during this session.
        let enabledIds = Set(records.filter { $0.manifest.isEnabled }.map { $0.manifest.id })

        lock.lock()
        let stale = sandboxes.filter { !enabledIds.contains($0.key) }.map { $0.value }
        for sandbox in stale {
            sandboxes[sandbox.manifest.id] = nil
            pages[sandbox.manifest.id] = nil
            settingsShortcuts[sandbox.manifest.id] = nil
            contextActions[sandbox.manifest.id] = nil
        }
        lock.unlock()
        if !stale.isEmpty { publishIntegrationsChanged() }
        stale.forEach { sandbox in
            host.clearPluginState(sandbox.manifest.id)
            sandbox.stop()
        }

        for record in desired {
            let state = AorusPluginStore.shared.permissionState(for: record.manifest.id)
            let digest = AorusPluginStore.sourceDigest(record.source)
            let requested = AorusPluginPermission.requestedBySource(record.source)
            guard state.sourceDigest == digest, requested.isSubset(of: state.granted) else {
                var manifest = record.manifest
                manifest.isEnabled = false
                try? AorusPluginStore.shared.updateManifest(manifest)
                continue
            }
            lock.lock()
            let exists = sandboxes[record.manifest.id] != nil
            lock.unlock()
            if !exists { start(record: record, host: host, permissions: state.granted) }
        }
    }

    public func start(id: String, completion: ((AorusPluginRunError?) -> Void)? = nil) {
        guard let host = currentHost(), let record = AorusPluginStore.shared.load(id: id), record.manifest.isEnabled else {
            completion?(.notRunning)
            return
        }
        let state = AorusPluginStore.shared.permissionState(for: id)
        let digest = AorusPluginStore.sourceDigest(record.source)
        let requested = AorusPluginPermission.requestedBySource(record.source)
        guard state.sourceDigest == digest, requested.isSubset(of: state.granted) else {
            completion?(.runtime(message: "Plugin permissions must be reviewed", line: nil))
            return
        }
        start(record: record, host: host, permissions: state.granted, completion: completion)
    }

    public func stop(id: String, completion: (() -> Void)? = nil) {
        lock.lock()
        let sandbox = sandboxes.removeValue(forKey: id)
        pages[id] = nil
        settingsShortcuts[id] = nil
        contextActions[id] = nil
        lock.unlock()
        publishIntegrationsChanged()
        currentHost()?.clearPluginState(id)
        sandbox?.stop(completion: completion)
        if sandbox == nil { completion?() }
    }

    public func restart(id: String, completion: ((AorusPluginRunError?) -> Void)? = nil) {
        stop(id: id) { [weak self] in self?.start(id: id, completion: completion) }
    }

    public func sandbox(id: String) -> AorusPluginSandbox? {
        lock.lock(); defer { lock.unlock() }
        return sandboxes[id]
    }

    public func settingsSchema(id: String) -> [AorusPluginSettingField] {
        lock.lock()
        let cached = schemas[id]
        lock.unlock()
        if let cached { return cached }
        guard let record = AorusPluginStore.shared.load(id: id) else { return [] }
        return AorusPluginStore.shared.schema(for: id, source: record.source)
    }

    public func processOutgoing(text: String, peerId: Int64, accountId: Int64) -> AorusPluginOutgoingVerdict {
        guard AorusPluginEntitlement.isAllowed else { return .passThrough }
        lock.lock()
        let active = Array(sandboxes.values)
        lock.unlock()
        var replacement = text
        let deadline = Date().addingTimeInterval(0.1)
        for sandbox in active where sandbox.hasOutgoingHooks {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let result = sandbox.processOutgoing(text: replacement, peerId: peerId, accountId: accountId, timeout: remaining)
            if result.consumed { return result }
            if let value = result.replacement { replacement = value }
        }
        return replacement == text ? .passThrough : AorusPluginOutgoingVerdict(replacement: replacement)
    }

    public func page(pluginId: String, pageId: String) -> AorusPluginUIPage? {
        lock.lock(); defer { lock.unlock() }
        return pages[pluginId]?.first(where: { $0.id == pageId })
    }

    public func pluginSettingsShortcuts() -> [(pluginId: String, shortcut: AorusPluginSettingsShortcut)] {
        lock.lock(); defer { lock.unlock() }
        return settingsShortcuts.keys.sorted().flatMap { pluginId in
            (settingsShortcuts[pluginId] ?? []).map { (pluginId, $0) }
        }
    }

    public func pluginContextActions() -> [(pluginId: String, action: AorusPluginContextAction)] {
        lock.lock(); defer { lock.unlock() }
        return Array(contextActions.keys.sorted().flatMap { pluginId in
            (contextActions[pluginId] ?? []).map { (pluginId, $0) }
        }.prefix(4))
    }

    public func performSettingsShortcut(pluginId: String, id: String) {
        lock.lock()
        let shortcut = settingsShortcuts[pluginId]?.first(where: { $0.id == id })
        let host = self.host
        lock.unlock()
        guard let shortcut, let host else { return }
        if let pageId = shortcut.pageId {
            guard isPermissionGranted(.customUI, pluginId: pluginId) else { return }
            host.pluginOpenPage(pluginId, pageId: pageId, style: "push") { _ in }
        } else if let url = shortcut.url {
            guard isPermissionGranted(.inAppBrowser, pluginId: pluginId) else { return }
            host.pluginOpenURL(pluginId, url: url) { _ in }
        }
    }

    public func openURL(pluginId: String, url: String, completion: ((Error?) -> Void)? = nil) {
        guard isPermissionGranted(.inAppBrowser, pluginId: pluginId) else {
            completion?(AorusPluginRequestError("In-app browser permission is not granted"))
            return
        }
        lock.lock(); let host = self.host; lock.unlock()
        guard let host else { completion?(AorusPluginRequestError("Plugin runtime is unavailable")); return }
        host.pluginOpenURL(pluginId, url: url) { result in
            switch result {
            case .success: completion?(nil)
            case let .failure(error): completion?(error)
            }
        }
    }

    /// Every tap on something a plugin put on screen goes through one of these two, and
    /// both write a line to the plugin's log. A button that does nothing is the hardest
    /// thing to debug from the outside, and the log is where the answer belongs: either the
    /// event was delivered and the plugin ignored it, or the plugin was not running to
    /// receive it.
    public func dispatchUIAction(pluginId: String, pageId: String, rowId: String, value: AorusPluginJSONValue?) {
        lock.lock(); let sandbox = sandboxes[pluginId]; lock.unlock()
        var payload: [String: Any] = ["pageId": pageId, "rowId": rowId]
        if let value { payload["value"] = value.anyValue }
        guard let sandbox else { return }
        sandbox.note(.debug, "uiAction \(pageId)/\(rowId)")
        sandbox.dispatch(event: "uiAction", payload: payload)
    }

    public func dispatchContextAction(pluginId: String, actionId: String, payload: [String: Any]) {
        lock.lock(); let sandbox = sandboxes[pluginId]; lock.unlock()
        var value = payload
        value["actionId"] = actionId
        guard let sandbox else { return }
        sandbox.note(.debug, "contextAction \(actionId)")
        sandbox.dispatch(event: "contextAction", payload: value)
    }

    fileprivate func setSchema(_ fields: [AorusPluginSettingField], id: String) {
        let fields = Array(fields.prefix(64))
        lock.lock(); schemas[id] = fields; lock.unlock()
        if let record = AorusPluginStore.shared.load(id: id) {
            try? AorusPluginStore.shared.setSchema(fields, sourceDigest: AorusPluginStore.sourceDigest(record.source), for: id)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("aorusgram.plugins.schemaChanged"), object: id)
        }
    }

    fileprivate func publishSettingsChanged(_ id: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("aorusgram.plugins.settingsChanged"), object: id)
        }
    }

    fileprivate func setPages(_ value: [AorusPluginUIPage], id: String) {
        lock.lock(); pages[id] = value; lock.unlock()
        publishIntegrationsChanged()
    }

    fileprivate func setSettingsShortcuts(_ value: [AorusPluginSettingsShortcut], id: String) {
        lock.lock(); settingsShortcuts[id] = value; lock.unlock()
        publishIntegrationsChanged()
    }

    fileprivate func setContextActions(_ value: [AorusPluginContextAction], id: String) {
        lock.lock(); contextActions[id] = value; lock.unlock()
        publishIntegrationsChanged()
    }

    private func publishIntegrationsChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("aorusgram.plugins.integrationsChanged"), object: nil)
        }
    }

    private func currentHost() -> AorusPluginTelegramHost? {
        lock.lock(); defer { lock.unlock() }
        return host
    }

    fileprivate func isPermissionGranted(_ permission: AorusPluginPermission, pluginId: String) -> Bool {
        guard AorusPluginEntitlement.isAllowed,
              let record = AorusPluginStore.shared.load(id: pluginId), record.manifest.isEnabled else { return false }
        let state = AorusPluginStore.shared.permissionState(for: pluginId)
        return state.sourceDigest == AorusPluginStore.sourceDigest(record.source) && state.granted.contains(permission)
    }

    private func stopAll() {
        lock.lock()
        let active = Array(sandboxes.values)
        sandboxes.removeAll()
        schemas.removeAll()
        pages.removeAll()
        settingsShortcuts.removeAll()
        contextActions.removeAll()
        lock.unlock()
        publishIntegrationsChanged()
        if let host = currentHost() { active.forEach { host.clearPluginState($0.manifest.id) } }
        active.forEach { $0.stop() }
    }

    private func start(record: AorusPluginRecord, host: AorusPluginTelegramHost, permissions: Set<AorusPluginPermission>, completion: ((AorusPluginRunError?) -> Void)? = nil) {
        // Every path that runs a plugin comes through here, so the entitlement is checked
        // once, at the moment a script would start executing. The settings screen already
        // routes a locked licence to the subscription flow; this covers autostart, which
        // runs before anyone opens a screen at all.
        // The one place a plugin can start. A refusal here used to be silent — the switch
        // stayed on, the card said nothing, and every command the plugin registered simply
        // never existed. It names itself now, and the card shows it.
        guard AorusPluginEntitlement.isAllowed else {
            completion?(.runtime(message: "AorusGram subscription is not active, so plugins do not run", line: nil))
            return
        }
        let sandbox = AorusPluginSandbox(
            manifest: record.manifest,
            source: record.source,
            host: host,
            permissions: permissions,
            storage: AorusPluginStore.shared.storage(for: record.manifest.id),
            settings: AorusPluginStore.shared.settings(for: record.manifest.id),
            settingsSchema: settingsSchema(id: record.manifest.id),
            filesDirectory: AorusPluginStore.shared.filesDirectory(for: record.manifest.id)
        )
        lock.lock()
        let previous = sandboxes.updateValue(sandbox, forKey: record.manifest.id)
        pages[record.manifest.id] = nil
        settingsShortcuts[record.manifest.id] = nil
        contextActions[record.manifest.id] = nil
        lock.unlock()
        publishIntegrationsChanged()
        previous?.stop()
        sandbox.start { [weak self, weak sandbox] error in
            if error != nil {
                self?.lock.lock()
                if self?.sandboxes[record.manifest.id] === sandbox { self?.sandboxes[record.manifest.id] = nil }
                self?.pages[record.manifest.id] = nil
                self?.settingsShortcuts[record.manifest.id] = nil
                self?.contextActions[record.manifest.id] = nil
                self?.lock.unlock()
                self?.publishIntegrationsChanged()
            }
            completion?(error)
        }
    }

    private func installObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AorusPluginStore.changedNotification, object: nil, queue: nil) { [weak self] _ in
            self?.reloadAutostart()
        })
        // On the main queue on purpose: the licence notification is posted from wherever
        // the gate happens to be, including during launch, and this handler starts and
        // stops plugins.
        observers.append(center.addObserver(forName: NSNotification.Name("aorusgram.licenseLockChanged"), object: nil, queue: .main) { [weak self] _ in
            AorusPluginEntitlement.invalidate()
            self?.reloadAutostart()
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            AorusPluginEntitlement.invalidate()
        })
        observers.append(center.addObserver(forName: NSNotification.Name("aorusgram.didReceiveMessage"), object: nil, queue: nil) { [weak self] note in
            guard let self, let info = note.userInfo,
                  let eventAccountPath = info["accountPath"] as? String,
                  eventAccountPath == self.context?.account.postbox.mediaBox.basePath else { return }
            var payload: [String: Any] = [:]
            for key in ["peerId", "senderId", "msgId", "msgNs", "text", "date", "peerKind"] {
                if let value = info[key] as? NSNumber, key == "peerId" || key == "senderId" {
                    payload[key] = String(value.int64Value)
                } else if let value = info[key] {
                    payload[key] = value
                }
            }
            payload["accountId"] = String(self.context?.account.id.int64 ?? 0)
            self.dispatch(event: "message", payload: payload)
        })
        observers.append(center.addObserver(forName: NSNotification.Name("aorusgram.willDeleteMessage"), object: nil, queue: nil) { [weak self] note in
            guard let self, let info = note.userInfo,
                  let eventAccountPath = info["accountPath"] as? String,
                  eventAccountPath == self.context?.account.postbox.mediaBox.basePath,
                  let peerId = info["peerId"] as? NSNumber,
                  let msgId = info["msgId"] as? NSNumber,
                  let msgNs = info["msgNs"] as? NSNumber else { return }
            self.dispatch(event: "messageDeleted", payload: [
                "accountId": String(self.context?.account.id.int64 ?? 0),
                "peerId": String(peerId.int64Value),
                "msgId": msgId,
                "msgNs": msgNs,
            ])
        })
        observers.append(center.addObserver(forName: NSNotification.Name("aorusgram.willEditMessage"), object: nil, queue: nil) { [weak self] note in
            guard let self, let info = note.userInfo,
                  let eventAccountPath = info["accountPath"] as? String,
                  eventAccountPath == self.context?.account.postbox.mediaBox.basePath,
                  let peerId = info["peerId"] as? NSNumber,
                  let msgId = info["msgId"] as? NSNumber,
                  let msgNs = info["msgNs"] as? NSNumber else { return }
            var payload: [String: Any] = [
                "accountId": String(self.context?.account.id.int64 ?? 0),
                "peerId": String(peerId.int64Value),
                "msgId": msgId,
                "msgNs": msgNs,
            ]
            if let original = info["originalText"] as? String { payload["originalText"] = String(original.prefix(32_768)) }
            if let updated = info["newText"] as? String { payload["text"] = String(updated.prefix(32_768)) }
            if let date = info["date"] as? NSNumber { payload["date"] = date }
            self.dispatch(event: "messageEdited", payload: payload)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.dispatch(event: "foreground", payload: [:])
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.dispatch(event: "background", payload: [:])
        })
        observers.append(center.addObserver(forName: .aorusSettingsChanged, object: nil, queue: nil) { [weak self] _ in
            self?.dispatch(event: "appSettingsChanged", payload: [:])
        })
        observers.append(center.addObserver(forName: AorusConnectionPreferences.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.dispatch(event: "connectionChanged", payload: [:])
        })
        // The chat on screen. These three are posted from the chat controller itself, on the
        // main thread, and carry only what `aorus.chat.current()` would have returned.
        observers.append(center.addObserver(forName: AorusPluginChatBridge.openedNotification, object: nil, queue: .main) { [weak self] note in
            self?.dispatch(event: "chatOpened", payload: note.userInfo as? [String: Any] ?? [:])
        })
        observers.append(center.addObserver(forName: AorusPluginChatBridge.closedNotification, object: nil, queue: .main) { [weak self] note in
            self?.dispatch(event: "chatClosed", payload: note.userInfo as? [String: Any] ?? [:])
        })
        observers.append(center.addObserver(forName: AorusPluginChatBridge.inputChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo, let text = info["text"] as? String else { return }
            var payload: [String: Any] = [
                "text": String(text.prefix(32_768)),
                "source": (info["source"] as? String) ?? "user",
            ]
            if let peerId = info["peerId"] as? String { payload["peerId"] = peerId }
            self?.dispatch(event: "inputChanged", payload: payload)
        })
    }

    private func dispatch(event: String, payload: [String: Any]) {
        lock.lock(); let active = Array(sandboxes.values); lock.unlock()
        active.forEach { $0.dispatch(event: event, payload: payload) }
    }
}

private final class AorusPluginTelegramHost: AorusPluginHostServices {
    private let context: AccountContext
    private weak var manager: AorusPluginRuntimeManager?
    private let aiLock = NSLock()
    private var aiStreams: [String: AorusAIStreamHandle] = [:]
    private var aiReservations = Set<String>()
    private var aiArtifacts: [String: [String: AorusAIArtifact]] = [:]
    private var aiTurnIds: [String: String] = [:]

    init(context: AccountContext, manager: AorusPluginRuntimeManager) {
        self.context = context
        self.manager = manager
    }

    var pluginExecutionAllowed: Bool { AorusPluginEntitlement.isAllowed }

    func clearPluginState(_ pluginId: String) {
        aiLock.lock()
        let stream = aiStreams.removeValue(forKey: pluginId)
        let turnId = aiTurnIds.removeValue(forKey: pluginId)
        aiReservations.remove(pluginId)
        aiArtifacts[pluginId] = nil
        aiLock.unlock()
        stream?.cancelTransport()
        if let turnId { AorusAIClient.shared.cancelTurn(turnId) { _ in } }
    }

    func pluginLog(_ pluginId: String, level: AorusPluginLogEntry.Level, text: String) {}

    func pluginStorageChanged(_ pluginId: String, values: [String: AorusPluginJSONValue]) {
        guard pluginExecutionAllowed else { return }
        try? AorusPluginStore.shared.setStorage(values, for: pluginId)
    }

    func pluginSettingsSchemaChanged(_ pluginId: String, fields: [AorusPluginSettingField]) {
        guard pluginExecutionAllowed else { return }
        manager?.setSchema(Array(fields.prefix(64)), id: pluginId)
    }

    func pluginSettingsChanged(_ pluginId: String, values: [String: AorusPluginJSONValue]) {
        guard pluginExecutionAllowed else { return }
        try? AorusPluginStore.shared.setSettings(values, for: pluginId)
        manager?.publishSettingsChanged(pluginId)
    }

    func pluginPagesChanged(_ pluginId: String, pages: [AorusPluginUIPage]) {
        guard manager?.isPermissionGranted(.customUI, pluginId: pluginId) == true else { return }
        let containsLink = pages.contains { page in
            page.sections.contains { section in section.rows.contains { $0.kind == .link } }
        }
        if containsLink, manager?.isPermissionGranted(.inAppBrowser, pluginId: pluginId) != true { return }
        manager?.setPages(pages, id: pluginId)
    }

    func pluginSettingsShortcutsChanged(_ pluginId: String, shortcuts: [AorusPluginSettingsShortcut]) {
        guard manager?.isPermissionGranted(.settingsIntegration, pluginId: pluginId) == true else { return }
        if shortcuts.contains(where: { $0.url != nil }), manager?.isPermissionGranted(.inAppBrowser, pluginId: pluginId) != true { return }
        manager?.setSettingsShortcuts(shortcuts, id: pluginId)
    }

    func pluginContextActionsChanged(_ pluginId: String, actions: [AorusPluginContextAction]) {
        guard manager?.isPermissionGranted(.contextMenu, pluginId: pluginId) == true else { return }
        manager?.setContextActions(actions, id: pluginId)
    }

    func pluginOpenPage(_ pluginId: String, pageId: String, style: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard manager?.isPermissionGranted(.customUI, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Custom UI permission is not granted")))
            return
        }
        DispatchQueue.main.async {
            guard let page = self.manager?.page(pluginId: pluginId, pageId: pageId),
                  let presenter = self.topController() else {
                completion(.failure(AorusPluginRequestError("Plugin page is not available")))
                return
            }
            let controller = AorusPluginPageController(context: self.context, pluginId: pluginId, page: page)
            // All three styles go onto Telegram's own navigation stack. A Display
            // `ViewController` is laid out by `containerLayoutUpdated`, which only Telegram's
            // containers call — inside a plain `UINavigationController` presented by UIKit it
            // is never called at all and the page comes up blank. `navigationPresentation`
            // is what makes the same stack render a controller as a card or full screen.
            guard let navigation = presenter.navigationController as? NavigationController else {
                completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                return
            }
            switch style {
            case "sheet":
                controller.navigationPresentation = .modal
                controller.installModalCloseButton()
            case "fullScreen":
                controller.navigationPresentation = .flatModal
                controller.installModalCloseButton()
            default:
                break
            }
            navigation.pushViewController(controller)
            completion(.success(()))
        }
    }

    func pluginOpenURL(_ pluginId: String, url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard manager?.isPermissionGranted(.inAppBrowser, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("In-app browser permission is not granted")))
            return
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              let host = parsed.host, (scheme == "http" || scheme == "https"),
              !AorusPluginSandbox.isBlocked(host: host) else {
            completion(.failure(AorusPluginRequestError("URL is not available to plugins")))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            guard AorusPluginSandbox.hostResolvesPublicly(host) else {
                completion(.failure(AorusPluginRequestError("URL is not available to plugins")))
                return
            }
            DispatchQueue.main.async {
                guard self.pluginExecutionAllowed,
                      let navigation = self.topController()?.navigationController as? NavigationController else {
                    completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                    return
                }
                let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                self.context.sharedContext.openExternalUrl(
                    context: self.context,
                    urlContext: .generic,
                    url: url,
                    forceExternal: false,
                    presentationData: presentationData,
                    navigationController: navigation,
                    dismissInput: {}
                )
                completion(.success(()))
            }
        }
    }

    func pluginOpenTelegramLink(_ pluginId: String, url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard manager?.isPermissionGranted(.openChats, pluginId: pluginId) == true,
              let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            completion(.failure(AorusPluginRequestError("Telegram link is not available")))
            return
        }
        let allowed: Bool
        if scheme == "tg" {
            allowed = parsed.host != nil
        } else if scheme == "https", let host = parsed.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            allowed = host == "t.me" || host == "telegram.me" || host == "telegram.dog"
        } else {
            allowed = false
        }
        guard allowed else {
            completion(.failure(AorusPluginRequestError("Only Telegram links are allowed")))
            return
        }
        DispatchQueue.main.async {
            guard self.pluginExecutionAllowed,
                  let navigation = self.topController()?.navigationController as? NavigationController else {
                completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                return
            }
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            self.context.sharedContext.openExternalUrl(
                context: self.context,
                urlContext: .generic,
                url: parsed.absoluteString,
                forceExternal: false,
                presentationData: presentationData,
                navigationController: navigation,
                dismissInput: {}
            )
            completion(.success(()))
        }
    }

    func pluginAIAsk(_ pluginId: String, prompt: String, history: [[String: String]], threadId: String?, event onEvent: @escaping ([String: Any]) -> Void, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.artificialIntelligence, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("AorusAI is unavailable")))
            return
        }
        aiLock.lock()
        guard aiStreams[pluginId] == nil, !aiReservations.contains(pluginId) else {
            aiLock.unlock()
            completion(.failure(AorusPluginRequestError("This plugin already has an AorusAI request in progress")))
            return
        }
        aiReservations.insert(pluginId)
        aiLock.unlock()

        var messages = history.compactMap { item -> AorusAIAgentPayload.Message? in
            guard let role = item["role"], let content = item["content"], ["user", "assistant"].contains(role) else { return nil }
            return AorusAIAgentPayload.Message(role: role, content: content)
        }
        messages.append(AorusAIAgentPayload.Message(role: "user", content: prompt))
        let payload = AorusAIAgentPayload(messages: messages, threadId: threadId)
        let stateLock = NSLock()
        var text = ""
        var artifacts: [AorusAIArtifact] = []
        var finished = false
        func finish(_ result: Result<[String: Any], Error>) {
            stateLock.lock()
            guard !finished else { stateLock.unlock(); return }
            finished = true
            stateLock.unlock()
            self.aiLock.lock()
            self.aiReservations.remove(pluginId)
            self.aiStreams[pluginId] = nil
            self.aiTurnIds[pluginId] = nil
            self.aiLock.unlock()
            completion(result)
        }

        let handle = AorusAIClient.shared.start(payload: payload, event: { event, _ in
            stateLock.lock()
            switch event {
            case let .agentStarted(turnId, _):
                onEvent(["type": "agent.start"])
                self.aiLock.lock()
                let active = self.aiReservations.contains(pluginId) || self.aiStreams[pluginId] != nil
                if active { self.aiTurnIds[pluginId] = turnId }
                self.aiLock.unlock()
                if !active { AorusAIClient.shared.cancelTurn(turnId) { _ in } }
            case let .responseDelta(delta):
                onEvent(["type": "response.delta", "text": delta])
                let room = max(0, AorusAIRequestLimits.responseCharacters - text.count)
                if room > 0 { text.append(room >= delta.count ? delta : String(delta.prefix(room))) }
            case let .completion(value, ready):
                if let value, !value.isEmpty { text = String(value.prefix(AorusAIRequestLimits.responseCharacters)) }
                for artifact in ready where !artifacts.contains(where: { $0.artifactId == artifact.artifactId }) {
                    if artifacts.count < AorusAIRequestLimits.responseArtifactCount { artifacts.append(artifact) }
                }
            case let .artifactReady(artifact):
                onEvent(["type": "artifact.ready", "filename": artifact.filename, "format": artifact.format, "size": artifact.size, "id": artifact.artifactId])
                if artifacts.count < AorusAIRequestLimits.responseArtifactCount,
                   !artifacts.contains(where: { $0.artifactId == artifact.artifactId }) { artifacts.append(artifact) }
            case let .status(label, progress):
                var value: [String: Any] = ["type": "status", "label": label]
                if let progress { value["progress"] = progress }
                onEvent(value)
            case let .buildPhase(phase, label, attempt):
                onEvent(["type": "build.phase", "phase": phase, "label": label, "attempt": attempt])
            case let .reasoningSummary(summary):
                onEvent(["type": "reasoning.summary", "summary": summary])
            case .responseStarted:
                onEvent(["type": "response.start"])
            case .responseDone:
                onEvent(["type": "response.done"])
            case .toolRequest, .permissionRequest:
                stateLock.unlock()
                self.cancelAIStream(pluginId)
                finish(.failure(AorusPluginRequestError("This AorusAI request needs an interaction in the full AorusAI chat")))
                return
            case let .done(ok, _):
                onEvent(["type": "done", "ok": ok])
                let finalText = text
                let finalArtifacts = artifacts
                stateLock.unlock()
                if ok {
                    self.rememberArtifacts(finalArtifacts, pluginId: pluginId)
                    let files: [[String: Any]] = finalArtifacts.map {
                        ["id": $0.artifactId, "filename": $0.filename, "mime": $0.mime, "size": $0.size, "format": $0.format]
                    }
                    finish(.success(["text": finalText, "artifacts": files]))
                } else {
                    finish(.failure(AorusPluginRequestError("AorusAI could not complete the request")))
                }
                return
            default:
                break
            }
            stateLock.unlock()
        }, completion: { result in
            switch result {
            case .success:
                stateLock.lock(); let finalText = text; let finalArtifacts = artifacts; stateLock.unlock()
                self.rememberArtifacts(finalArtifacts, pluginId: pluginId)
                let files: [[String: Any]] = finalArtifacts.map {
                    ["id": $0.artifactId, "filename": $0.filename, "mime": $0.mime, "size": $0.size, "format": $0.format]
                }
                finish(.success(["text": finalText, "artifacts": files]))
            case let .failure(error):
                finish(.failure(error))
            }
        })
        guard let handle else {
            finish(.failure(AorusPluginRequestError("AorusAI is unavailable")))
            return
        }
        aiLock.lock()
        if aiStreams[pluginId] == nil, aiReservations.contains(pluginId) {
            aiReservations.remove(pluginId)
            aiStreams[pluginId] = handle
            aiLock.unlock()
        } else {
            aiReservations.remove(pluginId)
            aiLock.unlock()
            handle.cancelTransport()
            finish(.failure(AorusPluginRequestError("This plugin already has an AorusAI request in progress")))
        }
    }

    func pluginAIOpenArtifact(_ pluginId: String, artifactId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.artificialIntelligence, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("AorusAI is unavailable")))
            return
        }
        aiLock.lock(); let artifact = aiArtifacts[pluginId]?[artifactId]; aiLock.unlock()
        guard let artifact else {
            completion(.failure(AorusPluginRequestError("Artifact is not available to this plugin")))
            return
        }
        _ = AorusAIClient.shared.downloadArtifact(artifact) { result in
            switch result {
            case let .success(url):
                DispatchQueue.main.async {
                    guard let presenter = self.topController() else {
                        completion(.failure(AorusPluginRequestError("Preview is unavailable")))
                        return
                    }
                    let preview = AorusPluginArtifactPreviewController(url: url)
                    presenter.present(preview, animated: true)
                    completion(.success(()))
                }
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func pluginAppFeatures(_ pluginId: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.appCustomization, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("App customization is unavailable")))
            return
        }
        DispatchQueue.main.async {
            guard AorusPluginEntitlement.isAllowed else {
                completion(.failure(AorusPluginRequestError("App customization is unavailable")))
                return
            }
            completion(.success(AorusPluginFeatureBroker.snapshot()))
        }
    }

    func pluginSetAppFeature(_ pluginId: String, featureId: String, value: Any, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.appCustomization, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("App customization is unavailable")))
            return
        }
        DispatchQueue.main.async {
            guard AorusPluginEntitlement.isAllowed else {
                completion(.failure(AorusPluginRequestError("App customization is unavailable")))
                return
            }
            completion(AorusPluginFeatureBroker.set(featureId, value: value))
        }
    }

    func pluginProxyStatus(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.connectionControl, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Connection control is unavailable")))
            return
        }
        completion(.success(AorusPluginProxyBroker.snapshot()))
    }

    func pluginSetProxyPreference(_ pluginId: String, key: String, value: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.connectionControl, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Connection control is unavailable")))
            return
        }
        switch key {
        case "enabled":
            AorusConnectionPreferences.shared.setBypassEnabled(value)
        case "stableCalls":
            AorusConnectionPreferences.shared.setStableCallsEnabled(value)
        default:
            completion(.failure(AorusPluginRequestError("Unsupported proxy preference")))
            return
        }
        completion(.success(AorusPluginProxyBroker.snapshot()))
    }

    func pluginRefreshProxy(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.connectionControl, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Connection control is unavailable")))
            return
        }
        AorusProxyManager.shared.refresh(force: true) { _ in
            guard AorusPluginEntitlement.isAllowed else {
                completion(.failure(AorusPluginRequestError("Connection control is unavailable")))
                return
            }
            completion(.success(AorusPluginProxyBroker.snapshot()))
        }
    }

    func pluginTelegramProxyStatus(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.telegramProxy, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Telegram proxy permission is not granted")))
            return
        }
        readTelegramProxySettings { settings in
            completion(.success(self.telegramProxySnapshot(settings)))
        }
    }

    func pluginSetTelegramProxyEnabled(_ pluginId: String, enabled: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guardTelegramProxyMutation(pluginId, completion: completion) { settings in
            guard !enabled || settings.activeServer != nil else {
                return .failure(AorusPluginRequestError("Select a Telegram proxy before enabling it"))
            }
            var updated = settings
            updated.enabled = enabled
            return .success(updated)
        }
    }

    func pluginSetTelegramProxyUseForCalls(_ pluginId: String, enabled: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guardTelegramProxyMutation(pluginId, completion: completion) { settings in
            var updated = settings
            updated.useForCalls = enabled
            return .success(updated)
        }
    }

    func pluginAddTelegramProxy(_ pluginId: String, type: String, host: String, port: Int32, username: String?, password: String?, secret: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, normalizedHost.count <= 253, port > 0 else {
            completion(.failure(AorusPluginRequestError("Invalid Telegram proxy address")))
            return
        }
        let connection: ProxyServerConnection
        switch type {
        case "socks5":
            guard (username?.count ?? 0) <= 256, (password?.count ?? 0) <= 256 else {
                completion(.failure(AorusPluginRequestError("Telegram proxy credentials are too long")))
                return
            }
            connection = .socks5(username: username?.isEmpty == true ? nil : username, password: password?.isEmpty == true ? nil : password)
        case "mtp":
            guard let value = secret, let decoded = decodeTelegramProxySecret(value) else {
                completion(.failure(AorusPluginRequestError("MTProto proxy secret must be valid hex or base64")))
                return
            }
            connection = .mtp(secret: decoded)
        default:
            completion(.failure(AorusPluginRequestError("Unsupported Telegram proxy type")))
            return
        }
        let server = ProxyServerSettings(host: normalizedHost, port: port, connection: connection)
        guardTelegramProxyMutation(pluginId, completion: completion) { settings in
            var updated = settings
            if let existing = updated.servers.firstIndex(of: server) {
                updated.activeServer = updated.servers[existing]
            } else {
                guard updated.servers.count < 64 else {
                    return .failure(AorusPluginRequestError("Telegram proxy limit reached"))
                }
                updated.servers.append(server)
                updated.activeServer = server
            }
            return .success(updated)
        }
    }

    func pluginRemoveTelegramProxy(_ pluginId: String, index: Int, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guardTelegramProxyMutation(pluginId, completion: completion) { settings in
            guard settings.servers.indices.contains(index) else {
                return .failure(AorusPluginRequestError("Telegram proxy is not available"))
            }
            var updated = settings
            let removed = updated.servers.remove(at: index)
            if updated.activeServer == removed {
                updated.activeServer = nil
                updated.enabled = false
            }
            return .success(updated)
        }
    }

    func pluginSelectTelegramProxy(_ pluginId: String, index: Int?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guardTelegramProxyMutation(pluginId, completion: completion) { settings in
            var updated = settings
            if let index {
                guard settings.servers.indices.contains(index) else {
                    return .failure(AorusPluginRequestError("Telegram proxy is not available"))
                }
                updated.activeServer = settings.servers[index]
            } else {
                updated.activeServer = nil
                updated.enabled = false
            }
            return .success(updated)
        }
    }

    private func guardTelegramProxyMutation(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void, update: @escaping (ProxySettings) -> Result<ProxySettings, Error>) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.telegramProxy, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Telegram proxy permission is not granted")))
            return
        }
        readTelegramProxySettings { current in
            guard AorusPluginEntitlement.isAllowed,
                  self.manager?.isPermissionGranted(.telegramProxy, pluginId: pluginId) == true else {
                completion(.failure(AorusPluginRequestError("Telegram proxy permission is not granted")))
                return
            }
            switch update(current) {
            case let .failure(error):
                completion(.failure(error))
            case let .success(updated):
                let _ = (updateProxySettingsInteractively(accountManager: self.context.sharedContext.accountManager, { _ in updated }) |> take(1)).start(next: { _ in
                    completion(.success(self.telegramProxySnapshot(updated)))
                })
            }
        }
    }

    private func readTelegramProxySettings(_ completion: @escaping (ProxySettings) -> Void) {
        let _ = (context.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.proxySettings]) |> take(1)).start(next: { data in
            completion(data.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? .defaultSettings)
        })
    }

    private func telegramProxySnapshot(_ settings: ProxySettings) -> [String: Any] {
        let servers: [[String: Any]] = settings.servers.enumerated().map { index, server in
            let type: String
            let hasCredentials: Bool
            switch server.connection {
            case let .socks5(username, password):
                type = "socks5"
                hasCredentials = !(username ?? "").isEmpty || !(password ?? "").isEmpty
            case .mtp:
                type = "mtp"
                hasCredentials = true
            }
            return [
                "index": NSNumber(value: index),
                "host": server.host,
                "port": NSNumber(value: server.port),
                "type": type,
                "active": NSNumber(value: server == settings.activeServer),
                "hasCredentials": NSNumber(value: hasCredentials),
            ]
        }
        return [
            "enabled": NSNumber(value: settings.enabled),
            "useForCalls": NSNumber(value: settings.useForCalls),
            "servers": servers,
        ]
    }

    private func decodeTelegramProxySecret(_ value: String) -> Data? {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty, compact.count <= 1_024 else { return nil }
        if compact.count.isMultiple(of: 2), compact.allSatisfy({ $0.isHexDigit }) {
            var result = Data()
            result.reserveCapacity(compact.count / 2)
            var index = compact.startIndex
            while index < compact.endIndex {
                let next = compact.index(index, offsetBy: 2)
                guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
                result.append(byte)
                index = next
            }
            return (16...512).contains(result.count) ? result : nil
        }
        guard let result = Data(base64Encoded: compact), (16...512).contains(result.count) else { return nil }
        return result
    }

    private func rememberArtifacts(_ artifacts: [AorusAIArtifact], pluginId: String) {
        aiLock.lock()
        var known = aiArtifacts[pluginId] ?? [:]
        for artifact in artifacts.prefix(AorusAIRequestLimits.responseArtifactCount) {
            known[artifact.artifactId] = artifact
        }
        aiArtifacts[pluginId] = known
        aiLock.unlock()
    }

    private func cancelAIStream(_ pluginId: String) {
        aiLock.lock(); let stream = aiStreams[pluginId]; aiLock.unlock()
        stream?.cancelTransport()
    }

    func pluginSendMessage(_ pluginId: String, peerId: Int64?, toSelf: Bool, accountId: Int64?, text: String, entities: [AorusPluginTextEntity], replyTo: Int32?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard manager?.isPermissionGranted(.sendMessages, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Send messages permission is not granted")))
            return
        }
        if let accountId, accountId != context.account.id.int64 {
            completion(.failure(AorusPluginRequestError("A plugin cannot send from another account")))
            return
        }
        let target: PeerId
        if toSelf {
            target = context.account.peerId
        } else if let peerId {
            target = PeerId(peerId)
        } else {
            completion(.failure(AorusPluginRequestError("peerId is required")))
            return
        }
        var attributes: [MessageAttribute] = []
        let converted = aorusPluginMessageEntities(entities)
        if !converted.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: converted))
        }
        let signal = enqueueMessages(account: context.account, peerId: target, messages: [
            .message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        ])
        let _ = signal.start(completed: { completion(.success(())) })
    }

    func pluginEditMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withPluginMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, completion: completion) { id in
            let signal = self.context.engine.messages.requestEditMessage(
                messageId: id,
                text: text,
                media: .keep,
                // Plugin edits are plain text. Entity generation belongs to TelegramUI and
                // importing that module here would create a dependency cycle.
                entities: nil,
                richText: nil,
                inlineStickers: [:],
                webpagePreviewAttribute: nil,
                disableUrlPreview: false,
                scheduleInfoAttribute: nil
            )
            let _ = signal.start(next: { result in
                if case .done = result { completion(.success(())) }
            }, error: { _ in
                completion(.failure(AorusPluginRequestError("Telegram rejected the message edit")))
            })
        }
    }

    func pluginDeleteMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, forEveryone: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        withPluginMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, completion: completion) { id in
            let signal = self.context.engine.messages.deleteMessagesInteractively(
                messageIds: [id],
                type: forEveryone ? .forEveryone : .forLocalPeer
            )
            let _ = signal.start(completed: { completion(.success(())) })
        }
    }

    func pluginForwardMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, toPeerId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        withPluginMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, completion: completion) { id in
            let signal = enqueueMessages(account: self.context.account, peerId: PeerId(toPeerId), messages: [
                .forward(source: id, threadId: nil, grouping: .none, attributes: [], correlationId: nil)
            ])
            let _ = signal.start(completed: { completion(.success(())) })
        }
    }

    func pluginReactToMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, reaction: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        withPluginMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, completion: completion) { id in
            self.context.engine.messages.setMessageReactions(ids: [id], reactions: reaction.map { [.builtin($0)] } ?? [])
            completion(.success(()))
        }
    }

    private func withPluginMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, completion: @escaping (Result<Void, Error>) -> Void, action: @escaping (MessageId) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.manageMessages, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Manage messages permission is not granted")))
            return
        }
        let id = MessageId(peerId: PeerId(peerId), namespace: namespace, id: messageId)
        let _ = (context.account.postbox.transaction { transaction in transaction.getMessage(id) != nil } |> take(1)).start(next: { exists in
            guard exists, AorusPluginEntitlement.isAllowed,
                  self.manager?.isPermissionGranted(.manageMessages, pluginId: pluginId) == true else {
                completion(.failure(AorusPluginRequestError(exists ? "Manage messages permission is not granted" : "Message is not available")))
                return
            }
            action(id)
        })
    }

    func pluginResolveChat(_ pluginId: String, username: String, completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
        guard manager?.isPermissionGranted(.chatMetadata, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Chat metadata permission is not granted")))
            return
        }
        let clean = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        guard !clean.isEmpty, clean.count <= 64 else { completion(.failure(AorusPluginRequestError("Invalid username"))); return }
        // resolvePeerByName emits .progress before it emits an answer, so taking the first
        // value would report "not found" for every name that is not already cached. The
        // progress values are dropped, and the flag makes the promise settle exactly once
        // whether the signal ends with an answer or with nothing at all.
        let answered = Atomic<Bool>(value: false)
        let answer: ([String: Any]?) -> Void = { value in
            if !answered.swap(true) {
                completion(.success(value))
            }
        }
        let _ = (context.engine.peers.resolvePeerByName(name: clean, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(peer) = result else { return .complete() }
            return .single(peer)
        }
        |> take(1)).start(next: { peer in
            answer(peer.map(self.pluginPeerDictionary))
        }, completed: {
            answer(nil)
        })
    }

    func pluginChatInfo(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
        guard manager?.isPermissionGranted(.chatMetadata, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Chat metadata permission is not granted")))
            return
        }
        let id: PeerId?
        if toSelf { id = context.account.peerId } else if let peerId { id = PeerId(peerId) } else { id = nil }
        guard let id else { completion(.failure(AorusPluginRequestError("peerId is required"))); return }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id)) |> take(1)).start(next: { peer in
            completion(.success(peer.map(self.pluginPeerDictionary)))
        })
    }

    func pluginChatHistory(_ pluginId: String, peerId: Int64?, toSelf: Bool, limit: Int, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        guard manager?.isPermissionGranted(.messageHistory, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Message history permission is not granted")))
            return
        }
        let id: PeerId?
        if toSelf { id = context.account.peerId } else if let peerId { id = PeerId(peerId) } else { id = nil }
        guard let id else {
            completion(.failure(AorusPluginRequestError("peerId is required")))
            return
        }
        let requested = min(100, max(1, limit))
        let signal = context.account.postbox.transaction { transaction -> [[String: Any]] in
            var result: [[String: Any]] = []
            var remainingCharacters = 128_000
            transaction.scanTopMessages(peerId: id, namespace: Namespaces.Message.Cloud, limit: requested) { message in
                guard result.count < requested, remainingCharacters > 0 else { return false }
                let text = String(message.text.prefix(min(32_768, remainingCharacters)))
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
                result.append(item)
                return true
            }
            return Array(result.reversed())
        }
        let _ = signal.start(next: { messages in
            completion(.success(messages))
        })
    }

    func pluginOpenChat(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard manager?.isPermissionGranted(.openChats, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Open chats permission is not granted")))
            return
        }
        let id: PeerId?
        if toSelf { id = context.account.peerId } else if let peerId { id = PeerId(peerId) } else { id = nil }
        guard let id else { completion(.failure(AorusPluginRequestError("peerId is required"))); return }
        // `NavigateToChatControllerParams.Location` is not `ChatLocation`: its `.peer` case
        // carries the peer itself, not an id. So the chat is loaded first, and a plugin
        // naming something this account cannot see is told so instead of opening nothing.
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id))
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self else {
                completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                return
            }
            guard let peer else {
                completion(.failure(AorusPluginRequestError("Chat is not available")))
                return
            }
            guard let navigation = self.topController()?.navigationController as? NavigationController else {
                completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                return
            }
            self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: self.context, chatLocation: .peer(peer)))
            completion(.success(()))
        })
    }

    // MARK: - The open chat
    //
    // Every call here goes through `AorusPluginChatBridge`, which holds the chat that is on
    // screen and nothing else. The bridge is main-thread-only because a chat controller is,
    // and a plugin calls from its own serial queue, so each one hops.

    /// Runs `body` against the open chat on the main thread, or fails with the one sentence
    /// that says there is none. The permission is checked before the hop, so a plugin that
    /// was not granted anything never reaches the chat at all.
    private func withOpenChat<T>(
        _ pluginId: String,
        permission: AorusPluginPermission,
        denied: String,
        completion: @escaping (Result<T, Error>) -> Void,
        _ body: @escaping (AorusPluginChatHost) -> T
    ) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(permission, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError(denied)))
            return
        }
        let run = {
            guard let host = AorusPluginChatBridge.shared.current else {
                completion(.failure(AorusPluginRequestError(AorusPluginSandbox.noChatOpen)))
                return
            }
            completion(.success(body(host)))
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    func pluginCurrentChat(_ pluginId: String, completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.chatMetadata, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Chat metadata permission is not granted")))
            return
        }
        // The one call that answers when no chat is open: `null` is the fact a plugin asks
        // for, and turning it into an error would make "is a chat open?" unanswerable.
        let run = {
            guard let host = AorusPluginChatBridge.shared.current else {
                completion(.success(nil))
                return
            }
            completion(.success(AorusPluginChatBridge.describe(host)))
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    func pluginCurrentChatDraft(_ pluginId: String, completion: @escaping (Result<String, Error>) -> Void) {
        withOpenChat(pluginId, permission: .composer, denied: "Composer permission is not granted", completion: completion) { host in
            String(host.aorusPluginDraftText().prefix(32_768))
        }
    }

    func pluginSetCurrentChatDraft(_ pluginId: String, text: String, mode: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withOpenChat(pluginId, permission: .composer, denied: "Composer permission is not granted", completion: completion) { host in
            switch mode {
            case "insert": host.aorusPluginInsertText(text)
            case "clear": host.aorusPluginClearInput()
            default: host.aorusPluginSetDraftText(text)
            }
        }
    }

    func pluginCurrentChatMessages(_ pluginId: String, limit: Int, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        withOpenChat(pluginId, permission: .chatMetadata, denied: "Chat metadata permission is not granted", completion: completion) { host in
            host.aorusPluginVisibleMessages(limit: min(100, max(1, limit)))
        }
    }

    func pluginCurrentChatTyping(_ pluginId: String, enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        withOpenChat(pluginId, permission: .composer, denied: "Composer permission is not granted", completion: completion) { host in
            host.aorusPluginSetTyping(enabled)
        }
    }

    func pluginCurrentChatMarkRead(_ pluginId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        withOpenChat(pluginId, permission: .composer, denied: "Composer permission is not granted", completion: completion) { host in
            host.aorusPluginMarkRead()
        }
    }

    func pluginCurrentChatScrollTo(_ pluginId: String, messageId: Int32, completion: @escaping (Result<Void, Error>) -> Void) {
        withOpenChat(pluginId, permission: .composer, denied: "Composer permission is not granted", completion: completion) { host in
            host.aorusPluginScrollToMessage(messageId)
        }
    }

    func pluginCurrentAccount(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard manager?.isPermissionGranted(.accountProfile, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Account profile permission is not granted")))
            return
        }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)) |> take(1)).start(next: { peer in
            completion(.success(["id": String(self.context.account.peerId.toInt64()), "title": peer?.compactDisplayTitle ?? ""]))
        })
    }

    func pluginAccounts(_ pluginId: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.accountSwitching, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Account switching permission is not granted")))
            return
        }
        let currentId = context.account.id
        let _ = (context.sharedContext.activeAccountsWithInfo |> take(1)).start(next: { value in
            let accounts: [[String: Any]] = value.accounts.map { item in
                var result: [String: Any] = [
                    "id": String(item.account.id.int64),
                    "peerId": String(item.peer.id.toInt64()),
                    "title": item.peer.compactDisplayTitle,
                    "current": NSNumber(value: item.account.id == currentId),
                ]
                if let username = item.peer.addressName, !username.isEmpty {
                    result["username"] = username
                }
                return result
            }
            completion(.success(accounts))
        })
    }

    func pluginSwitchAccount(_ pluginId: String, accountId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard AorusPluginEntitlement.isAllowed,
              manager?.isPermissionGranted(.accountSwitching, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Account switching permission is not granted")))
            return
        }
        let _ = (context.sharedContext.activeAccountsWithInfo |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, AorusPluginEntitlement.isAllowed,
                  self.manager?.isPermissionGranted(.accountSwitching, pluginId: pluginId) == true else {
                completion(.failure(AorusPluginRequestError("Account switching permission is not granted")))
                return
            }
            guard let account = value.accounts.first(where: { $0.account.id.int64 == accountId }) else {
                completion(.failure(AorusPluginRequestError("Account is not available")))
                return
            }
            if account.account.id != self.context.account.id {
                self.context.sharedContext.switchToAccount(id: account.account.id, fromSettingsController: nil, withChatListController: nil)
            }
            completion(.success(()))
        })
    }

    func pluginShowToast(_ pluginId: String, text: String, duration: Double?) {
        guard manager?.isPermissionGranted(.dialogs, pluginId: pluginId) == true else { return }
        DispatchQueue.main.async {
            guard let presenter = self.topController(), !text.isEmpty else { return }
            let tag = 0xA07A57
            presenter.view.viewWithTag(tag)?.removeFromSuperview()

            let effect = UIBlurEffect(style: self.context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance ? .systemMaterialDark : .systemMaterialLight)
            let toast = UIVisualEffectView(effect: effect)
            toast.tag = tag
            toast.layer.cornerRadius = 14
            toast.layer.cornerCurve = .continuous
            toast.clipsToBounds = true
            toast.alpha = 0
            toast.transform = CGAffineTransform(translationX: 0, y: 12)

            let label = UILabel()
            label.text = String(text.prefix(2_000))
            label.numberOfLines = 4
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .label
            toast.contentView.addSubview(label)
            presenter.view.addSubview(toast)

            let availableWidth = max(160, presenter.view.bounds.width - 40)
            let labelSize = label.sizeThatFits(CGSize(width: availableWidth - 32, height: 160))
            let toastWidth = min(availableWidth, max(140, labelSize.width + 32))
            let toastHeight = max(48, labelSize.height + 24)
            toast.frame = CGRect(
                x: (presenter.view.bounds.width - toastWidth) / 2,
                y: presenter.view.bounds.height - presenter.view.safeAreaInsets.bottom - toastHeight - 18,
                width: toastWidth,
                height: toastHeight
            )
            label.frame = toast.contentView.bounds.insetBy(dx: 16, dy: 12)
            toast.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin]

            UIView.animate(withDuration: 0.2) {
                toast.alpha = 1
                toast.transform = .identity
            }
            let visibleDuration = min(8.0, max(1.2, duration ?? 2.5))
            DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration) { [weak toast] in
                guard let toast else { return }
                UIView.animate(withDuration: 0.2, animations: {
                    toast.alpha = 0
                    toast.transform = CGAffineTransform(translationX: 0, y: 8)
                }, completion: { _ in toast.removeFromSuperview() })
            }
        }
    }

    func pluginAlert(_ pluginId: String, title: String, text: String?, completion: @escaping () -> Void) {
        guard manager?.isPermissionGranted(.dialogs, pluginId: pluginId) == true else { completion(); return }
        DispatchQueue.main.async { self.presentAlert(title: title, text: text, actions: [("OK", .default, completion)]) }
    }

    func pluginConfirm(_ pluginId: String, title: String, text: String?, ok: String?, cancel: String?, completion: @escaping (Bool) -> Void) {
        guard manager?.isPermissionGranted(.dialogs, pluginId: pluginId) == true else { completion(false); return }
        DispatchQueue.main.async {
            self.presentAlert(title: title, text: text, actions: [
                (cancel ?? "Cancel", .cancel, { completion(false) }),
                (ok ?? "OK", .default, { completion(true) })
            ])
        }
    }

    func pluginPrompt(_ pluginId: String, title: String, text: String?, placeholder: String?, defaultValue: String?, ok: String?, cancel: String?, completion: @escaping (String?) -> Void) {
        guard manager?.isPermissionGranted(.dialogs, pluginId: pluginId) == true else { completion(nil); return }
        DispatchQueue.main.async {
            guard let presenter = self.topController() else { completion(nil); return }
            let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
            alert.addTextField { field in field.placeholder = placeholder; field.text = defaultValue }
            alert.addAction(UIAlertAction(title: cancel ?? "Cancel", style: .cancel) { _ in completion(nil) })
            alert.addAction(UIAlertAction(title: ok ?? "OK", style: .default) { _ in completion(alert.textFields?.first?.text) })
            presenter.present(alert, animated: true)
        }
    }

    func pluginShare(_ pluginId: String, text: String?, url: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard manager?.isPermissionGranted(.dialogs, pluginId: pluginId) == true else {
            completion(.failure(AorusPluginRequestError("Dialogs permission is not granted")))
            return
        }
        var items: [Any] = []
        if let text, !text.isEmpty { items.append(text) }
        if let url, !url.isEmpty {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  let host = parsed.host, (scheme == "http" || scheme == "https"),
                  !AorusPluginSandbox.isBlocked(host: host) else {
                completion(.failure(AorusPluginRequestError("URL is not available to plugins")))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                guard AorusPluginSandbox.hostResolvesPublicly(host) else {
                    completion(.failure(AorusPluginRequestError("URL is not available to plugins")))
                    return
                }
                self.presentShare(items: items + [parsed], completion: completion)
            }
            return
        }
        guard !items.isEmpty else {
            completion(.failure(AorusPluginRequestError("Nothing to share")))
            return
        }
        presentShare(items: items, completion: completion)
    }

    private func presentShare(items: [Any], completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            guard self.pluginExecutionAllowed else {
                completion(.failure(AorusPluginRequestError("Plugin execution is unavailable")))
                return
            }
            guard let presenter = self.topController() else {
                completion(.failure(AorusPluginRequestError("Share sheet is unavailable")))
                return
            }
            let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1)
            }
            presenter.present(controller, animated: true)
            completion(.success(()))
        }
    }

    func pluginHaptic(_ pluginId: String, kind: String) {
        guard pluginExecutionAllowed else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: kind == "heavy" ? .heavy : .light).impactOccurred() }
    }

    func pluginClipboardRead(_ pluginId: String, completion: @escaping (String?) -> Void) {
        guard manager?.isPermissionGranted(.clipboardRead, pluginId: pluginId) == true else { completion(nil); return }
        DispatchQueue.main.async { completion(UIPasteboard.general.string) }
    }

    func pluginClipboardWrite(_ pluginId: String, text: String) {
        guard manager?.isPermissionGranted(.clipboardWrite, pluginId: pluginId) == true else { return }
        DispatchQueue.main.async { UIPasteboard.general.string = text }
    }

    func pluginTheme(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let theme = presentationData.theme
        let name: String
        switch theme.name {
        case let .builtin(builtin):
            switch builtin {
            case .dayClassic: name = "dayClassic"
            case .day: name = "day"
            case .night: name = "night"
            case .nightAccent: name = "nightAccent"
            }
        case let .custom(title):
            name = title
        }
        completion(.success([
            "isDark": NSNumber(value: theme.overallDarkAppearance),
            "name": name,
            "accent": AorusPluginTelegramHost.hex(theme.list.itemAccentColor),
            "background": AorusPluginTelegramHost.hex(theme.list.plainBackgroundColor),
            "groupedBackground": AorusPluginTelegramHost.hex(theme.list.blocksBackgroundColor),
            "text": AorusPluginTelegramHost.hex(theme.list.itemPrimaryTextColor),
            "secondaryText": AorusPluginTelegramHost.hex(theme.list.itemSecondaryTextColor),
            "destructive": AorusPluginTelegramHost.hex(theme.list.itemDestructiveColor),
        ]))
    }

    /// "RRGGBB", the same six digits a plugin's own accent is written as, so a colour read
    /// from the theme can be handed straight back to anything that takes one.
    private static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return AorusPluginAccent.fallback }
        let channel: (CGFloat) -> Int = { Int((min(1.0, max(0.0, $0)) * 255.0).rounded()) }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    var pluginDeviceInfo: [String: Any] {
        return [
            "language": pluginInterfaceLanguage,
            "systemVersion": UIDevice.current.systemVersion,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "isDark": context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance
        ]
    }

    var pluginInterfaceLanguage: String {
        return context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
    }

    private func pluginPeerDictionary(_ peer: EnginePeer) -> [String: Any] {
        let kind: String
        if case let .channel(channel) = peer {
            if case .broadcast = channel.info { kind = "channel" } else { kind = "group" }
        } else if peer.id.namespace == Namespaces.Peer.CloudGroup {
            kind = "group"
        } else if peer.id.namespace == Namespaces.Peer.SecretChat {
            kind = "secretChat"
        } else {
            kind = "user"
        }
        var result: [String: Any] = [
            "id": String(peer.id.toInt64()),
            "title": peer.compactDisplayTitle,
            "kind": kind,
            "verified": peer.isVerified,
            "premium": peer.isPremium,
            "scam": peer.isScam
        ]
        if let username = peer.addressName { result["username"] = username }
        return result
    }

    private func topController() -> UIViewController? {
        var controller = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController { controller = presented; continue }
            if let navigation = current as? UINavigationController, let top = navigation.topViewController { controller = top; continue }
            if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController { controller = selected; continue }
            break
        }
        return controller
    }

    private func presentAlert(title: String?, text: String?, actions: [(String, UIAlertAction.Style, () -> Void)]) {
        guard let presenter = topController() else { actions.last?.2(); return }
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        for action in actions { alert.addAction(UIAlertAction(title: action.0, style: action.1) { _ in action.2() }) }
        presenter.present(alert, animated: true)
    }
}

private enum AorusPluginFeatureBroker {
    private struct Definition {
        let id: String
        let category: String
        let type: String
        let minimum: Int?
        let maximum: Int?
        let options: [String]?

        init(_ id: String, _ category: String, _ type: String = "toggle", minimum: Int? = nil, maximum: Int? = nil, options: [String]? = nil) {
            self.id = id
            self.category = category
            self.type = type
            self.minimum = minimum
            self.maximum = maximum
            self.options = options
        }
    }

    private static let definitions: [Definition] = [
        Definition("ghostMode", "privacy"), Definition("blockReadReceipts", "privacy"),
        Definition("hideTyping", "privacy"), Definition("antiScreenshot", "privacy"),
        Definition("saveDeletedMessages", "messages"), Definition("saveEditedMessages", "messages"),
        Definition("antiSpamEnabled", "messages"), Definition("translator", "messages"),
        Definition("shareButton", "messages"), Definition("autoReply", "messages"),
        Definition("editLocally", "messages"), Definition("userMessagesInGroup", "messages"),
        Definition("messageSeconds", "messages"), Definition("doubleTapCopy", "messages"),
        Definition("tripleTapDelete", "messages"), Definition("wallEnabled", "messages"),
        Definition("maxMediaQuality", "media"), Definition("downloadAccel", "media"),
        Definition("voiceTranscription", "media"), Definition("videoMessagesRearCamera", "media"),
        Definition("deviceMicrophone", "media"), Definition("voiceTwinEnabled", "media"),
        Definition("voiceTwinPreset", "media", "select", options: ["anonymous", "male", "female", "robot", "child"]),
        Definition("videoMasksEnabled", "media"),
        Definition("videoMaskPreset", "media", "select", options: ["skull", "cyber", "oni", "phantom", "chrome", "aurora", "neonCat"]),
        Definition("callRecording", "calls"),
        Definition("glassUI", "interface"), Definition("amoledMode", "interface"),
        Definition("profileReportButton", "interface"), Definition("squareAvatars", "interface"),
        Definition("hideCallsTab", "tabs"), Definition("hideContactsTab", "tabs"),
        Definition("hideSearchButton", "tabs"), Definition("hideTabTitles", "tabs"),
        Definition("compactTabBar", "tabs"),
        Definition("streaks", "features"), Definition("siriShortcuts", "features"),
        Definition("cacheAutoClean", "storage"), Definition("cacheCleanInterval", "storage", "number", minimum: 1, maximum: 720),
        Definition("performanceStatsEnabled", "performance"), Definition("performanceShowUptime", "performance"),
        Definition("performanceShowRAM", "performance"), Definition("performanceShowCPU", "performance"),
        Definition("performanceShowFPS", "performance"), Definition("performanceShowBattery", "performance"),
        Definition("performanceShowNetwork", "performance"), Definition("performanceShowDisk", "performance"),
        Definition("performanceShowThermal", "performance"), Definition("performanceShowGraph", "performance"),
        Definition("ramAutoClean", "performance"), Definition("ramCleanInterval", "performance", "number", minimum: 10, maximum: 3600),
    ]

    static func snapshot() -> [[String: Any]] {
        let manager = AorusGramManager.shared
        return definitions.compactMap { definition in
            guard let value = value(for: definition.id, manager: manager) else { return nil }
            var result: [String: Any] = [
                "id": definition.id,
                "category": definition.category,
                "type": definition.type,
                "value": value,
                "requiresRestart": false,
            ]
            if let minimum = definition.minimum { result["min"] = minimum }
            if let maximum = definition.maximum { result["max"] = maximum }
            if definition.id == "videoMaskPreset" {
                let custom = AorusCustomMaskStore.records(isRussian: false).map(\.presetKey)
                result["options"] = (definition.options ?? []) + custom
            } else if let options = definition.options {
                result["options"] = options
            }
            return result
        }
    }

    static func set(_ id: String, value: Any) -> Result<[String: Any], Error> {
        guard definitions.contains(where: { $0.id == id }) else {
            return .failure(AorusPluginRequestError("Unknown app feature"))
        }
        let manager = AorusGramManager.shared
        let bool = strictBool(value)
        switch id {
        case "ghostMode": guard let bool else { return typeError() }; manager.ghostMode = bool
        case "blockReadReceipts": guard let bool else { return typeError() }; manager.blockReadReceipts = bool
        case "hideTyping": guard let bool else { return typeError() }; manager.hideTyping = bool
        case "antiScreenshot": guard let bool else { return typeError() }; manager.antiScreenshot = bool
        case "saveDeletedMessages": guard let bool else { return typeError() }; manager.saveDeletedMessages = bool
        case "saveEditedMessages": guard let bool else { return typeError() }; manager.saveEditedMessages = bool
        case "antiSpamEnabled": guard let bool else { return typeError() }; manager.antiSpamEnabled = bool
        case "translator": guard let bool else { return typeError() }; manager.translator = bool
        case "shareButton": guard let bool else { return typeError() }; manager.shareButton = bool
        case "autoReply": guard let bool else { return typeError() }; manager.autoReply = bool
        case "editLocally": guard let bool else { return typeError() }; manager.editLocally = bool
        case "userMessagesInGroup": guard let bool else { return typeError() }; manager.userMessagesInGroup = bool
        case "messageSeconds": guard let bool else { return typeError() }; manager.messageSeconds = bool
        case "doubleTapCopy": guard let bool else { return typeError() }; manager.doubleTapCopy = bool
        case "tripleTapDelete": guard let bool else { return typeError() }; manager.tripleTapDelete = bool
        case "wallEnabled": guard let bool else { return typeError() }; manager.wallEnabled = bool
        case "maxMediaQuality": guard let bool else { return typeError() }; manager.maxMediaQuality = bool
        case "downloadAccel": guard let bool else { return typeError() }; manager.downloadAccel = bool
        case "voiceTranscription": guard let bool else { return typeError() }; manager.voiceTranscription = bool
        case "videoMessagesRearCamera": guard let bool else { return typeError() }; manager.videoMessagesRearCamera = bool
        case "deviceMicrophone": guard let bool else { return typeError() }; manager.deviceMicrophone = bool
        case "voiceTwinEnabled": guard let bool else { return typeError() }; manager.voiceTwinEnabled = bool
        case "videoMasksEnabled": guard let bool else { return typeError() }; manager.videoMasksEnabled = bool
        case "callRecording": guard let bool else { return typeError() }; manager.callRecording = bool
        case "glassUI": guard let bool else { return typeError() }; manager.glassUI = bool
        case "amoledMode": guard let bool else { return typeError() }; manager.amoledMode = bool
        case "profileReportButton": guard let bool else { return typeError() }; manager.profileReportButton = bool
        case "squareAvatars": guard let bool else { return typeError() }; manager.squareAvatars = bool
        case "hideCallsTab": guard let bool else { return typeError() }; manager.hideCallsTab = bool
        case "hideContactsTab": guard let bool else { return typeError() }; manager.hideContactsTab = bool
        case "hideSearchButton": guard let bool else { return typeError() }; manager.hideSearchButton = bool
        case "hideTabTitles": guard let bool else { return typeError() }; manager.hideTabTitles = bool
        case "compactTabBar": guard let bool else { return typeError() }; manager.compactTabBar = bool
        case "streaks": guard let bool else { return typeError() }; manager.streaks = bool
        case "siriShortcuts": guard let bool else { return typeError() }; manager.siriShortcuts = bool
        case "cacheAutoClean": guard let bool else { return typeError() }; manager.cacheAutoClean = bool
        case "performanceStatsEnabled": guard let bool else { return typeError() }; manager.performanceStatsEnabled = bool
        case "performanceShowUptime": guard let bool else { return typeError() }; manager.performanceShowUptime = bool
        case "performanceShowRAM": guard let bool else { return typeError() }; manager.performanceShowRAM = bool
        case "performanceShowCPU": guard let bool else { return typeError() }; manager.performanceShowCPU = bool
        case "performanceShowFPS": guard let bool else { return typeError() }; manager.performanceShowFPS = bool
        case "performanceShowBattery": guard let bool else { return typeError() }; manager.performanceShowBattery = bool
        case "performanceShowNetwork": guard let bool else { return typeError() }; manager.performanceShowNetwork = bool
        case "performanceShowDisk": guard let bool else { return typeError() }; manager.performanceShowDisk = bool
        case "performanceShowThermal": guard let bool else { return typeError() }; manager.performanceShowThermal = bool
        case "performanceShowGraph": guard let bool else { return typeError() }; manager.performanceShowGraph = bool
        case "ramAutoClean": guard let bool else { return typeError() }; manager.ramAutoClean = bool
        case "cacheCleanInterval":
            guard let number = strictInt(value), (1...720).contains(number) else { return typeError() }
            manager.cacheCleanInterval = number
        case "ramCleanInterval":
            guard let number = strictInt(value), (10...3600).contains(number) else { return typeError() }
            manager.ramCleanInterval = number
        case "voiceTwinPreset":
            guard let text = value as? String, ["anonymous", "male", "female", "robot", "child"].contains(text) else { return typeError() }
            manager.voiceTwinPreset = text
        case "videoMaskPreset":
            let allowed = ["skull", "cyber", "oni", "phantom", "chrome", "aurora", "neonCat"] + AorusCustomMaskStore.records(isRussian: false).map(\.presetKey)
            guard let text = value as? String, allowed.contains(text) else { return typeError() }
            manager.videoMaskPreset = text
        default:
            return .failure(AorusPluginRequestError("Unknown app feature"))
        }
        if id == "wallEnabled", let enabled = self.value(for: id, manager: manager) as? Bool {
            NotificationCenter.default.post(
                name: Notification.Name("aorusgram_wall_visibility_changed"),
                object: NSNumber(value: enabled)
            )
        }
        guard let result = snapshot().first(where: { ($0["id"] as? String) == id }) else {
            return .failure(AorusPluginRequestError("App feature is unavailable"))
        }
        return .success(result)
    }

    private static func value(for id: String, manager: AorusGramManager) -> Any? {
        switch id {
        case "ghostMode": return manager.ghostMode
        case "blockReadReceipts": return manager.blockReadReceipts
        case "hideTyping": return manager.hideTyping
        case "antiScreenshot": return manager.antiScreenshot
        case "saveDeletedMessages": return manager.saveDeletedMessages
        case "saveEditedMessages": return manager.saveEditedMessages
        case "antiSpamEnabled": return manager.antiSpamEnabled
        case "translator": return manager.translator
        case "shareButton": return manager.shareButton
        case "autoReply": return manager.autoReply
        case "editLocally": return manager.editLocally
        case "userMessagesInGroup": return manager.userMessagesInGroup
        case "messageSeconds": return manager.messageSeconds
        case "doubleTapCopy": return manager.doubleTapCopy
        case "tripleTapDelete": return manager.tripleTapDelete
        case "wallEnabled": return manager.wallEnabled
        case "maxMediaQuality": return manager.maxMediaQuality
        case "downloadAccel": return manager.downloadAccel
        case "voiceTranscription": return manager.voiceTranscription
        case "videoMessagesRearCamera": return manager.videoMessagesRearCamera
        case "deviceMicrophone": return manager.deviceMicrophone
        case "voiceTwinEnabled": return manager.voiceTwinEnabled
        case "voiceTwinPreset": return manager.voiceTwinPreset
        case "videoMasksEnabled": return manager.videoMasksEnabled
        case "videoMaskPreset": return manager.videoMaskPreset
        case "callRecording": return manager.callRecording
        case "glassUI": return manager.glassUI
        case "amoledMode": return manager.amoledMode
        case "profileReportButton": return manager.profileReportButton
        case "squareAvatars": return manager.squareAvatars
        case "hideCallsTab": return manager.hideCallsTab
        case "hideContactsTab": return manager.hideContactsTab
        case "hideSearchButton": return manager.hideSearchButton
        case "hideTabTitles": return manager.hideTabTitles
        case "compactTabBar": return manager.compactTabBar
        case "streaks": return manager.streaks
        case "siriShortcuts": return manager.siriShortcuts
        case "cacheAutoClean": return manager.cacheAutoClean
        case "cacheCleanInterval": return manager.cacheCleanInterval
        case "performanceStatsEnabled": return manager.performanceStatsEnabled
        case "performanceShowUptime": return manager.performanceShowUptime
        case "performanceShowRAM": return manager.performanceShowRAM
        case "performanceShowCPU": return manager.performanceShowCPU
        case "performanceShowFPS": return manager.performanceShowFPS
        case "performanceShowBattery": return manager.performanceShowBattery
        case "performanceShowNetwork": return manager.performanceShowNetwork
        case "performanceShowDisk": return manager.performanceShowDisk
        case "performanceShowThermal": return manager.performanceShowThermal
        case "performanceShowGraph": return manager.performanceShowGraph
        case "ramAutoClean": return manager.ramAutoClean
        case "ramCleanInterval": return manager.ramCleanInterval
        default: return nil
        }
    }

    private static func strictBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func strictInt(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    private static func typeError() -> Result<[String: Any], Error> {
        return .failure(AorusPluginRequestError("Invalid value for app feature"))
    }
}

private enum AorusPluginProxyBroker {
    static func snapshot() -> [String: Any] {
        let preferences = AorusConnectionPreferences.shared
        var result: [String: Any] = [
            "enabled": preferences.bypassEnabled,
            "stableCalls": preferences.stableCallsEnabled,
            "connected": false,
            "servers": [],
        ]
        guard let text = UserDefaults.standard.string(forKey: "aorusgram_atunnel_status"),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any] else { return result }
        if let connected = raw["callTunnel"] as? NSNumber,
           CFGetTypeID(connected) == CFBooleanGetTypeID() {
            result["connected"] = connected.boolValue
        }
        if let updatedAt = raw["updatedAt"] as? NSNumber { result["updatedAt"] = updatedAt }
        if let servers = raw["servers"] as? [[String: Any]] {
            result["servers"] = servers.prefix(32).map { server -> [String: Any] in
                var safe: [String: Any] = [:]
                for key in ["id", "country", "region", "routeType", "via", "available", "active", "latencyMs", "jitterMs", "lossCount", "measuredAt"] {
                    if let value = server[key] { safe[key] = value }
                }
                return safe
            }
        }
        return result
    }
}

/// The selected message is provided only when the native menu represents one message.
/// Formatting a plugin described, in Telegram's own terms.
///
/// The offsets arrive in UTF-16 code units, already checked against the text, which is what
/// `MessageTextEntity` counts in too — so the ranges carry over directly. A custom emoji
/// with no sticker pack reference is exactly what Telegram builds for an emoji sent by id.
private func aorusPluginMessageEntities(_ entities: [AorusPluginTextEntity]) -> [MessageTextEntity] {
    return entities.compactMap { entity in
        let range = entity.offset ..< (entity.offset + entity.length)
        switch entity.kind {
        case .bold:
            return MessageTextEntity(range: range, type: .Bold)
        case .italic:
            return MessageTextEntity(range: range, type: .Italic)
        case .underline:
            return MessageTextEntity(range: range, type: .Underline)
        case .strikethrough:
            return MessageTextEntity(range: range, type: .Strikethrough)
        case .spoiler:
            return MessageTextEntity(range: range, type: .Spoiler)
        case .code:
            return MessageTextEntity(range: range, type: .Code)
        case .pre:
            return MessageTextEntity(range: range, type: .Pre(language: entity.language))
        case .blockquote:
            return MessageTextEntity(range: range, type: .BlockQuote(isCollapsed: entity.collapsed))
        case .textLink:
            guard let url = entity.url else { return nil }
            return MessageTextEntity(range: range, type: .TextUrl(url: url))
        case .customEmoji:
            guard let fileId = entity.customEmojiId else { return nil }
            return MessageTextEntity(range: range, type: .CustomEmoji(stickerPack: nil, fileId: fileId))
        }
    }
}

/// A shortcut a plugin registered, ready to be drawn as a row in Telegram's own settings
/// list. The row is built by the settings screen, which lives in another module and cannot
/// see anything of ours, so everything it needs — including the rendered icon — comes
/// across as plain data and one closure.
public struct AorusPluginSettingsEntry {
    public let title: String
    public let subtitle: String
    public let image: UIImage?
    public let open: () -> Void
}

/// Every shortcut every running plugin has registered, in a stable order.
public func aorusPluginSettingsEntries() -> [AorusPluginSettingsEntry] {
    return AorusPluginRuntimeManager.shared.pluginSettingsShortcuts().map { item in
        let manifest = AorusPluginStore.shared.manifest(id: item.pluginId)
        let accent = aorusPluginEntryColor(manifest?.accent ?? AorusPluginAccent.fallback)
        let symbol = item.shortcut.icon ?? manifest?.icon ?? AorusPluginIcon.fallback
        return AorusPluginSettingsEntry(
            title: item.shortcut.title,
            subtitle: item.shortcut.subtitle ?? "",
            image: aorusPluginSettingsRowIcon(symbol, color: accent),
            open: {
                AorusPluginRuntimeManager.shared.performSettingsShortcut(pluginId: item.pluginId, id: item.shortcut.id)
            }
        )
    }
}

/// The 30pt rounded tile Telegram draws next to every settings row, with the plugin's own
/// glyph and colour. Built here so the settings screen only has to place it.
private func aorusPluginSettingsRowIcon(_ symbol: String, color: UIColor) -> UIImage? {
    let side = CGSize(width: 30.0, height: 30.0)
    let configuration = UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium)
    let glyph = UIImage(systemName: AorusPluginIcon.normalized(symbol), withConfiguration: configuration)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    return UIGraphicsImageRenderer(size: side, format: format).image { context in
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: side), cornerRadius: 8.0).addClip()
        context.cgContext.setFillColor(color.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: side))
        guard let glyph else { return }
        let size = glyph.size
        let origin = CGPoint(x: (side.width - size.width) / 2.0, y: (side.height - size.height) / 2.0)
        glyph.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: origin, size: size))
    }
}

private func aorusPluginEntryColor(_ hex: String) -> UIColor {
    guard let value = UInt32(AorusPluginAccent.normalized(hex), radix: 16) else { return .systemPurple }
    return UIColor(
        red: CGFloat((value >> 16) & 0xff) / 255.0,
        green: CGFloat((value >> 8) & 0xff) / 255.0,
        blue: CGFloat(value & 0xff) / 255.0,
        alpha: 1.0
    )
}

public func aorusPluginMessageContextMenuItems(message: EngineRawMessage?) -> [ContextMenuItem] {
    var payload: [String: Any] = ["source": "message"]
    if let message {
        payload["peerId"] = String(message.id.peerId.toInt64())
        payload["namespace"] = message.id.namespace
        payload["messageId"] = message.id.id
        payload["text"] = message.text
    }
    return AorusPluginRuntimeManager.shared.pluginContextActions().map { entry in
        .action(ContextMenuActionItem(text: entry.action.title, icon: { theme in
            aorusPluginMenuIcon(entry.action.icon ?? AorusPluginIcon.fallback, color: theme.contextMenu.primaryColor)
        }, action: { _, complete in
            AorusPluginRuntimeManager.shared.dispatchContextAction(pluginId: entry.pluginId, actionId: entry.action.id, payload: payload)
            complete(.default)
        }))
    }
}

/// An SF Symbol, tinted, as a bitmap the context menu can draw.
///
/// A symbol image carries no `cgImage` — it is drawn from a vector description — so the two
/// obvious approaches both fail here. `withTintColor` keeps the colour as an attribute that
/// only `UIImageView` applies, and the context menu draws the image itself, so the glyph
/// came out black. Telegram's own `generateTintedImage` masks with `image.cgImage!`, which
/// for a symbol is nil and would trap. The symbol is rasterised first, which gives it a
/// `cgImage`, and that raster is then tinted the same way every other item in the menu is.
private func aorusPluginMenuIcon(_ name: String, color: UIColor) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .regular)
    guard let symbol = UIImage(systemName: AorusPluginIcon.normalized(name), withConfiguration: configuration) else {
        return nil
    }
    let size = CGSize(width: max(1.0, symbol.size.width), height: max(1.0, symbol.size.height))
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let raster = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        symbol.withRenderingMode(.alwaysTemplate).draw(in: CGRect(origin: .zero, size: size))
    }
    return generateTintedImage(image: raster, color: color)
}

private final class AorusPluginArtifactPreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let fileURL: URL

    init(url: URL) {
        self.fileURL = url
        super.init(nibName: nil, bundle: nil)
        self.dataSource = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { fileURL as NSURL }
}
