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
}

if failures == 0 {
    print("Aorus plugin core tests: OK")
} else {
    exit(1)
}
}
}
