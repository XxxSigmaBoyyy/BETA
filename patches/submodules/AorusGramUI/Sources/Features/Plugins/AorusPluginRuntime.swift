import Foundation
import UIKit
import Postbox
import TelegramCore
import AccountContext
import SwiftSignalKit
import Display
import ContextUI
import QuickLook
import AorusGram

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
        guard AorusLicenseAccess.isAllowed else {
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
            guard state.sourceDigest == digest, requested.isSubset(of: state.granted) else { continue }
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
        guard AorusLicenseAccess.isAllowed else { return .passThrough }
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

    public func dispatchUIAction(pluginId: String, pageId: String, rowId: String, value: AorusPluginJSONValue?) {
        lock.lock(); let sandbox = sandboxes[pluginId]; lock.unlock()
        var payload: [String: Any] = ["pageId": pageId, "rowId": rowId]
        if let value { payload["value"] = value.anyValue }
        sandbox?.dispatch(event: "uiAction", payload: payload)
    }

    public func dispatchContextAction(pluginId: String, actionId: String, payload: [String: Any]) {
        lock.lock(); let sandbox = sandboxes[pluginId]; lock.unlock()
        var value = payload
        value["actionId"] = actionId
        sandbox?.dispatch(event: "contextAction", payload: value)
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
        guard AorusLicenseAccess.isAllowed,
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
        guard AorusLicenseAccess.isAllowed else {
            completion?(.notRunning)
            return
        }
        let sandbox = AorusPluginSandbox(
            manifest: record.manifest,
            source: record.source,
            host: host,
            permissions: permissions,
            storage: AorusPluginStore.shared.storage(for: record.manifest.id),
            settings: AorusPluginStore.shared.settings(for: record.manifest.id),
            settingsSchema: settingsSchema(id: record.manifest.id)
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
        observers.append(center.addObserver(forName: NSNotification.Name("aorusgram.licenseLockChanged"), object: nil, queue: nil) { [weak self] _ in
            self?.reloadAutostart()
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
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.dispatch(event: "foreground", payload: [:])
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.dispatch(event: "background", payload: [:])
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

    var pluginExecutionAllowed: Bool { AorusLicenseAccess.isAllowed }

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
        try? AorusPluginStore.shared.setStorage(values, for: pluginId)
    }

    func pluginSettingsSchemaChanged(_ pluginId: String, fields: [AorusPluginSettingField]) {
        manager?.setSchema(Array(fields.prefix(64)), id: pluginId)
    }

    func pluginSettingsChanged(_ pluginId: String, values: [String: AorusPluginJSONValue]) {
        try? AorusPluginStore.shared.setSettings(values, for: pluginId)
        manager?.publishSettingsChanged(pluginId)
    }

    func pluginPagesChanged(_ pluginId: String, pages: [AorusPluginUIPage]) {
        manager?.setPages(pages, id: pluginId)
    }

    func pluginSettingsShortcutsChanged(_ pluginId: String, shortcuts: [AorusPluginSettingsShortcut]) {
        manager?.setSettingsShortcuts(shortcuts, id: pluginId)
    }

    func pluginContextActionsChanged(_ pluginId: String, actions: [AorusPluginContextAction]) {
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
            if style == "push" {
                guard let navigation = presenter.navigationController as? NavigationController else {
                    completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                    return
                }
                navigation.pushViewController(controller)
            } else {
                controller.installModalCloseButton()
                let navigation = UINavigationController(rootViewController: controller)
                navigation.modalPresentationStyle = style == "fullScreen" ? .fullScreen : .pageSheet
                presenter.present(navigation, animated: true)
            }
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

    func pluginAIAsk(_ pluginId: String, prompt: String, history: [[String: String]], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard AorusLicenseAccess.isAllowed,
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
        let payload = AorusAIAgentPayload(messages: messages)
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
                self.aiLock.lock()
                let active = self.aiReservations.contains(pluginId) || self.aiStreams[pluginId] != nil
                if active { self.aiTurnIds[pluginId] = turnId }
                self.aiLock.unlock()
                if !active { AorusAIClient.shared.cancelTurn(turnId) { _ in } }
            case let .responseDelta(delta):
                let room = max(0, AorusAIRequestLimits.responseCharacters - text.count)
                if room > 0 { text.append(room >= delta.count ? delta : String(delta.prefix(room))) }
            case let .completion(value, ready):
                if let value, !value.isEmpty { text = String(value.prefix(AorusAIRequestLimits.responseCharacters)) }
                for artifact in ready where !artifacts.contains(where: { $0.artifactId == artifact.artifactId }) {
                    if artifacts.count < AorusAIRequestLimits.responseArtifactCount { artifacts.append(artifact) }
                }
            case let .artifactReady(artifact):
                if artifacts.count < AorusAIRequestLimits.responseArtifactCount,
                   !artifacts.contains(where: { $0.artifactId == artifact.artifactId }) { artifacts.append(artifact) }
            case .toolRequest, .permissionRequest:
                stateLock.unlock()
                self.cancelAIStream(pluginId)
                finish(.failure(AorusPluginRequestError("This AorusAI request needs an interaction in the full AorusAI chat")))
                return
            case let .done(ok, _):
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
        guard AorusLicenseAccess.isAllowed,
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

    func pluginSendMessage(_ pluginId: String, peerId: Int64?, toSelf: Bool, accountId: Int64?, text: String, replyTo: Int32?, completion: @escaping (Result<Void, Error>) -> Void) {
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
        let signal = enqueueMessages(account: context.account, peerId: target, messages: [
            .message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        ])
        let _ = signal.start(completed: { completion(.success(())) })
    }

    func pluginResolveChat(_ pluginId: String, username: String, completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
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
        let id: PeerId?
        if toSelf { id = context.account.peerId } else if let peerId { id = PeerId(peerId) } else { id = nil }
        guard let id else { completion(.failure(AorusPluginRequestError("peerId is required"))); return }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id)) |> take(1)).start(next: { peer in
            completion(.success(peer.map(self.pluginPeerDictionary)))
        })
    }

    func pluginOpenChat(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
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

    func pluginCurrentAccount(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)) |> take(1)).start(next: { peer in
            completion(.success(["id": String(self.context.account.peerId.toInt64()), "title": peer?.compactDisplayTitle ?? ""]))
        })
    }

    func pluginShowToast(_ pluginId: String, text: String, duration: Double?) {
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
        DispatchQueue.main.async { self.presentAlert(title: title, text: text, actions: [("OK", .default, completion)]) }
    }

    func pluginConfirm(_ pluginId: String, title: String, text: String?, ok: String?, cancel: String?, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.presentAlert(title: title, text: text, actions: [
                (cancel ?? "Cancel", .cancel, { completion(false) }),
                (ok ?? "OK", .default, { completion(true) })
            ])
        }
    }

    func pluginPrompt(_ pluginId: String, title: String, text: String?, placeholder: String?, defaultValue: String?, ok: String?, cancel: String?, completion: @escaping (String?) -> Void) {
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
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: kind == "heavy" ? .heavy : .light).impactOccurred() }
    }

    func pluginClipboardRead(_ pluginId: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { completion(UIPasteboard.general.string) }
    }

    func pluginClipboardWrite(_ pluginId: String, text: String) {
        DispatchQueue.main.async { UIPasteboard.general.string = text }
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
        while let presented = controller?.presentedViewController { controller = presented }
        if let navigation = controller as? UINavigationController { return navigation.topViewController }
        return controller
    }

    private func presentAlert(title: String?, text: String?, actions: [(String, UIAlertAction.Style, () -> Void)]) {
        guard let presenter = topController() else { actions.last?.2(); return }
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        for action in actions { alert.addAction(UIAlertAction(title: action.0, style: action.1) { _ in action.2() }) }
        presenter.present(alert, animated: true)
    }
}

/// Native message-menu contributions from running plugins. Selecting one reports only the
/// plugin-owned action id. Message contents and Telegram identifiers are not implicitly
/// disclosed by a UI integration; a plugin that needs message events must request that
/// separate permission explicitly.
public func aorusPluginMessageContextMenuItems() -> [ContextMenuItem] {
    return AorusPluginRuntimeManager.shared.pluginContextActions().map { entry in
        .action(ContextMenuActionItem(text: entry.action.title, icon: { theme in
            UIImage(systemName: AorusPluginIcon.normalized(entry.action.icon ?? AorusPluginIcon.fallback))?.withTintColor(theme.actionSheet.primaryTextColor, renderingMode: .alwaysOriginal)
        }, action: { _, complete in
            complete(.default)
            AorusPluginRuntimeManager.shared.dispatchContextAction(pluginId: entry.pluginId, actionId: entry.action.id, payload: ["source": "message"])
        }))
    }
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
