import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aorus-plugin-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class LockedPluginHost: AorusPluginNullHost {
    override var pluginExecutionAllowed: Bool { false }
}

@main
private enum AorusPluginCoreTests {
static func main() {
expect(AorusPluginStore.normalizedIdentifier("../license") == nil, "path traversal id is rejected")
expect(AorusPluginStore.normalizedIdentifier(UUID().uuidString) != nil, "UUID id is accepted")
expect(AorusPluginSandbox.isBlocked(host: "ai.aorusgram.com"), "control-plane host is blocked")
expect(AorusPluginSandbox.isBlocked(host: "AI.AORUSGRAM.COM."), "control-plane host with a trailing dot is blocked")
expect(AorusPluginSandbox.isBlocked(host: "127.0.0.1"), "IPv4 loopback is blocked")
expect(AorusPluginSandbox.isBlocked(host: "::ffff:127.0.0.1"), "IPv4-mapped loopback is blocked")
expect(AorusPluginSandbox.isBlocked(host: "::127.0.0.1"), "IPv4-compatible loopback is blocked")
expect(AorusPluginSandbox.isBlocked(host: "fe80::1%en0"), "scoped IPv6 link-local address is blocked")
expect(AorusPluginSandbox.isBlocked(host: "2001:db8::1"), "IPv6 documentation range is blocked")
expect(AorusPluginSandbox.isBlocked(host: "service.local"), "local discovery host is blocked")
expect(!AorusPluginSandbox.isBlocked(host: "example.com"), "public host is not blocked syntactically")

let source = "aorus.http.fetch('https://example.com'); aorus.clipboard.read();"
let requested = AorusPluginPermission.requestedBySource(source)
expect(requested == [.network, .clipboardRead], "source capability scan is deterministic")
let integrationSource = "aorus.ui.definePages([]); aorus.integrations.settings.register({}); aorus.integrations.contextMenu.register({}); aorus.browser.open('https://example.com'); aorus.ai.ask('hello');"
expect(
    AorusPluginPermission.requestedBySource(integrationSource) == [.customUI, .settingsIntegration, .contextMenu, .inAppBrowser, .artificialIntelligence],
    "declarative integrations request every sensitive capability"
)
let linkIntegrationSource = "aorus.ui.definePages([{ id: 'web', title: 'Web', sections: [{ rows: [{ id: 'open', type: 'link', title: 'Open', url: 'https://example.com' }] }] }]);"
expect(AorusPluginPermission.requestedBySource(linkIntegrationSource).contains(.inAppBrowser), "link rows request browser permission")
let appIntegrationSource = "aorus.app.currentAccount(); aorus.app.openChat('me'); aorus.app.openURL('https://example.com'); aorus.app.share({ text: 'Hello' });"
expect(
    AorusPluginPermission.requestedBySource(appIntegrationSource) == [.accountProfile, .openChats, .dialogs, .inAppBrowser],
    "app integration aliases request their privileged capabilities"
)
let customizationSource = "aorus.features.list(); aorus.interface.set('compactTabBar', true); aorus.tabs.setVisible('wall', true); aorus.avatars.setSquare(true); aorus.wall.setEnabled(true); aorus.proxy.status();"
expect(
    AorusPluginPermission.requestedBySource(customizationSource) == [.appCustomization, .connectionControl],
    "app customization and connection control use separate explicit grants"
)
let telegramSource = "aorus.chats.history('me', { limit: 10 }); aorus.telegram.openLink('tg://resolve?domain=telegram');"
expect(
    AorusPluginPermission.requestedBySource(telegramSource) == [.messageHistory, .openChats],
    "Telegram history and native navigation use separate explicit grants"
)
let accountAndProxySource = "aorus.accounts.list(); aorus.accounts.switchTo('42'); aorus.telegramProxy.status(); aorus.telegramProxy.setEnabled(true);"
expect(
    AorusPluginPermission.requestedBySource(accountAndProxySource) == [.accountSwitching, .telegramProxy],
    "account switching and Telegram proxy management require separate grants"
)
expect(
    AorusPluginPermission.requestedBySource("aorus.messages.edit(ref, 'x'); aorus.messages.delete(ref); aorus.messages.forward(ref, '2'); aorus.messages.react(ref, '👍');") == [.manageMessages],
    "message mutation methods require the manage-messages grant"
)
// The consent sheet is built from the probe table, so a capability with no needle is one
// nobody is ever asked about and the plugin is therefore never granted — its calls fail
// silently forever. `aorus.ui.toast` was exactly that.
for permission in AorusPluginPermission.allCases {
    expect(
        AorusPluginPermission.sourceProbes.contains(where: { $0.0 == permission }),
        "permission \(permission.rawValue) has no way to be requested from a source"
    )
}
// And a needle that names an API the prelude does not publish can never match. The last
// component has to exist as a member of the public API, and a subscribed event has to be
// one the prelude accepts.
for (permission, needles) in AorusPluginPermission.sourceProbes {
    for needle in needles {
        if needle.hasPrefix("aorus.on(") || needle.hasPrefix("aorus.once(") {
            let quoted = needle.drop(while: { $0 != "'" && $0 != "\"" }).dropFirst()
            let event = String(quoted.prefix(while: { $0 != "'" && $0 != "\"" }))
            expect(
                AorusPluginPrelude.events.contains(event),
                "\(permission.rawValue) watches for an event the prelude does not accept: \(needle)"
            )
            continue
        }
        guard needle.hasPrefix("aorus.") else { continue }
        for member in needle.split(separator: ".").dropFirst() {
            expect(
                AorusPluginPrelude.source.contains("\(member):"),
                "\(permission.rawValue) watches for an API the prelude does not publish: \(needle)"
            )
        }
    }
}
// Fail-closed is only safe if it never fires on a working system: with the execution limit
// missing, no plugin starts at all and every screen still looks fine, which reads on a
// device as the whole feature being dead.
expect(AorusPluginSandbox.watchdogAvailable, "JavaScriptCore exposes the execution time limit")

// A `url:` key inside an http payload is not a request for the browser. Over-asking on the
// consent sheet is not the safe direction: it is how a person learns to grant the sheet
// without reading it.
let httpPayloadSource = "aorus.http.fetch('https://example.com', { method: 'POST', body: { url: 'https://example.com/callback' } });"
expect(
    AorusPluginPermission.requestedBySource(httpPayloadSource) == [.network],
    "a url named inside an http payload does not request the in-app browser"
)

let pageJSON = Data("""
[{"id":"main","title":"Main","sections":[{"rows":[{"id":"enabled","type":"toggle","title":"Enabled","value":true},{"id":"run","type":"button","title":"Run"}]}]}]
""".utf8)
expect(AorusPluginUIPage.validated(from: pageJSON)?.first?.sections.first?.rows.count == 2, "valid declarative page is accepted")
let duplicateRows = Data("""
[{"id":"main","title":"Main","sections":[{"rows":[{"id":"same","type":"text","title":"One"},{"id":"same","type":"text","title":"Two"}]}]}]
""".utf8)
expect(AorusPluginUIPage.validated(from: duplicateRows) == nil, "duplicate UI row identifiers are rejected")
let unsafeLinkPage = Data("[{\"id\":\"main\",\"title\":\"Main\",\"sections\":[{\"rows\":[{\"id\":\"open\",\"type\":\"link\",\"title\":\"Open\",\"url\":\"file:///private/data\"}]}]}]".utf8)
expect(AorusPluginUIPage.validated(from: unsafeLinkPage) == nil, "native page links reject non-web schemes")
let shortcutJSON = Data("[{\"id\":\"youtube\",\"title\":\"YouTube\",\"url\":\"https://youtube.com\"}]".utf8)
expect(AorusPluginSettingsShortcut.validated(from: shortcutJSON)?.count == 1, "valid settings shortcut is accepted")
let placedShortcutJSON = Data("[{\"id\":\"youtube\",\"title\":\"YouTube\",\"url\":\"https://youtube.com\",\"placement\":\"interface\"}]".utf8)
expect(AorusPluginSettingsShortcut.validated(from: placedShortcutJSON)?.first?.placement == "interface", "settings shortcut can choose its native destination")
let invalidPlacementJSON = Data("[{\"id\":\"wrong\",\"title\":\"Wrong\",\"url\":\"https://example.com\",\"placement\":\"license\"}]".utf8)
expect(AorusPluginSettingsShortcut.validated(from: invalidPlacementJSON) == nil, "plugins cannot inject into the license screen")
let settingSchema = AorusPluginSettingField.schema(from: [
    ["key": "__section_0", "type": "section", "title": "General"],
    ["key": "interval", "type": "slider", "title": "Interval", "min": 10, "max": 300, "step": 5],
    ["key": "accent", "type": "color", "title": "Accent"],
    ["key": "notes", "type": "textarea", "title": "Notes"],
    ["key": "reset", "type": "reset", "title": "Reset"],
])
expect(settingSchema.map { $0.kind } == [.section, .slider, .colorPicker, .multiline, .reset], "plugin setting sections support native controls")
let ambiguousShortcutJSON = Data("[{\"id\":\"bad\",\"title\":\"Bad\",\"pageId\":\"main\",\"url\":\"https://example.com\"}]".utf8)
expect(AorusPluginSettingsShortcut.validated(from: ambiguousShortcutJSON) == nil, "shortcut cannot mix page and URL destinations")
let unsafeShortcutJSON = Data("[{\"id\":\"bad\",\"title\":\"Bad\",\"url\":\"javascript:alert(1)\"}]".utf8)
expect(AorusPluginSettingsShortcut.validated(from: unsafeShortcutJSON) == nil, "settings shortcuts reject non-web schemes")

let root = temporaryDirectory()
defer { try? FileManager.default.removeItem(at: root) }
let store = AorusPluginStore(rootURL: root)
let manifest = AorusPluginManifest(name: "Test", summary: String(repeating: "x", count: 2_000), isEnabled: true, autostart: true)
let record = AorusPluginRecord(manifest: manifest, source: "console.log('ok');")
do {
    try store.save(record)
    expect(store.manifest(id: manifest.id)?.summary.count == 2_000, "long plugin description persists without truncation")
    let digest = AorusPluginStore.sourceDigest(record.source)
    try store.setPermissionState(AorusPluginPermissionState(sourceDigest: digest, granted: [.network]), for: manifest.id)
    let schema = [AorusPluginSettingField(key: "enabled", kind: .toggle, title: "Enabled", defaultValue: .bool(true))]
    try store.setSchema(schema, sourceDigest: digest, for: manifest.id)
    expect(store.permissionState(for: manifest.id).granted == [.network], "permission state persists")
    expect(store.schema(for: manifest.id, source: record.source) == schema, "settings schema persists for the source revision")
    var changed = record
    changed.source = "console.log('changed');"
    try store.save(changed)
    expect(store.permissionState(for: manifest.id).granted.isEmpty, "source change revokes permission grants")
    expect(store.schema(for: manifest.id, source: changed.source).isEmpty, "source change revokes the stale settings schema")
    expect(store.manifest(id: manifest.id)?.isEnabled == false, "source change disables the plugin")
} catch {
    expect(false, "store operations failed: \(error)")
}

do {
    let original = AorusPluginRecord(manifest: AorusPluginManifest(name: "Exported", isEnabled: true, autostart: true), source: "console.log('bundle');")
    try store.save(original)
    try store.setSettings(["privateToken": .string("must-not-leave-device")], for: original.manifest.id)
    let data = store.export(id: original.manifest.id)!
    let exportedText = String(decoding: data, as: UTF8.self)
    expect(!exportedText.contains("must-not-leave-device"), "exports exclude installation-owned settings")
    let imported = try store.importPlugin(data: data)
    expect(!imported.isEnabled && !imported.autostart, "imported plugin starts disabled without autostart")
    expect(store.permissionState(for: imported.id).granted.isEmpty, "exports never carry permission grants")
} catch {
    expect(false, "import/export failed: \(error)")
}

let oversized = Data(repeating: 0x61, count: AorusPluginStore.importLimitBytes + 1)
do {
    _ = try store.importPlugin(data: oversized)
    expect(false, "oversized import must fail")
} catch AorusPluginStoreError.sourceLimit {
    // Expected.
} catch {
    expect(false, "oversized import failed with wrong error: \(error)")
}

let diagnostics = AorusPluginSandbox.checkSyntax("function () {")
expect(!diagnostics.isEmpty, "invalid JavaScript is diagnosed")
let tokens = AorusJavaScriptTokenizer.tokenize("const x = aorus.storage.get('x');")
expect(tokens.contains(where: { $0.kind == .keyword }), "tokenizer finds keywords")
expect(tokens.contains(where: { $0.kind == .api }), "tokenizer finds plugin API")

if AorusPluginSandbox.watchdogAvailable {
    let host = AorusPluginNullHost()
    var sendCount = 0
    host.onSendMessage = { _, _, _, _, _, _ in sendCount += 1 }
    let deniedSource = "aorus.on('start', function () { aorus.messages.send('me', 'blocked').catch(function () {}); });"
    let deniedManifest = AorusPluginManifest(name: "Denied")
    let denied = AorusPluginSandbox(manifest: deniedManifest, source: deniedSource, host: host, permissions: [])
    let started = DispatchSemaphore(value: 0)
    denied.start { error in expect(error == nil, "sandbox starts valid source"); started.signal() }
    _ = started.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.1)
    expect(sendCount == 0, "ungranted message permission never reaches the host")
    denied.stop()

    let exactHost = AorusPluginNullHost()
    var receivedPeerId: Int64?
    var receivedAccountId: Int64?
    exactHost.onSendMessage = { _, peerId, _, accountId, _, _ in
        receivedPeerId = peerId
        receivedAccountId = accountId
    }
    let exactSource = "aorus.on('start', function () { aorus.messages.send('-1009876543210123', 'exact', { accountId: '9223372036854775000' }); });"
    let exactManifest = AorusPluginManifest(name: "Exact IDs")
    let exact = AorusPluginSandbox(manifest: exactManifest, source: exactSource, host: exactHost, permissions: [.sendMessages])
    let exactStarted = DispatchSemaphore(value: 0)
    exact.start { error in expect(error == nil, "sandbox starts exact-id source"); exactStarted.signal() }
    _ = exactStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.1)
    expect(receivedPeerId == -1_009_876_543_210_123, "64-bit peer id reaches the host without JavaScript precision loss")
    expect(receivedAccountId == 9_223_372_036_854_775_000, "64-bit account id reaches the host without JavaScript precision loss")
    exact.stop()

    let eventHost = AorusPluginNullHost()
    var eventStorage: [String: AorusPluginJSONValue] = [:]
    eventHost.onStorageChanged = { _, values in eventStorage = values }
    let eventSource = """
    aorus.on('messageDeleted', function (event) { aorus.storage.set('deleted', event.msgId); });
    aorus.on('messageEdited', function (event) { aorus.storage.set('edited', event.text); });
    """
    let events = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Message events"),
        source: eventSource,
        host: eventHost,
        permissions: [.incomingMessages]
    )
    let eventsStarted = DispatchSemaphore(value: 0)
    events.start { error in expect(error == nil, "message event plugin starts"); eventsStarted.signal() }
    _ = eventsStarted.wait(timeout: .now() + 2)
    events.dispatch(event: "messageDeleted", payload: ["msgId": 42])
    events.dispatch(event: "messageEdited", payload: ["text": "updated"])
    Thread.sleep(forTimeInterval: 0.1)
    expect(eventStorage["deleted"] == .number(42), "delete events reach a plugin with message permission")
    expect(eventStorage["edited"] == .string("updated"), "edit events reach a plugin with message permission")
    events.stop()

    let deniedEventHost = AorusPluginNullHost()
    var deniedEventWrites = 0
    deniedEventHost.onStorageChanged = { _, _ in deniedEventWrites += 1 }
    let deniedEvents = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Denied message events"),
        source: eventSource,
        host: deniedEventHost,
        permissions: []
    )
    let deniedEventsStarted = DispatchSemaphore(value: 0)
    deniedEvents.start { error in expect(error == nil, "denied event plugin still starts safely"); deniedEventsStarted.signal() }
    _ = deniedEventsStarted.wait(timeout: .now() + 2)
    deniedEvents.dispatch(event: "messageEdited", payload: ["text": "blocked"])
    Thread.sleep(forTimeInterval: 0.1)
    expect(deniedEventWrites == 0, "message events do not cross the sandbox without permission")
    deniedEvents.stop()

    let commandSource = "aorus.commands.register('r', function (args) { return args.toUpperCase(); });"
    let command = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Command"),
        source: commandSource,
        host: AorusPluginNullHost(),
        permissions: [.outgoingMessages]
    )
    let commandStarted = DispatchSemaphore(value: 0)
    command.start { error in expect(error == nil, "command plugin starts"); commandStarted.signal() }
    _ = commandStarted.wait(timeout: .now() + 2)
    let verdict = command.processOutgoing(text: ".r hello", peerId: 100, accountId: 200, timeout: 0.5)
    expect(!verdict.consumed && verdict.replacement == "HELLO", "chat command replaces outgoing text")
    command.stop()

    let asyncHost = AorusPluginNullHost()
    var translatedMessages: [String] = []
    let translated = DispatchSemaphore(value: 0)
    asyncHost.onAIAsk = { _, prompt, _ in ["text": "Translated: \(prompt)", "artifacts": []] }
    asyncHost.onSendMessage = { _, _, _, _, text, _ in translatedMessages.append(text); translated.signal() }
    let asyncCommand = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Translate command"),
        source: """
        aorus.commands.register('tr', async function (args, context) {
            var answer = await aorus.ai.ask(args, { onEvent: function (event) {
                if (event.type === 'status') { aorus.storage.set('phase', event.label); }
            }});
            return answer.text;
        });
        """,
        host: asyncHost,
        permissions: [.outgoingMessages, .artificialIntelligence, .sendMessages]
    )
    let asyncStarted = DispatchSemaphore(value: 0)
    asyncCommand.start { error in expect(error == nil, "async command starts"); asyncStarted.signal() }
    _ = asyncStarted.wait(timeout: .now() + 2)
    let asyncVerdict = asyncCommand.processOutgoing(text: ".tr hello", peerId: 100, accountId: 200, timeout: 0.5)
    expect(asyncVerdict.consumed, "async command consumes original text before Telegram enqueue")
    expect(translated.wait(timeout: .now() + 2) == .success, "async command completes its send")
    expect(translatedMessages == ["Translated: hello"], "async AI command sends the answer exactly once")
    expect(asyncCommand.storageSnapshot["phase"]?.stringValue == "Working", "AI progress events reach the plugin")
    asyncCommand.stop()

    let integrationHost = AorusPluginNullHost()
    var receivedPages: [AorusPluginUIPage] = []
    var receivedShortcuts: [AorusPluginSettingsShortcut] = []
    var receivedActions: [AorusPluginContextAction] = []
    var openedPageStyle: String?
    var sharedText: String?
    integrationHost.onPagesChanged = { _, pages in receivedPages = pages }
    integrationHost.onSettingsShortcutsChanged = { _, shortcuts in receivedShortcuts = shortcuts }
    integrationHost.onContextActionsChanged = { _, actions in receivedActions = actions }
    integrationHost.onOpenPage = { _, _, style in openedPageStyle = style }
    integrationHost.onShare = { _, text, _ in sharedText = text }
    let integrationRuntimeSource = """
    var page = aorus.ui.createPage({ id: 'main', title: 'Main' });
    page.section({ title: 'Controls' })
        .button({ id: 'run', title: 'Run' })
        .slider({ id: 'level', title: 'Level', min: 0, max: 10, step: 1, value: 5 })
        .end()
        .publish();
    page.open({ style: 'sheet' });
    aorus.integrations.settings.register({ id: 'main', title: 'Plugin tools', pageId: 'main' });
    aorus.integrations.contextMenu.register({ id: 'reply', title: 'Prepare reply', icon: 'message.fill' });
    aorus.app.share('Prepared securely');
    """
    let integration = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Integrations"),
        source: integrationRuntimeSource,
        host: integrationHost,
        permissions: [.customUI, .settingsIntegration, .contextMenu, .dialogs]
    )
    let integrationStarted = DispatchSemaphore(value: 0)
    integration.start { error in expect(error == nil, "integration plugin starts"); integrationStarted.signal() }
    _ = integrationStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.1)
    expect(receivedPages.first?.id == "main", "JavaScript page definition reaches the native host")
    expect(receivedPages.first?.sections.first?.rows.last?.kind == .slider, "native UI builder publishes advanced controls")
    expect(openedPageStyle == "sheet", "native UI builder preserves modal presentation style")
    expect(receivedShortcuts.first?.pageId == "main", "JavaScript settings shortcut reaches the native host")
    expect(receivedActions.first?.id == "reply", "JavaScript context action reaches the native host")
    expect(sharedText == "Prepared securely", "native share broker reaches the host without exposing UIApplication")
    integration.stop()

    let linkHost = AorusPluginNullHost()
    var linkedShortcuts: [AorusPluginSettingsShortcut] = []
    linkHost.onSettingsShortcutsChanged = { _, value in linkedShortcuts = value }
    let linkSource = "aorus.integrations.settings.register({ id: 'youtube', title: 'YouTube', icon: 'play.rectangle.fill', url: 'https://youtube.com', placement: 'interface' });"
    expect(AorusPluginPermission.requestedBySource(linkSource).contains(.inAppBrowser), "settings link requests browser permission during review")
    let link = AorusPluginSandbox(manifest: AorusPluginManifest(name: "YouTube"), source: linkSource, host: linkHost, permissions: [.settingsIntegration, .inAppBrowser])
    let linkStarted = DispatchSemaphore(value: 0)
    link.start { error in expect(error == nil, "documented URL shortcut starts with reviewed permissions"); linkStarted.signal() }
    _ = linkStarted.wait(timeout: .now() + 2)
    expect(linkedShortcuts.first?.placement == "interface", "URL shortcut reaches its chosen section")
    link.stop()

    let settingsHost = AorusPluginNullHost()
    var declaredSettings: [AorusPluginSettingField] = []
    settingsHost.onSettingsSchemaChanged = { _, fields in declaredSettings = fields }
    let settingsPlugin = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Settings form"),
        source: "aorus.settings.addSection({ title: 'General', items: [{ key: 'delay', type: 'slider', title: 'Delay', min: 1, max: 10, default: 3 }] });",
        host: settingsHost
    )
    let settingsStarted = DispatchSemaphore(value: 0)
    settingsPlugin.start { error in expect(error == nil, "settings form plugin starts"); settingsStarted.signal() }
    _ = settingsStarted.wait(timeout: .now() + 2)
    expect(declaredSettings.map { $0.kind } == [.section, .slider], "addSection publishes its native settings controls")
    settingsPlugin.stop()

    let customizationHost = AorusPluginNullHost()
    var changedFeature: String?
    var changedFeatureValue: Bool?
    var changedProxyPreference: String?
    customizationHost.onAppFeatures = { _ in
        [["id": "squareAvatars", "category": "interface", "type": "toggle", "value": false]]
    }
    customizationHost.onSetAppFeature = { _, id, value in
        changedFeature = id
        changedFeatureValue = (value as? NSNumber)?.boolValue
        return ["id": id, "category": "interface", "type": "toggle", "value": value]
    }
    customizationHost.onProxyStatus = { _ in
        ["enabled": true, "stableCalls": true, "connected": true, "servers": []]
    }
    customizationHost.onSetProxyPreference = { _, key, value in
        changedProxyPreference = "\(key):\(value)"
        return ["enabled": value, "stableCalls": true, "connected": false, "servers": []]
    }
    let customization = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Customization"),
        source: """
        aorus.on('start', function () {
            aorus.features.list().then(function (items) { return aorus.interface.set(items[0].id, true); });
            aorus.proxy.status().then(function () { return aorus.proxy.setEnabled(false); });
        });
        """,
        host: customizationHost,
        permissions: [.appCustomization, .connectionControl]
    )
    let customizationStarted = DispatchSemaphore(value: 0)
    customization.start { error in expect(error == nil, "customization plugin starts"); customizationStarted.signal() }
    _ = customizationStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(changedFeature == "squareAvatars" && changedFeatureValue == true, "feature changes cross only the typed broker")
    expect(changedProxyPreference == "enabled:false", "proxy changes cross only the preference broker")
    customization.stop()

    let telegramHost = AorusPluginNullHost()
    var requestedHistoryLimit: Int?
    var openedTelegramURL: String?
    telegramHost.onChatHistory = { _, _, toSelf, limit in
        requestedHistoryLimit = toSelf ? limit : nil
        return [["id": 7, "peerId": "1", "text": "hello", "incoming": true]]
    }
    telegramHost.onOpenTelegramLink = { _, url in openedTelegramURL = url }
    let telegram = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Telegram"),
        source: """
        aorus.on('start', async function () {
            const items = await aorus.chats.history('me', { limit: 12 });
            if (items.length === 1) { await aorus.telegram.openLink('tg://resolve?domain=telegram'); }
        });
        """,
        host: telegramHost,
        permissions: [.messageHistory, .openChats]
    )
    let telegramStarted = DispatchSemaphore(value: 0)
    telegram.start { error in expect(error == nil, "Telegram plugin starts"); telegramStarted.signal() }
    _ = telegramStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(requestedHistoryLimit == 12, "history request preserves Saved Messages and bounded limit")
    expect(openedTelegramURL == "tg://resolve?domain=telegram", "Telegram links cross only the native navigation broker")
    telegram.stop()

    let accountProxyHost = AorusPluginNullHost()
    var switchedAccount: Int64?
    accountProxyHost.onAccounts = { _ in [["id": "42", "peerId": "100", "title": "Work", "current": false]] }
    accountProxyHost.onSwitchAccount = { _, accountId in switchedAccount = accountId }
    accountProxyHost.onTelegramProxyStatus = { _ in
        ["enabled": true, "useForCalls": false, "servers": [["index": 0, "host": "proxy.example", "port": 443, "type": "mtp", "active": true, "hasCredentials": true]]]
    }
    let accountProxy = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Accounts and proxy"),
        source: """
        aorus.on('start', async function () {
            const accounts = await aorus.accounts.list();
            if (accounts.length === 1) { await aorus.accounts.switchTo(accounts[0].id); }
            const status = await aorus.telegramProxy.status();
            if (status.servers.length === 1) { await aorus.telegramProxy.setUseForCalls(true); }
        });
        """,
        host: accountProxyHost,
        permissions: [.accountSwitching, .telegramProxy]
    )
    let accountProxyStarted = DispatchSemaphore(value: 0)
    accountProxy.start { error in expect(error == nil, "account and proxy plugin starts"); accountProxyStarted.signal() }
    _ = accountProxyStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(switchedAccount == 42, "account switch accepts only a decimal local account identifier")
    accountProxy.stop()

    let messageActionHost = AorusPluginNullHost()
    var messageActions: [String] = []
    messageActionHost.onMessageAction = { _, action, peerId, namespace, messageId in
        messageActions.append("\(action):\(peerId):\(namespace):\(messageId)")
    }
    let messageActionsPlugin = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Message actions"),
        source: """
        aorus.on('start', async function () {
            const ref = { peerId: '100', namespace: 0, messageId: 7 };
            await aorus.messages.edit(ref, 'updated');
            await aorus.messages.delete(ref, { forEveryone: false });
            await aorus.messages.forward(ref, '200');
            await aorus.messages.react(ref, '👍');
        });
        """,
        host: messageActionHost,
        permissions: [.manageMessages]
    )
    let messageActionsStarted = DispatchSemaphore(value: 0)
    messageActionsPlugin.start { error in expect(error == nil, "message actions plugin starts"); messageActionsStarted.signal() }
    _ = messageActionsStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.8)
    expect(messageActions == ["edit:100:0:7", "delete:100:0:7", "forward:100:0:7", "react:100:0:7"], "message actions cross only the typed native broker")
    messageActionsPlugin.stop()

    let deniedIntegrationHost = AorusPluginNullHost()
    var deniedIntegrationCalls = 0
    deniedIntegrationHost.onPagesChanged = { _, _ in deniedIntegrationCalls += 1 }
    deniedIntegrationHost.onSettingsShortcutsChanged = { _, _ in deniedIntegrationCalls += 1 }
    deniedIntegrationHost.onContextActionsChanged = { _, _ in deniedIntegrationCalls += 1 }
    let deniedIntegration = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Denied integrations"),
        source: integrationRuntimeSource,
        host: deniedIntegrationHost,
        permissions: []
    )
    let deniedIntegrationStarted = DispatchSemaphore(value: 0)
    deniedIntegration.start { error in expect(error != nil, "integration source fails closed without permissions"); deniedIntegrationStarted.signal() }
    _ = deniedIntegrationStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.1)
    expect(deniedIntegrationCalls == 0, "ungranted integration permissions never reach the native host")
    deniedIntegration.stop()

    let lockedHost = LockedPluginHost()
    var lockedShareCalls = 0
    lockedHost.onShare = { _, _, _ in lockedShareCalls += 1 }
    let lockedSandbox = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Locked"),
        source: "aorus.on('start', function () { aorus.app.share('blocked').catch(function () {}); });",
        host: lockedHost,
        permissions: [.dialogs]
    )
    let lockedStarted = DispatchSemaphore(value: 0)
    lockedSandbox.start { _ in lockedStarted.signal() }
    _ = lockedStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.1)
    expect(lockedShareCalls == 0, "host execution lock blocks privileged broker calls")
    lockedSandbox.stop()

    let aiHost = AorusPluginNullHost()
    var aiPrompt: String?
    var aiLog: String?
    aiHost.onAIAsk = { _, prompt, history in
        aiPrompt = prompt
        return ["text": "Answer", "artifacts": [], "historyCount": history.count]
    }
    aiHost.onLog = { _, _, text in aiLog = text }
    let aiSource = """
    var chat = aorus.ai.createChat();
    aorus.on('start', async function () {
        var answer = await chat.ask('Question');
        console.log(answer.text);
    });
    """
    let ai = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "AI chat"),
        source: aiSource,
        host: aiHost,
        permissions: [.artificialIntelligence]
    )
    let aiStarted = DispatchSemaphore(value: 0)
    ai.start { error in expect(error == nil, "AI chat plugin starts"); aiStarted.signal() }
    _ = aiStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(aiPrompt == "Question", "AorusAI chat sends the plugin question through the host")
    expect(aiLog == "Answer", "AorusAI chat resolves the assistant response")
    ai.stop()

    // A plugin that once failed to answer the outgoing hook in time used to be shut out of
    // every event for the rest of the session: the flag never cleared and `deliver` dropped
    // on it. One slow millisecond and every button the plugin registered stopped working,
    // with nothing on screen to say so. A timeout is now a cooldown on the synchronous hook
    // alone, and events keep arriving throughout.
    let slowHost = AorusPluginNullHost()
    var slowActions = 0
    slowHost.onToast = { _, _ in slowActions += 1 }
    let slowSource = """
    aorus.on('send', function () {
        var until = Date.now() + 400;
        while (Date.now() < until) {}
        return false;
    });
    aorus.on('uiAction', function () { aorus.ui.toast('acted'); });
    """
    let slow = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Slow hook"),
        source: slowSource,
        host: slowHost,
        permissions: [.outgoingMessages, .dialogs]
    )
    let slowStarted = DispatchSemaphore(value: 0)
    slow.start { error in expect(error == nil, "slow plugin starts"); slowStarted.signal() }
    _ = slowStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.1)
    expect(slow.hasOutgoingHooks, "a send handler registers an outgoing hook")
    let slowVerdict = slow.processOutgoing(text: "hello", peerId: 1, accountId: 1, timeout: 0.05)
    expect(slowVerdict.timedOut, "a handler over its budget reports a timeout")
    expect(slow.isHung, "a timed-out plugin is cooling down")
    expect(!slow.hasOutgoingHooks, "a cooling plugin is skipped by the send path")
    slow.dispatch(event: "uiAction", payload: ["pageId": "p", "rowId": "r"])
    Thread.sleep(forTimeInterval: 0.6)
    expect(slowActions == 1, "events are still delivered while the outgoing hook is cooling down")
    expect(slow.registration().commands.isEmpty, "a send handler is not a command")
    slow.stop()

    // Formatted text. Telegram counts entity offsets in UTF-16 code units, which is not
    // what a character count gives once an emoji is in the string — get it wrong and the
    // formatting lands on the wrong characters instead of failing, so the offsets are
    // checked against a string that has one.
    let formatHost = AorusPluginNullHost()
    var sentText: String?
    var sentEntities: [AorusPluginTextEntity] = []
    formatHost.onSendMessage = { _, _, _, _, text, _ in sentText = text }
    formatHost.onSendEntities = { _, entities in sentEntities = entities }
    let formatSource = """
    aorus.on('start', function () {
        var payload = aorus.text.compose([
            '💎 ', aorus.text.bold('жирный'), ' ',
            aorus.text.link('сайт', 'https://example.com'), ' ',
            aorus.text.customEmoji('🔥', '5234567890'), ' ',
            aorus.text.pre('code()', 'swift')
        ]);
        aorus.messages.send('me', payload);
    });
    """
    let format = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Formatting"),
        source: formatSource,
        host: formatHost,
        permissions: [.sendMessages]
    )
    let formatStarted = DispatchSemaphore(value: 0)
    format.start { error in expect(error == nil, "formatting plugin starts"); formatStarted.signal() }
    _ = formatStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(sentText == "💎 жирный сайт 🔥 code()", "compose joins the parts in order")
    expect(sentEntities.count == 4, "every styled part becomes an entity")
    if sentEntities.count == 4 {
        let utf16 = Array((sentText ?? "").utf16)
        expect(sentEntities[0].kind == .bold, "the first entity is the bold run")
        // "💎 " is three UTF-16 units, not two: the diamond is a surrogate pair.
        expect(sentEntities[0].offset == 3, "an emoji before the run is counted in UTF-16 units")
        expect(sentEntities[0].length == 6, "the bold run covers exactly its own text")
        let boldUnits = Array(utf16[sentEntities[0].offset ..< (sentEntities[0].offset + sentEntities[0].length)])
        expect(String(utf16CodeUnits: boldUnits, count: boldUnits.count) == "жирный", "the bold range lands on the bold text")
        expect(sentEntities[1].kind == .textLink && sentEntities[1].url == "https://example.com", "a link carries its url")
        expect(sentEntities[2].kind == .customEmoji && sentEntities[2].customEmojiId == 5_234_567_890, "a custom emoji carries its numeric id")
        expect(sentEntities[3].kind == .pre && sentEntities[3].language == "swift", "a pre block carries its language")
    }
    format.stop()

    // Everything a plugin can get wrong in an entity is dropped rather than shifting the
    // rest of the formatting: a range past the end, a link that is not a web link, an
    // emoji id that is not a number, a type nobody knows.
    let rejected = AorusPluginTextEntity.validated([
        ["type": "bold", "offset": NSNumber(value: 0), "length": NSNumber(value: 4)],
        ["type": "bold", "offset": NSNumber(value: 3), "length": NSNumber(value: 99)],
        ["type": "text_link", "offset": NSNumber(value: 0), "length": NSNumber(value: 2), "url": "file:///etc/passwd"],
        ["type": "custom_emoji", "offset": NSNumber(value: 0), "length": NSNumber(value: 2), "customEmojiId": "not-a-number"],
        ["type": "rainbow", "offset": NSNumber(value: 0), "length": NSNumber(value: 2)],
        ["type": "italic", "offset": NSNumber(value: -1), "length": NSNumber(value: 2)]
    ], text: "abcd")
    expect(rejected.count == 1 && rejected[0].kind == .bold, "only the entity that fits the text survives validation")

    // The open chat. Reading the title is chat metadata; the composer is a grant of its own,
    // because what someone has typed and not sent is not the same fact as which chat is open.
    expect(
        AorusPluginPermission.requestedBySource("aorus.chat.current(); aorus.chat.messages({ limit: 10 });") == [.chatMetadata],
        "reading the open chat is chat metadata"
    )
    expect(
        AorusPluginPermission.requestedBySource("aorus.chat.draft(); aorus.chat.setDraft('x'); aorus.chat.scrollTo(5);") == [.composer],
        "the composer is its own grant, and setDraft is not a draft read"
    )
    expect(
        AorusPluginPermission.requestedBySource("aorus.on('inputChanged', function () {});") == [.composer],
        "watching someone type asks for the composer"
    )

    // Nothing is open between chats, and that is the answer rather than the chat that was
    // open a moment ago. `current()` says so with null, because "is a chat open?" has to be
    // answerable; every call that would act on a chat refuses.
    let noChatHost = AorusPluginNullHost()
    var noChatResults: [String: AorusPluginJSONValue] = [:]
    noChatHost.onStorageChanged = { _, values in noChatResults = values }
    let noChatSource = """
    aorus.on('start', function () {
        aorus.chat.current().then(function (chat) { aorus.storage.set('current', chat === null ? 'null' : 'chat'); });
        aorus.chat.setDraft('hi').then(
            function () { aorus.storage.set('write', 'allowed'); },
            function (error) { aorus.storage.set('write', String(error.message || error)); }
        );
    });
    """
    let noChat = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "No chat"),
        source: noChatSource,
        host: noChatHost,
        permissions: [.chatMetadata, .composer]
    )
    let noChatStarted = DispatchSemaphore(value: 0)
    noChat.start { error in expect(error == nil, "chat plugin starts with no chat open"); noChatStarted.signal() }
    _ = noChatStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(noChatResults["current"] == .string("null"), "with no chat open, current() answers null")
    expect(noChatResults["write"] == .string(AorusPluginSandbox.noChatOpen), "with no chat open, writing the composer is refused")
    noChat.stop()

    // With a chat open, every call reaches the host with exactly what the script passed.
    let openChatHost = AorusPluginNullHost()
    var chatDraftWrites: [(String, String)] = []
    var chatTyping: Bool?
    var chatMarkedRead = 0
    var chatScrolledTo: Int32?
    var chatMessageLimit: Int?
    openChatHost.onCurrentChat = { _ in ["peerId": "-1001234567890", "title": "Team", "kind": "group", "threadId": "77"] }
    openChatHost.onCurrentChatDraft = { _ in "draft so far" }
    openChatHost.onSetCurrentChatDraft = { _, text, mode in chatDraftWrites.append((mode, text)) }
    openChatHost.onCurrentChatMessages = { _, limit in
        chatMessageLimit = limit
        return [["id": NSNumber(value: 5), "text": "hello"]]
    }
    openChatHost.onCurrentChatTyping = { _, enabled in chatTyping = enabled }
    openChatHost.onCurrentChatMarkRead = { _ in chatMarkedRead += 1 }
    openChatHost.onCurrentChatScrollTo = { _, messageId in chatScrolledTo = messageId }
    var chatResults: [String: AorusPluginJSONValue] = [:]
    openChatHost.onStorageChanged = { _, values in chatResults = values }
    let openChatSource = """
    aorus.on('start', function () {
        aorus.chat.current().then(function (chat) { aorus.storage.set('chat', chat.title + '/' + chat.kind + '/' + chat.threadId + '/' + chat.peerId); });
        aorus.chat.draft().then(function (text) { aorus.storage.set('draft', text); });
        aorus.chat.setDraft('replaced');
        aorus.chat.insert(' more');
        aorus.chat.clear();
        aorus.chat.messages({ limit: 7 }).then(function (items) { aorus.storage.set('messages', items.length + ':' + items[0].text); });
        aorus.chat.setTyping(true);
        aorus.chat.markRead();
        aorus.chat.scrollTo({ id: 4321 });
    });
    """
    let openChat = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Open chat"),
        source: openChatSource,
        host: openChatHost,
        permissions: [.chatMetadata, .composer]
    )
    let openChatStarted = DispatchSemaphore(value: 0)
    openChat.start { error in expect(error == nil, "chat plugin starts with a chat open"); openChatStarted.signal() }
    _ = openChatStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.3)
    expect(chatResults["chat"] == .string("Team/group/77/-1001234567890"), "current() carries title, kind, thread and a 64-bit peer id")
    expect(chatResults["draft"] == .string("draft so far"), "draft() reads the composer")
    expect(chatDraftWrites.map { $0.0 } == ["set", "insert", "clear"], "set, insert and clear reach the host as distinct modes in order")
    expect(chatDraftWrites.count == 3 && chatDraftWrites[0].1 == "replaced", "setDraft carries its text")
    expect(chatDraftWrites.count == 3 && chatDraftWrites[1].1 == " more", "insert carries its text")
    expect(chatDraftWrites.count == 3 && chatDraftWrites[2].1 == "", "clear carries no text")
    expect(chatMessageLimit == 7, "messages() passes the limit it was given")
    expect(chatResults["messages"] == .string("1:hello"), "messages() returns what the host gave")
    expect(chatTyping == true, "setTyping reaches the host")
    expect(chatMarkedRead == 1, "markRead reaches the host")
    expect(chatScrolledTo == 4321, "scrollTo accepts a message object and passes its id")
    openChat.stop()

    // A grant for one half is not a grant for the other.
    let halfChatHost = AorusPluginNullHost()
    var halfChatWrites = 0
    halfChatHost.onCurrentChat = { _ in ["peerId": "1", "title": "Someone", "kind": "user"] }
    halfChatHost.onSetCurrentChatDraft = { _, _, _ in halfChatWrites += 1 }
    var halfChatResults: [String: AorusPluginJSONValue] = [:]
    halfChatHost.onStorageChanged = { _, values in halfChatResults = values }
    let halfChatSource = """
    aorus.on('start', function () {
        aorus.chat.setDraft('x').then(
            function () { aorus.storage.set('write', 'allowed'); },
            function (error) { aorus.storage.set('write', String(error.message || error)); }
        );
        aorus.chat.current().then(
            function () { aorus.storage.set('read', 'allowed'); },
            function (error) { aorus.storage.set('read', String(error.message || error)); }
        );
    });
    """
    let halfChat = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Read only chat"),
        source: halfChatSource,
        host: halfChatHost,
        permissions: [.chatMetadata]
    )
    let halfChatStarted = DispatchSemaphore(value: 0)
    halfChat.start { error in expect(error == nil, "read-only chat plugin starts"); halfChatStarted.signal() }
    _ = halfChatStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(halfChatWrites == 0, "an ungranted composer write never reaches the host")
    expect(halfChatResults["write"] == .string("Permission not granted: composer"), "the refusal names the permission that was missing")
    expect(halfChatResults["read"] == .string("allowed"), "chat metadata still answers")
    halfChat.stop()

    // The three chat events, and the two grants that carry them.
    let chatEventHost = AorusPluginNullHost()
    var chatEventValues: [String: AorusPluginJSONValue] = [:]
    chatEventHost.onStorageChanged = { _, values in chatEventValues = values }
    let chatEventSource = """
    aorus.on('chatOpened', function (event) { aorus.storage.set('opened', event.title); });
    aorus.on('chatClosed', function () { aorus.storage.set('closed', 'yes'); });
    aorus.on('inputChanged', function (event) { aorus.storage.set('input', event.source + ':' + event.text); });
    """
    let chatEvents = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Chat events"),
        source: chatEventSource,
        host: chatEventHost,
        permissions: [.chatMetadata, .composer]
    )
    let chatEventsStarted = DispatchSemaphore(value: 0)
    chatEvents.start { error in expect(error == nil, "chat event plugin starts"); chatEventsStarted.signal() }
    _ = chatEventsStarted.wait(timeout: .now() + 2)
    chatEvents.dispatch(event: "chatOpened", payload: ["peerId": "5", "title": "Team", "kind": "group"])
    chatEvents.dispatch(event: "chatClosed", payload: ["peerId": "5"])
    chatEvents.dispatch(event: "inputChanged", payload: ["text": "hi", "source": "user"])
    Thread.sleep(forTimeInterval: 0.2)
    expect(chatEventValues["opened"] == .string("Team"), "chatOpened carries the chat it opened")
    expect(chatEventValues["closed"] == .string("yes"), "chatClosed is delivered")
    expect(chatEventValues["input"] == .string("user:hi"), "inputChanged carries the text and what caused it")
    chatEvents.stop()

    let deniedChatEventHost = AorusPluginNullHost()
    var deniedChatEventWrites = 0
    deniedChatEventHost.onStorageChanged = { _, _ in deniedChatEventWrites += 1 }
    let deniedChatEvents = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Denied chat events"),
        source: chatEventSource,
        host: deniedChatEventHost,
        permissions: []
    )
    let deniedChatEventsStarted = DispatchSemaphore(value: 0)
    deniedChatEvents.start { error in expect(error == nil, "denied chat event plugin still starts"); deniedChatEventsStarted.signal() }
    _ = deniedChatEventsStarted.wait(timeout: .now() + 2)
    deniedChatEvents.dispatch(event: "chatOpened", payload: ["peerId": "5", "title": "Team", "kind": "group"])
    deniedChatEvents.dispatch(event: "chatClosed", payload: ["peerId": "5"])
    deniedChatEvents.dispatch(event: "inputChanged", payload: ["text": "hi", "source": "user"])
    Thread.sleep(forTimeInterval: 0.2)
    expect(deniedChatEventWrites == 0, "no chat event reaches a plugin that was granted neither")
    deniedChatEvents.stop()

    // Bad arguments are refused in JavaScript, before anything crosses the boundary.
    let chatArgHost = AorusPluginNullHost()
    var chatArgReached = 0
    chatArgHost.onCurrentChatScrollTo = { _, _ in chatArgReached += 1 }
    chatArgHost.onCurrentChatTyping = { _, _ in chatArgReached += 1 }
    chatArgHost.onCurrentChatMessages = { _, _ in chatArgReached += 1; return [] }
    var chatArgResults: [String: AorusPluginJSONValue] = [:]
    chatArgHost.onStorageChanged = { _, values in chatArgResults = values }
    let chatArgSource = """
    aorus.on('start', function () {
        try { aorus.chat.scrollTo('abc'); } catch (error) { aorus.storage.set('scroll', 'rejected'); }
        try { aorus.chat.messages({ limit: 500 }); } catch (error) { aorus.storage.set('limit', 'rejected'); }
        try { aorus.chat.setTyping('yes'); } catch (error) { aorus.storage.set('typing', 'rejected'); }
    });
    """
    let chatArgs = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Chat arguments"),
        source: chatArgSource,
        host: chatArgHost,
        permissions: [.chatMetadata, .composer]
    )
    let chatArgsStarted = DispatchSemaphore(value: 0)
    chatArgs.start { error in expect(error == nil, "chat argument plugin starts"); chatArgsStarted.signal() }
    _ = chatArgsStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(chatArgResults["scroll"] == .string("rejected"), "scrollTo rejects something that is not a message id")
    expect(chatArgResults["limit"] == .string("rejected"), "messages() rejects a limit outside the range")
    expect(chatArgResults["typing"] == .string("rejected"), "setTyping rejects a value that is not a boolean")
    expect(chatArgReached == 0, "a rejected argument never reaches the host")
    chatArgs.stop()

    // The plugin's own files, end to end through JavaScript.
    let fileHost = AorusPluginNullHost()
    var fileResults: [String: AorusPluginJSONValue] = [:]
    fileHost.onStorageChanged = { _, values in fileResults = values }
    let fileDirectory = temporaryDirectory().appendingPathComponent("files", isDirectory: true)
    let fileSource = """
    aorus.on('start', function () {
        aorus.files.writeText('notes.txt', 'first')
            .then(function () { return aorus.files.append('notes.txt', ' and second'); })
            .then(function () { return aorus.files.readText('notes.txt'); })
            .then(function (text) { aorus.storage.set('text', text); })
            .then(function () { return aorus.files.writeJSON('state.json', { count: 3 }); })
            .then(function () { return aorus.files.readJSON('state.json'); })
            .then(function (value) { aorus.storage.set('json', value.count); })
            .then(function () { return aorus.files.readJSON('nothing.json', 'fallback'); })
            .then(function (value) { aorus.storage.set('fallback', value); })
            .then(function () { return aorus.files.readText('nothing.txt'); })
            .then(function (value) { aorus.storage.set('missing', value === null ? 'null' : 'something'); })
            .then(function () { return aorus.files.list(); })
            .then(function (items) { aorus.storage.set('list', items.map(function (item) { return item.name; }).join(',')); })
            .then(function () { return aorus.files.exists('state.json'); })
            .then(function (there) { aorus.storage.set('exists', there ? 'yes' : 'no'); })
            .then(function () { return aorus.files.remove('state.json'); })
            .then(function (removed) { aorus.storage.set('removed', removed ? 'yes' : 'no'); })
            .then(function () { return aorus.files.writeText('../escape.txt', 'no'); })
            .then(
                function () { aorus.storage.set('escape', 'allowed'); },
                function () { aorus.storage.set('escape', 'rejected'); }
            )
            .then(function () { return aorus.files.usage(); })
            .then(function (usage) { aorus.storage.set('count', usage.count); });
    });
    """
    let fileSandbox = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Files"),
        source: fileSource,
        host: fileHost,
        permissions: [],
        filesDirectory: fileDirectory
    )
    let fileStarted = DispatchSemaphore(value: 0)
    fileSandbox.start { error in expect(error == nil, "file plugin starts"); fileStarted.signal() }
    _ = fileStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.5)
    expect(fileResults["text"] == .string("first and second"), "append adds to what was written")
    expect(fileResults["json"] == .number(3), "writeJSON and readJSON round-trip a value")
    expect(fileResults["fallback"] == .string("fallback"), "readJSON of a missing file answers with the fallback")
    expect(fileResults["missing"] == .string("null"), "readText of a missing file answers null")
    expect(fileResults["list"] == .string("notes.txt,state.json"), "list names the files in order")
    expect(fileResults["exists"] == .string("yes"), "exists answers for a file that is there")
    expect(fileResults["removed"] == .string("yes"), "remove reports that the file was there")
    expect(fileResults["escape"] == .string("rejected"), "a name that is not plainly a file name is refused")
    expect(fileResults["count"] == .number(1), "usage counts what is left")
    fileSandbox.stop()

    // What a plugin draws over the chat. Every number is clamped rather than rejected — a
    // plugin asking for a 900-point button has made a mistake, not an attack, and the useful
    // answer is the largest button that still fits.
    let overlayHost = AorusPluginNullHost()
    var publishedOverlays: [AorusPluginOverlay] = []
    overlayHost.onOverlaysChanged = { _, items in publishedOverlays = items }
    var overlayResults: [String: AorusPluginJSONValue] = [:]
    overlayHost.onStorageChanged = { _, values in overlayResults = values }
    let overlaySource = """
    aorus.on('start', function () {
        var button = aorus.ui.addFloatingButton(
            { title: 'Go', icon: 'bolt.fill', backgroundColor: '#0A84FF', position: 'BottomLeft', offsetY: -120, width: 900, alpha: 4, draggable: true },
            function (event) { aorus.storage.set('tapped', event.id); }
        );
        var panel = aorus.ui.addChatPanel({ title: 'Recording', subtitle: 'in progress' });
        aorus.storage.set('ids', button + '|' + panel);
        aorus.ui.updateChatPanel(panel, { title: 'Recording', subtitle: 'stopped' });
        aorus.storage.set('count', aorus.ui.overlays().length);
        try { aorus.ui.addFloatingButton({ title: '' }); } catch (error) { aorus.storage.set('empty', 'threw'); }
    });
    """
    let overlaySandbox = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Overlays"),
        source: overlaySource,
        host: overlayHost,
        permissions: [.customUI]
    )
    let overlayStarted = DispatchSemaphore(value: 0)
    overlaySandbox.start { error in expect(error == nil, "overlay plugin starts"); overlayStarted.signal() }
    _ = overlayStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.3)
    expect(publishedOverlays.count == 2, "both overlays reach the app")
    if publishedOverlays.count == 2 {
        let button = publishedOverlays[0]
        expect(button.kind == .floatingButton, "the first overlay is the button")
        expect(button.position == .bottomLeft, "a position is matched whatever its case")
        expect(button.backgroundColor == "0A84FF", "a colour arrives as six hex digits without the hash")
        expect(button.width == AorusPluginOverlay.maximumSide, "an oversized width is clamped, not refused")
        expect(button.alpha == 1.0, "an out-of-range alpha is clamped to fully opaque")
        expect(button.offsetY == -120.0, "an offset within range is kept exactly")
        expect(button.draggable, "draggable carries across")
        expect(button.displayMode == .iconText, "a button with both a glyph and a word shows both")
        let panel = publishedOverlays[1]
        expect(panel.kind == .chatPanel, "the second overlay is the panel")
        expect(panel.subtitle == "stopped", "an update replaces what the panel says")
        expect(panel.position == .topLeft, "a panel defaults to the top of the chat")
    }
    expect(overlayResults["count"] == .number(2), "the plugin can read back what it has drawn")
    // A button with neither a glyph nor a word on it is an invisible tap target, so it is
    // dropped — and the add fails rather than reporting an id for something not on screen.
    expect(overlayResults["empty"] == .string("threw"), "an overlay with nothing to show is refused")
    // A handler given to `add` is called directly, so a plugin with several buttons does not
    // have to work out which one was pressed.
    overlaySandbox.dispatch(event: "overlayAction", payload: ["id": "floatingButton-1"])
    Thread.sleep(forTimeInterval: 0.2)
    expect(overlayResults["tapped"] == .string("floatingButton-1"), "a tap reaches the handler the plugin passed in")
    overlaySandbox.stop()

    // Without the grant nothing is drawn at all, and the add says so rather than reporting
    // an id for something that does not exist.
    let deniedOverlayHost = AorusPluginNullHost()
    var deniedOverlayCount = 0
    deniedOverlayHost.onOverlaysChanged = { _, _ in deniedOverlayCount += 1 }
    var deniedOverlayResults: [String: AorusPluginJSONValue] = [:]
    deniedOverlayHost.onStorageChanged = { _, values in deniedOverlayResults = values }
    let deniedOverlays = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Denied overlays"),
        source: "aorus.on('start', function () { try { aorus.ui.addFloatingButton({ title: 'Go' }); } catch (error) { aorus.storage.set('add', 'refused'); } });",
        host: deniedOverlayHost,
        permissions: []
    )
    let deniedOverlaysStarted = DispatchSemaphore(value: 0)
    deniedOverlays.start { error in expect(error == nil, "denied overlay plugin starts"); deniedOverlaysStarted.signal() }
    _ = deniedOverlaysStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(deniedOverlayCount == 0, "an ungranted overlay never reaches the app")
    expect(deniedOverlayResults["add"] == .string("refused"), "an ungranted add reports rather than returning an id")
    deniedOverlays.stop()

    // A message's attachment, and acting on somebody in a group.
    let mediaHost = AorusPluginNullHost()
    var mediaCalls: [(String, Int32)] = []
    mediaHost.onMedia = { _, action, _, _, messageId in
        mediaCalls.append((action, messageId))
        return ["kind": "photo", "sizeBytes": NSNumber(value: 2048), "downloaded": NSNumber(value: true)]
    }
    var moderationCalls: [(String, Int64, Int64)] = []
    mediaHost.onModerate = { _, action, chat, user in
        moderationCalls.append((action, chat, user))
        return ["ok": NSNumber(value: action != "ban")]
    }
    var mediaResults: [String: AorusPluginJSONValue] = [:]
    mediaHost.onStorageChanged = { _, values in mediaResults = values }
    let mediaSource = """
    var ref = { peerId: '-1001234567890', namespace: 0, messageId: 77 };
    aorus.on('start', function () {
        aorus.media.info(ref).then(function (value) { aorus.storage.set('info', value.kind + '/' + value.sizeBytes); });
        aorus.media.download(ref);
        aorus.media.save(ref);
        aorus.media.share(ref);
        aorus.moderation.kick('42', { chatPeerId: '-1001234567890' })
            .then(function (value) { aorus.storage.set('kick', value.ok ? 'yes' : 'no'); });
        aorus.moderation.ban('42', { chatPeerId: '-1001234567890' })
            .then(function (value) { aorus.storage.set('ban', value.ok ? 'yes' : 'no'); });
        try { aorus.moderation.ban('42'); } catch (error) { aorus.storage.set('noChat', 'rejected'); }
    });
    """
    let mediaSandbox = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Media"),
        source: mediaSource,
        host: mediaHost,
        permissions: [.messageHistory, .dialogs, .manageMessages]
    )
    let mediaStarted = DispatchSemaphore(value: 0)
    mediaSandbox.start { error in expect(error == nil, "media plugin starts"); mediaStarted.signal() }
    _ = mediaStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.3)
    expect(mediaResults["info"] == .string("photo/2048"), "info describes the attachment")
    expect(mediaCalls.map { $0.0 } == ["info", "download", "save", "share"], "each media call reaches the host as its own action")
    expect(mediaCalls.allSatisfy { $0.1 == 77 }, "and carries the message it was asked about")
    expect(moderationCalls.map { $0.0 } == ["kick", "ban"], "moderation actions reach the host by name")
    expect(moderationCalls.first?.2 == 42, "with the person they are about")
    expect(mediaResults["kick"] == .string("yes"), "an action the rights allow answers ok")
    // Telegram's own rights decide, and being refused is an answer rather than an error.
    expect(mediaResults["ban"] == .string("no"), "an action the rights refuse answers not-ok instead of failing")
    expect(mediaResults["noChat"] == .string("rejected"), "moderating without naming the group is refused before it crosses")
    mediaSandbox.stop()

    // Sharing and saving put something on screen, so they need the grant that covers that —
    // even for a plugin that may read the message.
    let mediaReadOnlyHost = AorusPluginNullHost()
    var mediaReadOnlyCalls = 0
    mediaReadOnlyHost.onMedia = { _, _, _, _, _ in mediaReadOnlyCalls += 1; return [:] }
    var mediaReadOnlyResults: [String: AorusPluginJSONValue] = [:]
    mediaReadOnlyHost.onStorageChanged = { _, values in mediaReadOnlyResults = values }
    let mediaReadOnly = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Media read only"),
        source: """
        aorus.on('start', function () {
            aorus.media.info({ peerId: '1', namespace: 0, messageId: 1 }).then(function () { aorus.storage.set('info', 'allowed'); });
            aorus.media.share({ peerId: '1', namespace: 0, messageId: 1 }).then(
                function () { aorus.storage.set('share', 'allowed'); },
                function (error) { aorus.storage.set('share', String(error.message || error)); }
            );
        });
        """,
        host: mediaReadOnlyHost,
        permissions: [.messageHistory]
    )
    let mediaReadOnlyStarted = DispatchSemaphore(value: 0)
    mediaReadOnly.start { error in expect(error == nil, "read-only media plugin starts"); mediaReadOnlyStarted.signal() }
    _ = mediaReadOnlyStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(mediaReadOnlyResults["info"] == .string("allowed"), "reading the attachment is message history")
    expect(mediaReadOnlyResults["share"] == .string("Permission not granted: dialogs"), "putting it on screen also needs dialogs")
    expect(mediaReadOnlyCalls == 1, "and the refused one never reaches the host")
    mediaReadOnly.stop()

    // Storage's JSON conveniences, the console's own history, and what a plugin may do.
    let shelfHost = AorusPluginNullHost()
    var shelfResults: [String: AorusPluginJSONValue] = [:]
    shelfHost.onStorageChanged = { _, values in shelfResults = values }
    let shelfSource = """
    aorus.on('start', function () {
        aorus.storage.setJSON('state', { count: 1 });
        aorus.storage.set('log', 'line');
        var length = aorus.storage.push('items', 'a');
        length = aorus.storage.push('items', 'b');
        // Pushing onto something that is not an array starts a new one rather than throwing:
        // a plugin recovering from its own bad write should not have to clear the key first.
        aorus.storage.push('log', 'c');
        aorus.storage.set('read', aorus.storage.getJSON('state').count + '/' + length
            + '/' + aorus.storage.getJSON('missing', 'fallback')
            + '/' + (aorus.storage.has('state') ? 'yes' : 'no')
            + '/' + aorus.storage.get('items').join(''));
        console.log('first');
        console.warn('second');
        aorus.storage.set('history', aorus.console.history(10).length >= 2 ? 'kept' : 'lost');
        aorus.storage.set('runtime', aorus.runtime.pluginId.length > 0
            ? (aorus.runtime.hasPermission('sendMessages') ? 'granted' : 'denied') : 'noId');
        aorus.storage.set('unknownPermission', aorus.runtime.hasPermission('notAPermission') ? 'yes' : 'no');
    });
    """
    let shelf = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Shelf"),
        source: shelfSource,
        host: shelfHost,
        permissions: [.sendMessages]
    )
    let shelfStarted = DispatchSemaphore(value: 0)
    shelf.start { error in expect(error == nil, "storage plugin starts"); shelfStarted.signal() }
    _ = shelfStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.3)
    expect(shelfResults["read"] == .string("1/2/fallback/yes/ab"), "the JSON helpers, push, the fallback and has all answer")
    expect(shelfResults["log"] == .array([.string("c")]), "pushing onto something that is not an array starts a new one")
    expect(shelfResults["history"] == .string("kept"), "a plugin can read its own console back")
    expect(shelfResults["runtime"] == .string("granted"), "a plugin knows its own id and what it was granted")
    expect(shelfResults["unknownPermission"] == .string("no"), "a permission that does not exist is not granted")
    shelf.stop()

    // Words the app draws, replaced by a plugin, and put back.
    let stringsHost = AorusPluginNullHost()
    var publishedStrings: [String: String] = [:]
    var stringPublishes = 0
    stringsHost.onStringOverridesChanged = { _, values in publishedStrings = values; stringPublishes += 1 }
    var stringsResults: [String: AorusPluginJSONValue] = [:]
    stringsHost.onStorageChanged = { _, values in stringsResults = values }
    let stringsSource = """
    aorus.on('start', function () {
        aorus.strings.override('Chat_Title', 'Разговор');
        aorus.strings.override('Common_OK', 'Ладно');
        aorus.strings.restore('Common_OK');
        aorus.storage.set('left', Object.keys(aorus.strings.all()).join(','));
        aorus.storage.set('restored', String(aorus.strings.restoreAll()));
    });
    """
    let stringsSandbox = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Strings"),
        source: stringsSource,
        host: stringsHost,
        permissions: [.appCustomization]
    )
    let stringsStarted = DispatchSemaphore(value: 0)
    stringsSandbox.start { error in expect(error == nil, "strings plugin starts"); stringsStarted.signal() }
    _ = stringsStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.3)
    expect(stringsResults["left"] == .string("Chat_Title"), "a restored key is gone and the other one stays")
    expect(stringsResults["restored"] == .string("1"), "restoreAll answers how many it put back")
    expect(publishedStrings.isEmpty, "the last publish is the empty set, because restoreAll republishes")
    expect(stringPublishes == 4, "every change republishes the whole set")
    stringsSandbox.stop()

    let deniedStringsHost = AorusPluginNullHost()
    var deniedStringPublishes = 0
    deniedStringsHost.onStringOverridesChanged = { _, _ in deniedStringPublishes += 1 }
    var deniedStringsResults: [String: AorusPluginJSONValue] = [:]
    deniedStringsHost.onStorageChanged = { _, values in deniedStringsResults = values }
    let deniedStrings = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Denied strings"),
        source: "aorus.on('start', function () { try { aorus.strings.override('a', 'b'); } catch (error) { aorus.storage.set('override', 'refused'); } });",
        host: deniedStringsHost,
        permissions: []
    )
    let deniedStringsStarted = DispatchSemaphore(value: 0)
    deniedStrings.start { error in expect(error == nil, "denied strings plugin starts"); deniedStringsStarted.signal() }
    _ = deniedStringsStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(deniedStringPublishes == 0, "an ungranted override never reaches the app")
    expect(deniedStringsResults["override"] == .string("refused"), "and the plugin is told, rather than believing it worked")
    deniedStrings.stop()

    // One plugin talking to another, through the app.
    let busHost = AorusPluginNullHost()
    var broadcast: (topic: String, json: String)?
    busHost.onBroadcast = { _, topic, json in broadcast = (topic, json) }
    var busResults: [String: AorusPluginJSONValue] = [:]
    busHost.onStorageChanged = { _, values in busResults = values }
    let busSource = """
    aorus.plugins.on('weather', function (event) {
        aorus.storage.set('heard', event.from + ':' + event.payload.city);
    });
    aorus.plugins.on('other', function () { aorus.storage.set('wrongTopic', 'yes'); });
    aorus.on('start', function () {
        aorus.plugins.emit('weather', { city: 'Riga' });
        aorus.storage.set('topics', aorus.plugins.topics().sort().join(','));
    });
    """
    let bus = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Bus"),
        source: busSource,
        host: busHost,
        permissions: [.pluginMessaging]
    )
    let busStarted = DispatchSemaphore(value: 0)
    bus.start { error in expect(error == nil, "bus plugin starts"); busStarted.signal() }
    _ = busStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(broadcast?.topic == "weather", "an emit reaches the app with its topic")
    expect(broadcast?.json == "{\"city\":\"Riga\"}", "and with its payload")
    expect(busResults["topics"] == .string("other,weather"), "a plugin can list what it is listening for")
    // What the app sends back, as another plugin would have caused.
    bus.dispatch(event: "pluginMessage", payload: ["topic": "weather", "from": "other-plugin", "payload": ["city": "Riga"]])
    Thread.sleep(forTimeInterval: 0.2)
    expect(busResults["heard"] == .string("other-plugin:Riga"), "a message reaches the handler for its topic, carrying who sent it")
    expect(busResults["wrongTopic"] == nil, "and reaches no other topic's handler")
    bus.stop()

    // The theme a plugin draws against.
    let themeHost = AorusPluginNullHost()
    var themeResults: [String: AorusPluginJSONValue] = [:]
    themeHost.onStorageChanged = { _, values in themeResults = values }
    themeHost.onTheme = { _ in ["isDark": NSNumber(value: true), "name": "night", "accent": "5B4DFF", "text": "FFFFFF"] }
    let themeSandbox = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "Theme"),
        source: "aorus.on('start', function () { aorus.theme.current().then(function (theme) { aorus.storage.set('theme', theme.name + '/' + theme.accent + '/' + (theme.isDark ? 'dark' : 'light')); }); });",
        host: themeHost,
        permissions: []
    )
    let themeStarted = DispatchSemaphore(value: 0)
    themeSandbox.start { error in expect(error == nil, "theme plugin starts"); themeStarted.signal() }
    _ = themeStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(themeResults["theme"] == .string("night/5B4DFF/dark"), "the theme reaches a plugin without any grant, like isDark always has")
    themeSandbox.stop()

    // A plugin with nowhere to write is told so rather than writing somewhere else.
    let noFilesHost = AorusPluginNullHost()
    var noFilesResults: [String: AorusPluginJSONValue] = [:]
    noFilesHost.onStorageChanged = { _, values in noFilesResults = values }
    let noFiles = AorusPluginSandbox(
        manifest: AorusPluginManifest(name: "No files"),
        source: "aorus.on('start', function () { aorus.files.writeText('a.txt', 'x').then(function () { aorus.storage.set('write', 'allowed'); }, function (error) { aorus.storage.set('write', String(error.message || error)); }); });",
        host: noFilesHost,
        permissions: []
    )
    let noFilesStarted = DispatchSemaphore(value: 0)
    noFiles.start { error in expect(error == nil, "plugin without file storage starts"); noFilesStarted.signal() }
    _ = noFilesStarted.wait(timeout: .now() + 2)
    Thread.sleep(forTimeInterval: 0.2)
    expect(noFilesResults["write"] == .string("This plugin has no file storage"), "a plugin with no file directory is told so")
    noFiles.stop()
}

// The name rule is what makes a path outside the directory unrepresentable, so it is checked
// directly rather than only through a plugin that happens to try one.
for badName in ["", ".", "..", ".hidden", "a/b", "../escape", "a\\b", "a b", String(repeating: "x", count: 65), "note..txt", "/etc/passwd"] {
    expect(AorusPluginFiles.normalizedName(badName) == nil, "file name '\(badName)' is refused")
}
for goodName in ["notes.txt", "a", "state-2.json", "A_B.c", String(repeating: "x", count: 64)] {
    expect(AorusPluginFiles.normalizedName(goodName) == goodName, "file name '\(goodName)' is accepted unchanged")
}

let quotaDirectory = temporaryDirectory().appendingPathComponent("quota", isDirectory: true)
let quotaFiles = AorusPluginFiles(directory: quotaDirectory)
do {
    try quotaFiles.write("big.txt", text: String(repeating: "x", count: AorusPluginFiles.maximumFileBytes + 1))
    expect(false, "a file over the per-file limit is refused")
} catch let error as AorusPluginFiles.FileError {
    expect(error == .tooLarge, "an oversized file is refused for being oversized")
} catch {
    expect(false, "an oversized file is refused with a file error")
}
do {
    try quotaFiles.write("ok.txt", text: "fine")
    let readBack = try quotaFiles.read("ok.txt")
    let readMissing = try quotaFiles.read("gone.txt")
    let removedMissing = try quotaFiles.remove("gone.txt")
    expect(readBack == "fine", "a file within the limit is written and read back")
    expect(readMissing == nil, "reading a missing file is nil, not an error")
    expect(removedMissing == false, "removing a file that is not there is not an error")
    // Overwriting with something smaller always fits, even at the quota.
    try quotaFiles.write("ok.txt", text: "f")
    expect((quotaFiles.usage()["bytes"] as? NSNumber)?.intValue == 1, "an overwrite replaces rather than adds")
    expect(quotaFiles.clear() == 1, "clear removes the plugin's files")
    expect(quotaFiles.list().isEmpty, "nothing is left after clear")
} catch {
    expect(false, "writing within the limits succeeds")
}

if failures == 0 {
    print("Aorus plugin core tests: OK")
} else {
    exit(1)
}
}
}
