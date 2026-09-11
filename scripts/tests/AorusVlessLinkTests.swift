import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusVlessLink test failed: \(message)\n", stderr)
        exit(1)
    }
}

private func key(_ index: Int, host: String = "edge.example.com") -> String {
    let suffix = String(format: "%012x", index)
    return "vless://00000000-0000-4000-8000-\(suffix)@\(host):443?encryption=none&security=tls&sni=\(host)&type=ws&path=%2Faorus#Node-\(index)"
}

private func parsesOneProductionShape() {
    guard case let .success(.servers(servers)) = AorusVlessLink.parse(key(1)) else {
        require(false, "valid VLESS TLS/WS key")
        return
    }
    require(servers.count == 1, "one key produces one server")
    require(servers[0].address == "edge.example.com", "host is preserved")
    require(servers[0].port == 443, "port is preserved")
    require(servers[0].security == "tls", "TLS is preserved")
    require(servers[0].network == "ws", "WebSocket is preserved")
    require(servers[0].path == "/aorus", "path is decoded")
}

private func boundsUntrustedFanOut() {
    let input = (0 ..< 400).map { key($0 + 1) }.joined(separator: "\n")
    guard case let .success(.servers(servers)) = AorusVlessLink.parse(input) else {
        require(false, "large valid subscription body")
        return
    }
    require(servers.count == AorusVlessLink.maximumServersPerImport, "server fan-out is capped")
    require(Set(servers.map(\.id)).count == servers.count, "bounded list remains deduplicated")
}

private func rejectsInsecureAndMalformedInput() {
    require(AorusVlessLink.parse("http://panel.example.com/sub") == .failure(.insecureSubscription), "HTTP subscription is refused")
    require(AorusVlessLink.parse("vless://not-a-uuid@example.com:443") == .failure(.malformed), "invalid credential is refused")
    require(AorusVlessLink.parse(String(repeating: "x", count: 512_001)) == .failure(.empty), "oversized paste is refused")
}

@main
private enum AorusVlessLinkTests {
    static func main() {
        parsesOneProductionShape()
        boundsUntrustedFanOut()
        rejectsInsecureAndMalformedInput()
        print("AorusVlessLink tests: OK")
    }
}
