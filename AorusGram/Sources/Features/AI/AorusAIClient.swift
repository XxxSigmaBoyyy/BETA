import Foundation

public final class AorusAIStreamHandle {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var isCancelled = false

    fileprivate init() {
    }

    fileprivate func installCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            cancellation()
        } else {
            self.cancellation = cancellation
            lock.unlock()
        }
    }

    public func cancelTransport() {
        lock.lock()
        isCancelled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit { cancelTransport() }
}

public final class AorusAIClient {
    public static let shared = AorusAIClient()
    public static let baseURL = URL(string: "https://ai.aorusgram.com")!
    private let requestQueue = DispatchQueue(label: "com.aorusgram.ai.requests", qos: .userInitiated)

    private init() {}

    public func checkHealth(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue(SubscriptionConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: AorusPinnedSessionDelegate.shared, delegateQueue: nil)
        session.dataTask(with: request) { _, response, _ in
            defer { session.finishTasksAndInvalidate() }
            let healthy = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { completion(healthy) }
        }.resume()
    }

    @discardableResult
    public func start(
        payload: AorusAIAgentPayload,
        event: @escaping (AorusAIEvent) -> Void,
        completion: @escaping (Result<Void, AorusAIClientError>) -> Void
    ) -> AorusAIStreamHandle? {
        guard LicenseKeyProvider.isProvisioned else {
            completion(.failure(.notProvisioned))
            return nil
        }
        let handle = AorusAIStreamHandle()
        requestQueue.async { [weak self, weak handle] in
            guard let self, let handle else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            guard let body = try? encoder.encode(payload),
                  let request = self.signedRequest(method: "POST", path: "/v1/aorus/agent", body: body, contentType: "application/json", accept: "text/event-stream") else {
                DispatchQueue.main.async {
                    completion(.failure(LicenseKeyProvider.isProvisioned ? .malformedResponse : .notProvisioned))
                }
                return
            }
            let stream = AorusAIStreamOperation(request: request, event: event, completion: completion)
            stream.start()
            handle.installCancellation { stream.cancel() }
        }
        return handle
    }

    public func cancelTurn(_ turnId: String, completion: @escaping (Result<Void, AorusAIClientError>) -> Void) {
        requestQueue.async { [weak self] in
            guard let self else { return }
            let bodyObject = ["turn_id": turnId]
            guard let body = try? JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys]),
                  let request = self.signedRequest(method: "POST", path: "/v1/aorus/agent/cancel", body: body, contentType: "application/json", accept: "application/json") else {
                DispatchQueue.main.async {
                    completion(.failure(LicenseKeyProvider.isProvisioned ? .malformedResponse : .notProvisioned))
                }
                return
            }
            self.performData(request: request, completion: completion)
        }
    }

    public func downloadArtifact(
        _ artifact: AorusAIArtifact,
        completion: @escaping (Result<URL, AorusAIClientError>) -> Void
    ) {
        guard !artifact.isExpired else {
            completion(.failure(.artifactExpired))
            return
        }
        guard Self.isSafeArtifactId(artifact.artifactId), artifact.size >= 0, artifact.size <= 512 * 1024 * 1024 else {
            completion(.failure(.malformedResponse))
            return
        }
        requestQueue.async { [weak self] in
            guard let self else { return }
            let normalizedPath = "/download/" + artifact.artifactId
            let accept = Self.safeMIMEType(artifact.mime) ?? "application/octet-stream"
            guard let request = self.signedRequest(method: "GET", path: normalizedPath, body: Data(), contentType: nil, accept: accept) else {
                DispatchQueue.main.async {
                    completion(.failure(LicenseKeyProvider.isProvisioned ? .malformedResponse : .notProvisioned))
                }
                return
            }
            self.performArtifactDownload(artifact, request: request, completion: completion)
        }
    }

    private func performArtifactDownload(
        _ artifact: AorusAIArtifact,
        request: URLRequest,
        completion: @escaping (Result<URL, AorusAIClientError>) -> Void
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: AorusPinnedSessionDelegate.shared, delegateQueue: nil)
        session.downloadTask(with: request) { temporaryURL, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(Self.mapTransportError(error))) }
                return
            }
            guard (200..<300).contains(http.statusCode), let temporaryURL else {
                DispatchQueue.main.async { completion(.failure(Self.mapHTTP(http.statusCode, data: nil))) }
                return
            }
            if let responseMIME = http.mimeType?.lowercased(),
               let expectedMIME = Self.safeMIMEType(artifact.mime)?.lowercased(),
               expectedMIME != "application/octet-stream",
               responseMIME != expectedMIME {
                DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                return
            }
            if http.expectedContentLength > 512 * 1024 * 1024 {
                DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                return
            }
            let safeName = Self.safeFilename(artifact.filename)
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("AorusAI", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(safeName)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actualSize >= 0,
                      actualSize <= 512 * 1024 * 1024,
                      artifact.size == 0 || actualSize == artifact.size else {
                    DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                    return
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try FileManager.default.moveItem(at: temporaryURL, to: target)
                DispatchQueue.main.async { completion(.success(target)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
            }
        }.resume()
    }

    fileprivate func signedRequest(method: String, path: String, body: Data, contentType: String?, accept: String?) -> URLRequest? {
        guard LicenseKeyProvider.isProvisioned, AorusEnvGuard.enforceBeforeRequest() else { return nil }
        guard path.hasPrefix("/"),
              let url = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL,
              url.scheme == "https",
              url.host?.lowercased() == Self.baseURL.host else { return nil }

        let timestamp = String(Int64(Date().timeIntervalSince1970))
        let nonce = LicenseCrypto.randomHex(byteCount: 16)
        let device = DeviceFingerprint.deviceHash().lowercased()
        let keyVersion = LicenseKeyProvider.keyVersion
        let bodyHash = LicenseCrypto.sha256Hex(body).lowercased()
        let message = "\(timestamp)\n\(nonce)\n\(device)\n\(keyVersion)\n\(bodyHash)"
        guard let signature = LicenseKeyProvider.withLicenseHmacKey({ keyBytes in
            LicenseCrypto.hmacSHA256Hex(message: Data(message.utf8), keyBytes: keyBytes).lowercased()
        }) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if method != "GET" && method != "HEAD" { request.httpBody = body }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.setValue(SubscriptionConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(timestamp, forHTTPHeaderField: "X-Aorus-Ts")
        request.setValue(nonce, forHTTPHeaderField: "X-Aorus-Nonce")
        request.setValue(device, forHTTPHeaderField: "X-Aorus-Device")
        request.setValue(keyVersion, forHTTPHeaderField: "X-Aorus-Kv")
        request.setValue(bodyHash, forHTTPHeaderField: "X-Aorus-Body-SHA256")
        request.setValue(signature, forHTTPHeaderField: "X-Aorus-Sign")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func performData(request: URLRequest, completion: @escaping (Result<Void, AorusAIClientError>) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: AorusPinnedSessionDelegate.shared, delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            let result: Result<Void, AorusAIClientError>
            if let error {
                result = .failure(Self.mapTransportError(error))
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = .success(())
            } else if let http = response as? HTTPURLResponse {
                result = .failure(Self.mapHTTP(http.statusCode, data: data))
            } else {
                result = .failure(.serverUnavailable)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    fileprivate static func mapTransportError(_ error: Error?) -> AorusAIClientError {
        guard let urlError = error as? URLError else { return .serverUnavailable }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .offline
        case .timedOut: return .timeout
        default: return .serverUnavailable
        }
    }

    fileprivate static func mapHTTP(_ status: Int, data: Data?) -> AorusAIClientError {
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = (object?["error"] as? String)?.lowercased() ?? ""
        if status == 401 || status == 403 { return .authorization }
        if status == 429 || code.contains("quota") {
            let reset = Self.dateFromMilliseconds(object?["reset_at"] ?? object?["quota_reset_at"])
            return .quota(AorusAIQuota(resetAt: reset, label: object?["message"] as? String))
        }
        if status == 404 && code.contains("artifact") { return .artifactExpired }
        if status >= 500 { return .serverUnavailable }
        return .http(status)
    }

    fileprivate static func dateFromMilliseconds(_ value: Any?) -> Date? {
        let raw: Double?
        if let number = value as? NSNumber { raw = number.doubleValue }
        else if let string = value as? String { raw = Double(string) }
        else { raw = nil }
        guard let raw else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }

    private static func safeFilename(_ filename: String) -> String {
        let lastComponent = URL(fileURLWithPath: filename).lastPathComponent
        let cleaned = lastComponent
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "AorusAI-file" : String(cleaned.prefix(180))
    }

    private static func isSafeArtifactId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value == 45 || scalar.value == 95
        }
    }

    private static func safeMIMEType(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 127,
              !value.contains("\r"), !value.contains("\n") else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-/")
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }
}

private final class AorusAIStreamOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let request: URLRequest
    private let eventHandler: (AorusAIEvent) -> Void
    private let completionHandler: (Result<Void, AorusAIClientError>) -> Void
    private let parser = AorusAISSEParser()
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseStatus: Int?
    private var errorBody = Data()
    private var receivedSuccessfulDone = false
    private var completed = false

    init(request: URLRequest, event: @escaping (AorusAIEvent) -> Void, completion: @escaping (Result<Void, AorusAIClientError>) -> Void) {
        self.request = request
        self.eventHandler = event
        self.completionHandler = completion
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        AorusPinnedSessionDelegate.shared.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        AorusPinnedSessionDelegate.shared.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseStatus = (response as? HTTPURLResponse)?.statusCode
        if let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let mime = http.mimeType?.lowercased(),
           mime != "text/event-stream" && mime != "application/octet-stream" {
            completionHandler(.cancel)
            finish(.failure(.malformedResponse))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let status = responseStatus, (200..<300).contains(status) else {
            if errorBody.count < 64 * 1024 { errorBody.append(data) }
            return
        }
        emit(parser.append(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil { emit(parser.finish()) }
        let result: Result<Void, AorusAIClientError>
        if let error {
            result = .failure(AorusAIClient.mapTransportError(error))
        } else if let status = responseStatus, !(200..<300).contains(status) {
            result = .failure(AorusAIClient.mapHTTP(status, data: errorBody))
        } else if responseStatus == nil {
            result = .failure(.serverUnavailable)
        } else if receivedSuccessfulDone {
            result = .success(())
        } else {
            result = .failure(.serverUnavailable)
        }
        finish(result)
    }

    private func emit(_ events: [AorusAISSEParser.Event]) {
        for raw in events {
            if let parsed = Self.parse(raw) {
                if case .done(ok: true) = parsed {
                    receivedSuccessfulDone = true
                }
                DispatchQueue.main.async { self.eventHandler(parsed) }
            }
        }
    }

    private func finish(_ result: Result<Void, AorusAIClientError>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        task = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.completionHandler(result) }
    }

    private static func parse(_ raw: AorusAISSEParser.Event) -> AorusAIEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: raw.data) as? [String: Any] else {
            return raw.name == "message" ? nil : .unknown(name: raw.name)
        }
        switch raw.name {
        case "agent.start":
            guard let turn = object["turn_id"] as? String, !turn.isEmpty else { return nil }
            return .agentStarted(turnId: turn, context: object["context"] as? String)
        case "status", "render.start", "render.phase", "render_progress", "build_progress":
            // Only display the backend's user-facing label. Internal phase names are
            // implementation details and must never leak into the chat UI.
            let label = (object["label"] as? String) ?? ""
            let progress = (object["progress"] as? NSNumber)?.doubleValue
            return label.isEmpty && progress == nil ? nil : .status(label: label, progress: progress)
        case "reasoning.summary":
            guard let value = object["summary"] as? String else { return nil }
            return .reasoningSummary(value)
        case "response.start":
            return .responseStarted
        case "response.delta":
            if let data = object["data"] as? [String: Any], let text = data["text"] as? String { return .responseDelta(text) }
            if let text = object["text"] as? String { return .responseDelta(text) }
            return nil
        case "artifact.ready", "build_result", "build.result":
            let source = (object["artifact"] as? [String: Any]) ?? object
            guard let artifactId = source["artifact_id"] as? String,
                  let filename = source["filename"] as? String else { return nil }
            let download = source["download"] as? [String: Any]
            let path = (download?["path"] as? String) ?? "/download/\(artifactId)"
            let expires = (download?["expires_at"] as? NSNumber)?.int64Value ?? (source["expires_at"] as? NSNumber)?.int64Value
            let artifact = AorusAIArtifact(
                artifactId: artifactId,
                filename: filename,
                mime: (source["mime"] as? String) ?? "application/octet-stream",
                size: (source["size"] as? NSNumber)?.int64Value ?? 0,
                format: (source["format"] as? String) ?? URL(fileURLWithPath: filename).pathExtension,
                downloadPath: path,
                expiresAt: expires
            )
            return .artifactReady(artifact)
        case "permission_request":
            let requestId = (object["request_id"] as? String) ?? (object["id"] as? String) ?? UUID().uuidString
            let kind = (object["kind"] as? String) ?? (object["permission"] as? String) ?? "unknown"
            let peerId = (object["peer_id"] as? NSNumber)?.int64Value
            let count = (object["count"] as? NSNumber)?.intValue
            return .permissionRequest(AorusAIPermissionRequest(requestId: requestId, kind: kind, peerId: peerId, count: count, previewText: object["text"] as? String))
        case "quota", "quota.exhausted":
            let reset = AorusAIClient.dateFromMilliseconds(object["reset_at"] ?? object["quota_reset_at"])
            return .quota(AorusAIQuota(resetAt: reset, label: object["label"] as? String))
        case "response.done":
            return .responseDone
        case "done":
            return .done(ok: (object["ok"] as? Bool) ?? false)
        default:
            return .unknown(name: raw.name)
        }
    }
}
