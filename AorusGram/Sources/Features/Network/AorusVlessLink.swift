import Foundation
import CryptoKit

/// One proxy server the user brought themselves, and the Xray configuration it turns into.
///
/// The type is still called `AorusVlessServer` because that is what is on disk in every install
/// that already has a configuration, but it is no longer VLESS-only: it carries any key the
/// in-process Xray core can dial — VLESS, VMess, Trojan and Shadowsocks. `proto` says which, and
/// the fields a given protocol has no use for are simply empty.
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
    /// Which Xray outbound this becomes: "vless", "vmess", "trojan" or "shadowsocks".
    public let proto: String
    public let address: String
    public let port: Int
    /// The credential: the UUID for VLESS and VMess, the password for Trojan and Shadowsocks.
    public let credential: String
    /// The VMess cipher ("auto", "aes-128-gcm", …) or the Shadowsocks method ("aes-256-gcm", …).
    /// Empty for VLESS and Trojan, neither of which has a cipher of its own.
    public let encryption: String
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

    public init(
        id: String,
        name: String,
        proto: String,
        address: String,
        port: Int,
        credential: String,
        encryption: String,
        flow: String,
        network: String,
        security: String,
        serverName: String?,
        fingerprint: String?,
        publicKey: String?,
        shortId: String?,
        spiderX: String?,
        alpn: [String],
        path: String?,
        host: String?,
        serviceName: String?,
        headerType: String?,
        mode: String?,
        allowInsecure: Bool,
        link: String
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.address = address
        self.port = port
        self.credential = credential
        self.encryption = encryption
        self.flow = flow
        self.network = network
        self.security = security
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.shortId = shortId
        self.spiderX = spiderX
        self.alpn = alpn
        self.path = path
        self.host = host
        self.serviceName = serviceName
        self.headerType = headerType
        self.mode = mode
        self.allowInsecure = allowInsecure
        self.link = link
    }

    /// Decoded field by field, and `credential` falls back to the `userId` key the VLESS-only
    /// versions of this build wrote. A server list that fails to decode is a user who opens the
    /// screen to find their subscription gone, so every field a later build added has a default
    /// and the one that was renamed still reads its old name.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.proto = try container.decodeIfPresent(String.self, forKey: .proto) ?? "vless"
        self.address = try container.decode(String.self, forKey: .address)
        self.port = try container.decode(Int.self, forKey: .port)
        if let credential = try container.decodeIfPresent(String.self, forKey: .credential) {
            self.credential = credential
        } else {
            self.credential = try container.decode(String.self, forKey: .userId)
        }
        self.encryption = try container.decodeIfPresent(String.self, forKey: .encryption) ?? ""
        self.flow = try container.decodeIfPresent(String.self, forKey: .flow) ?? ""
        self.network = try container.decodeIfPresent(String.self, forKey: .network) ?? "tcp"
        self.security = try container.decodeIfPresent(String.self, forKey: .security) ?? "none"
        self.serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        self.fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        self.publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        self.shortId = try container.decodeIfPresent(String.self, forKey: .shortId)
        self.spiderX = try container.decodeIfPresent(String.self, forKey: .spiderX)
        self.alpn = try container.decodeIfPresent([String].self, forKey: .alpn) ?? []
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.host = try container.decodeIfPresent(String.self, forKey: .host)
        self.serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        self.headerType = try container.decodeIfPresent(String.self, forKey: .headerType)
        self.mode = try container.decodeIfPresent(String.self, forKey: .mode)
        self.allowInsecure = try container.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? false
        self.link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
    }

    /// Written by hand for the same reason the decoder is: `userId` is a key with no property, so
    /// the compiler cannot synthesize this half either. Nothing writes `userId` any more — a build
    /// that reads this back knows `credential`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.proto, forKey: .proto)
        try container.encode(self.address, forKey: .address)
        try container.encode(self.port, forKey: .port)
        try container.encode(self.credential, forKey: .credential)
        try container.encode(self.encryption, forKey: .encryption)
        try container.encode(self.flow, forKey: .flow)
        try container.encode(self.network, forKey: .network)
        try container.encode(self.security, forKey: .security)
        try container.encodeIfPresent(self.serverName, forKey: .serverName)
        try container.encodeIfPresent(self.fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(self.publicKey, forKey: .publicKey)
        try container.encodeIfPresent(self.shortId, forKey: .shortId)
        try container.encodeIfPresent(self.spiderX, forKey: .spiderX)
        try container.encode(self.alpn, forKey: .alpn)
        try container.encodeIfPresent(self.path, forKey: .path)
        try container.encodeIfPresent(self.host, forKey: .host)
        try container.encodeIfPresent(self.serviceName, forKey: .serviceName)
        try container.encodeIfPresent(self.headerType, forKey: .headerType)
        try container.encodeIfPresent(self.mode, forKey: .mode)
        try container.encode(self.allowInsecure, forKey: .allowInsecure)
        try container.encode(self.link, forKey: .link)
    }

    /// Spelled out because `userId` is a decoding-only key: it is what the older builds wrote for
    /// what is now `credential`, and a synthesized key set would not contain it.
    private enum CodingKeys: String, CodingKey {
        case id, name, proto, address, port, credential, userId, encryption, flow, network
        case security, serverName, fingerprint, publicKey, shortId, spiderX, alpn, path, host
        case serviceName, headerType, mode, allowInsecure, link
    }

    /// How the protocol is spelled in every other client's interface.
    public var protocolTitle: String {
        switch self.proto {
        case "vmess":
            return "VMess"
        case "trojan":
            return "Trojan"
        case "shadowsocks":
            return "Shadowsocks"
        default:
            return "VLESS"
        }
    }

    /// What the server row shows under the name: enough to tell two entries of the same
    /// subscription apart without printing the credential.
    ///
    /// Protocol first and address last, the order every VLESS client prints it in — the transport
    /// is what the user compares two entries by, and the address is the part they scan for.
    public var summary: String {
        var parts: [String] = [self.protocolTitle]
        if self.proto == "shadowsocks" {
            // Shadowsocks has no transport and no TLS layer of its own, so the cipher is the only
            // thing there is to say about the wire — and it is what a user picks between.
            if !self.encryption.isEmpty {
                parts.append(self.encryption.uppercased())
            }
            parts.append("\(self.address):\(self.port)")
            return parts.joined(separator: " | ")
        }
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
        return parts.joined(separator: " | ")
    }

    /// The same line without the address, for a row that also has to fit a measured handshake and a
    /// "best server" label on one line of a list. The address is what a hostname of any length
    /// truncates away, and of the three it is the one the row's own title already stands for.
    public var transportSummary: String {
        var parts = self.summary.components(separatedBy: " | ")
        if !parts.isEmpty {
            parts.removeLast()
        }
        return parts.joined(separator: " | ")
    }
}

/// What a pasted blob turned out to be.
public enum AorusVlessImport: Equatable {
    case servers([AorusVlessServer])
    /// Subscription URLs, which have to be fetched before there is anything to connect to. Plural
    /// because a message with two links in it is one paste, and importing the first while silently
    /// dropping the second is worse than either.
    case subscriptions([String])
}

/// `Error` as well as `Equatable`: the parse and subscription paths both hand this back through
/// `Result`, whose `Failure` has to conform, and the UI compares cases to pick a message.
public enum AorusVlessImportError: Error, Equatable {
    /// Nothing on the clipboard, or nothing but whitespace.
    case empty
    /// Recognisably a proxy key, but not one this core can carry: Hysteria2, TUIC and WireGuard
    /// links, a `happ://crypt…` deep link, or a transport no Xray outbound implements.
    case unsupported
    /// Meant to be a proxy key and is not one.
    case malformed
    /// A subscription served over plain HTTP. The response is the credential, so this is
    /// refused rather than downgraded.
    case insecureSubscription
    /// The exact key set or subscription is already present. Existing subscriptions have their
    /// own refresh action, so importing them again must not create an indistinguishable card.
    case duplicate
    /// The panel answered, and what it answered is "this account has no device slot left". It sends
    /// a list of unusable placeholder nodes in that case, which is indistinguishable from a damaged
    /// response unless the header that says so is read.
    case deviceLimit
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
    /// VMess ciphers Xray still implements. "auto" is what every current link carries.
    private static let supportedVmessCiphers: Set<String> = [
        "auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"
    ]
    /// Shadowsocks methods Xray implements, in the spelling its configuration expects. The
    /// aliases every other client emits are folded onto these at parse time.
    private static let supportedShadowsocksMethods: Set<String> = [
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
        "chacha20-poly1305", "xchacha20-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "none", "plain"
    ]
    /// Every scheme this parser will look at. `hysteria2`, `hy2`, `tuic` and `wireguard` are
    /// deliberately absent and named here so the refusal can say why: they are separate protocols
    /// that Xray has no outbound for, so accepting one would produce a card that cannot connect.
    private static let keySchemes = ["vless://", "vmess://", "trojan://", "ss://"]
    private static let foreignSchemes = [
        "hysteria://", "hysteria2://", "hy2://", "tuic://", "wireguard://", "wg://",
        "juicity://", "snell://", "ssr://", "socks://", "socks5://"
    ]

    /// Parse whatever the user pasted.
    ///
    /// Everything people actually copy is accepted: one key or a list of them in any of the four
    /// protocols the core can dial, the base64 blob a subscription endpoint answers with (the
    /// response gets copied as often as the URL), one or more subscription URLs, and the
    /// `happ://` deep links that channels hand out instead of a plain link.
    ///
    /// The scan is line by line rather than a decision made from the first characters of the
    /// paste: a message copied out of a channel routinely has a subscription URL, three keys and
    /// two lines of prose in it, and the shape of the first line is no guide to the rest.
    public static func parse(_ raw: String) -> Result<AorusVlessImport, AorusVlessImportError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512_000 else {
            return .failure(.empty)
        }

        var body = trimmed
        if let unwrapped = unwrapDeepLink(trimmed) {
            body = unwrapped
        } else if trimmed.lowercased().hasPrefix("happ://") {
            // A `happ://crypt…` link carries the servers encrypted under that client's own key.
            // There is nothing to parse and nothing to ask for, so it is named rather than
            // reported as damaged text.
            return .failure(.unsupported)
        }
        if !body.lowercased().contains("://"), let decoded = decodeBase64Text(body) {
            // A subscription response is base64 of the same newline-separated links, so the
            // decode is tried before giving up rather than as a special case the user has to
            // know about.
            body = decoded
        }
        // A panel answers in whatever notation the client that asked is known to read, and it picks
        // that from the user agent rather than from anything the request can say. So a body may be
        // a configuration document instead of a list of links, and it describes the same servers.
        if let parsed = parseConfigurationBody(body) {
            return parsed.isEmpty ? .failure(.unsupported) : .success(.servers(parsed))
        }

        var servers: [AorusVlessServer] = []
        var seen = Set<String>()
        var subscriptions: [String] = []
        var sawInsecureSubscription = false
        var sawForeignProtocol = false
        var sawBrokenKey = false
        for line in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate.contains("://") else { continue }
            let lowerCandidate = candidate.lowercased()
            if lowerCandidate.hasPrefix("https://") {
                if let url = URL(string: candidate), url.host != nil, !subscriptions.contains(candidate) {
                    subscriptions.append(candidate)
                }
                continue
            }
            if lowerCandidate.hasPrefix("http://") {
                sawInsecureSubscription = true
                continue
            }
            guard keySchemes.contains(where: { lowerCandidate.hasPrefix($0) }) else {
                if foreignSchemes.contains(where: { lowerCandidate.hasPrefix($0) }) {
                    sawForeignProtocol = true
                }
                continue
            }
            guard let server = parseKey(candidate) else {
                sawBrokenKey = true
                continue
            }
            guard !seen.contains(server.id) else { continue }
            seen.insert(server.id)
            servers.append(server)
        }

        // Keys win over subscription URLs when a paste has both: the keys are already usable, and
        // a fetch that fails would otherwise throw away servers that parsed.
        if !servers.isEmpty {
            return .success(.servers(servers))
        }
        if !subscriptions.isEmpty {
            return .success(.subscriptions(subscriptions))
        }
        if sawForeignProtocol {
            return .failure(.unsupported)
        }
        if sawInsecureSubscription {
            return .failure(.insecureSubscription)
        }
        if sawBrokenKey {
            return .failure(.malformed)
        }
        return .failure(.malformed)
    }

    /// The payload of a client deep link, or nil when this is not one.
    ///
    /// Channels hand out `happ://add/<url>` and its relatives instead of a bare link, and a user
    /// who taps "copy" gets the deep link. The command segment is dropped and the rest is treated
    /// as what it turns out to be — a percent-encoded URL, or base64 of a list of keys — because
    /// which of the two a given command carries is not something to hardcode.
    static func unwrapDeepLink(_ value: String) -> String? {
        let lowercased = value.lowercased()
        let schemes = ["happ://", "v2raytun://", "streisand://", "shadowrocket://", "sn://"]
        guard let scheme = schemes.first(where: { lowercased.hasPrefix($0) }) else { return nil }
        var payload = String(value.dropFirst(scheme.count))
        let firstSegment = payload.lowercased().split(separator: "/").first.map(String.init) ?? ""
        // `crypt`…`crypt5` payloads are encrypted under the other client's own key, and `routing`
        // carries a rule set rather than servers. Neither is text to parse, so both are handed back
        // as "not a deep link we can open" and named as unsupported rather than as damaged.
        guard firstSegment != "routing", !firstSegment.hasPrefix("crypt") else { return nil }
        for command in ["add/", "import/", "install/", "sub/", "subscription/", "import-config/"] {
            if payload.lowercased().hasPrefix(command) {
                payload = String(payload.dropFirst(command.count))
                break
            }
        }
        payload = payload.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !payload.isEmpty else { return nil }
        let decoded = (payload.removingPercentEncoding ?? payload).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        if decoded.contains("://") {
            return decoded
        }
        return decodeBase64Text(decoded) ?? decoded
    }

    /// One proxy URI, whichever of the four protocols it is written in.
    ///
    /// The scheme is rewritten in lower case before it is handed on: a key pasted out of a document
    /// that capitalised it is the same key, and the parsers below match their scheme exactly.
    public static func parseKey(_ uri: String) -> AorusVlessServer? {
        guard uri.count <= 8192 else { return nil }
        let lowercased = uri.lowercased()
        guard let scheme = keySchemes.first(where: { lowercased.hasPrefix($0) }) else { return nil }
        let normalized = scheme + String(uri.dropFirst(scheme.count))
        switch scheme {
        case "vmess://":
            return parseVmess(normalized)
        case "trojan://":
            return parseTrojan(normalized)
        case "ss://":
            return parseShadowsocks(normalized)
        default:
            return parseServer(normalized)
        }
    }

    /// One `vless://` URI, or nil when it is not one this client can carry.
    public static func parseServer(_ uri: String) -> AorusVlessServer? {
        guard let parts = splitUri(uri, scheme: "vless://") else { return nil }
        let rawUserId = (parts.userInfo.removingPercentEncoding ?? parts.userInfo)
            .trimmingCharacters(in: .whitespaces)
        guard let uuid = UUID(uuidString: rawUserId) else { return nil }
        return makeServer(
            proto: "vless",
            credential: uuid.uuidString.lowercased(),
            encryption: "",
            address: parts.address,
            port: parts.port,
            query: parts.query,
            remark: parts.remark,
            link: uri
        )
    }

    /// One `vmess://` key, in either of the two shapes clients publish.
    ///
    /// The old shape is base64 of a JSON object; the AEAD shape is a URI just like VLESS's. Either
    /// way `alterId` is dropped: Xray removed the legacy MD5 authentication that non-zero values
    /// selected, so 0 is the only value that can still connect anywhere.
    public static func parseVmess(_ uri: String) -> AorusVlessServer? {
        guard uri.count <= 8192, uri.hasPrefix("vmess://") else { return nil }
        let body = String(uri.dropFirst("vmess://".count))
        guard !body.isEmpty else { return nil }

        if body.contains("@") {
            // AEAD shape.
            guard let parts = splitUri(uri, scheme: "vmess://") else { return nil }
            let rawId = (parts.userInfo.removingPercentEncoding ?? parts.userInfo)
                .trimmingCharacters(in: .whitespaces)
            guard let uuid = UUID(uuidString: rawId) else { return nil }
            return makeServer(
                proto: "vmess",
                credential: uuid.uuidString.lowercased(),
                encryption: vmessCipher(parts.query["encryption"] ?? parts.query["scy"]),
                address: parts.address,
                port: parts.port,
                query: parts.query,
                remark: parts.remark,
                link: uri
            )
        }

        guard let text = decodeBase64Text(body),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any] else {
            return nil
        }
        // Clients disagree on the case of every key in this object, and a key read with the wrong
        // case is a field silently lost rather than an error the user can see.
        var fields: [String: Any] = [:]
        for (key, value) in raw {
            fields[key.lowercased()] = value
        }
        guard let host = jsonString(fields["add"]),
              let portText = jsonString(fields["port"]), let portNumber = Int(portText),
              let rawId = jsonString(fields["id"]), let uuid = UUID(uuidString: rawId) else {
            return nil
        }
        // Routed through the same host check as every other key, including the IPv6 literals that
        // this shape writes unbracketed.
        let bracketed = host.contains(":") ? "[\(host)]:\(portNumber)" : "\(host):\(portNumber)"
        guard let (address, port) = splitHostPort(bracketed) else { return nil }

        var query: [String: String] = [:]
        let network = (jsonString(fields["net"]) ?? "tcp").lowercased()
        query["type"] = network
        if let headerType = jsonString(fields["type"]) { query["headertype"] = headerType }
        if let value = jsonString(fields["host"]) { query["host"] = value }
        if let value = jsonString(fields["path"]) { query["path"] = value }
        if let value = jsonString(fields["tls"]) { query["security"] = value }
        if let value = jsonString(fields["sni"]) { query["sni"] = value }
        if let value = jsonString(fields["alpn"]) { query["alpn"] = value }
        if let value = jsonString(fields["fp"]) { query["fp"] = value }
        if let value = jsonString(fields["mode"]) { query["mode"] = value }
        if let value = jsonString(fields["pbk"]) { query["pbk"] = value }
        if let value = jsonString(fields["sid"]) { query["sid"] = value }
        if let value = jsonString(fields["spx"]) { query["spx"] = value }
        if let value = jsonString(fields["allowinsecure"]) { query["allowinsecure"] = value }
        if network == "grpc" {
            // gRPC has no path; this shape puts the service name where a path would go.
            query["servicename"] = jsonString(fields["servicename"]) ?? jsonString(fields["path"])
            query["path"] = nil
        }
        return makeServer(
            proto: "vmess",
            credential: uuid.uuidString.lowercased(),
            encryption: vmessCipher(jsonString(fields["scy"]) ?? jsonString(fields["security"])),
            address: address,
            port: port,
            query: query,
            remark: jsonString(fields["ps"]).map { String($0.prefix(64)) },
            link: uri
        )
    }

    /// One `trojan://password@host:port` key. Trojan is TLS by definition, so a key that names no
    /// security still gets it rather than being read as plaintext.
    public static func parseTrojan(_ uri: String) -> AorusVlessServer? {
        guard let parts = splitUri(uri, scheme: "trojan://") else { return nil }
        let password = (parts.userInfo.removingPercentEncoding ?? parts.userInfo)
        guard !password.isEmpty, password.count <= 256 else { return nil }
        var query = parts.query
        if (query["security"] ?? "").isEmpty {
            query["security"] = "tls"
        }
        return makeServer(
            proto: "trojan",
            credential: password,
            encryption: "",
            address: parts.address,
            port: parts.port,
            query: query,
            remark: parts.remark,
            link: uri
        )
    }

    /// One `ss://` key: the SIP002 shape, the shape with a plaintext userinfo section, and the
    /// legacy shape where everything after the scheme is one base64 blob.
    public static func parseShadowsocks(_ uri: String) -> AorusVlessServer? {
        guard uri.count <= 4096, uri.hasPrefix("ss://") else { return nil }
        var rest = String(uri.dropFirst("ss://".count))
        guard !rest.isEmpty else { return nil }

        var remark: String?
        if let hash = rest.firstIndex(of: "#") {
            let fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
            let decoded = (fragment.removingPercentEncoding ?? fragment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty {
                remark = String(decoded.prefix(64))
            }
        }
        var queryText = ""
        if let mark = rest.firstIndex(of: "?") {
            queryText = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
        }
        if !rest.contains("@"), let decoded = decodeBase64Text(rest) {
            // Legacy shape: "method:password@host:port" was base64'd whole.
            rest = decoded
        }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        var userInfo = String(rest[..<at]).removingPercentEncoding ?? String(rest[..<at])
        if !userInfo.contains(":"), let decoded = decodeBase64Text(userInfo) {
            userInfo = decoded
        }
        guard let separator = userInfo.firstIndex(of: ":") else { return nil }
        let method = shadowsocksMethod(String(userInfo[..<separator]))
        let password = String(userInfo[userInfo.index(after: separator)...])
        guard supportedShadowsocksMethods.contains(method), !password.isEmpty,
              password.count <= 256 else {
            return nil
        }
        guard let (address, port) = splitHostPort(String(rest[rest.index(after: at)...])) else {
            return nil
        }
        let query = parseQuery(queryText)
        // A plugin — obfs, v2ray-plugin, shadow-tls — is a second program on the wire, and the
        // in-process core has no way to run one.
        guard query["plugin"] == nil else { return nil }
        return makeServer(
            proto: "shadowsocks",
            credential: password,
            encryption: method,
            address: address,
            port: port,
            query: query,
            remark: remark,
            link: uri
        )
    }

    /// The parts of a `scheme://userinfo@host:port?query#remark` key.
    private struct UriParts {
        let userInfo: String
        let address: String
        let port: Int
        let query: [String: String]
        let remark: String?
    }

    /// Split by hand rather than through `URLComponents`. Remarks routinely contain unencoded
    /// spaces, emoji and country flags, and `URLComponents(string:)` returns nil for the whole
    /// URI when it sees one — which would silently drop the servers with the friendliest names.
    private static func splitUri(_ uri: String, scheme: String) -> UriParts? {
        guard uri.count <= 8192, uri.hasPrefix(scheme) else { return nil }
        var rest = String(uri.dropFirst(scheme.count))
        guard !rest.isEmpty else { return nil }

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
            query = parseQuery(String(rest[rest.index(after: mark)...]))
            rest = String(rest[..<mark])
        }
        // Last "@", not first: a userinfo section holds a credential, which may carry an "@" when
        // a client failed to encode it, while a hostname never does.
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let userInfo = String(rest[..<at])
        guard !userInfo.isEmpty else { return nil }
        guard let (address, port) = splitHostPort(String(rest[rest.index(after: at)...])) else {
            return nil
        }
        return UriParts(userInfo: userInfo, address: address, port: port, query: query, remark: remark)
    }

    private static func parseQuery(_ text: String) -> [String: String] {
        var query: [String: String] = [:]
        for pair in text.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<equals]).lowercased()
            let rawValue = String(pair[pair.index(after: equals)...])
            let value = (rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue)
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            query[key] = value
        }
        return query
    }

    /// A JSON value that may have been written as a string or as a number, as text.
    private static func jsonString(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    /// A cipher VMess actually has. An unrecognised one becomes "auto" rather than a refused
    /// import: "auto" is negotiated with the server, so it connects wherever the named one would.
    private static func vmessCipher(_ value: String?) -> String {
        let cipher = (value ?? "").lowercased()
        return supportedVmessCiphers.contains(cipher) ? cipher : "auto"
    }

    /// A Shadowsocks method in the spelling Xray's configuration expects.
    ///
    /// Clash, sing-box and the SIP002 links panels write all spell the ChaCha methods with "ietf" in
    /// them, and that spelling is the same cipher. Folding it here is the difference between an
    /// import that works and a key silently refused as an unknown method.
    private static func shadowsocksMethod(_ value: String) -> String {
        let method = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch method {
        case "chacha20-ietf-poly1305":
            return "chacha20-poly1305"
        case "xchacha20-ietf-poly1305":
            return "xchacha20-poly1305"
        default:
            return method
        }
    }

    /// Everything a key of any protocol has in common: the transport, the TLS or REALITY layer,
    /// the identity digest that gives the row its id, and the name shown for it.
    private static func makeServer(
        proto: String,
        credential: String,
        encryption: String,
        address: String,
        port: Int,
        query: [String: String],
        remark: String?,
        link: String
    ) -> AorusVlessServer? {
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

        // XTLS Vision is a VLESS-only flow. Xray removed it from Trojan, and VMess never had it.
        var flow = proto == "vless" ? (query["flow"] ?? "").lowercased() : ""
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
        canonicalFields.append(proto)
        canonicalFields.append(address)
        canonicalFields.append(String(port))
        canonicalFields.append(credential)
        canonicalFields.append(encryption)
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
            proto: proto,
            address: address,
            port: port,
            credential: credential,
            encryption: encryption,
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
            link: link
        )
    }

    // MARK: - Configuration documents

    /// One outbound out of a document, with the name the document gave it.
    private struct DocumentOutbound {
        let fields: [String: Any]
        let name: String?
    }

    /// The servers in a configuration document, or nil when the body is not one.
    ///
    /// Three notations, all of which a user ends up with through no fault of their own: an Xray
    /// configuration, a list of them (which is how a panel writes one configuration per server), a
    /// sing-box configuration, and Clash's YAML. A client that reads only the base64 link list is
    /// one panel template away from importing nothing at all.
    ///
    /// Every entry is turned back into a link and parsed as one rather than mapped onto the struct
    /// field by field. That leaves a single validation path — the host, port, transport, security
    /// and identity checks in `makeServer` — and leaves the row with a link the user can copy out
    /// and paste into another client.
    static func parseConfigurationBody(_ body: String) -> [AorusVlessServer]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000_000, let first = trimmed.first else {
            return nil
        }
        if first == "{" || first == "[" {
            guard let data = trimmed.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
                return nil
            }
            let outbounds = documentOutbounds(root, name: nil, depth: 0)
            return serversFromLinks(outbounds.compactMap { outboundUri($0) })
        }
        if trimmed.hasPrefix("proxies:") || trimmed.contains("\nproxies:") {
            return serversFromLinks(clashProxyUris(trimmed))
        }
        return nil
    }

    private static func serversFromLinks(_ links: [String]) -> [AorusVlessServer] {
        var servers: [AorusVlessServer] = []
        var seen = Set<String>()
        for link in links {
            guard let server = parseKey(link), !seen.contains(server.id) else { continue }
            seen.insert(server.id)
            servers.append(server)
        }
        return servers
    }

    /// Every outbound in a JSON document, however deeply the document nests them.
    ///
    /// A panel that answers in the Xray dialect sends an array of whole configurations, each with
    /// one usable outbound in it and the server's name in `remarks`; sing-box sends one document
    /// whose outbounds carry their own names in `tag`. Both are walked by the same recursion, and
    /// the depth limit is what keeps a hostile body from turning into an unbounded walk.
    private static func documentOutbounds(_ root: Any, name: String?, depth: Int) -> [DocumentOutbound] {
        guard depth < 6 else { return [] }
        if let array = root as? [Any] {
            var result: [DocumentOutbound] = []
            for element in array {
                result.append(contentsOf: documentOutbounds(element, name: name, depth: depth + 1))
            }
            return result
        }
        guard let object = root as? [String: Any] else { return [] }
        var result: [DocumentOutbound] = []
        let documentName = jsonString(object["remarks"]) ?? jsonString(object["name"]) ?? name
        if let nested = object["outbounds"] {
            result.append(contentsOf: documentOutbounds(nested, name: documentName, depth: depth + 1))
        }
        if object["protocol"] != nil || object["type"] != nil {
            result.append(DocumentOutbound(fields: object, name: documentName))
        }
        return result
    }

    /// The link one outbound describes, or nil when it describes something that is not a server:
    /// `freedom`, `blackhole`, `dns`, a selector, or a protocol the core has no outbound for.
    private static func outboundUri(_ entry: DocumentOutbound) -> String? {
        let fields = entry.fields
        if let proto = jsonString(fields["type"])?.lowercased(), fields["server"] != nil {
            return singboxOutboundUri(fields, proto: proto, name: entry.name)
        }
        if let proto = jsonString(fields["protocol"])?.lowercased() {
            return xrayOutboundUri(fields, proto: proto, name: entry.name)
        }
        return nil
    }

    /// The Xray dialect: the address lives under `settings`, the transport under `streamSettings`.
    private static func xrayOutboundUri(
        _ fields: [String: Any],
        proto: String,
        name: String?
    ) -> String? {
        let settings = fields["settings"] as? [String: Any] ?? [:]
        let stream = fields["streamSettings"] as? [String: Any] ?? [:]
        var query = xrayStreamQuery(stream)
        // `tag` is a routing name -- "proxy", "direct" -- so it is only a fallback for the name the
        // configuration itself carries.
        let remark = name ?? jsonString(fields["tag"])
        switch proto {
        case "vless", "vmess":
            guard let vnext = (settings["vnext"] as? [[String: Any]])?.first,
                  let host = jsonString(vnext["address"]),
                  let port = jsonString(vnext["port"]),
                  let user = (vnext["users"] as? [[String: Any]])?.first,
                  let credential = jsonString(user["id"]) else {
                return nil
            }
            if proto == "vmess" {
                query["encryption"] = vmessCipher(jsonString(user["security"]))
                return buildUri(scheme: "vmess", userInfo: credential, host: host, port: port, query: query, remark: remark)
            }
            if let flow = jsonString(user["flow"]) {
                query["flow"] = flow
            }
            return buildUri(scheme: "vless", userInfo: credential, host: host, port: port, query: query, remark: remark)
        case "trojan", "shadowsocks":
            guard let server = (settings["servers"] as? [[String: Any]])?.first,
                  let host = jsonString(server["address"]),
                  let port = jsonString(server["port"]),
                  let password = jsonString(server["password"]) else {
                return nil
            }
            if proto == "trojan" {
                return buildUri(scheme: "trojan", userInfo: password, host: host, port: port, query: query, remark: remark)
            }
            guard let method = jsonString(server["method"])?.lowercased() else { return nil }
            return buildShadowsocksUri(method: method, password: password, host: host, port: port, remark: remark)
        default:
            return nil
        }
    }

    /// `streamSettings` as the query a link writes the same facts in.
    private static func xrayStreamQuery(_ stream: [String: Any]) -> [String: String] {
        var query: [String: String] = [:]
        var network = (jsonString(stream["network"]) ?? "tcp").lowercased()
        if network == "h2" {
            network = "http"
        }
        query["type"] = network
        query["security"] = (jsonString(stream["security"]) ?? "none").lowercased()
        if let tls = stream["tlsSettings"] as? [String: Any] {
            if let value = jsonString(tls["serverName"]) { query["sni"] = value }
            if let value = jsonString(tls["fingerprint"]) { query["fp"] = value }
            if let list = tls["alpn"] as? [Any] {
                query["alpn"] = list.compactMap { jsonString($0) }.joined(separator: ",")
            }
            if let value = tls["allowInsecure"] as? Bool, value { query["allowInsecure"] = "1" }
        }
        if let reality = stream["realitySettings"] as? [String: Any] {
            if let value = jsonString(reality["serverName"]) { query["sni"] = value }
            if let value = jsonString(reality["fingerprint"]) { query["fp"] = value }
            if let value = jsonString(reality["publicKey"]) { query["pbk"] = value }
            if let value = jsonString(reality["shortId"]) { query["sid"] = value }
            if let value = jsonString(reality["spiderX"]) { query["spx"] = value }
        }
        for (key, value) in xrayTransportQuery(stream, network: network) {
            query[key] = value
        }
        return query
    }

    private static func xrayTransportQuery(_ stream: [String: Any], network: String) -> [String: String] {
        var query: [String: String] = [:]
        switch network {
        case "ws", "httpupgrade", "xhttp":
            let key = network == "ws" ? "wsSettings" : (network == "httpupgrade" ? "httpupgradeSettings" : "xhttpSettings")
            guard let settings = stream[key] as? [String: Any] else { return query }
            if let value = jsonString(settings["path"]) { query["path"] = value }
            if let value = jsonString(settings["host"]) { query["host"] = value }
            if let value = jsonString(settings["mode"]) { query["mode"] = value }
            if let headers = settings["headers"] as? [String: Any] {
                if let host = jsonString(headers["Host"]) ?? jsonString(headers["host"]) {
                    query["host"] = host
                }
            }
        case "grpc":
            guard let settings = stream["grpcSettings"] as? [String: Any] else { return query }
            if let value = jsonString(settings["serviceName"]) { query["serviceName"] = value }
            if let multi = settings["multiMode"] as? Bool, multi { query["mode"] = "multi" }
        case "http":
            guard let settings = stream["httpSettings"] as? [String: Any] else { return query }
            if let value = jsonString(settings["path"]) { query["path"] = value }
            if let hosts = settings["host"] as? [Any] {
                if let first = hosts.compactMap({ jsonString($0) }).first { query["host"] = first }
            } else if let value = jsonString(settings["host"]) {
                query["host"] = value
            }
        default:
            guard let settings = stream["tcpSettings"] as? [String: Any],
                  let header = settings["header"] as? [String: Any],
                  (jsonString(header["type"]) ?? "").lowercased() == "http" else {
                return query
            }
            query["headerType"] = "http"
            guard let request = header["request"] as? [String: Any] else { return query }
            if let paths = request["path"] as? [Any] {
                if let first = paths.compactMap({ jsonString($0) }).first { query["path"] = first }
            }
            if let headers = request["headers"] as? [String: Any], let hosts = headers["Host"] as? [Any] {
                if let first = hosts.compactMap({ jsonString($0) }).first { query["host"] = first }
            }
        }
        return query
    }

    /// The sing-box dialect: flat address fields, TLS in one object, transport in another.
    private static func singboxOutboundUri(
        _ fields: [String: Any],
        proto: String,
        name: String?
    ) -> String? {
        guard let host = jsonString(fields["server"]),
              let port = jsonString(fields["server_port"]) else {
            return nil
        }
        let remark = jsonString(fields["tag"]) ?? name
        var query = singboxStreamQuery(fields)
        switch proto {
        case "vless", "vmess":
            guard let credential = jsonString(fields["uuid"]) else { return nil }
            if proto == "vmess" {
                query["encryption"] = vmessCipher(jsonString(fields["security"]))
                return buildUri(scheme: "vmess", userInfo: credential, host: host, port: port, query: query, remark: remark)
            }
            if let flow = jsonString(fields["flow"]) {
                query["flow"] = flow
            }
            return buildUri(scheme: "vless", userInfo: credential, host: host, port: port, query: query, remark: remark)
        case "trojan":
            guard let password = jsonString(fields["password"]) else { return nil }
            return buildUri(scheme: "trojan", userInfo: password, host: host, port: port, query: query, remark: remark)
        case "shadowsocks":
            guard let password = jsonString(fields["password"]),
                  let method = jsonString(fields["method"])?.lowercased() else {
                return nil
            }
            return buildShadowsocksUri(method: method, password: password, host: host, port: port, remark: remark)
        default:
            return nil
        }
    }

    private static func singboxStreamQuery(_ fields: [String: Any]) -> [String: String] {
        var query: [String: String] = [:]
        var network = "tcp"
        if let transport = fields["transport"] as? [String: Any] {
            let type = (jsonString(transport["type"]) ?? "").lowercased()
            if !type.isEmpty {
                network = type
            }
            if let value = jsonString(transport["path"]) { query["path"] = value }
            if let value = jsonString(transport["host"]) { query["host"] = value }
            if let hosts = transport["host"] as? [Any] {
                if let first = hosts.compactMap({ jsonString($0) }).first { query["host"] = first }
            }
            if let value = jsonString(transport["service_name"]) { query["serviceName"] = value }
            if let headers = transport["headers"] as? [String: Any] {
                if let host = jsonString(headers["Host"]) ?? jsonString(headers["host"]) {
                    query["host"] = host
                }
                if let hosts = (headers["Host"] as? [Any]) ?? (headers["host"] as? [Any]) {
                    if let first = hosts.compactMap({ jsonString($0) }).first { query["host"] = first }
                }
            }
        }
        query["type"] = network
        var security = "none"
        if let tls = fields["tls"] as? [String: Any], (tls["enabled"] as? Bool) ?? false {
            security = "tls"
            if let value = jsonString(tls["server_name"]) { query["sni"] = value }
            if let list = tls["alpn"] as? [Any] {
                query["alpn"] = list.compactMap { jsonString($0) }.joined(separator: ",")
            }
            if let value = tls["insecure"] as? Bool, value { query["allowInsecure"] = "1" }
            if let utls = tls["utls"] as? [String: Any], let value = jsonString(utls["fingerprint"]) {
                query["fp"] = value
            }
            if let reality = tls["reality"] as? [String: Any], (reality["enabled"] as? Bool) ?? false {
                security = "reality"
                if let value = jsonString(reality["public_key"]) { query["pbk"] = value }
                if let value = jsonString(reality["short_id"]) { query["sid"] = value }
            }
        }
        query["security"] = security
        return query
    }

    /// The links a Clash document's `proxies:` list describes.
    ///
    /// Only that one list is read, and only the keys a server needs. This is not a YAML parser and
    /// is not meant to become one: `rules:`, `proxy-groups:` and the rest of the document describe
    /// routing this client does not take from a subscription.
    private static func clashProxyUris(_ text: String) -> [String] {
        return clashProxyBlocks(text).compactMap { clashProxyUri($0) }
    }

    /// Each `proxies:` entry flattened to lowercase dotted keys — `ws-opts.headers.host` — with list
    /// values joined by commas, which is the notation a link writes them in anyway.
    private static func clashProxyBlocks(_ text: String) -> [[String: String]] {
        var blocks: [[String: String]] = []
        var current: [String: String] = [:]
        var open = false
        var inProxies = false
        var proxiesIndent = -1
        var entryIndent = -1
        var path: [(indent: Int, key: String)] = []
        var lastKey: String?

        func flush() {
            if open, !current.isEmpty {
                blocks.append(current)
            }
            current = [:]
            open = false
            path = []
            lastKey = nil
        }

        func assign(indent: Int, line: String) {
            guard let colon = line.firstIndex(of: ":") else { return }
            let key = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { return }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while let last = path.last, last.indent >= indent {
                path.removeLast()
            }
            let prefix = path.map { $0.key }.joined(separator: ".")
            let full = prefix.isEmpty ? key : prefix + "." + key
            if value.isEmpty {
                // A key with nothing after it opens either a nested mapping or a list; both are
                // resolved by the lines that follow.
                path.append((indent, key))
                lastKey = full
                return
            }
            if value.hasPrefix("{") {
                for (nested, nestedValue) in clashFlowPairs(value) {
                    current[full + "." + nested] = nestedValue
                }
                return
            }
            if value.hasPrefix("[") {
                current[full] = clashInlineList(value)
                return
            }
            current[full] = clashScalar(value)
            lastKey = full
        }

        for rawLine in text.components(separatedBy: "\n") {
            let expanded = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let indent = expanded.prefix(while: { $0 == " " }).count
            if !inProxies {
                if trimmed == "proxies:" {
                    inProxies = true
                    proxiesIndent = indent
                }
                continue
            }
            if !trimmed.hasPrefix("-"), indent <= proxiesIndent {
                // The next top-level section has started, so the proxy list is over.
                break
            }
            if trimmed.hasPrefix("-"), entryIndent < 0 || indent <= entryIndent {
                flush()
                entryIndent = indent
                open = true
                let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{") {
                    for (key, value) in clashFlowPairs(rest) {
                        current[key] = value
                    }
                    continue
                }
                if !rest.isEmpty {
                    assign(indent: entryIndent + 2, line: rest)
                }
                continue
            }
            guard open else { continue }
            if trimmed.hasPrefix("-") {
                guard let key = lastKey else { continue }
                let item = clashScalar(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if let existing = current[key], !existing.isEmpty {
                    current[key] = existing + "," + item
                } else {
                    current[key] = item
                }
                continue
            }
            assign(indent: indent, line: trimmed)
        }
        flush()
        return blocks
    }

    private static func clashInlineList(_ value: String) -> String {
        var inner = value.dropFirst()
        if inner.hasSuffix("]") {
            inner = inner.dropLast()
        }
        return inner.split(separator: ",").map { clashScalar(String($0)) }.joined(separator: ",")
    }

    /// A flow mapping — `{name: a, ws-opts: {path: /b}}` — flattened the same way.
    private static func clashFlowPairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var body = text.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("{") else { return result }
        body = String(body.dropFirst())
        if body.hasSuffix("}") {
            body = String(body.dropLast())
        }
        var parts: [String] = []
        var depth = 0
        var buffer = ""
        for character in body {
            if character == "{" || character == "[" {
                depth += 1
            }
            if character == "}" || character == "]" {
                depth -= 1
            }
            if character == ",", depth == 0 {
                parts.append(buffer)
                buffer = ""
                continue
            }
            buffer.append(character)
        }
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(buffer)
        }
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[part.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            let value = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("{") {
                for (nested, nestedValue) in clashFlowPairs(value) {
                    result[key + "." + nested] = nestedValue
                }
            } else if value.hasPrefix("[") {
                result[key] = clashInlineList(value)
            } else {
                result[key] = clashScalar(value)
            }
        }
        return result
    }

    private static func clashScalar(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func clashProxyUri(_ block: [String: String]) -> String? {
        guard let proto = block["type"]?.lowercased(),
              let host = block["server"],
              let port = block["port"] else {
            return nil
        }
        let remark = block["name"]
        var network = (block["network"] ?? "tcp").lowercased()
        if network == "h2" {
            network = "http"
        }
        var query: [String: String] = ["type": network]
        // Clash spells trojan's TLS nowhere because trojan is always over TLS.
        var security = (block["tls"] == "true" || proto == "trojan") ? "tls" : "none"
        if let value = block["servername"] ?? block["sni"] { query["sni"] = value }
        if let value = block["client-fingerprint"] ?? block["fingerprint"] { query["fp"] = value }
        if let value = block["alpn"] { query["alpn"] = value }
        if block["skip-cert-verify"] == "true" { query["allowInsecure"] = "1" }
        if let value = block["reality-opts.public-key"] {
            security = "reality"
            query["pbk"] = value
            if let shortId = block["reality-opts.short-id"] { query["sid"] = shortId }
        }
        query["security"] = security
        switch network {
        case "ws", "httpupgrade":
            let prefix = network == "ws" ? "ws-opts" : "httpupgrade-opts"
            if let value = block["\(prefix).path"] { query["path"] = value }
            if let value = block["\(prefix).headers.host"] ?? block["\(prefix).host"] { query["host"] = value }
        case "grpc":
            if let value = block["grpc-opts.grpc-service-name"] { query["serviceName"] = value }
        case "http":
            if let value = block["h2-opts.path"] { query["path"] = value }
            if let value = block["h2-opts.host"] {
                query["host"] = value.split(separator: ",").first.map(String.init) ?? value
            }
        default:
            break
        }
        switch proto {
        case "vless":
            guard let uuid = block["uuid"] else { return nil }
            if let flow = block["flow"] { query["flow"] = flow }
            return buildUri(scheme: "vless", userInfo: uuid, host: host, port: port, query: query, remark: remark)
        case "vmess":
            guard let uuid = block["uuid"] else { return nil }
            query["encryption"] = vmessCipher(block["cipher"])
            return buildUri(scheme: "vmess", userInfo: uuid, host: host, port: port, query: query, remark: remark)
        case "trojan":
            guard let password = block["password"] else { return nil }
            return buildUri(scheme: "trojan", userInfo: password, host: host, port: port, query: query, remark: remark)
        case "ss", "shadowsocks":
            guard let password = block["password"], let method = block["cipher"]?.lowercased() else { return nil }
            return buildShadowsocksUri(method: method, password: password, host: host, port: port, remark: remark)
        default:
            return nil
        }
    }

    /// Percent-encoding for a link this parser builds. Everything outside the unreserved set is
    /// escaped, so a password with an "@" or a path with a "?" in it cannot move the boundaries the
    /// parser on the other side splits on.
    private static let uriValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func uriEncoded(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: uriValueAllowed) ?? value
    }

    private static func buildUri(
        scheme: String,
        userInfo: String,
        host: String,
        port: String,
        query: [String: String],
        remark: String?
    ) -> String? {
        guard let number = Int(port), (1 ... 65_535).contains(number) else { return nil }
        guard !userInfo.isEmpty, userInfo.count <= 256 else { return nil }
        var text = "\(scheme)://\(uriEncoded(userInfo))@\(bracketedHost(host)):\(number)"
        let pairs = query.keys.sorted().compactMap { key -> String? in
            guard let value = query[key], !value.isEmpty else { return nil }
            return "\(key)=\(uriEncoded(value))"
        }
        if !pairs.isEmpty {
            text += "?" + pairs.joined(separator: "&")
        }
        if let remark, !remark.isEmpty {
            text += "#" + uriEncoded(String(remark.prefix(64)))
        }
        return text
    }

    /// SIP002, which carries the method and the password as one base64 userinfo section.
    private static func buildShadowsocksUri(
        method: String,
        password: String,
        host: String,
        port: String,
        remark: String?
    ) -> String? {
        guard let number = Int(port), (1 ... 65_535).contains(number) else { return nil }
        guard !password.isEmpty, password.count <= 256 else { return nil }
        let userInfo = Data("\(method):\(password)".utf8).base64EncodedString()
        var text = "ss://\(userInfo)@\(bracketedHost(host)):\(number)"
        if let remark, !remark.isEmpty {
            text += "#" + uriEncoded(String(remark.prefix(64)))
        }
        return text
    }

    /// An IPv6 literal has to be bracketed before a port can be appended to it.
    private static func bracketedHost(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    /// The Xray configuration for one user server on one loopback port.
    ///
    /// Same shape as the signed lane's: one SOCKS inbound on 127.0.0.1 and one outbound of
    /// whichever protocol the key named, with no routing table because there is only one place
    /// traffic can go. Nothing here is a system-wide tunnel — the inbound is a loopback socket, and
    /// the only thing pointed at it is this app's own MTProto connection.
    public static func xrayConfiguration(
        server: AorusVlessServer,
        localPort: Int,
        udpEnabled: Bool,
        muxEnabled: Bool
    ) -> String? {
        var settings: [String: Any] = [:]
        switch server.proto {
        case "vmess":
            var user: [String: Any] = [
                "id": server.credential,
                // Xray dropped the legacy authentication that a non-zero alterId selected, so this
                // is the only value that connects — whatever the key we imported said.
                "alterId": 0,
                "security": server.encryption.isEmpty ? "auto" : server.encryption
            ]
            user["level"] = 0
            settings["vnext"] = [[
                "address": server.address,
                "port": server.port,
                "users": [user]
            ]]
            settings["packetEncoding"] = udpEnabled ? "xudp" : "none"
        case "trojan":
            settings["servers"] = [[
                "address": server.address,
                "port": server.port,
                "password": server.credential
            ]]
        case "shadowsocks":
            settings["servers"] = [[
                "address": server.address,
                "port": server.port,
                "method": server.encryption,
                "password": server.credential
            ]]
        default:
            var user: [String: Any] = [
                "id": server.credential,
                "encryption": "none"
            ]
            if !server.flow.isEmpty {
                user["flow"] = server.flow
            }
            settings["vnext"] = [[
                "address": server.address,
                "port": server.port,
                "users": [user]
            ]]
            // "xudp" is what makes UDP over VLESS work at all; "none" is the honest way to say the
            // user turned it off, rather than omitting the key and getting the core's default.
            settings["packetEncoding"] = udpEnabled ? "xudp" : "none"
        }

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
            "tag": "aorus-user-outbound",
            "protocol": server.proto,
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
