import Foundation

// Isolated license API client.
//
// Uses a private ephemeral URLSession that does NOT route through Telegram
// networking / MTProto / the proxy in any way. Every request is HMAC-signed per
// the Aorus license protocol. Nothing sensitive (key, signature, body with code)
// is ever logged.
//
// HMAC message:
//   ts + "\n" + nonce + "\n" + device + "\n" + kv + "\n" + bodySha256
final class LicenseAPIClient {
    static let shared = LicenseAPIClient()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = SubscriptionConfig.requestTimeout
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        // TLS SPKI pinning delegate. Inert (default trust) until pins are configured.
        self.session = URLSession(configuration: cfg,
                                  delegate: AorusPinnedSessionDelegate.shared,
                                  delegateQueue: nil)
    }

    // MARK: - Public endpoints

    func bootstrap(telegramUserId: Int64?,
                   completion: @escaping (Result<LicenseResponse, LicenseError>) -> Void) {
        post(path: "/license/bootstrap", body: baseBody(telegramUserId: telegramUserId), completion: completion)
    }

    func check(telegramUserId: Int64?,
               completion: @escaping (Result<LicenseResponse, LicenseError>) -> Void) {
        post(path: "/license/check", body: baseBody(telegramUserId: telegramUserId), completion: completion)
    }

    func activate(code: String, telegramUserId: Int64?,
                  completion: @escaping (Result<LicenseResponse, LicenseError>) -> Void) {
        var body = baseBody(telegramUserId: telegramUserId)
        body["code"] = code
        post(path: "/license/activate", body: body, completion: completion)
    }

    func badgeSnapshot(completion: @escaping (Result<BadgeSnapshotResponse, LicenseError>) -> Void) {
        signedPost(path: "/license/badges/snapshot", body: [:], allowsUnsignedResponse: true) { result in
            switch result {
            case .success(let response):
                guard (200..<300).contains(response.statusCode) else {
                    let policy = LicenseResponse(json: response.object)
                    if response.statusCode == 426, policy.status == .clientOutdated {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("aorusgram.clientOutdated"),
                                object: nil,
                                userInfo: ["response": policy]
                            )
                        }
                    }
                    completion(.failure(.http(response.statusCode)))
                    return
                }
                guard let snapshot = BadgeSnapshotResponse(json: response.object) else {
                    completion(.failure(.decode))
                    return
                }
                completion(.success(snapshot))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Internals

    private func baseBody(telegramUserId: Int64?) -> [String: Any] {
        var body: [String: Any] = [:]
        if let uid = telegramUserId { body["telegram_user_id"] = uid }
        // Tamper signal: jailbreak / injected-hook / debugger. Placed in the body so
        // it is covered by the request's HMAC (X-Aorus-Body-Sha256). The SERVER is the
        // enforcement point — it can deny/ban a device or key based on these flags.
        let env = AorusEnvGuard.flags()
        if !env.isEmpty { body["env"] = env }
        return body
    }

    private func post(path: String,
                      body: [String: Any],
                      completion: @escaping (Result<LicenseResponse, LicenseError>) -> Void) {
        signedPost(path: path, body: body) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let parsed = LicenseResponse(json: response.object)
                if !(200..<300).contains(response.statusCode) {
                    // A revoked build is a signed, authoritative policy verdict. Treat
                    // unsigned/forged 426 responses as network errors in signedPost.
                    if response.statusCode == 426, parsed.status == .clientOutdated {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("aorusgram.clientOutdated"),
                                object: nil,
                                userInfo: ["response": parsed]
                            )
                        }
                        completion(.success(parsed))
                    } else if let code = parsed.errorCode {
                        completion(.failure(.server(code)))
                    } else {
                        completion(.failure(.http(response.statusCode)))
                    }
                    return
                }
                // 2xx but carrying an explicit error code (defensive).
                if let code = parsed.errorCode, parsed.status == .networkError {
                    completion(.failure(.server(code)))
                    return
                }
                completion(.success(parsed))
            }
        }
    }

    private struct SignedJSONResponse {
        let statusCode: Int
        let object: [String: Any]
    }

    // One signing/verification pipeline for every license API operation. The body is
    // serialized exactly once; its SHA-256 and the URLRequest both use those bytes.
    /// `allowsUnsignedResponse` relaxes ONE thing and only for routes that grant nothing.
    ///
    /// Every verdict that opens the app stays strict: an unsigned licence answer is
    /// refused. The badge roster is different in kind — it decides which little picture
    /// sits beside a name and confers no access, no entitlement and no capability — and
    /// it is a route the server added later, so it need not go through the same response
    /// signer. With the requirement on, an unsigned roster is discarded as a network
    /// failure and nobody has a badge, silently, which is exactly what was reported three
    /// times. A forged roster could at most draw a cosmetic badge, and it would still have
    /// to get past the pinned connection and the request HMAC. An actively *invalid*
    /// signature is still refused here, on every route.
    private func signedPost(path: String,
                            body: [String: Any],
                            allowsUnsignedResponse: Bool = false,
                            completion: @escaping (Result<SignedJSONResponse, LicenseError>) -> Void) {
        guard LicenseKeyProvider.isProvisioned, AorusBuildKeyProvider.isProvisioned else {
            completion(.failure(.notProvisioned)); return
        }
        guard AorusEnvGuard.enforceBeforeRequest() else {
            completion(.failure(.network)); return
        }
        guard let url = URL(string: SubscriptionConfig.baseURLString + path) else {
            completion(.failure(.network)); return
        }

        // Exact bytes that will be sent — the signature is computed over THESE bytes.
        let bodyData: Data
        if body.isEmpty {
            bodyData = Data("{}".utf8)
        } else if let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
            bodyData = encoded
        } else {
            completion(.failure(.decode)); return
        }

        let ts = String(Int64(Date().timeIntervalSince1970))
        let nonce = LicenseCrypto.randomHex(byteCount: 16)        // 32 hex
        let device = DeviceFingerprint.deviceHash()               // 64 hex
        let kv = SubscriptionConfig.keyVersion
        let bodySha = LicenseCrypto.sha256Hex(bodyData)

        let message = ts + "\n" + nonce + "\n" + device + "\n" + kv + "\n" + bodySha
        guard let sign = LicenseKeyProvider.withLicenseHmacKey({ keyBytes in
            LicenseCrypto.hmacSHA256Hex(message: Data(message.utf8), keyBytes: keyBytes)
        }) else {
            completion(.failure(.notProvisioned)); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SubscriptionConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(ts, forHTTPHeaderField: "X-Aorus-Ts")
        request.setValue(nonce, forHTTPHeaderField: "X-Aorus-Nonce")
        request.setValue(device, forHTTPHeaderField: "X-Aorus-Device")
        request.setValue(kv, forHTTPHeaderField: "X-Aorus-Kv")
        request.setValue(bodySha, forHTTPHeaderField: "X-Aorus-Body-Sha256")
        request.setValue(sign, forHTTPHeaderField: "X-Aorus-Sign")
        guard AorusBuildKeyProvider.applyHeaders(
            to: &request, timestamp: ts, nonce: nonce, device: device
        ) else {
            completion(.failure(.notProvisioned)); return
        }

        let task = session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(.network)); return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network)); return
            }
            guard let data = data, data.count <= 2 * 1024 * 1024,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure((200..<300).contains(http.statusCode) ? .decode : .http(http.statusCode)))
                return
            }

            // Response authenticity: confirm the body was signed by OUR server (anti
            // fake-server / MITM) and bound to THIS request's nonce (anti-replay).
            // Inert until a public key is provisioned; a forged/corrupted signature is
            // treated as a network failure so it never grants access, while a
            // legitimate device still keeps its valid offline grace.
            switch LicenseResponseVerifier.verify(bodyData: data,
                                                  headers: http.allHeaderFields,
                                                  requestNonce: nonce) {
            case .ok:
                break
            case .unsigned:
                if SubscriptionConfig.requireSignedResponse, !allowsUnsignedResponse {
                    completion(.failure(.network)); return
                }
            case .invalid:
                completion(.failure(.network)); return
            }
            completion(.success(SignedJSONResponse(statusCode: http.statusCode, object: object)))
        }
        task.resume()
    }
}
