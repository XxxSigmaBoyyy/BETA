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

let root = temporaryDirectory()
defer { try? FileManager.default.removeItem(at: root) }
let store = AorusPluginStore(rootURL: root)
let manifest = AorusPluginManifest(name: "Test", isEnabled: true, autostart: true)
let record = AorusPluginRecord(manifest: manifest, source: "console.log('ok');")
do {
    try store.save(record)
    let digest = AorusPluginStore.sourceDigest(record.source)
    try store.setPermissionState(AorusPluginPermissionState(sourceDigest: digest, granted: [.network]), for: manifest.id)
    expect(store.permissionState(for: manifest.id).granted == [.network], "permission state persists")
    var changed = record
    changed.source = "console.log('changed');"
    try store.save(changed)
    expect(store.permissionState(for: manifest.id).granted.isEmpty, "source change revokes permission grants")
    expect(store.manifest(id: manifest.id)?.isEnabled == false, "source change disables the plugin")
} catch {
    expect(false, "store operations failed: \(error)")
}

do {
    let original = AorusPluginRecord(manifest: AorusPluginManifest(name: "Exported", isEnabled: true, autostart: true), source: "console.log('bundle');")
    try store.save(original)
    let data = store.export(id: original.manifest.id)!
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
}

if failures == 0 {
    print("Aorus plugin core tests: OK")
} else {
    exit(1)
}
}
}
