import Foundation
import JavaScriptCore
import CryptoKit
import Darwin

// One running plugin. Each plugin gets its own JavaScriptCore virtual machine, its own
// context and its own serial queue: nothing a plugin does can reach another plugin's
// objects, a plugin that leaks memory leaks its own heap, and every line of JavaScript a
// plugin owns runs on one thread the plugin never shares.
//
// The sandbox installs exactly one object into the context, `__aorusHost`, whose members are
// the Swift blocks below. The prelude (AorusPluginPrelude) wraps them in the public API and
// removes the object again, so what the blocks accept is the complete list of what a plugin
// can ask the app to do. Everything that needs Telegram goes out through
// `AorusPluginHostServices`; the UI module implements that and is the only place plugin
// requests meet account data. This file knows nothing about accounts, settings of the app,
// or the licence, and must stay that way.

/// What the sandbox asks the app for. Every call names the plugin so the implementation can
/// attribute it, and every asynchronous one completes exactly once.
public protocol AorusPluginHostServices: AnyObject {
    var pluginExecutionAllowed: Bool { get }
    func pluginLog(_ pluginId: String, level: AorusPluginLogEntry.Level, text: String)
    func pluginStorageChanged(_ pluginId: String, values: [String: AorusPluginJSONValue])
    func pluginSettingsSchemaChanged(_ pluginId: String, fields: [AorusPluginSettingField])
    func pluginSettingsChanged(_ pluginId: String, values: [String: AorusPluginJSONValue])
    func pluginSendMessage(_ pluginId: String, peerId: Int64?, toSelf: Bool, accountId: Int64?, text: String, replyTo: Int32?, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginEditMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, text: String, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginDeleteMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, forEveryone: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginForwardMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, toPeerId: Int64, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginReactToMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, reaction: String?, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginResolveChat(_ pluginId: String, username: String, completion: @escaping (Result<[String: Any]?, Error>) -> Void)
    func pluginChatInfo(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<[String: Any]?, Error>) -> Void)
    func pluginChatHistory(_ pluginId: String, peerId: Int64?, toSelf: Bool, limit: Int, completion: @escaping (Result<[[String: Any]], Error>) -> Void)
    func pluginOpenChat(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginCurrentAccount(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginAccounts(_ pluginId: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void)
    func pluginSwitchAccount(_ pluginId: String, accountId: Int64, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginShowToast(_ pluginId: String, text: String, duration: Double?)
    func pluginAlert(_ pluginId: String, title: String, text: String?, completion: @escaping () -> Void)
    func pluginConfirm(_ pluginId: String, title: String, text: String?, ok: String?, cancel: String?, completion: @escaping (Bool) -> Void)
    func pluginPrompt(_ pluginId: String, title: String, text: String?, placeholder: String?, defaultValue: String?, ok: String?, cancel: String?, completion: @escaping (String?) -> Void)
    func pluginShare(_ pluginId: String, text: String?, url: String?, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginPagesChanged(_ pluginId: String, pages: [AorusPluginUIPage])
    func pluginSettingsShortcutsChanged(_ pluginId: String, shortcuts: [AorusPluginSettingsShortcut])
    func pluginContextActionsChanged(_ pluginId: String, actions: [AorusPluginContextAction])
    func pluginOpenPage(_ pluginId: String, pageId: String, style: String, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginOpenURL(_ pluginId: String, url: String, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginOpenTelegramLink(_ pluginId: String, url: String, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginAIAsk(_ pluginId: String, prompt: String, history: [[String: String]], completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginAIOpenArtifact(_ pluginId: String, artifactId: String, completion: @escaping (Result<Void, Error>) -> Void)
    func pluginAppFeatures(_ pluginId: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void)
    func pluginSetAppFeature(_ pluginId: String, featureId: String, value: Any, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginProxyStatus(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginSetProxyPreference(_ pluginId: String, key: String, value: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginRefreshProxy(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginTelegramProxyStatus(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginSetTelegramProxyEnabled(_ pluginId: String, enabled: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginSetTelegramProxyUseForCalls(_ pluginId: String, enabled: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginAddTelegramProxy(_ pluginId: String, type: String, host: String, port: Int32, username: String?, password: String?, secret: String?, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginRemoveTelegramProxy(_ pluginId: String, index: Int, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginSelectTelegramProxy(_ pluginId: String, index: Int?, completion: @escaping (Result<[String: Any], Error>) -> Void)
    func pluginHaptic(_ pluginId: String, kind: String)
    func pluginClipboardRead(_ pluginId: String, completion: @escaping (String?) -> Void)
    func pluginClipboardWrite(_ pluginId: String, text: String)
    var pluginDeviceInfo: [String: Any] { get }
    var pluginInterfaceLanguage: String { get }
}

/// A host that does nothing: what the tests and the editor's dry run use. Sending a message
/// or opening a chat "succeeds" without effect, dialogs answer as if dismissed, the log goes
/// to `onLog`.
open class AorusPluginNullHost: AorusPluginHostServices {
    public var onLog: ((String, AorusPluginLogEntry.Level, String) -> Void)?
    public var onStorageChanged: ((String, [String: AorusPluginJSONValue]) -> Void)?
    public var onSettingsSchemaChanged: ((String, [AorusPluginSettingField]) -> Void)?
    public var onSettingsChanged: ((String, [String: AorusPluginJSONValue]) -> Void)?
    public var onSendMessage: ((String, Int64?, Bool, Int64?, String, Int32?) -> Void)?
    public var onMessageAction: ((String, String, Int64, Int32, Int32) -> Void)?
    public var onToast: ((String, String) -> Void)?
    public var onShare: ((String, String?, String?) -> Void)?
    public var onPagesChanged: ((String, [AorusPluginUIPage]) -> Void)?
    public var onSettingsShortcutsChanged: ((String, [AorusPluginSettingsShortcut]) -> Void)?
    public var onContextActionsChanged: ((String, [AorusPluginContextAction]) -> Void)?
    public var onOpenPage: ((String, String, String) -> Void)?
    public var onOpenURL: ((String, String) -> Void)?
    public var onOpenTelegramLink: ((String, String) -> Void)?
    public var onChatHistory: ((String, Int64?, Bool, Int) -> [[String: Any]])?
    public var onAIAsk: ((String, String, [[String: String]]) -> [String: Any])?
    public var onAIOpenArtifact: ((String, String) -> Void)?
    public var onAppFeatures: ((String) -> [[String: Any]])?
    public var onSetAppFeature: ((String, String, Any) -> [String: Any])?
    public var onProxyStatus: ((String) -> [String: Any])?
    public var onSetProxyPreference: ((String, String, Bool) -> [String: Any])?
    public var onRefreshProxy: ((String) -> [String: Any])?
    public var onAccounts: ((String) -> [[String: Any]])?
    public var onSwitchAccount: ((String, Int64) -> Void)?
    public var onTelegramProxyStatus: ((String) -> [String: Any])?
    public var language = "en"

    public init() {}

    open var pluginExecutionAllowed: Bool { true }

    open func pluginLog(_ pluginId: String, level: AorusPluginLogEntry.Level, text: String) { onLog?(pluginId, level, text) }
    open func pluginStorageChanged(_ pluginId: String, values: [String: AorusPluginJSONValue]) { onStorageChanged?(pluginId, values) }
    open func pluginSettingsSchemaChanged(_ pluginId: String, fields: [AorusPluginSettingField]) { onSettingsSchemaChanged?(pluginId, fields) }
    open func pluginSettingsChanged(_ pluginId: String, values: [String: AorusPluginJSONValue]) { onSettingsChanged?(pluginId, values) }
    open func pluginSendMessage(_ pluginId: String, peerId: Int64?, toSelf: Bool, accountId: Int64?, text: String, replyTo: Int32?, completion: @escaping (Result<Void, Error>) -> Void) {
        onSendMessage?(pluginId, peerId, toSelf, accountId, text, replyTo)
        completion(.success(()))
    }
    open func pluginEditMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, text: String, completion: @escaping (Result<Void, Error>) -> Void) { onMessageAction?(pluginId, "edit", peerId, namespace, messageId); completion(.success(())) }
    open func pluginDeleteMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, forEveryone: Bool, completion: @escaping (Result<Void, Error>) -> Void) { onMessageAction?(pluginId, "delete", peerId, namespace, messageId); completion(.success(())) }
    open func pluginForwardMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, toPeerId: Int64, completion: @escaping (Result<Void, Error>) -> Void) { onMessageAction?(pluginId, "forward", peerId, namespace, messageId); completion(.success(())) }
    open func pluginReactToMessage(_ pluginId: String, peerId: Int64, namespace: Int32, messageId: Int32, reaction: String?, completion: @escaping (Result<Void, Error>) -> Void) { onMessageAction?(pluginId, "react", peerId, namespace, messageId); completion(.success(())) }
    open func pluginResolveChat(_ pluginId: String, username: String, completion: @escaping (Result<[String: Any]?, Error>) -> Void) { completion(.success(nil)) }
    open func pluginChatInfo(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<[String: Any]?, Error>) -> Void) { completion(.success(nil)) }
    open func pluginChatHistory(_ pluginId: String, peerId: Int64?, toSelf: Bool, limit: Int, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        completion(.success(onChatHistory?(pluginId, peerId, toSelf, limit) ?? []))
    }
    open func pluginOpenChat(_ pluginId: String, peerId: Int64?, toSelf: Bool, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    open func pluginCurrentAccount(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        completion(.success(["id": NSNumber(value: 0), "firstName": "", "lastName": "", "username": ""]))
    }
    open func pluginAccounts(_ pluginId: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) { completion(.success(onAccounts?(pluginId) ?? [])) }
    open func pluginSwitchAccount(_ pluginId: String, accountId: Int64, completion: @escaping (Result<Void, Error>) -> Void) { onSwitchAccount?(pluginId, accountId); completion(.success(())) }
    open func pluginShowToast(_ pluginId: String, text: String, duration: Double?) { onToast?(pluginId, text) }
    open func pluginAlert(_ pluginId: String, title: String, text: String?, completion: @escaping () -> Void) { completion() }
    open func pluginConfirm(_ pluginId: String, title: String, text: String?, ok: String?, cancel: String?, completion: @escaping (Bool) -> Void) { completion(false) }
    open func pluginPrompt(_ pluginId: String, title: String, text: String?, placeholder: String?, defaultValue: String?, ok: String?, cancel: String?, completion: @escaping (String?) -> Void) { completion(nil) }
    open func pluginShare(_ pluginId: String, text: String?, url: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        onShare?(pluginId, text, url)
        completion(.success(()))
    }
    open func pluginPagesChanged(_ pluginId: String, pages: [AorusPluginUIPage]) { onPagesChanged?(pluginId, pages) }
    open func pluginSettingsShortcutsChanged(_ pluginId: String, shortcuts: [AorusPluginSettingsShortcut]) { onSettingsShortcutsChanged?(pluginId, shortcuts) }
    open func pluginContextActionsChanged(_ pluginId: String, actions: [AorusPluginContextAction]) { onContextActionsChanged?(pluginId, actions) }
    open func pluginOpenPage(_ pluginId: String, pageId: String, style: String, completion: @escaping (Result<Void, Error>) -> Void) {
        onOpenPage?(pluginId, pageId, style)
        completion(.success(()))
    }
    open func pluginOpenURL(_ pluginId: String, url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        onOpenURL?(pluginId, url)
        completion(.success(()))
    }
    open func pluginOpenTelegramLink(_ pluginId: String, url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        onOpenTelegramLink?(pluginId, url)
        completion(.success(()))
    }
    open func pluginAIAsk(_ pluginId: String, prompt: String, history: [[String: String]], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        completion(.success(onAIAsk?(pluginId, prompt, history) ?? ["text": "", "artifacts": []]))
    }
    open func pluginAIOpenArtifact(_ pluginId: String, artifactId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        onAIOpenArtifact?(pluginId, artifactId)
        completion(.success(()))
    }
    open func pluginAppFeatures(_ pluginId: String, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        completion(.success(onAppFeatures?(pluginId) ?? []))
    }
    open func pluginSetAppFeature(_ pluginId: String, featureId: String, value: Any, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        completion(.success(onSetAppFeature?(pluginId, featureId, value) ?? ["id": featureId, "value": value]))
    }
    open func pluginProxyStatus(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        completion(.success(onProxyStatus?(pluginId) ?? ["enabled": false, "stableCalls": false, "connected": false, "servers": []]))
    }
    open func pluginSetProxyPreference(_ pluginId: String, key: String, value: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        completion(.success(onSetProxyPreference?(pluginId, key, value) ?? ["enabled": false, "stableCalls": false, "connected": false, "servers": []]))
    }
    open func pluginRefreshProxy(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        completion(.success(onRefreshProxy?(pluginId) ?? ["enabled": false, "stableCalls": false, "connected": false, "servers": []]))
    }
    open func pluginTelegramProxyStatus(_ pluginId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { completion(.success(onTelegramProxyStatus?(pluginId) ?? ["enabled": false, "useForCalls": false, "servers": []])) }
    open func pluginSetTelegramProxyEnabled(_ pluginId: String, enabled: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) { pluginTelegramProxyStatus(pluginId, completion: completion) }
    open func pluginSetTelegramProxyUseForCalls(_ pluginId: String, enabled: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) { pluginTelegramProxyStatus(pluginId, completion: completion) }
    open func pluginAddTelegramProxy(_ pluginId: String, type: String, host: String, port: Int32, username: String?, password: String?, secret: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) { pluginTelegramProxyStatus(pluginId, completion: completion) }
    open func pluginRemoveTelegramProxy(_ pluginId: String, index: Int, completion: @escaping (Result<[String: Any], Error>) -> Void) { pluginTelegramProxyStatus(pluginId, completion: completion) }
    open func pluginSelectTelegramProxy(_ pluginId: String, index: Int?, completion: @escaping (Result<[String: Any], Error>) -> Void) { pluginTelegramProxyStatus(pluginId, completion: completion) }
    open func pluginHaptic(_ pluginId: String, kind: String) {}
    open func pluginClipboardRead(_ pluginId: String, completion: @escaping (String?) -> Void) { completion(nil) }
    open func pluginClipboardWrite(_ pluginId: String, text: String) {}
    open var pluginDeviceInfo: [String: Any] {
        return ["language": language, "systemVersion": "0", "appVersion": "0", "isDark": false]
    }
    open var pluginInterfaceLanguage: String { return language }
}

public enum AorusPluginRunError: Error, Equatable {
    case syntax([AorusPluginDiagnostic])
    case runtime(message: String, line: Int?)
    case terminated
    case notRunning

    public var message: String {
        switch self {
        case let .syntax(diagnostics):
            return diagnostics.first?.message ?? "Syntax error"
        case let .runtime(message, _):
            return message
        case .terminated:
            return "JavaScript execution terminated"
        case .notRunning:
            return "The plugin is not running"
        }
    }
}

/// What the outgoing-text hook decided. `timedOut` means the plugin did not answer within
/// its budget: the text goes out untouched and the plugin is marked hung.
public struct AorusPluginOutgoingVerdict: Equatable {
    public var consumed: Bool
    public var replacement: String?
    public var timedOut: Bool

    public init(consumed: Bool = false, replacement: String? = nil, timedOut: Bool = false) {
        self.consumed = consumed
        self.replacement = replacement
        self.timedOut = timedOut
    }

    public static let passThrough = AorusPluginOutgoingVerdict()
}

public final class AorusPluginSandbox {
    /// Wall-clock budget for any single entry into JavaScript. A handler that runs longer is
    /// terminated by JavaScriptCore itself, with an exception the plugin's log records.
    public static let executionLimit: TimeInterval = 3.0
    /// The largest response `aorus.http.fetch` hands back.
    public static let responseLimitBytes = 5 * 1024 * 1024
    public static let requestBodyLimitBytes = 2 * 1024 * 1024
    public static let requestPayloadLimitBytes = 256 * 1024
    public static let pendingRequestLimit = 32
    /// How many log lines the sandbox keeps for the console panel.
    public static let recentLogLimit = 500
    /// Hosts a plugin may not talk to: the app's own control plane.
    public static let blockedHostSuffixes: [String] = ["aorusgram.com"]

    public let manifest: AorusPluginManifest
    public let source: String
    public let queue: DispatchQueue
    public let permissions: Set<AorusPluginPermission>

    private let hostServices: AorusPluginHostServices
    private var virtualMachine: JSVirtualMachine?
    private var context: JSContext?
    private var dispatcher: JSValue?
    private var pendingException: JSValue?
    private var timers: [Int32: DispatchWorkItem] = [:]
    private var storageValues: [String: AorusPluginJSONValue]
    private var settingsValues: [String: AorusPluginJSONValue]
    private(set) public var settingsSchema: [AorusPluginSettingField]
    private var session: URLSession?
    private var networkDelegate: AorusPluginNetworkDelegate?
    private var pendingRequestIds = Set<Int32>()
    private let stateLock = NSLock()
    private var runningFlag = false
    private var hungFlag = false
    private var lastErrorText: String?
    private var recentEntries: [AorusPluginLogEntry] = []
    private var sendHooks = false
    private var commandHooks = false

    /// Called on the sandbox queue for every log line, after the host has been told. The
    /// editor's console attaches here.
    public var onLog: ((AorusPluginLogEntry) -> Void)?

    public init(manifest: AorusPluginManifest, source: String, host: AorusPluginHostServices, permissions: Set<AorusPluginPermission> = [], storage: [String: AorusPluginJSONValue] = [:], settings: [String: AorusPluginJSONValue] = [:], settingsSchema: [AorusPluginSettingField] = []) {
        self.manifest = manifest
        self.source = source
        self.hostServices = host
        self.permissions = permissions
        self.storageValues = storage
        self.settingsValues = settings
        self.settingsSchema = settingsSchema
        self.queue = DispatchQueue(label: "aorusgram.plugin.\(manifest.id)", qos: .userInitiated)
    }

    deinit {
        for (_, item) in timers { item.cancel() }
        session?.invalidateAndCancel()
    }

    // MARK: - State

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return runningFlag
    }

    public var isHung: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return hungFlag
    }

    public var lastError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastErrorText
    }

    /// True when the plugin registered a command or a `send` handler, so the chat's send
    /// path knows whether waiting on this plugin can change anything.
    public var hasOutgoingHooks: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return runningFlag && !hungFlag && permissions.contains(.outgoingMessages) && (sendHooks || commandHooks)
    }

    public var recentLog: [AorusPluginLogEntry] {
        stateLock.lock(); defer { stateLock.unlock() }
        return recentEntries
    }

    public func clearLog() {
        stateLock.lock()
        recentEntries.removeAll()
        stateLock.unlock()
    }

    public var storageSnapshot: [String: AorusPluginJSONValue] {
        stateLock.lock(); defer { stateLock.unlock() }
        return storageValues
    }

    private func setState(running: Bool? = nil, hung: Bool? = nil, error: String?? = nil) {
        stateLock.lock()
        if let running = running { runningFlag = running }
        if let hung = hung { hungFlag = hung }
        if let error = error { lastErrorText = error }
        stateLock.unlock()
    }

    // MARK: - Logging

    private func record(_ level: AorusPluginLogEntry.Level, _ text: String) {
        let entry = AorusPluginLogEntry(level: level, text: text)
        stateLock.lock()
        recentEntries.append(entry)
        if recentEntries.count > AorusPluginSandbox.recentLogLimit {
            recentEntries.removeFirst(recentEntries.count - AorusPluginSandbox.recentLogLimit)
        }
        if level == .error {
            lastErrorText = text
        }
        stateLock.unlock()
        hostServices.pluginLog(manifest.id, level: level, text: text)
        onLog?(entry)
    }

    // MARK: - Watchdog

    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (JSContextGroupRef?, Double, TerminateCallback?, UnsafeMutableRawPointer?) -> Void

    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()

    /// Whether this JavaScriptCore lets the sandbox bound execution time.
    public static var watchdogAvailable: Bool {
        return setExecutionTimeLimit != nil
    }

    private static let terminate: TerminateCallback = { _, _ in
        return true
    }

    private func installWatchdog(on context: JSContext) {
        guard let set = AorusPluginSandbox.setExecutionTimeLimit else {
            record(.debug, "Execution time limit is not available on this system")
            return
        }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        set(group, AorusPluginSandbox.executionLimit, AorusPluginSandbox.terminate, nil)
    }

    // MARK: - Lifecycle

    /// Builds the context, runs the prelude and the plugin, then delivers `start`.
    public func start(completion: ((AorusPluginRunError?) -> Void)? = nil) {
        queue.async {
            if self.context != nil {
                completion?(nil)
                return
            }
            let diagnostics = AorusPluginSandbox.checkSyntax(self.source)
            if !diagnostics.isEmpty {
                let first = diagnostics[0]
                self.setState(running: false, error: .some("Line \(first.line): \(first.message)"))
                self.record(.error, "Syntax error at line \(first.line): \(first.message)")
                completion?(.syntax(diagnostics))
                return
            }
            guard AorusPluginSandbox.watchdogAvailable else {
                let message = "JavaScript execution isolation is unavailable on this system"
                self.setState(running: false, error: .some(message))
                self.record(.error, message)
                completion?(.runtime(message: message, line: nil))
                return
            }
            guard let virtualMachine = JSVirtualMachine(), let context = JSContext(virtualMachine: virtualMachine) else {
                completion?(.runtime(message: "Could not create a JavaScript context", line: nil))
                return
            }
            context.name = "AorusGram plugin \(self.manifest.name)"
            context.exceptionHandler = { [weak self] _, exception in
                guard let self = self else { return }
                self.pendingException = exception
                if let exception = exception {
                    let message = AorusPluginSandbox.describe(exception: exception)
                    if message.localizedCaseInsensitiveContains("execution terminated") {
                        self.setState(hung: true, error: .some(message))
                    }
                    self.record(.error, message)
                }
            }
            self.virtualMachine = virtualMachine
            self.context = context
            self.installWatchdog(on: context)
            self.installHost(in: context)

            self.pendingException = nil
            context.evaluateScript(AorusPluginPrelude.source, withSourceURL: URL(string: "aorus://prelude.js"))
            if let exception = self.pendingException {
                self.tearDown()
                completion?(.runtime(message: "Prelude failed: " + AorusPluginSandbox.describe(exception: exception), line: nil))
                return
            }
            guard self.dispatcher != nil else {
                self.tearDown()
                completion?(.runtime(message: "Prelude did not register a dispatcher", line: nil))
                return
            }
            self.setState(running: true, hung: false, error: .some(nil))
            self.pendingException = nil
            context.evaluateScript(self.source, withSourceURL: URL(string: "aorus://main.js"))
            if let exception = self.pendingException {
                let line = exception.forProperty("line").isNumber ? Int(exception.forProperty("line").toInt32()) : nil
                let message = AorusPluginSandbox.describe(exception: exception)
                self.tearDown()
                self.setState(running: false, error: .some(message))
                completion?(.runtime(message: message, line: line))
                return
            }
            self.deliver(event: "start", payload: nil)
            completion?(nil)
        }
    }

    /// Delivers `stop` and destroys the context. Timers die with it.
    public func stop(completion: (() -> Void)? = nil) {
        queue.async {
            if self.context != nil, !self.isHung {
                self.deliver(event: "stop", payload: nil)
            }
            self.tearDown()
            completion?()
        }
    }

    private func tearDown() {
        for (_, item) in timers { item.cancel() }
        timers.removeAll()
        dispatcher = nil
        context?.exceptionHandler = nil
        context = nil
        virtualMachine = nil
        session?.invalidateAndCancel()
        session = nil
        networkDelegate = nil
        pendingRequestIds.removeAll()
        stateLock.lock()
        runningFlag = false
        sendHooks = false
        commandHooks = false
        stateLock.unlock()
    }

    // MARK: - Events

    /// Delivers an event asynchronously on the plugin's queue.
    public func dispatch(event: String, payload: [String: Any]) {
        if ["message", "messageDeleted", "messageEdited"].contains(event) && !permissions.contains(.incomingMessages) { return }
        if event == "send" && !permissions.contains(.outgoingMessages) { return }
        if event == "appSettingsChanged" && !permissions.contains(.appCustomization) { return }
        if event == "connectionChanged" && !permissions.contains(.connectionControl) { return }
        queue.async {
            self.deliver(event: event, payload: payload)
        }
    }

    private func deliver(event: String, payload: [String: Any]?) {
        guard let dispatcher = dispatcher, context != nil, !isHung else { return }
        pendingException = nil
        if let payload = payload {
            dispatcher.invokeMethod("dispatch", withArguments: [event, payload])
        } else {
            dispatcher.invokeMethod("dispatch", withArguments: [event])
        }
    }

    /// The settings the person changed on the plugin's card.
    public func updateSettings(_ values: [String: AorusPluginJSONValue]) {
        queue.async {
            self.stateLock.lock()
            self.settingsValues = values
            self.stateLock.unlock()
            guard let dispatcher = self.dispatcher, self.context != nil, !self.isHung else { return }
            let json = String(decoding: AorusPluginJSONValue.object(values).serialized(), as: UTF8.self)
            dispatcher.invokeMethod("settingsChanged", withArguments: [json])
        }
    }

    /// Runs the plugin's commands and `send` handlers over an outgoing text. Blocks the
    /// caller for at most `timeout`; a plugin that does not answer in time is marked hung and
    /// never waited on again.
    public func processOutgoing(text: String, peerId: Int64, accountId: Int64, timeout: TimeInterval) -> AorusPluginOutgoingVerdict {
        guard hasOutgoingHooks else { return .passThrough }
        final class Box {
            let lock = NSLock()
            var verdict = AorusPluginOutgoingVerdict.passThrough
            var abandoned = false
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            var verdict = AorusPluginOutgoingVerdict.passThrough
            if let dispatcher = self.dispatcher, self.context != nil {
                self.pendingException = nil
                if let result = dispatcher.invokeMethod("runOutgoing", withArguments: [text, String(peerId), String(accountId)]),
                   result.isObject {
                    verdict.consumed = result.forProperty("consumed").toBool()
                    let replacement = result.forProperty("replacement")
                    if let replacement = replacement, replacement.isString {
                        verdict.replacement = replacement.toString()
                    }
                }
            }
            box.lock.lock()
            let abandoned = box.abandoned
            if !abandoned { box.verdict = verdict }
            box.lock.unlock()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            box.lock.lock()
            box.abandoned = true
            box.lock.unlock()
            setState(hung: true, error: .some("The plugin did not answer within \(Int(timeout * 1000)) ms and was stopped"))
            record(.error, "Outgoing hook did not finish within \(Int(timeout * 1000)) ms; the plugin is marked as hung")
            return AorusPluginOutgoingVerdict(consumed: false, replacement: nil, timedOut: true)
        }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.verdict
    }

    /// What the running plugin registered: the command prefix, the command names and the
    /// events it listens to. For the card that has to answer "why did my command do
    /// nothing" without anyone reading the source. Reads only, and gives up rather than
    /// waiting on a plugin that is busy.
    public struct Registration: Equatable {
        public var prefix: String
        public var commands: [String]
        public var events: [String]

        public init(prefix: String = ".", commands: [String] = [], events: [String] = []) {
            self.prefix = prefix
            self.commands = commands
            self.events = events
        }
    }

    public func registration(timeout: TimeInterval = 0.3) -> Registration {
        final class Box {
            let lock = NSLock()
            var value = Registration()
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            var value = Registration()
            if let dispatcher = self.dispatcher, self.context != nil, !self.isHung {
                self.pendingException = nil
                if let prefix = dispatcher.invokeMethod("commandPrefix", withArguments: []), prefix.isString {
                    value.prefix = prefix.toString()
                }
                if let commands = dispatcher.invokeMethod("commandNames", withArguments: []), commands.isArray {
                    value.commands = (commands.toArray() as? [String]) ?? []
                }
                if let events = dispatcher.invokeMethod("eventNames", withArguments: []), events.isArray {
                    value.events = (events.toArray() as? [String]) ?? []
                }
            }
            box.lock.lock()
            box.value = value
            box.lock.unlock()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value
    }

    /// Evaluates a snippet in the running context and describes the result. For the console
    /// in the editor.
    public func runSnippet(_ code: String, completion: @escaping (Result<String, AorusPluginRunError>) -> Void) {
        queue.async {
            guard let context = self.context else {
                completion(.failure(.notRunning))
                return
            }
            self.pendingException = nil
            let result = context.evaluateScript(code, withSourceURL: URL(string: "aorus://console.js"))
            if let exception = self.pendingException {
                let message = AorusPluginSandbox.describe(exception: exception)
                if message.contains("execution terminated") {
                    completion(.failure(.terminated))
                } else {
                    let line = exception.forProperty("line").isNumber ? Int(exception.forProperty("line").toInt32()) : nil
                    completion(.failure(.runtime(message: message, line: line)))
                }
                return
            }
            completion(.success(AorusPluginSandbox.describe(result: result, in: context)))
        }
    }

    // MARK: - Syntax

    /// Parses without running. Line and column are what JavaScriptCore reports, 1-based.
    public static func checkSyntax(_ source: String) -> [AorusPluginDiagnostic] {
        guard let context = JSContext() else { return [] }
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        let valid = JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception)
        if valid { return [] }
        guard let exception = exception else {
            return [AorusPluginDiagnostic(line: 1, message: "Syntax error")]
        }
        let value = JSValue(jsValueRef: exception, in: context)
        let line = value?.forProperty("line").isNumber == true ? Int(value!.forProperty("line").toInt32()) : 1
        let column: Int? = value?.forProperty("column").isNumber == true ? Int(value!.forProperty("column").toInt32()) : nil
        var message = value?.forProperty("message").toString() ?? "Syntax error"
        if message == "undefined" || message.isEmpty {
            message = value?.toString() ?? "Syntax error"
        }
        return [AorusPluginDiagnostic(line: line, column: column, message: message, severity: .error)]
    }

    // MARK: - Host object

    private func installHost(in context: JSContext) {
        guard let hostObject = JSValue(newObjectIn: context) else { return }
        let pluginId = manifest.id

        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.record(AorusPluginLogEntry.Level(rawValue: level) ?? .info, text)
        }
        hostObject.setObject(log, forKeyedSubscript: "log" as NSString)

        let hooksChanged: @convention(block) (Bool, Bool) -> Void = { [weak self] hasSend, hasCommands in
            guard let self = self else { return }
            self.stateLock.lock()
            self.sendHooks = self.permissions.contains(.outgoingMessages) && hasSend
            self.commandHooks = self.permissions.contains(.outgoingMessages) && hasCommands
            self.stateLock.unlock()
        }
        hostObject.setObject(hooksChanged, forKeyedSubscript: "hooksChanged" as NSString)

        let registerDispatcher: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.dispatcher = value
        }
        hostObject.setObject(registerDispatcher, forKeyedSubscript: "registerDispatcher" as NSString)

        let pluginInfo: @convention(block) () -> [String: Any] = { [manifest] in
            return ["id": manifest.id, "name": manifest.name, "version": manifest.version, "author": manifest.author]
        }
        hostObject.setObject(pluginInfo, forKeyedSubscript: "pluginInfo" as NSString)

        let deviceInfo: @convention(block) () -> [String: Any] = { [weak self] in
            return self?.hostServices.pluginDeviceInfo ?? [:]
        }
        hostObject.setObject(deviceInfo, forKeyedSubscript: "deviceInfo" as NSString)

        let language: @convention(block) () -> String = { [weak self] in
            return self?.hostServices.pluginInterfaceLanguage ?? "en"
        }
        hostObject.setObject(language, forKeyedSubscript: "language" as NSString)

        let storageInitial: @convention(block) () -> String = { [weak self] in
            guard let self = self else { return "{}" }
            return String(decoding: AorusPluginJSONValue.object(self.storageSnapshot).serialized(), as: UTF8.self)
        }
        hostObject.setObject(storageInitial, forKeyedSubscript: "storageInitial" as NSString)

        let storageWrite: @convention(block) (String, JSValue?) -> Bool = { [weak self] key, json in
            guard let self = self, self.hostServices.pluginExecutionAllowed else { return false }
            return self.writeStorage(key: key, json: json)
        }
        hostObject.setObject(storageWrite, forKeyedSubscript: "storageWrite" as NSString)

        let settingsInitial: @convention(block) () -> String = { [weak self] in
            guard let self = self else { return "{}" }
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            return String(decoding: AorusPluginJSONValue.object(self.settingsValues).serialized(), as: UTF8.self)
        }
        hostObject.setObject(settingsInitial, forKeyedSubscript: "settingsInitial" as NSString)

        let settingsDefine: @convention(block) (String) -> Void = { [weak self] json in
            guard let self = self, self.hostServices.pluginExecutionAllowed else { return }
            let data = Data(json.utf8)
            guard data.count <= AorusPluginSandbox.requestPayloadLimitBytes,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let list = object as? [Any] else { return }
            let fields = AorusPluginSettingField.schema(from: list)
            self.stateLock.lock()
            self.settingsSchema = fields
            self.stateLock.unlock()
            self.hostServices.pluginSettingsSchemaChanged(pluginId, fields: fields)
        }
        hostObject.setObject(settingsDefine, forKeyedSubscript: "settingsDefine" as NSString)

        let settingsWrite: @convention(block) (String, String) -> Void = { [weak self] key, json in
            let data = Data(json.utf8)
            guard let self = self, self.hostServices.pluginExecutionAllowed,
                  key.count <= 64, data.count <= AorusPluginStore.storageLimitBytes,
                  let value = AorusPluginJSONValue.parse(data) else { return }
            self.stateLock.lock()
            let previous = self.settingsValues
            self.settingsValues[key] = value
            let snapshot = self.settingsValues
            if AorusPluginJSONValue.object(snapshot).serialized().count > AorusPluginStore.storageLimitBytes {
                self.settingsValues = previous
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()
            self.hostServices.pluginSettingsChanged(pluginId, values: snapshot)
        }
        hostObject.setObject(settingsWrite, forKeyedSubscript: "settingsWrite" as NSString)

        let pagesDefine: @convention(block) (String) -> Bool = { [weak self] json in
            guard let self, self.hostServices.pluginExecutionAllowed, self.permissions.contains(.customUI) else { return false }
            let data = Data(json.utf8)
            guard let pages = AorusPluginUIPage.validated(from: data) else { return false }
            if pages.contains(where: { page in page.sections.contains(where: { section in section.rows.contains(where: { $0.kind == .link }) }) }),
               !self.permissions.contains(.inAppBrowser) { return false }
            self.hostServices.pluginPagesChanged(pluginId, pages: pages)
            return true
        }
        hostObject.setObject(pagesDefine, forKeyedSubscript: "pagesDefine" as NSString)

        let settingsShortcutsDefine: @convention(block) (String) -> Bool = { [weak self] json in
            guard let self, self.hostServices.pluginExecutionAllowed, self.permissions.contains(.settingsIntegration) else { return false }
            let data = Data(json.utf8)
            guard let shortcuts = AorusPluginSettingsShortcut.validated(from: data) else { return false }
            if shortcuts.contains(where: { $0.url != nil }), !self.permissions.contains(.inAppBrowser) { return false }
            self.hostServices.pluginSettingsShortcutsChanged(pluginId, shortcuts: shortcuts)
            return true
        }
        hostObject.setObject(settingsShortcutsDefine, forKeyedSubscript: "settingsShortcutsDefine" as NSString)

        let contextActionsDefine: @convention(block) (String) -> Bool = { [weak self] json in
            guard let self, self.hostServices.pluginExecutionAllowed, self.permissions.contains(.contextMenu) else { return false }
            let data = Data(json.utf8)
            guard let actions = AorusPluginContextAction.validated(from: data) else { return false }
            self.hostServices.pluginContextActionsChanged(pluginId, actions: actions)
            return true
        }
        hostObject.setObject(contextActionsDefine, forKeyedSubscript: "contextActionsDefine" as NSString)

        let timerSchedule: @convention(block) (Int32, Double, Bool) -> Void = { [weak self] id, milliseconds, repeats in
            self?.scheduleTimer(id: id, milliseconds: milliseconds, repeats: repeats)
        }
        hostObject.setObject(timerSchedule, forKeyedSubscript: "timerSchedule" as NSString)

        let timerCancel: @convention(block) (Int32) -> Void = { [weak self] id in
            guard let self = self else { return }
            self.timers[id]?.cancel()
            self.timers[id] = nil
        }
        hostObject.setObject(timerCancel, forKeyedSubscript: "timerCancel" as NSString)

        let request: @convention(block) (String, String, Int32) -> Void = { [weak self] kind, payload, id in
            guard let self = self else { return }
            guard payload.lengthOfBytes(using: .utf8) <= AorusPluginSandbox.requestPayloadLimitBytes else {
                self.rejectImmediately(id, message: "Request payload is too large")
                return
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
            self.handleRequest(kind: kind, payload: object, id: id)
        }
        hostObject.setObject(request, forKeyedSubscript: "request" as NSString)

        let crypto: @convention(block) (String, String, String) -> JSValue = { [weak self] operation, first, second in
            let context = self?.context ?? JSContext()!
            guard self?.hostServices.pluginExecutionAllowed == true else { return JSValue(nullIn: context) }
            if let result = AorusPluginSandbox.crypto(operation: operation, first: first, second: second) {
                return JSValue(object: result, in: context)
            }
            return JSValue(nullIn: context)
        }
        hostObject.setObject(crypto, forKeyedSubscript: "crypto" as NSString)

        let toast: @convention(block) (String, Double) -> Void = { [weak self] text, duration in
            guard let self = self, self.hostServices.pluginExecutionAllowed, self.permissions.contains(.dialogs) else { return }
            self.hostServices.pluginShowToast(pluginId, text: String(text.prefix(2_000)), duration: duration > 0 ? duration : nil)
        }
        hostObject.setObject(toast, forKeyedSubscript: "toast" as NSString)

        let haptic: @convention(block) (String) -> Void = { [weak self] kind in
            guard let self, self.hostServices.pluginExecutionAllowed else { return }
            self.hostServices.pluginHaptic(pluginId, kind: kind)
        }
        hostObject.setObject(haptic, forKeyedSubscript: "haptic" as NSString)

        let clipboardWrite: @convention(block) (String) -> Void = { [weak self] text in
            guard let self = self, self.hostServices.pluginExecutionAllowed, self.permissions.contains(.clipboardWrite) else { return }
            self.hostServices.pluginClipboardWrite(pluginId, text: String(text.prefix(100_000)))
        }
        hostObject.setObject(clipboardWrite, forKeyedSubscript: "clipboardWrite" as NSString)

        context.setObject(hostObject, forKeyedSubscript: "__aorusHost" as NSString)
    }

    // MARK: - Storage

    private func writeStorage(key: String, json: JSValue?) -> Bool {
        guard !key.isEmpty, key.count <= 128 else { return false }
        stateLock.lock()
        let previous = storageValues
        if let json = json, json.isString {
            let data = Data(json.toString().utf8)
            guard data.count <= AorusPluginStore.storageLimitBytes, let value = AorusPluginJSONValue.parse(data) else {
                stateLock.unlock()
                return false
            }
            storageValues[key] = value
        } else {
            storageValues[key] = nil
        }
        let serialized = AorusPluginJSONValue.object(storageValues).serialized()
        if serialized.count > AorusPluginStore.storageLimitBytes {
            storageValues = previous
            stateLock.unlock()
            return false
        }
        let snapshot = storageValues
        stateLock.unlock()
        hostServices.pluginStorageChanged(manifest.id, values: snapshot)
        return true
    }

    // MARK: - Timers

    private func scheduleTimer(id: Int32, milliseconds: Double, repeats: Bool) {
        timers[id]?.cancel()
        let bounded = min(86_400_000, max(repeats ? 50 : 1, milliseconds))
        let delay = bounded / 1000.0
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.hostServices.pluginExecutionAllowed,
                  let dispatcher = self.dispatcher, self.context != nil, self.timers[id] != nil else { return }
            if repeats {
                self.scheduleTimer(id: id, milliseconds: bounded, repeats: true)
            } else {
                self.timers[id] = nil
            }
            self.pendingException = nil
            dispatcher.invokeMethod("timerFire", withArguments: [NSNumber(value: id)])
        }
        timers[id] = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Requests

    private func settle(_ id: Int32, with result: Result<Any?, Error>) {
        queue.async {
            guard let dispatcher = self.dispatcher, self.context != nil else { return }
            guard self.pendingRequestIds.remove(id) != nil else { return }
            self.pendingException = nil
            switch result {
            case let .success(value):
                let json: String
                if let value = value, let converted = AorusPluginJSONValue(any: value) {
                    json = String(decoding: converted.serialized(), as: UTF8.self)
                } else {
                    json = "null"
                }
                dispatcher.invokeMethod("resolve", withArguments: [NSNumber(value: id), json])
            case let .failure(error):
                dispatcher.invokeMethod("reject", withArguments: [NSNumber(value: id), AorusPluginSandbox.message(for: error)])
            }
        }
    }

    private func rejectImmediately(_ id: Int32, message: String) {
        queue.async {
            guard let dispatcher = self.dispatcher, self.context != nil else { return }
            dispatcher.invokeMethod("reject", withArguments: [NSNumber(value: id), message])
        }
    }

    private func require(_ permission: AorusPluginPermission, id: Int32) -> Bool {
        guard permissions.contains(permission) else {
            settle(id, with: .failure(AorusPluginRequestError("Permission not granted: \(permission.rawValue)")))
            return false
        }
        return true
    }

    private static func message(for error: Error) -> String {
        if let error = error as? AorusPluginRequestError {
            return error.message
        }
        return (error as NSError).localizedDescription
    }

    private func handleRequest(kind: String, payload: [String: Any], id: Int32) {
        guard hostServices.pluginExecutionAllowed else {
            rejectImmediately(id, message: "Plugin execution is unavailable")
            return
        }
        guard !pendingRequestIds.contains(id), pendingRequestIds.count < AorusPluginSandbox.pendingRequestLimit else {
            rejectImmediately(id, message: "Too many pending requests")
            return
        }
        pendingRequestIds.insert(id)
        let pluginId = manifest.id
        let host = hostServices
        func int64(_ key: String) -> Int64? {
            if let text = payload[key] as? String { return Int64(text) }
            guard let number = payload[key] as? NSNumber,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  abs(number.doubleValue) <= 9_007_199_254_740_991 else { return nil }
            return Int64(number.doubleValue)
        }
        func string(_ key: String) -> String? {
            return payload[key] as? String
        }
        func int32(_ key: String) -> Int32? {
            guard let number = payload[key] as? NSNumber,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { return nil }
            return number.int32Value
        }
        func boolean(_ key: String) -> Bool? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        let toSelf = (payload["toSelf"] as? NSNumber)?.boolValue ?? false

        switch kind {
        case "messages.send":
            guard require(.sendMessages, id: id) else { return }
            guard let text = string("text") else {
                settle(id, with: .failure(AorusPluginRequestError("text is required")))
                return
            }
            guard !text.isEmpty, text.count <= 32_768 else {
                settle(id, with: .failure(AorusPluginRequestError("Message is empty or too long")))
                return
            }
            let replyTo: Int32? = (payload["replyTo"] as? NSNumber).map { $0.int32Value }
            host.pluginSendMessage(pluginId, peerId: int64("peerId"), toSelf: toSelf, accountId: int64("accountId"), text: text, replyTo: replyTo) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "messages.edit":
            guard require(.manageMessages, id: id) else { return }
            guard let peerId = int64("peerId"), let namespace = int32("namespace"), let messageId = int32("messageId"),
                  let text = string("text"), !text.isEmpty, text.count <= 32_768 else {
                settle(id, with: .failure(AorusPluginRequestError("A valid message reference and text are required")))
                return
            }
            host.pluginEditMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, text: text) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "messages.delete":
            guard require(.manageMessages, id: id) else { return }
            guard let peerId = int64("peerId"), let namespace = int32("namespace"), let messageId = int32("messageId"),
                  let forEveryone = boolean("forEveryone") else {
                settle(id, with: .failure(AorusPluginRequestError("A valid message reference is required")))
                return
            }
            host.pluginDeleteMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, forEveryone: forEveryone) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "messages.forward":
            guard require(.manageMessages, id: id) else { return }
            guard let peerId = int64("peerId"), let namespace = int32("namespace"), let messageId = int32("messageId"), let toPeerId = int64("toPeerId") else {
                settle(id, with: .failure(AorusPluginRequestError("A valid source message and destination peer are required")))
                return
            }
            host.pluginForwardMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, toPeerId: toPeerId) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "messages.react":
            guard require(.manageMessages, id: id) else { return }
            guard let peerId = int64("peerId"), let namespace = int32("namespace"), let messageId = int32("messageId") else {
                settle(id, with: .failure(AorusPluginRequestError("A valid message reference is required")))
                return
            }
            let reaction = string("reaction")
            guard reaction == nil || (reaction != nil && !reaction!.isEmpty && reaction!.count <= 16) else {
                settle(id, with: .failure(AorusPluginRequestError("reaction is invalid")))
                return
            }
            host.pluginReactToMessage(pluginId, peerId: peerId, namespace: namespace, messageId: messageId, reaction: reaction) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "chats.resolve":
            guard require(.chatMetadata, id: id) else { return }
            guard let username = string("username"), !username.isEmpty else {
                settle(id, with: .failure(AorusPluginRequestError("username is required")))
                return
            }
            host.pluginResolveChat(pluginId, username: username) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value.map { $0 as Any } })
            }
        case "chats.get":
            guard require(.chatMetadata, id: id) else { return }
            host.pluginChatInfo(pluginId, peerId: int64("peerId"), toSelf: toSelf) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value.map { $0 as Any } })
            }
        case "chats.history":
            guard require(.messageHistory, id: id) else { return }
            let limit = (payload["limit"] as? NSNumber)?.intValue ?? 50
            guard (1...100).contains(limit) else {
                settle(id, with: .failure(AorusPluginRequestError("limit must be between 1 and 100")))
                return
            }
            host.pluginChatHistory(pluginId, peerId: int64("peerId"), toSelf: toSelf, limit: limit) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "chats.open":
            guard require(.openChats, id: id) else { return }
            host.pluginOpenChat(pluginId, peerId: int64("peerId"), toSelf: toSelf) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "telegram.openLink":
            guard require(.openChats, id: id) else { return }
            guard let url = string("url"), !url.isEmpty, url.count <= 2_048 else {
                settle(id, with: .failure(AorusPluginRequestError("url is required")))
                return
            }
            host.pluginOpenTelegramLink(pluginId, url: url) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "account.current":
            guard require(.accountProfile, id: id) else { return }
            host.pluginCurrentAccount(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "accounts.list":
            guard require(.accountSwitching, id: id) else { return }
            host.pluginAccounts(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "accounts.switch":
            guard require(.accountSwitching, id: id) else { return }
            guard let accountId = int64("accountId") else {
                settle(id, with: .failure(AorusPluginRequestError("accountId is required")))
                return
            }
            host.pluginSwitchAccount(pluginId, accountId: accountId) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "features.list":
            guard require(.appCustomization, id: id) else { return }
            host.pluginAppFeatures(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "features.get":
            guard require(.appCustomization, id: id) else { return }
            guard let featureId = string("id"), !featureId.isEmpty, featureId.count <= 64 else {
                settle(id, with: .failure(AorusPluginRequestError("feature id is required")))
                return
            }
            host.pluginAppFeatures(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { features -> Any? in
                    features.first(where: { ($0["id"] as? String) == featureId }).map { $0 as Any }
                })
            }
        case "features.set":
            guard require(.appCustomization, id: id) else { return }
            guard let featureId = string("id"), !featureId.isEmpty, featureId.count <= 64,
                  let value = payload["value"], !(value is NSNull) else {
                settle(id, with: .failure(AorusPluginRequestError("feature id and value are required")))
                return
            }
            host.pluginSetAppFeature(pluginId, featureId: featureId, value: value) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "proxy.status":
            guard require(.connectionControl, id: id) else { return }
            host.pluginProxyStatus(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "proxy.set":
            guard require(.connectionControl, id: id) else { return }
            guard let key = string("key"), ["enabled", "stableCalls"].contains(key),
                  let value = boolean("value") else {
                settle(id, with: .failure(AorusPluginRequestError("Unsupported proxy preference")))
                return
            }
            host.pluginSetProxyPreference(pluginId, key: key, value: value) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "proxy.refresh":
            guard require(.connectionControl, id: id) else { return }
            host.pluginRefreshProxy(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "telegramProxy.status":
            guard require(.telegramProxy, id: id) else { return }
            host.pluginTelegramProxyStatus(pluginId) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "telegramProxy.setEnabled":
            guard require(.telegramProxy, id: id) else { return }
            guard let enabled = boolean("enabled") else {
                settle(id, with: .failure(AorusPluginRequestError("enabled must be a boolean")))
                return
            }
            host.pluginSetTelegramProxyEnabled(pluginId, enabled: enabled) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "telegramProxy.setUseForCalls":
            guard require(.telegramProxy, id: id) else { return }
            guard let enabled = boolean("enabled") else {
                settle(id, with: .failure(AorusPluginRequestError("enabled must be a boolean")))
                return
            }
            host.pluginSetTelegramProxyUseForCalls(pluginId, enabled: enabled) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "telegramProxy.add":
            guard require(.telegramProxy, id: id) else { return }
            guard let type = string("type"), let hostName = string("host"),
                  let portNumber = payload["port"] as? NSNumber,
                  (1...65_535).contains(portNumber.intValue) else {
                settle(id, with: .failure(AorusPluginRequestError("type, host and a valid port are required")))
                return
            }
            host.pluginAddTelegramProxy(pluginId, type: type, host: hostName, port: Int32(portNumber.intValue), username: string("username"), password: string("password"), secret: string("secret")) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "telegramProxy.remove":
            guard require(.telegramProxy, id: id) else { return }
            guard let index = (payload["index"] as? NSNumber)?.intValue, index >= 0 else {
                settle(id, with: .failure(AorusPluginRequestError("A valid server index is required")))
                return
            }
            host.pluginRemoveTelegramProxy(pluginId, index: index) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "telegramProxy.select":
            guard require(.telegramProxy, id: id) else { return }
            let index: Int?
            if payload["index"] == nil || payload["index"] is NSNull {
                index = nil
            } else if let value = (payload["index"] as? NSNumber)?.intValue, value >= 0 {
                index = value
            } else {
                settle(id, with: .failure(AorusPluginRequestError("index must be null or a non-negative integer")))
                return
            }
            host.pluginSelectTelegramProxy(pluginId, index: index) { [weak self] result in
                self?.settle(id, with: result.map { value -> Any? in value as Any })
            }
        case "ui.alert":
            guard require(.dialogs, id: id) else { return }
            host.pluginAlert(pluginId, title: string("title") ?? "", text: string("text")) { [weak self] in
                self?.settle(id, with: .success(nil))
            }
        case "ui.confirm":
            guard require(.dialogs, id: id) else { return }
            host.pluginConfirm(pluginId, title: string("title") ?? "", text: string("text"), ok: string("ok"), cancel: string("cancel")) { [weak self] answer in
                self?.settle(id, with: .success(NSNumber(value: answer)))
            }
        case "ui.prompt":
            guard require(.dialogs, id: id) else { return }
            host.pluginPrompt(pluginId, title: string("title") ?? "", text: string("text"), placeholder: string("placeholder"), defaultValue: string("defaultValue"), ok: string("ok"), cancel: string("cancel")) { [weak self] answer in
                self?.settle(id, with: .success(answer.map { $0 as Any }))
            }
        case "ui.share":
            guard require(.dialogs, id: id) else { return }
            let text = string("text").map { String($0.prefix(100_000)) }
            let url = string("url").map { String($0.prefix(2_048)) }
            guard text != nil || url != nil else {
                settle(id, with: .failure(AorusPluginRequestError("text or url is required")))
                return
            }
            host.pluginShare(pluginId, text: text, url: url) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "ui.openPage":
            guard require(.customUI, id: id) else { return }
            guard let pageId = string("pageId"), !pageId.isEmpty, pageId.count <= 64 else {
                settle(id, with: .failure(AorusPluginRequestError("pageId is required")))
                return
            }
            let style = string("style") ?? "push"
            guard ["push", "sheet", "fullScreen"].contains(style) else {
                settle(id, with: .failure(AorusPluginRequestError("Unsupported page presentation style")))
                return
            }
            host.pluginOpenPage(pluginId, pageId: pageId, style: style) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "browser.open":
            guard require(.inAppBrowser, id: id) else { return }
            guard let url = string("url"), !url.isEmpty, url.count <= 2_048 else {
                settle(id, with: .failure(AorusPluginRequestError("url is required")))
                return
            }
            host.pluginOpenURL(pluginId, url: url) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "ai.ask":
            guard require(.artificialIntelligence, id: id) else { return }
            guard let prompt = string("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty, prompt.count <= 16_000 else {
                settle(id, with: .failure(AorusPluginRequestError("prompt is empty or too long")))
                return
            }
            let history = (payload["history"] as? [[String: Any]] ?? []).prefix(20).compactMap { item -> [String: String]? in
                guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                      let content = item["content"] as? String, !content.isEmpty else { return nil }
                return ["role": role, "content": String(content.prefix(8_000))]
            }
            host.pluginAIAsk(pluginId, prompt: prompt, history: Array(history)) { [weak self] result in
                self?.settle(id, with: result.map { $0 as Any })
            }
        case "ai.openArtifact":
            guard require(.artificialIntelligence, id: id) else { return }
            guard let artifactId = string("artifactId"), !artifactId.isEmpty, artifactId.count <= 128 else {
                settle(id, with: .failure(AorusPluginRequestError("artifactId is required")))
                return
            }
            host.pluginAIOpenArtifact(pluginId, artifactId: artifactId) { [weak self] result in
                self?.settle(id, with: result.map { _ -> Any? in nil })
            }
        case "clipboard.read":
            guard require(.clipboardRead, id: id) else { return }
            host.pluginClipboardRead(pluginId) { [weak self] text in
                self?.settle(id, with: .success(text.map { $0 as Any }))
            }
        case "util.sleep":
            let milliseconds = max(0, min(600_000, (payload["ms"] as? NSNumber)?.doubleValue ?? 0))
            queue.asyncAfter(deadline: .now() + milliseconds / 1000.0) { [weak self] in
                self?.settle(id, with: .success(nil))
            }
        case "http.fetch":
            guard require(.network, id: id) else { return }
            fetch(payload: payload, id: id)
        default:
            settle(id, with: .failure(AorusPluginRequestError("Unknown request: \(kind)")))
        }
    }

    // MARK: - HTTP

    /// Validates the request the way the contract describes, then loads it through a
    /// session of its own with no cookies and no cache.
    private func fetch(payload: [String: Any], id: Int32) {
        guard let urlText = payload["url"] as? String, let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            settle(id, with: .failure(AorusPluginRequestError("Invalid URL")))
            return
        }
        guard scheme == "http" || scheme == "https" else {
            settle(id, with: .failure(AorusPluginRequestError("Only http and https URLs are allowed")))
            return
        }
        if AorusPluginSandbox.isBlocked(host: host) || !AorusPluginSandbox.hostResolvesPublicly(host) {
            settle(id, with: .failure(AorusPluginRequestError("Host is not available to plugins")))
            return
        }
        var request = URLRequest(url: url)
        let method = ((payload["method"] as? String) ?? "GET").uppercased()
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method) else {
            settle(id, with: .failure(AorusPluginRequestError("HTTP method is not allowed")))
            return
        }
        request.httpMethod = method
        if let headers = payload["headers"] as? [String: Any] {
            for (name, value) in headers {
                let lowered = name.lowercased()
                guard !["host", "cookie", "proxy-authorization", "proxy-connection", "connection", "content-length"].contains(lowered),
                      name.count <= 128 else { continue }
                request.setValue(String(String(describing: value).prefix(8_192)), forHTTPHeaderField: name)
            }
        }
        if let body = payload["body"] as? String {
            let data = Data(body.utf8)
            guard data.count <= AorusPluginSandbox.requestBodyLimitBytes else {
                settle(id, with: .failure(AorusPluginRequestError("Request body is too large")))
                return
            }
            request.httpBody = data
        }
        let timeout = min(120.0, max(1.0, ((payload["timeout"] as? NSNumber)?.doubleValue ?? 30_000) / 1000.0))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if session == nil {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            let delegate = AorusPluginNetworkDelegate()
            networkDelegate = delegate
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
        guard let session = session, let delegate = networkDelegate else {
            settle(id, with: .failure(AorusPluginRequestError("Network session is unavailable")))
            return
        }
        let task = session.dataTask(with: request)
        delegate.register(task: task) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .failure(error):
                self.settle(id, with: .failure(error))
            case let .success((body, http)):
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                let result: [String: Any] = [
                    "status": NSNumber(value: http.statusCode),
                    "url": http.url?.absoluteString ?? urlText,
                    "headers": headers,
                    "body": String(decoding: body, as: UTF8.self),
                ]
                self.settle(id, with: .success(result))
            }
        }
        task.resume()
    }

    public static func isBlocked(host: String) -> Bool {
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if lowered == "localhost" || lowered.hasSuffix(".localhost") || lowered.hasSuffix(".local") || lowered.hasSuffix(".internal") || lowered.hasSuffix(".home.arpa") || isUnsafeIPAddress(lowered) {
            return true
        }
        for suffix in blockedHostSuffixes {
            if lowered == suffix || lowered.hasSuffix("." + suffix) {
                return true
            }
        }
        return false
    }

    public static func hostResolvesPublicly(_ host: String) -> Bool {
        if isBlocked(host: host) { return false }
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = true
                let address = String(cString: buffer)
                if isUnsafeIPAddress(address) { return false }
            }
            cursor = info.pointee.ai_next
        }
        return found
    }

    static func isUnsafeIPAddress(_ text: String) -> Bool {
        let text = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            return first == 0 || first == 10 || first == 127 ||
                (first == 100 && (64...127).contains(second)) ||
                (first == 169 && second == 254) || (first == 172 && (16...31).contains(second)) ||
                (first == 192 && (second == 0 || second == 168)) ||
                (first == 198 && (second == 18 || second == 19 || second == 51)) ||
                (first == 203 && second == 0) || first >= 224
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            let allZero = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let siteLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0
            let multicast = bytes[0] == 0xff
            let mappedV4 = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            let compatibleV4 = bytes[0..<12].allSatisfy { $0 == 0 }
            if mappedV4 || compatibleV4 {
                return isUnsafeIPAddress("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
            }
            let documentation = bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8
            return allZero || loopback || uniqueLocal || linkLocal || siteLocal || multicast || documentation
        }
        return false
    }

    // MARK: - Crypto

    static func crypto(operation: String, first: String, second: String) -> String? {
        switch operation {
        case "sha256":
            return SHA256.hash(data: Data(first.utf8)).map { String(format: "%02x", $0) }.joined()
        case "hmac":
            let key = SymmetricKey(data: Data(first.utf8))
            let code = HMAC<SHA256>.authenticationCode(for: Data(second.utf8), using: key)
            return code.map { String(format: "%02x", $0) }.joined()
        case "uuid":
            return UUID().uuidString.lowercased()
        case "random":
            let count = max(1, min(1024, Int(first) ?? 16))
            var generator = SystemRandomNumberGenerator()
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            return bytes.map { String(format: "%02x", $0) }.joined()
        case "b64e":
            return Data(first.utf8).base64EncodedString()
        case "b64d":
            guard let data = Data(base64Encoded: first, options: [.ignoreUnknownCharacters]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }

    // MARK: - Describing values

    static func describe(exception: JSValue) -> String {
        var text = exception.toString() ?? "Error"
        if text == "undefined" || text.isEmpty {
            text = exception.forProperty("message").toString() ?? "Error"
        }
        let line = exception.forProperty("line")
        if let line = line, line.isNumber {
            text += " (line \(line.toInt32()))"
        }
        return text
    }

    static func describe(result: JSValue?, in context: JSContext) -> String {
        guard let result = result else { return "undefined" }
        if result.isUndefined { return "undefined" }
        if result.isNull { return "null" }
        if result.isString { return result.toString() }
        if result.isObject, let json = context.objectForKeyedSubscript("JSON"), let text = json.invokeMethod("stringify", withArguments: [result, JSValue(nullIn: context)!, NSNumber(value: 2)]), text.isString {
            return text.toString()
        }
        return result.toString() ?? "undefined"
    }
}

private final class AorusPluginNetworkDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    typealias Completion = (Result<(Data, HTTPURLResponse), Error>) -> Void

    private struct State {
        var data = Data()
        var response: HTTPURLResponse?
        var completion: Completion
        var failure: Error?
        var redirectCount = 0
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    func register(task: URLSessionDataTask, completion: @escaping Completion) {
        lock.lock()
        states[task.taskIdentifier] = State(completion: completion)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        if var state = states[task.taskIdentifier] {
            state.redirectCount += 1
            states[task.taskIdentifier] = state
            if state.redirectCount > 5 {
                state.failure = AorusPluginRequestError("Too many redirects")
                states[task.taskIdentifier] = state
                lock.unlock()
                completionHandler(nil)
                return
            }
        }
        lock.unlock()
        guard let url = request.url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              (scheme == "http" || scheme == "https"),
              !AorusPluginSandbox.isBlocked(host: host),
              AorusPluginSandbox.hostResolvesPublicly(host) else {
            setFailure(AorusPluginRequestError("Redirect target is not available to plugins"), for: task.taskIdentifier)
            completionHandler(nil)
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if response.url?.host?.caseInsensitiveCompare(host) != .orderedSame {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(sanitized)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            setFailure(AorusPluginRequestError("No HTTP response"), for: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(AorusPluginSandbox.responseLimitBytes) {
            setFailure(AorusPluginRequestError("Response too large"), for: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        if var state = states[dataTask.taskIdentifier] {
            state.response = response
            states[dataTask.taskIdentifier] = state
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if var state = states[dataTask.taskIdentifier], state.failure == nil {
            if state.data.count + data.count > AorusPluginSandbox.responseLimitBytes {
                state.failure = AorusPluginRequestError("Response too large")
                states[dataTask.taskIdentifier] = state
                lock.unlock()
                dataTask.cancel()
                return
            }
            state.data.append(data)
            states[dataTask.taskIdentifier] = state
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state = state else { return }
        if let failure = state.failure {
            state.completion(.failure(failure))
        } else if let error = error {
            state.completion(.failure(AorusPluginRequestError(error.localizedDescription)))
        } else if let response = state.response {
            state.completion(.success((state.data, response)))
        } else {
            state.completion(.failure(AorusPluginRequestError("No HTTP response")))
        }
    }

    private func setFailure(_ error: Error, for taskIdentifier: Int) {
        lock.lock()
        if var state = states[taskIdentifier] {
            state.failure = error
            states[taskIdentifier] = state
        }
        lock.unlock()
    }
}

/// An error raised by the host for a plugin request; its message is what the promise
/// rejects with.
public struct AorusPluginRequestError: Error {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
