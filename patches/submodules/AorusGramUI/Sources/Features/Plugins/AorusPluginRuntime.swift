import Foundation
import UIKit
import Postbox
import TelegramCore
import AccountContext
import SwiftSignalKit
import Display
import AorusGram

public final class AorusPluginRuntimeManager {
    public static let shared = AorusPluginRuntimeManager()

    private let lock = NSLock()
    private var context: AccountContext?
    private var host: AorusPluginTelegramHost?
    private var sandboxes: [String: AorusPluginSandbox] = [:]
    private var schemas: [String: [AorusPluginSettingField]] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {}

    public func configure(context: AccountContext) {
        lock.lock()
        let unchanged = self.context === context
        let previous = unchanged ? [] : Array(sandboxes.values)
        if !unchanged {
            sandboxes.removeAll()
            schemas.removeAll()
            self.context = context
            self.host = AorusPluginTelegramHost(context: context, manager: self)
        }
        lock.unlock()
        guard !unchanged else { return }
        previous.forEach { $0.stop() }
        installObservers()
        reloadAutostart()
    }

    public func reloadAutostart() {
        guard let host = currentHost() else { return }
        let records = AorusPluginStore.shared.list().compactMap { AorusPluginStore.shared.load(id: $0.id) }
        let desired = records.filter { $0.manifest.isEnabled && $0.manifest.autostart }
        let desiredIds = Set(desired.map { $0.manifest.id })

        lock.lock()
        let stale = sandboxes.filter { !desiredIds.contains($0.key) }.map { $0.value }
        for sandbox in stale { sandboxes[sandbox.manifest.id] = nil }
        lock.unlock()
        stale.forEach { $0.stop() }

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
        guard let host = currentHost(), let record = AorusPluginStore.shared.load(id: id) else {
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
        lock.unlock()
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
        lock.lock(); defer { lock.unlock() }
        return schemas[id] ?? []
    }

    public func processOutgoing(text: String, peerId: Int64, accountId: Int64) -> AorusPluginOutgoingVerdict {
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

    fileprivate func setSchema(_ fields: [AorusPluginSettingField], id: String) {
        lock.lock(); schemas[id] = fields; lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("aorusgram.plugins.schemaChanged"), object: id)
        }
    }

    private func currentHost() -> AorusPluginTelegramHost? {
        lock.lock(); defer { lock.unlock() }
        return host
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
        lock.unlock()
        previous?.stop()
        sandbox.start { [weak self, weak sandbox] error in
            if error != nil {
                self?.lock.lock()
                if self?.sandboxes[record.manifest.id] === sandbox { self?.sandboxes[record.manifest.id] = nil }
                self?.lock.unlock()
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

    init(context: AccountContext, manager: AorusPluginRuntimeManager) {
        self.context = context
        self.manager = manager
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
            answer(peer.map { ["id": String($0.id.toInt64()), "title": $0.compactDisplayTitle] })
        }, completed: {
            answer(nil)
        })
    }

    func pluginChatInfo(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<[String: Any]?, Error>) -> Void) {
        let id: PeerId?
        if toSelf { id = context.account.peerId } else if let peerId { id = PeerId(peerId) } else { id = nil }
        guard let id else { completion(.failure(AorusPluginRequestError("peerId is required"))); return }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: id)) |> take(1)).start(next: { peer in
            completion(.success(peer.map { ["id": String($0.id.toInt64()), "title": $0.compactDisplayTitle] }))
        })
    }

    func pluginOpenChat(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let id: PeerId?
        if toSelf { id = context.account.peerId } else if let peerId { id = PeerId(peerId) } else { id = nil }
        guard let id else { completion(.failure(AorusPluginRequestError("peerId is required"))); return }
        DispatchQueue.main.async {
            guard let navigation = self.topController()?.navigationController as? NavigationController else {
                completion(.failure(AorusPluginRequestError("Navigation is unavailable")))
                return
            }
            self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: self.context, chatLocation: .peer(id)))
            completion(.success(()))
        }
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
