import Foundation
import CryptoKit

/// A VLESS server the user brought themselves, and the Xray configuration it turns into.
///
/// This is deliberately a different type from `AorusRealityEndpoint`. That one is issued by the
/// signed control plane, is validated against a device-bound profile, and only ever carries
/// REALITY over plain TCP because that is the only shape the infrastructure serves. A key pasted
/// out of somebody's channel can be anything: TLS over WebSocket behind a CDN, gRPC with a
/// service name, plain TCP with an HTTP header disguise. Forcing the two through one model would
/// mean either loosening the validation the signed profile depends on, or refusing most of the
/// keys a user actually has.
public struct AorusVlessServer: Codable, Equatable {
    /// Content-derived, so a subscription that is fetched again produces the same ids and the
    /// server the user picked stays picked. Two identical keys in one subscription collapse into
    /// one row for the same reason.
    public let id: String
    /// The `#remark` from the link, or `address:port` when it has none. Renameable by the user.
    public var name: String
    public let address: String
    public let port: Int
    public let userId: String
    /// "" or "xtls-rprx-vision". Anything else is dropped at parse time rather than passed to
    /// the core, which would refuse the whole configuration for one unknown word.
    public let flow: String
    /// Xray's transport name, already normalised ("raw" → "tcp", "h2" → "http").
    public let network: String
    /// "none", "tls" or "reality".
    public let security: String
    public let serverName: String?
    public let fingerprint: String?
    public let publicKey: String?
    public let shortId: String?
    public let spiderX: String?
    public let alpn: [String]
    public let path: String?
    public let host: String?
    public let serviceName: String?
    /// TCP header disguise ("http") — the one `headerType` value that is worth carrying.
    public let headerType: String?
    /// gRPC multi-mode / xhttp mode, whichever the transport reads it as.
    public let mode: String?
    public let allowInsecure: Bool
    /// The original URI. Kept so a configuration can be exported back to the clipboard exactly
    /// as it arrived, which is the only form another client will accept.
    public let link: String

    /// What the server row shows under the name: enough to tell two entries of the same
    /// subscription apart without printing the credential.
    ///
    /// Protocol first and address last, the order every VLESS client prints it in — the transport
    /// is what the user compares two entries by, and the address is the part they scan for.
    public var summary: String {
        var parts: [String] = ["VLESS"]
        switch self.network {
        case "ws":
            parts.append("WS")
        case "grpc":
            parts.append("gRPC")
        case "http":
            parts.append("HTTP/2")
        case "httpupgrade":
            parts.append("HTTPUpgrade")
        case "xhttp":
            parts.append("XHTTP")
        default:
            parts.append("TCP")
        }
        if self.security == "reality" {
            parts.append("Reality")
        } else if self.security == "tls" {
            parts.append("TLS")
        }
        if self.flow == "xtls-rprx-vision" {
            parts.append("Vision")
        }
        parts.append("\(self.address):\(self.port)")
        return parts.joined(separator: " · ")
    }
}

/// What a pasted blob turned out to be.
public enum AorusVlessImport: Equatable {
    case servers([AorusVlessServer])
    /// A subscription URL, which has to be fetched before there is anything to connect to.
    case subscription(String)
}

/// `Error` as well as `Equatable`: the parse and subscription paths both hand this back through
/// `Result`, whose `Failure` has to conform, and the UI compares cases to pick a message.
public enum AorusVlessImportError: Error, Equatable {
    /// Nothing on the clipboard, or nothing but whitespace.
    case empty
    /// Recognisably a proxy key, but not one this client can carry (vmess, ss, trojan, or a
    /// VLESS transport that would need a different core configuration).
    case unsupported
    /// Meant to be a VLESS link and is not one.
    case malformed
    /// A subscription served over plain HTTP. The response is the credential, so this is
    /// refused rather than downgraded.
    case insecureSubscription
    /// The exact key set or subscription is already present. Existing subscriptions have their
    /// own refresh action, so importing them again must not create an indistinguishable card.
    case duplicate
}

/// Everything that turns text into servers, and servers into Xray configurations.
public enum AorusVlessLink {
    /// Xray transports this client can build a working outbound for. A key using anything else
    /// is refused at import: accepting it would produce a configuration the core rejects, and
    /// the user would see "does not connect" instead of "not supported".
    private static let supportedNetworks: Set<String> = ["tcp", "ws", "grpc", "http", "httpupgrade", "xhttp"]
    private static let supportedSecurities: Set<String> = ["none", "tls", "reality"]
    /// uTLS ClientHello shapes. Same list the signed profile allows, for the same reason: an
    /// unknown fingerprint is a configuration the core will not start.
    private static let supportedFingerprints: Set<String> = [
        "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"
    ]

    /// Parse whatever the user pasted.
    ///
    /// Three shapes are accepted because all three are what people actually copy: one or more
    /// `vless://` lines, the base64 blob a subscription endpoint returns (people copy the
    /// response as often as the URL), and the subscription URL itself.
    public static func parse(_ raw: String) -> Result<AorusVlessImport, AorusVlessImportError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512_000 else {
            return .failure(.empty)
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") {
            return .failure(.insecureSubscription)
        }
        if lowercased.hasPrefix("https://") {
            guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let url = URL(string: trimmed), url.host != nil else {
                return .failure(.malformed)
            }
            return .success(.subscription(trimmed))
        }

        var body = trimmed
        if !lowercased.contains("://") {
            // A subscription response is base64 of the same newline-separated links, so the
            // decode is tried before giving up rather than as a special case the user has to
            // know about.
            guard let decoded = decodeBase64Text(trimmed) else {
                return .failure(.malformed)
            }
            body = decoded
        }

        var servers: [AorusVlessServer] = []
        var seen = Set<String>()
        var sawOtherProtocol = false
        var sawUnsupportedVless = false
        for line in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else { continue }
            let lowerCandidate = candidate.lowercased()
            guard lowerCandidate.hasPrefix("vless://") else {
                if lowerCandidate.contains("://") {
                    sawOtherProtocol = true
                }
                continue
            }
            guard let server = parseServer(candidate) else {
                sawUnsupportedVless = true
                continue
            }
            guard !seen.contains(server.id) else { continue }
            seen.insert(server.id)
            servers.append(server)
        }

        if servers.isEmpty {
            if sawUnsupportedVless || sawOtherProtocol {
                return .failure(.unsupported)
            }
            return .failure(.malformed)
        }
        return .success(.servers(servers))
    }

    /// One `vless://` URI, or nil when it is not one this client can carry.
    ///
    /// Split by hand rather than through `URLComponents`. Remarks routinely contain unencoded
    /// spaces, emoji and country flags, and `URLComponents(string:)` returns nil for the whole
    /// URI when it sees one — which would silently drop the servers with the friendliest names.
    public static func parseServer(_ uri: String) -> AorusVlessServer? {
        guard uri.count <= 4096 else { return nil }
        let withoutScheme = String(uri.dropFirst("vless://".count))
        guard !withoutScheme.isEmpty else { return nil }

        var rest = withoutScheme
        var remark: String?
        if let hash = rest.firstIndex(of: "#") {
            let fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
            let decoded = fragment.removingPercentEncoding ?? fragment
            let cleaned = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                remark = String(cleaned.prefix(64))
            }
        }
        var query: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            let queryText = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
            for pair in queryText.split(separator: "&") {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                let key = String(pair[..<equals]).lowercased()
                let rawValue = String(pair[pair.index(after: equals)...])
                let value = (rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue)
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !value.isEmpty else { continue }
                query[key] = value
            }
        }
        // Last "@", not first: a userinfo section is a UUID and holds no "@", while a hostname
        // never does, so the last one is the separator even if a client encoded something odd.
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let userInfo = String(rest[..<at])
        let hostPort = String(rest[rest.index(after: at)...])

        let rawUserId = (userInfo.removingPercentEncoding ?? userInfo).trimmingCharacters(in: .whitespaces)
        guard let uuid = UUID(uuidString: rawUserId) else { return nil }
        let userId = uuid.uuidString.lowercased()

        guard let (address, port) = splitHostPort(hostPort) else { return nil }

        var network = (query["type"] ?? query["net"] ?? "tcp").lowercased()
        if network == "raw" || network.isEmpty {
            network = "tcp"
        }
        if network == "h2" {
            network = "http"
        }
        guard supportedNetworks.contains(network) else { return nil }

        var security = (query["security"] ?? "none").lowercased()
        if security.isEmpty {
            security = "none"
        }
        guard supportedSecurities.contains(security) else { return nil }

        var flow = (query["flow"] ?? "").lowercased()
        if flow != "xtls-rprx-vision" {
            flow = ""
        }

        var fingerprint = (query["fp"] ?? "").lowercased()
        if !fingerprint.isEmpty, !supportedFingerprints.contains(fingerprint) {
            // An unrecognised shape is dropped rather than refused: the connection works
            // without one, and a censor recognising Xray's default handshake is a milder
            // failure than an import the user cannot complete.
            fingerprint = ""
        }
        if security == "reality", fingerprint.isEmpty {
            fingerprint = "chrome"
        }

        let sni = query["sni"] ?? query["peer"]
        let hostHeader = query["host"]
        let serverName = normalizedHostname(sni) ?? normalizedHostname(hostHeader)
        let publicKey = query["pbk"]
        if security == "reality" {
            // REALITY without the server's public key cannot complete its handshake, and
            // without a name to present it has nothing to imitate.
            guard let publicKey, !publicKey.isEmpty, publicKey.count <= 128,
                  serverName != nil else {
                return nil
            }
        }

        var path = query["path"]
        if let value = path, !value.hasPrefix("/") {
            path = "/" + value
        }
        if let value = path, value.count > 512 {
            return nil
        }

        let alpn = (query["alpn"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 16 }
        let allowInsecure = ["1", "true", "yes"].contains((query["allowinsecure"] ?? "").lowercased())

        // Every value that changes the wire handshake belongs to the identity. REALITY
        // subscriptions often publish several credentials on the same host and UUID; omitting
        // pbk/sid/SNI here can collapse them into one row and leave a stale core running.
        //
        // The fields are appended one at a time on purpose. As a single eighteen-element literal
        // mixing `??`, a ternary and method calls, the element type has to be inferred from all of
        // them at once and the compiler gives up: "unable to type-check this expression in
        // reasonable time". Against `append`'s known `String` the same expressions check instantly.
        var canonicalFields: [String] = []
        canonicalFields.append(address)
        canonicalFields.append(String(port))
        canonicalFields.append(userId)
        canonicalFields.append(flow)
        canonicalFields.append(network)
        canonicalFields.append(security)
        canonicalFields.append(serverName ?? "")
        canonicalFields.append(fingerprint)
        canonicalFields.append(publicKey ?? "")
        canonicalFields.append(query["sid"] ?? "")
        canonicalFields.append(query["spx"] ?? "")
        canonicalFields.append(alpn.joined(separator: ","))
        canonicalFields.append(path ?? "")
        canonicalFields.append(normalizedHostname(hostHeader) ?? "")
        canonicalFields.append(query["servicename"] ?? "")
        canonicalFields.append((query["headertype"] ?? "").lowercased())
        canonicalFields.append((query["mode"] ?? "").lowercased())
        canonicalFields.append(allowInsecure ? "1" : "0")
        let canonical = canonicalFields.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()

        return AorusVlessServer(
            id: digest,
            name: remark ?? "\(address):\(port)",
            address: address,
            port: port,
            userId: userId,
            flow: flow,
            network: network,
            security: security,
            serverName: serverName,
            fingerprint: fingerprint.isEmpty ? nil : fingerprint,
            publicKey: publicKey,
            shortId: query["sid"],
            spiderX: query["spx"],
            alpn: alpn,
            path: path,
            host: normalizedHostname(hostHeader),
            serviceName: query["servicename"],
            headerType: (query["headertype"] ?? "").lowercased() == "http" ? "http" : nil,
            mode: query["mode"]?.lowercased(),
            allowInsecure: allowInsecure,
            link: uri
        )
    }

    /// The Xray configuration for one user server on one loopback port.
    ///
    /// Same shape as the signed lane's: one SOCKS inbound on 127.0.0.1 and one VLESS outbound,
    /// with no routing table because there is only one place traffic can go. Nothing here is a
    /// system-wide tunnel — the inbound is a loopback socket, and the only thing pointed at it
    /// is this app's own MTProto connection.
    public static func xrayConfiguration(
        server: AorusVlessServer,
        localPort: Int,
        udpEnabled: Bool,
        muxEnabled: Bool
    ) -> String? {
        var user: [String: Any] = [
            "id": server.userId,
            "encryption": "none"
        ]
        if !server.flow.isEmpty {
            user["flow"] = server.flow
        }
        var settings: [String: Any] = [
            "vnext": [[
                "address": server.address,
                "port": server.port,
                "users": [user]
            ]]
        ]
        // "xudp" is what makes UDP over VLESS work at all; "none" is the honest way to say the
        // user turned it off, rather than omitting the key and getting the core's default.
        settings["packetEncoding"] = udpEnabled ? "xudp" : "none"

        var streamSettings: [String: Any] = [
            "network": server.network,
            "security": server.security
        ]
        switch server.security {
        case "reality":
            var reality: [String: Any] = [
                "serverName": server.serverName ?? "",
                "publicKey": server.publicKey ?? "",
                "fingerprint": server.fingerprint ?? "chrome"
            ]
            if let shortId = server.shortId {
                reality["shortId"] = shortId
            }
            if let spiderX = server.spiderX {
                reality["spiderX"] = spiderX
            }
            streamSettings["realitySettings"] = reality
        case "tls":
            var tls: [String: Any] = [
                "serverName": server.serverName ?? server.address,
                "allowInsecure": server.allowInsecure
            ]
            if let fingerprint = server.fingerprint {
                tls["fingerprint"] = fingerprint
            }
            if !server.alpn.isEmpty {
                tls["alpn"] = server.alpn
            }
            streamSettings["tlsSettings"] = tls
        default:
            break
        }

        switch server.network {
        case "ws":
            var ws: [String: Any] = ["path": server.path ?? "/"]
            if let host = server.host {
                ws["headers"] = ["Host": host]
            }
            streamSettings["wsSettings"] = ws
        case "httpupgrade":
            var upgrade: [String: Any] = ["path": server.path ?? "/"]
            if let host = server.host {
                upgrade["host"] = host
            }
            streamSettings["httpupgradeSettings"] = upgrade
        case "xhttp":
            var xhttp: [String: Any] = ["path": server.path ?? "/"]
            if let host = server.host {
                xhttp["host"] = host
            }
            if let mode = server.mode {
                xhttp["mode"] = mode
            }
            streamSettings["xhttpSettings"] = xhttp
        case "grpc":
            streamSettings["grpcSettings"] = [
                "serviceName": server.serviceName ?? "",
                "multiMode": server.mode == "multi"
            ]
        case "http":
            var http: [String: Any] = ["path": server.path ?? "/"]
            if let host = server.host {
                http["host"] = [host]
            }
            streamSettings["httpSettings"] = http
        default:
            if server.headerType == "http" {
                var request: [String: Any] = ["path": [server.path ?? "/"]]
                if let host = server.host {
                    request["headers"] = ["Host": [host]]
                }
                streamSettings["tcpSettings"] = ["header": ["type": "http", "request": request]]
            }
        }

        var outbound: [String: Any] = [
            "tag": "aorus-user-vless",
            "protocol": "vless",
            "settings": settings,
            "streamSettings": streamSettings
        ]
        // XTLS Vision multiplexes at the TLS layer and refuses to share a connection with
        // Xray's own mux, so the two are never on at once whatever the user asked for.
        let mux = muxEnabled && server.flow.isEmpty
        outbound["mux"] = ["enabled": mux, "concurrency": mux ? 8 : -1]

        let config: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "tag": "aorus-user-socks",
                "listen": "127.0.0.1",
                "port": localPort,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": udpEnabled, "ip": "127.0.0.1"]
            ]],
            "outbounds": [outbound]
        ]
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func splitHostPort(_ value: String) -> (String, Int)? {
        var hostPart = value
        var portPart = ""
        if value.hasPrefix("[") {
            // Bracketed IPv6 literal: the colons inside the brackets are part of the address.
            guard let close = value.firstIndex(of: "]") else { return nil }
            hostPart = String(value[value.index(after: value.startIndex) ..< close])
            let after = value[value.index(after: close)...]
            guard after.isEmpty || after.hasPrefix(":") else { return nil }
            portPart = String(after.dropFirst())
        } else if let colon = value.lastIndex(of: ":") {
            hostPart = String(value[..<colon])
            portPart = String(value[value.index(after: colon)...])
        }
        guard let port = Int(portPart), (1 ... 65_535).contains(port) else { return nil }
        let host = hostPart.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, host.count <= 255 else { return nil }
        guard host != "0.0.0.0", host != "::", host != "localhost", !host.hasPrefix("127.") else {
            // A loopback dial target would point the outbound at our own inbound.
            return nil
        }
        guard host.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d || byte == 0x2e || byte == 0x3a
        }) else {
            return nil
        }
        return (host, port)
    }

    private static func normalizedHostname(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        guard trimmed.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d || byte == 0x2e
        }) else {
            return nil
        }
        return trimmed
    }

    /// Base64 in either alphabet, with or without padding, ignoring the line breaks some
    /// subscription endpoints wrap their output in.
    static func decodeBase64Text(_ value: String) -> String? {
        let compact = value.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count <= 512_000 else { return nil }
        var base64 = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
