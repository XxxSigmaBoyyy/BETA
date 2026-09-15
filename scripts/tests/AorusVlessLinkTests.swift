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

/// The core reads a WebSocket host from two places and says of one of them: "deprecated, will be
/// removed soon". Every feature it has said that about and then removed cost this client a
/// transport that quietly stopped connecting, so the host is written the way it asks for.
private func writesTheWebSocketHostTheWayTheCoreAsksFor() {
    let uri = "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443"
        + "?encryption=none&security=tls&sni=edge.example.com&type=ws&path=%2Faorus&host=cdn.example.com#W"
    guard let server = AorusVlessLink.parseKey(uri),
          let ws = streamSettings(of: server)?["wsSettings"] as? [String: Any] else {
        require(false, "a WebSocket key with a Host imports and builds")
        return
    }
    require(ws["host"] as? String == "cdn.example.com", "the host is the independent field")
    require(ws["headers"] == nil, "and not the header form the core is retiring")
    require(ws["path"] as? String == "/aorus", "the path is unchanged")

    // HTTPUpgrade is stricter about the same thing: a Host inside its headers is a hard error,
    // which would fail the whole configuration rather than this one outbound.
    let upgrade = uri.replacingOccurrences(of: "type=ws", with: "type=httpupgrade")
    guard let upgraded = AorusVlessLink.parseKey(upgrade),
          let block = streamSettings(of: upgraded)?["httpupgradeSettings"] as? [String: Any] else {
        require(false, "an HTTPUpgrade key imports and builds")
        return
    }
    require(block["host"] as? String == "cdn.example.com" && block["headers"] == nil,
            "HTTPUpgrade carries its host the only way it is allowed to")
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

// MARK: - Transports this core removed

/// Xray removed the HTTP/2 transport: `TransportProtocol.Build` answers "the feature has been
/// removed" for `h2`, `h3` and `http`, and a stream settings block that will not build fails the
/// WHOLE configuration, so the core never starts. Such a key used to be imported and produced a
/// card that could only ever say "does not connect".
private func refusesTransportsTheCoreRemoved() {
    for transport in ["h2", "http", "h3", "quic"] {
        let uri = "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443"
            + "?encryption=none&security=tls&sni=edge.example.com&type=\(transport)&path=%2Fx#N"
        require(AorusVlessLink.parseKey(uri) == nil, "\(transport) is not imported")
        require(AorusVlessLink.parse(uri) == .failure(.unsupported),
                "\(transport) is refused as unsupported, not as damaged text")
    }

    // The base64 shape of a VMess key writes the transport inside the object, which is the only
    // place the refusal can read it from.
    let object = "{\"v\":\"2\",\"add\":\"edge.example.com\",\"port\":\"443\","
        + "\"id\":\"00000000-0000-4000-8000-000000000001\",\"net\":\"h2\",\"tls\":\"tls\"}"
    let vmess = "vmess://" + Data(object.utf8).base64EncodedString()
    require(AorusVlessLink.parse(vmess) == .failure(.unsupported), "a legacy VMess h2 key is named, not called damaged")

    // A server carrying a removed transport can still be sitting in a store written by an older
    // build. It must not reach the core, where it would fail the whole configuration.
    let stale = AorusVlessServer(
        id: "stale", name: "stale", proto: "vless", address: "edge.example.com", port: 443,
        credential: "00000000-0000-4000-8000-000000000001", encryption: "", flow: "",
        network: "http", security: "tls", serverName: "edge.example.com", fingerprint: nil,
        publicKey: nil, shortId: nil, spiderX: nil, alpn: [], path: "/x", host: nil,
        serviceName: nil, headerType: nil, mode: nil, allowInsecure: false, link: ""
    )
    require(AorusVlessLink.xrayConfiguration(server: stale, localPort: 10_800, udpEnabled: true, muxEnabled: true) == nil,
            "a stored server on a removed transport builds no configuration")

    // The transports the core still carries are untouched by that refusal.
    for transport in ["tcp", "ws", "grpc", "httpupgrade", "xhttp", "splithttp"] {
        let uri = "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443"
            + "?encryption=none&security=tls&sni=edge.example.com&type=\(transport)#N"
        require(AorusVlessLink.parseKey(uri) != nil, "\(transport) still imports")
    }
}

// MARK: - What the core refuses wholesale

private let realityPublicKey = "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"

private func realityKey(
    network: String = "tcp",
    publicKey: String = realityPublicKey,
    shortId: String = "0123456789abcdef"
) -> String {
    return "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443"
        + "?encryption=none&security=reality&sni=edge.example.com&type=\(network)"
        + "&pbk=\(publicKey)&sid=\(shortId)#R"
}

private func streamSettings(of server: AorusVlessServer) -> [String: Any]? {
    guard let json = AorusVlessLink.xrayConfiguration(server: server, localPort: 10_900, udpEnabled: true, muxEnabled: true),
          let data = json.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let outbound = (root["outbounds"] as? [[String: Any]])?.first else {
        return nil
    }
    return outbound["streamSettings"] as? [String: Any]
}

/// Each of these was refused by the real Xray configuration loader, run against the exact core
/// this build links. A refusal there is not one outbound failing — the configuration is built as
/// a whole, so one bad key stops the core from starting and takes every other server in the
/// user's list down with it. That is why they are caught at import, where they cost one row.
private func refusesWhatWouldFailTheWholeConfiguration() {
    // "REALITY only supports RAW, XHTTP and gRPC for now."
    for network in ["ws", "httpupgrade"] {
        require(AorusVlessLink.parseKey(realityKey(network: network)) == nil,
                "REALITY over \(network) is not imported")
    }
    for network in ["tcp", "xhttp", "grpc"] {
        require(AorusVlessLink.parseKey(realityKey(network: network)) != nil,
                "REALITY over \(network) still imports")
    }

    // The short id is decoded as hex into eight bytes: at most sixteen digits, an even number of
    // them, and nothing outside the alphabet.
    for shortId in ["zznothex", "0123456789abcdef01", "abc"] {
        require(AorusVlessLink.parseKey(realityKey(shortId: shortId)) == nil,
                "a short id the core would refuse (\(shortId)) is not imported")
    }
    for shortId in ["ab", "0123456789abcdef"] {
        require(AorusVlessLink.parseKey(realityKey(shortId: shortId)) != nil,
                "a valid short id (\(shortId)) still imports")
    }
    require(AorusVlessLink.parseKey(realityKey(shortId: "AB"))?.shortId == "ab",
            "and an upper-case one is folded rather than refused")

    // The public key is unpadded base64url decoding to exactly 32 bytes.
    for key in ["", "not-a-key", String(repeating: "a", count: 43) + "a"] {
        require(AorusVlessLink.parseKey(realityKey(publicKey: key)) == nil,
                "a public key the core would refuse is not imported")
    }
    // A panel that writes the same key in the standard alphabet is rewritten, not refused: the
    // core decodes it with base64url only.
    guard let standard = AorusVlessLink.parseKey(
        realityKey(publicKey: "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI%2BT4E7RoLJS0%3D")
    ) else {
        require(false, "a standard-alphabet public key is accepted")
        return
    }
    require(standard.publicKey == realityPublicKey, "and rewritten into the one the core reads")

    // XHTTP refuses a mode it does not know. An unknown one is dropped, not refused — the
    // transport's own default negotiates — but it must never reach the core.
    let unknownMode = "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443"
        + "?encryption=none&security=tls&sni=edge.example.com&type=xhttp&path=%2Fx&mode=bogus#X"
    guard let dropped = AorusVlessLink.parseKey(unknownMode) else {
        require(false, "the key itself still imports")
        return
    }
    require(dropped.mode == nil, "an unknown XHTTP mode is dropped at import")
    for mode in ["auto", "packet-up", "stream-up", "stream-one"] {
        let uri = unknownMode.replacingOccurrences(of: "mode=bogus", with: "mode=\(mode)")
        require(AorusVlessLink.parseKey(uri)?.mode == mode, "\(mode) survives")
    }
    // A row written by an older build can still carry one, and it must not reach the core either.
    let staleMode = AorusVlessServer(
        id: "x", name: "x", proto: "vless", address: "edge.example.com", port: 443,
        credential: "00000000-0000-4000-8000-000000000001", encryption: "", flow: "",
        network: "xhttp", security: "none", serverName: nil, fingerprint: nil, publicKey: nil,
        shortId: nil, spiderX: nil, alpn: [], path: "/x", host: nil, serviceName: nil,
        headerType: nil, mode: "bogus", allowInsecure: false, link: ""
    )
    let xhttp = (streamSettings(of: staleMode)?["xhttpSettings"] as? [String: Any])
    require(xhttp != nil && xhttp?["mode"] == nil, "and is dropped on the way out as well")

    // Ciphers this core does not have. It answers "unknown cipher method" and fails the whole
    // configuration rather than the one outbound.
    for method in ["aes-192-gcm", "none", "plain"] {
        let userInfo = Data("\(method):ss-password".utf8).base64EncodedString()
        require(AorusVlessLink.parseKey("ss://\(userInfo)@edge.example.com:443#S") == nil,
                "\(method) is not imported")
    }
    for method in ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "2022-blake3-aes-256-gcm"] {
        let userInfo = Data("\(method):ss-password".utf8).base64EncodedString()
        require(AorusVlessLink.parseKey("ss://\(userInfo)@edge.example.com:443#S") != nil,
                "\(method) still imports")
    }
}

/// `allowInsecure` was removed from this core. It answers "the feature has been removed" and
/// fails the whole configuration, so one key carrying the flag stopped the core from starting.
/// The row keeps it — it is part of the row's identity and of the link the user copies back out —
/// and it simply never reaches the core.
private func neverHandsTheCoreTheFlagItRemoved() {
    let insecure = "vless://00000000-0000-4000-8000-000000000001@edge.example.com:443"
        + "?encryption=none&security=tls&sni=edge.example.com&allowInsecure=1#I"
    guard let server = AorusVlessLink.parseKey(insecure) else {
        require(false, "such a key still imports — refusing it would cost the user the server")
        return
    }
    require(server.allowInsecure, "the flag is read and kept on the row")
    require(server.link.contains("allowInsecure"), "and survives in the link")

    guard let tls = streamSettings(of: server)?["tlsSettings"] as? [String: Any] else {
        require(false, "the TLS block is built")
        return
    }
    require(tls["allowInsecure"] == nil, "and is not written into the configuration")

    // Hysteria 2 goes through a different builder and had the same flaw.
    guard let hysteria = AorusVlessLink.parseKey("hy2://pass@gate.example.com:443?insecure=1"),
          let hysteriaTls = streamSettings(of: hysteria)?["tlsSettings"] as? [String: Any] else {
        require(false, "the Hysteria 2 key imports and builds")
        return
    }
    require(hysteria.allowInsecure, "its flag is read too")
    require(hysteriaTls["allowInsecure"] == nil, "and is not written either")

    // A pinned digest, which is what this core offers instead, does reach it.
    guard let pinned = AorusVlessLink.parseKey("hy2://pass@gate.example.com:443?pinSHA256=" + String(repeating: "ab", count: 32)),
          let pinnedTls = streamSettings(of: pinned)?["tlsSettings"] as? [String: Any] else {
        require(false, "a pinned key imports and builds")
        return
    }
    require(pinnedTls["pinnedPeerCertSha256"] as? String == String(repeating: "ab", count: 32),
            "the pinned digest is what the core is given instead")
}

// MARK: - Hysteria 2

private let hysteriaKey = "hysteria2://s3cret-pass@gate.example.com:8443/"
    + "?sni=gate.example.com&insecure=1&obfs=salamander&obfs-password=mask-pass"
    + "&mport=20000-25000&pinSHA256=" + String(repeating: "ab", count: 32)
    + "#Гейт"

private func parsesAHysteria2Key() {
    guard case let .success(.servers(servers)) = AorusVlessLink.parse(hysteriaKey) else {
        require(false, "a Hysteria 2 key imports")
        return
    }
    require(servers.count == 1, "one key produces one server")
    let server = servers[0]
    require(server.proto == "hysteria2", "the protocol is recorded")
    require(server.protocolTitle == "Hysteria2", "and named the way every other client names it")
    require(server.address == "gate.example.com", "the host is read past the trailing slash")
    require(server.port == 8443, "the port is read")
    require(server.credential == "s3cret-pass", "the auth string is the credential")
    require(server.network == "hysteria", "the core's own name for the transport")
    require(server.security == "tls", "Hysteria 2 is always TLS")
    require(server.alpn == ["h3"], "and always HTTP/3")
    require(server.serverName == "gate.example.com", "the SNI is read")
    require(server.allowInsecure, "insecure=1 is read")
    require(server.obfsPassword == "mask-pass", "the Salamander password is carried")
    require(server.portHopping == "20000-25000", "the hopping range is carried")
    require(server.pinnedCertSha256 == String(repeating: "ab", count: 32), "the pinned digest is carried")
    require(server.name == "Гейт", "a non-Latin remark survives")

    // The short alias, a missing port, and no query at all.
    guard let short = AorusVlessLink.parseKey("hy2://pass@gate.example.com#Short") else {
        require(false, "hy2:// is the same scheme")
        return
    }
    require(short.proto == "hysteria2" && short.port == 443, "the port defaults to 443")
    require(short.obfsPassword == nil && short.portHopping == nil, "and nothing is invented")

    // A TCP handshake to a Hysteria 2 server measures nothing: it is QUIC, so nothing answers a
    // TCP connect whether the server is healthy or not. The latency sweep skips such rows on this
    // flag rather than spending its whole timeout to record a failure that says nothing.
    require(!server.respondsToTcpHandshake, "a Hysteria 2 server is not measured over TCP")
    require(AorusVlessLink.parseKey(key(1))?.respondsToTcpHandshake == true,
            "and every server that does listen on TCP still is")

    require(short.summary.contains("Hysteria2"), "the row says what it is")
    require(servers[0].summary.contains("Salamander"), "and says the packets are masked")
    require(servers[0].summary.contains("Hopping"), "and that the association hops ports")
}

private func refusesAHysteria2KeyItCannotHonour() {
    // An obfuscation this core has no mask for is a client that sends packets the server drops.
    require(AorusVlessLink.parseKey("hy2://pass@gate.example.com:443?obfs=xplus&obfs-password=p") == nil,
            "an obfuscation other than Salamander is refused")
    require(AorusVlessLink.parseKey("hy2://pass@gate.example.com:443?obfs=salamander") == nil,
            "Salamander without its password is refused")
    // Values the core parses itself: one it cannot read fails the whole configuration, so it is
    // caught here instead.
    require(AorusVlessLink.parseKey("hy2://pass@gate.example.com:443?pinSHA256=zz") == nil,
            "a pinned digest that is not a SHA-256 is refused")
    require(AorusVlessLink.parseKey("hy2://pass@gate.example.com:443?mport=20000..25000") == nil,
            "a hopping range the core cannot parse is refused")
    require(AorusVlessLink.parseKey("hy2://@gate.example.com:443") == nil, "an empty auth string is refused")

    // Hysteria 1 is a different wire protocol, and the outbound refuses anything whose version is
    // not 2 — so it is named as unsupported rather than accepted and left to fail at the handshake.
    require(AorusVlessLink.parse("hysteria://pass@gate.example.com:443?upmbps=100") == .failure(.unsupported),
            "Hysteria 1 is refused by name")
    for scheme in ["tuic://", "wireguard://", "juicity://", "ssr://"] {
        require(AorusVlessLink.parse("\(scheme)pass@gate.example.com:443") == .failure(.unsupported),
                "\(scheme) is still refused by name")
    }
}

/// Every key asserted here was read off this core's own configuration structs:
/// `HysteriaClientConfig{version,address,port}` for the outbound, `HysteriaConfig{version,auth}`
/// under `hysteriaSettings`, `Salamander{password}` as a UDP mask under `finalmask`, and
/// `UdpHop{ports}` under `finalmask.quicParams`. A spelling that drifts from them is a
/// configuration the core refuses whole, which is why they are pinned rather than eyeballed.
private func buildsTheHysteria2ConfigurationTheCoreReads() {
    guard let server = AorusVlessLink.parseKey(hysteriaKey),
          let json = AorusVlessLink.xrayConfiguration(server: server, localPort: 10_801, udpEnabled: true, muxEnabled: true),
          let data = json.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let outbound = (root["outbounds"] as? [[String: Any]])?.first,
          let stream = outbound["streamSettings"] as? [String: Any],
          let settings = outbound["settings"] as? [String: Any] else {
        require(false, "the Hysteria 2 configuration is built and is JSON")
        return
    }
    require(outbound["protocol"] as? String == "hysteria", "the outbound is the hysteria one")
    require((settings["version"] as? Int) == 2, "and declares version 2, which is the only one it accepts")
    require(settings["address"] as? String == "gate.example.com", "the outbound carries the address itself")
    require((settings["port"] as? Int) == 8443, "and the port")

    require(stream["network"] as? String == "hysteria", "the transport is the hysteria one")
    require(stream["security"] as? String == "tls", "TLS is required — the dialer refuses a nil TLS config")

    guard let hysteria = stream["hysteriaSettings"] as? [String: Any] else {
        require(false, "the transport block is present")
        return
    }
    require((hysteria["version"] as? Int) == 2, "the transport declares version 2 as well")
    require(hysteria["auth"] as? String == "s3cret-pass", "the credential travels in the transport")

    guard let tls = stream["tlsSettings"] as? [String: Any] else {
        require(false, "the TLS block is present")
        return
    }
    require(tls["alpn"] as? [String] == ["h3"], "ALPN is h3 — an empty one is filled with h2/http1.1, which this server will not negotiate")
    require(tls["serverName"] as? String == "gate.example.com", "the SNI is passed on")
    // `insecure=1` was read off the key and is on the row, but the core removed the flag and
    // fails the whole configuration over it, so it is not here. See the test above.
    require(tls["allowInsecure"] == nil, "the flag the core removed is not passed on")
    require(tls["pinnedPeerCertSha256"] as? String == String(repeating: "ab", count: 32), "the pinned digest is passed on")

    guard let finalMask = stream["finalmask"] as? [String: Any],
          let masks = finalMask["udp"] as? [[String: Any]], let mask = masks.first else {
        require(false, "the UDP mask is present")
        return
    }
    require(mask["type"] as? String == "salamander", "the mask is Salamander")
    require((mask["settings"] as? [String: Any])?["password"] as? String == "mask-pass", "with its password")
    let hop = (finalMask["quicParams"] as? [String: Any])?["udpHop"] as? [String: Any]
    require(hop?["ports"] as? String == "20000-25000", "and the hopping range rides with it")

    // QUIC multiplexes already; Xray's own mux over it would be a second layer doing the same work.
    require(outbound["mux"] == nil, "no mux is asked for")

    // The inbound the app dials is unchanged, whatever the outbound turned out to be.
    guard let inbound = (root["inbounds"] as? [[String: Any]])?.first else {
        require(false, "the loopback inbound is present")
        return
    }
    require(inbound["listen"] as? String == "127.0.0.1" && (inbound["port"] as? Int) == 10_801,
            "the loopback SOCKS inbound is unchanged")

    // A server with neither obfuscation nor hopping asks for no mask at all rather than an empty one.
    guard let plain = AorusVlessLink.parseKey("hy2://pass@gate.example.com:443"),
          let plainJson = AorusVlessLink.xrayConfiguration(server: plain, localPort: 10_802, udpEnabled: false, muxEnabled: false),
          let plainData = plainJson.data(using: .utf8),
          let plainRoot = (try? JSONSerialization.jsonObject(with: plainData)) as? [String: Any],
          let plainOutbound = (plainRoot["outbounds"] as? [[String: Any]])?.first,
          let plainStream = plainOutbound["streamSettings"] as? [String: Any] else {
        require(false, "the plain Hysteria 2 configuration is built")
        return
    }
    require(plainStream["finalmask"] == nil, "no mask block when there is nothing to mask")
    require((plainStream["tlsSettings"] as? [String: Any])?["serverName"] as? String == "gate.example.com",
            "a key with no SNI presents the address it dialled")
}

private func carriesHysteria2AcrossAStoreRoundTrip() {
    guard let server = AorusVlessLink.parseKey(hysteriaKey) else {
        require(false, "the key parses")
        return
    }
    guard let encoded = try? JSONEncoder().encode(server),
          let decoded = try? JSONDecoder().decode(AorusVlessServer.self, from: encoded) else {
        require(false, "a Hysteria 2 server survives the store")
        return
    }
    require(decoded == server, "every field survives, the new ones included")

    // A row written by a build that had never heard of these fields still decodes.
    let legacy = """
    {"id":"x","name":"n","proto":"vless","address":"edge.example.com","port":443,\
    "credential":"00000000-0000-4000-8000-000000000001","encryption":"","flow":"",\
    "network":"ws","security":"tls","alpn":[],"allowInsecure":false,"link":""}
    """
    guard let old = try? JSONDecoder().decode(AorusVlessServer.self, from: Data(legacy.utf8)) else {
        require(false, "an older row still decodes")
        return
    }
    require(old.obfsPassword == nil && old.pinnedCertSha256 == nil && old.portHopping == nil,
            "and the fields it never had are absent rather than invented")
}

// MARK: - Whole pastes and whole documents

/// "чтоб импортировал конфигурацию и были все сервера": one paste routinely holds several
/// protocols and a couple this core cannot dial. The ones it can must all arrive.
private func importsEverySupportedServerOutOfAMixedPaste() {
    let paste = [
        "Тут мои сервера:",
        key(1),
        "hysteria2://pass@gate.example.com:8443?sni=gate.example.com#Hy2",
        "hysteria://old@legacy.example.com:443",
        "tuic://uuid:pass@tuic.example.com:443",
        "trojan://password@trojan.example.com:443?security=tls&sni=trojan.example.com#Trojan",
        "vless://00000000-0000-4000-8000-000000000009@h2.example.com:443?encryption=none&security=tls&type=h2#Dead",
        ""
    ].joined(separator: "\n")

    guard case let .success(.servers(servers)) = AorusVlessLink.parse(paste) else {
        require(false, "a mixed paste still imports")
        return
    }
    let protocols = Set(servers.map(\.proto))
    require(protocols == ["vless", "hysteria2", "trojan"],
            "every server this core can dial arrives, and only those")
    require(servers.count == 3, "one row each")
    // The two it cannot dial, and the one on a removed transport, are dropped rather than
    // imported as cards that could never connect.
    require(!servers.contains(where: { $0.address == "legacy.example.com" }), "Hysteria 1 is not imported")
    require(!servers.contains(where: { $0.address == "tuic.example.com" }), "TUIC is not imported")
    require(!servers.contains(where: { $0.address == "h2.example.com" }), "the removed transport is not imported")
}

private func readsHysteria2OutOfEveryConfigurationDialect() {
    let clash = """
    proxies:
      - name: "Hy2 RU"
        type: hysteria2
        server: gate.example.com
        port: 8443
        password: clash-pass
        obfs: salamander
        obfs-password: clash-mask
        sni: gate.example.com
        skip-cert-verify: true
        ports: "20000-25000"
      - name: "WS"
        type: vless
        server: edge.example.com
        port: 443
        uuid: 00000000-0000-4000-8000-000000000002
        tls: true
        network: ws
        ws-opts:
          path: /aorus
    """
    guard let clashServers = AorusVlessLink.parseConfigurationBody(clash) else {
        require(false, "the Clash document is read")
        return
    }
    guard let hy2 = clashServers.first(where: { $0.proto == "hysteria2" }) else {
        require(false, "its Hysteria 2 entry is read")
        return
    }
    require(clashServers.count == 2, "and the other entry too")
    require(hy2.credential == "clash-pass" && hy2.obfsPassword == "clash-mask", "with its credential and mask")
    require(hy2.portHopping == "20000-25000" && hy2.allowInsecure, "its hopping range and its insecure flag")
    require(hy2.name == "Hy2 RU", "and the name the document gave it")

    let singbox = """
    {"outbounds":[
      {"type":"hysteria2","tag":"Hy2 SB","server":"gate.example.com","server_ports":["20000:25000"],
       "password":"sb-pass","obfs":{"type":"salamander","password":"sb-mask"},
       "tls":{"enabled":true,"server_name":"gate.example.com","insecure":false}},
      {"type":"direct","tag":"direct"}
    ]}
    """
    guard let singboxServers = AorusVlessLink.parseConfigurationBody(singbox),
          let sb = singboxServers.first(where: { $0.proto == "hysteria2" }) else {
        require(false, "the sing-box document's Hysteria 2 entry is read")
        return
    }
    require(singboxServers.count == 1, "and its `direct` outbound is not mistaken for a server")
    require(sb.credential == "sb-pass" && sb.obfsPassword == "sb-mask", "with its credential and mask")
    require(sb.port == 20_000, "a hopping entry with no single port opens on the first of the range")
    require(sb.portHopping == "20000-25000", "and the range is rewritten in the notation this core reads")

    let xray = """
    {"outbounds":[{"protocol":"hysteria","tag":"Hy2 X",
      "settings":{"version":2,"address":"gate.example.com","port":8443},
      "streamSettings":{"network":"hysteria","security":"tls",
        "tlsSettings":{"serverName":"gate.example.com","alpn":["h3"]},
        "hysteriaSettings":{"version":2,"auth":"x-pass"},
        "finalmask":{"udp":[{"type":"salamander","settings":{"password":"x-mask"}}],
                     "quicParams":{"udpHop":{"ports":"30000-31000"}}}}}]}
    """
    guard let xrayServers = AorusVlessLink.parseConfigurationBody(xray), let x = xrayServers.first else {
        require(false, "the Xray document's Hysteria 2 outbound is read")
        return
    }
    require(x.proto == "hysteria2" && x.credential == "x-pass", "with the credential from the transport block")
    require(x.obfsPassword == "x-mask" && x.portHopping == "30000-31000", "and the mask and the range")

    // Version 1 written in the Xray dialect is refused for the same reason the link is.
    let xrayV1 = """
    {"outbounds":[{"protocol":"hysteria","settings":{"version":1,"address":"g.example.com","port":443},
      "streamSettings":{"network":"hysteria","hysteriaSettings":{"version":1,"auth":"p"}}}]}
    """
    require((AorusVlessLink.parseConfigurationBody(xrayV1) ?? []).isEmpty, "a version-1 outbound is not imported")

    // An obfuscation this core has no mask for is refused in every dialect, rather than imported
    // unmasked — a client that does not obfuscate sends packets such a server drops.
    let clashForeignObfs = """
    proxies:
      - name: "X"
        type: hysteria2
        server: gate.example.com
        port: 8443
        password: p
        obfs: xplus
        obfs-password: m
    """
    require((AorusVlessLink.parseConfigurationBody(clashForeignObfs) ?? []).isEmpty,
            "a Clash entry with a foreign obfuscation is not imported")
    let clashObfsNoPassword = """
    proxies:
      - name: "X"
        type: hysteria2
        server: gate.example.com
        port: 8443
        password: p
        obfs: salamander
    """
    require((AorusVlessLink.parseConfigurationBody(clashObfsNoPassword) ?? []).isEmpty,
            "nor one that names Salamander without its password")
    let singboxForeignObfs = """
    {"outbounds":[{"type":"hysteria2","server":"gate.example.com","server_port":8443,
      "password":"p","obfs":{"type":"xplus","password":"m"},"tls":{"enabled":true}}]}
    """
    require((AorusVlessLink.parseConfigurationBody(singboxForeignObfs) ?? []).isEmpty,
            "and neither is a sing-box entry with one")

    // Clash writes a uTLS ClientHello shape under the same key that holds a certificate digest on
    // a Hysteria 2 entry. The shape must not be mistaken for a digest, and must not lose the row.
    let clashFingerprint = """
    proxies:
      - name: "F"
        type: hysteria2
        server: gate.example.com
        port: 8443
        password: p
        fingerprint: chrome
    """
    guard let fingerprinted = AorusVlessLink.parseConfigurationBody(clashFingerprint)?.first else {
        require(false, "a uTLS fingerprint does not cost the row")
        return
    }
    require(fingerprinted.pinnedCertSha256 == nil, "and is not mistaken for a pinned certificate")
}

/// Every document reader writes a link and parses it back, so the two halves have to agree — and
/// the link it wrote is the one the row keeps, which is what the user copies into another client.
private func roundTripsAHysteria2Link() {
    let clash = """
    proxies:
      - name: "Round"
        type: hysteria2
        server: gate.example.com
        port: 8443
        password: "pa ss/with@signs"
        obfs: salamander
        obfs-password: "mask,pass"
        sni: gate.example.com
        ports: "20000-25000,30000-31000"
    """
    guard let built = AorusVlessLink.parseConfigurationBody(clash)?.first else {
        require(false, "the document entry becomes a server")
        return
    }
    require(built.link.hasPrefix("hysteria2://"), "and the row keeps a link in the scheme other clients read")
    guard let again = AorusVlessLink.parseKey(built.link) else {
        require(false, "which parses back")
        return
    }
    require(again == built, "a Hysteria 2 server survives a trip through its own link")
    require(again.credential == "pa ss/with@signs", "an auth string full of delimiters is not cut on one")
    require(again.obfsPassword == "mask,pass", "and neither is the mask password")
    require(again.portHopping == "20000-25000,30000-31000", "a two-range hop survives")

    // Two credentials on one host stay two rows.
    guard let first = AorusVlessLink.parseKey(hysteriaKey),
          let other = AorusVlessLink.parseKey("hy2://other-pass@gate.example.com:8443") else {
        require(false, "both keys parse")
        return
    }
    require(other.id != first.id, "a different credential is a different row")
}

@main
private enum AorusVlessLinkTests {
    static func main() {
        parsesOneProductionShape()
        writesTheWebSocketHostTheWayTheCoreAsksFor()
        boundsUntrustedFanOut()
        rejectsInsecureAndMalformedInput()
        refusesTransportsTheCoreRemoved()
        refusesWhatWouldFailTheWholeConfiguration()
        neverHandsTheCoreTheFlagItRemoved()
        parsesAHysteria2Key()
        refusesAHysteria2KeyItCannotHonour()
        buildsTheHysteria2ConfigurationTheCoreReads()
        carriesHysteria2AcrossAStoreRoundTrip()
        importsEverySupportedServerOutOfAMixedPaste()
        readsHysteria2OutOfEveryConfigurationDialect()
        roundTripsAHysteria2Link()
        print("AorusVlessLink tests: OK")
    }
}
