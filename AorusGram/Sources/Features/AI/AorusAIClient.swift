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

/// Cancels one artifact download.
///
/// Unlike `AorusAIStreamHandle` it does **not** cancel itself when it is released: a
/// download the caller stopped tracking must still finish and land in the temporary
/// directory, and only an explicit `cancel()` — the user tapping the card again — stops
/// the transfer.
public final class AorusAIDownloadHandle {
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

    public func cancel() {
        lock.lock()
        isCancelled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }
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

    /// Metadata-only probe (`HEAD`) for one artifact.
    ///
    /// The body is empty, so the signature covers the SHA-256 of zero bytes exactly
    /// like the `GET`. Used before a large transfer to confirm the signed link is
    /// still alive without spending the user's bandwidth.
    public func probeArtifact(
        _ artifact: AorusAIArtifact,
        completion: @escaping (Result<AorusAIArtifactProbe, AorusAIClientError>) -> Void
    ) {
        guard let path = Self.artifactPath(for: artifact) else {
            completion(.failure(artifact.isExpired ? .artifactExpired : .malformedResponse))
            return
        }
        requestQueue.async { [weak self] in
            guard let self else { return }
            guard let request = self.signedRequest(method: "HEAD", path: path, body: Data(), contentType: nil, accept: "*/*") else {
                DispatchQueue.main.async {
                    completion(.failure(LicenseKeyProvider.isProvisioned ? .malformedResponse : .notProvisioned))
                }
                return
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: AorusPinnedSessionDelegate.shared, delegateQueue: nil)
            session.dataTask(with: request) { _, response, error in
                defer { session.finishTasksAndInvalidate() }
                guard error == nil, let http = response as? HTTPURLResponse else {
                    DispatchQueue.main.async { completion(.failure(Self.mapArtifactTransportError(error))) }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    DispatchQueue.main.async { completion(.failure(Self.mapArtifactHTTP(http.statusCode))) }
                    return
                }
                let probe = AorusAIArtifactProbe(
                    size: http.expectedContentLength >= 0 ? http.expectedContentLength : nil,
                    mime: http.mimeType.flatMap { AorusAIArtifactFlow.safeMIME($0) },
                    filename: Self.filename(from: http, fallback: artifact.filename),
                    acceptsRanges: (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
                )
                DispatchQueue.main.async { completion(.success(probe)) }
            }.resume()
        }
    }

    /// Downloads one artifact through the public gateway.
    ///
    /// The path comes from `AorusAIArtifactFlow`, so a payload that tried to point at
    /// another host, another object or a query string never reaches the network. The
    /// gateway attaches the private vault token server-side; the client never holds
    /// one.
    ///
    /// The returned handle cancels the transfer, which is what makes a stalled download
    /// stoppable instead of a card that spins until the resource timeout: cancelling
    /// reports `.cancelled`, exactly like a cancelled turn.
    @discardableResult
    public func downloadArtifact(
        _ artifact: AorusAIArtifact,
        range: ClosedRange<Int64>? = nil,
        completion: @escaping (Result<URL, AorusAIClientError>) -> Void
    ) -> AorusAIDownloadHandle {
        let handle = AorusAIDownloadHandle()
        guard let path = Self.artifactPath(for: artifact) else {
            completion(.failure(artifact.isExpired ? .artifactExpired : .malformedResponse))
            return handle
        }
        requestQueue.async { [weak self] in
            guard let self else { return }
            let accept = AorusAIArtifactFlow.safeMIME(artifact.mime) ?? "application/octet-stream"
            guard var request = self.signedRequest(method: "GET", path: path, body: Data(), contentType: nil, accept: accept) else {
                DispatchQueue.main.async {
                    completion(.failure(LicenseKeyProvider.isProvisioned ? .malformedResponse : .notProvisioned))
                }
                return
            }
            if let range, range.lowerBound >= 0, range.upperBound >= range.lowerBound {
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            }
            self.performArtifactDownload(artifact, request: request, isPartial: range != nil, handle: handle, completion: completion)
        }
        return handle
    }

    /// The one relative path this artifact may be fetched from, or nil when the
    /// artifact is expired, its id unsafe, or its stored path not ours.
    private static func artifactPath(for artifact: AorusAIArtifact) -> String? {
        guard !artifact.isExpired else { return nil }
        guard artifact.size >= 0, artifact.size <= 512 * 1024 * 1024 else { return nil }
        guard AorusAIArtifactFlow.downloadURL(for: artifact) != nil else { return nil }
        return AorusAIArtifactFlow.signingPath(for: artifact)
    }

    /// `Content-Disposition` wins over the stored filename, exactly as the spec asks,
    /// but only after the same sanitising the stored name went through.
    private static func filename(from response: HTTPURLResponse, fallback: String) -> String {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return AorusAIArtifactFlow.safeFilename(fallback)
        }
        var candidate: String?
        for part in disposition.components(separatedBy: ";") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.lowercased().hasPrefix("filename*=") {
                var value = String(token.dropFirst("filename*=".count))
                if let marker = value.range(of: "''") { value = String(value[marker.upperBound...]) }
                candidate = value.removingPercentEncoding ?? value
                break
            }
            if token.lowercased().hasPrefix("filename=") {
                candidate = String(token.dropFirst("filename=".count))
            }
        }
        guard var value = candidate else { return AorusAIArtifactFlow.safeFilename(fallback) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let safe = AorusAIArtifactFlow.safeFilename(value)
        return safe == "AorusAI-file" ? AorusAIArtifactFlow.safeFilename(fallback) : safe
    }

    private func performArtifactDownload(
        _ artifact: AorusAIArtifact,
        request: URLRequest,
        isPartial: Bool,
        handle: AorusAIDownloadHandle,
        completion: @escaping (Result<URL, AorusAIClientError>) -> Void
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: AorusPinnedSessionDelegate.shared, delegateQueue: nil)
        let task = session.downloadTask(with: request) { temporaryURL, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(Self.mapArtifactTransportError(error))) }
                return
            }
            // A ranged request answers 206; a full one answers 200. A server that
            // ignores the range and sends 200 for a partial request is answering a
            // different question than the one asked.
            let expectedStatus = isPartial ? 206 : 200
            guard http.statusCode == expectedStatus || (!isPartial && http.statusCode == 206), let temporaryURL else {
                DispatchQueue.main.async { completion(.failure(Self.mapArtifactHTTP(http.statusCode))) }
                return
            }
            if let responseMIME = http.mimeType?.lowercased(),
               let expectedMIME = AorusAIArtifactFlow.safeMIME(artifact.mime)?.lowercased(),
               expectedMIME != "application/octet-stream" {
                // The authenticated public gateway may intentionally normalize a safe
                // binary download to octet-stream. Accept that transport type, but never
                // accept an HTML/text error page as a document artifact.
                let isGenericBinary = responseMIME == "application/octet-stream"
                let isExpectedType = responseMIME == expectedMIME
                guard isGenericBinary || isExpectedType else {
                    DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                    return
                }
            }
            if http.expectedContentLength > 512 * 1024 * 1024 {
                DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                return
            }
            let safeName = Self.filename(from: http, fallback: artifact.filename)
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("AorusAI", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(safeName)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                // artifact.size is response metadata, not an HTTP framing contract. The
                // transport's own Content-Length is the authoritative exact-byte check.
                let responseSizeMatches = isPartial || http.expectedContentLength < 0 || actualSize == http.expectedContentLength
                let hasExpectedPayload = isPartial || artifact.size == 0 || actualSize > 0
                guard actualSize >= 0,
                      actualSize <= 512 * 1024 * 1024,
                      responseSizeMatches,
                      hasExpectedPayload else {
                    DispatchQueue.main.async { completion(.failure(.malformedResponse)) }
                    return
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try FileManager.default.moveItem(at: temporaryURL, to: target)
                DispatchQueue.main.async { completion(.success(target)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.artifactDownloadFailed)) }
            }
        }
        handle.installCancellation { [weak task] in
            task?.cancel()
        }
        task.resume()
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
            return .quota(Self.quota(from: object))
        }
        if status == 410 { return .artifactExpired }
        if status == 404 && code.contains("artifact") { return .artifactGone }
        if status >= 500 { return .serverUnavailable }
        return .http(status)
    }

    /// Reads the quota reset metadata the backend actually reports. Nothing is
    /// invented locally: without server metadata the UI shows no reset time.
    fileprivate static func quota(from object: [String: Any]?) -> AorusAIQuota {
        let label = (object?["label"] as? String) ?? (object?["message"] as? String)
        if let seconds = Self.secondsFromNumber(object?["retry_after"] ?? object?["retry_after_seconds"] ?? object?["reset_in"]) {
            return AorusAIQuota(resetAt: Date().addingTimeInterval(seconds), label: label, isRelative: true)
        }
        let reset = Self.dateFromMilliseconds(object?["reset_at"] ?? object?["quota_reset_at"] ?? object?["resets_at"])
        return AorusAIQuota(resetAt: reset, label: label, isRelative: false)
    }

    fileprivate static func secondsFromNumber(_ value: Any?) -> TimeInterval? {
        let raw: Double?
        if let number = value as? NSNumber { raw = number.doubleValue }
        else if let string = value as? String { raw = Double(string) }
        else { raw = nil }
        guard let raw, raw > 0, raw < 60 * 60 * 24 * 31 else { return nil }
        return raw
    }

    fileprivate static func dateFromMilliseconds(_ value: Any?) -> Date? {
        let raw: Double?
        if let number = value as? NSNumber { raw = number.doubleValue }
        else if let string = value as? String { raw = Double(string) }
        else { raw = nil }
        guard let raw else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }

    /// Artifact-specific status mapping. The vault answers with a plain status and no
    /// JSON body, so each case is turned into one user-facing situation here and the
    /// raw code never reaches the UI.
    fileprivate static func mapArtifactHTTP(_ status: Int) -> AorusAIClientError {
        switch status {
        case 403: return .artifactNotOwned
        case 410: return .artifactExpired
        case 404: return .artifactGone
        case 401: return .authorization
        case 429: return .quota(AorusAIQuota(resetAt: nil, label: nil))
        default: return status >= 500 ? .serverUnavailable : .artifactDownloadFailed
        }
    }

    /// A dropped transfer is a download failure, not a generic server outage: the
    /// spec asks for "Не удалось скачать файл" in that case.
    fileprivate static func mapArtifactTransportError(_ error: Error?) -> AorusAIClientError {
        switch Self.mapTransportError(error) {
        case .cancelled: return .cancelled
        case .offline: return .offline
        default: return .artifactDownloadFailed
        }
    }
}

/// What a `HEAD` on an artifact told us. Deliberately metadata only.
public struct AorusAIArtifactProbe: Equatable {
    public var size: Int64?
    public var mime: String?
    public var filename: String
    public var acceptsRanges: Bool

    public init(size: Int64?, mime: String?, filename: String, acceptsRanges: Bool) {
        self.size = size
        self.mime = mime
        self.filename = filename
        self.acceptsRanges = acceptsRanges
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
                // `awaiting_tool` and `awaiting_permission` arrive with `ok: true`:
                // the stream legitimately ends there and the controller answers with a
                // continuation request, so the transport must report success, not an
                // "unavailable" error (§17).
                if case .done(ok: true, state: _) = parsed {
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
            // Decoding lives in `AorusAIArtifactFlow` so the exact production payload
            // — including a hostile `download.path` or a `token` the backend might
            // add later — is covered by the release preflight tests, not only by a
            // device. `artifact.ready` is never merely "unknown": losing it loses the
            // user's file.
            guard let artifact = AorusAIArtifactFlow.decode(object) else { return nil }
            return .artifactReady(artifact)
        case "tool.request":
            // The device is asked to run a Telegram tool. `requires_user_approval`
            // is honoured literally: `telegram.profile.get` sends `false` and must
            // therefore run without any extra dialog (§4).
            guard let tool = (object["tool"] as? String), !tool.isEmpty else { return nil }
            let requestId = (object["id"] as? String) ?? (object["request_id"] as? String) ?? UUID().uuidString
            let arguments = object["arguments"] as? [String: Any]
            return .toolRequest(AorusAIToolRequest(
                requestId: requestId,
                tool: tool,
                label: object["label"] as? String,
                username: AorusAIStreamOperation.username(from: arguments),
                limit: (arguments?["limit"] as? NSNumber)?.intValue,
                requiresUserApproval: (object["requires_user_approval"] as? Bool) ?? false
            ))
        case "tool.result":
            // The backend confirming its own bookkeeping. Purely informational: it is
            // shown as a transient status, never as a chat message (§15).
            guard let tool = object["tool"] as? String, !tool.isEmpty else { return nil }
            return .toolResult(tool: tool, ok: (object["ok"] as? Bool) ?? true, label: object["label"] as? String)
        case "permission.request":
            let requestId = (object["id"] as? String) ?? (object["request_id"] as? String) ?? UUID().uuidString
            let tool = (object["tool"] as? String) ?? AorusAITool.chatHistory
            let arguments = object["arguments"] as? [String: Any]
            var options: [AorusAIPermissionOption] = []
            for rawOption in (object["options"] as? [[String: Any]]) ?? [] {
                guard let label = rawOption["label"] as? String, !label.isEmpty else { continue }
                let limit = (rawOption["limit"] as? NSNumber)?.intValue
                let mode = rawOption["mode"] as? String
                let id = (rawOption["id"] as? String) ?? limit.map({ String($0) }) ?? mode ?? label
                options.append(AorusAIPermissionOption(id: id, label: label, limit: limit, mode: mode))
            }
            return .permissionRequest(AorusAIPermissionRequest(
                requestId: requestId,
                tool: tool,
                title: object["title"] as? String,
                text: (object["description"] as? String) ?? (object["text"] as? String),
                username: AorusAIStreamOperation.username(from: arguments),
                options: options,
                allowCancel: (object["allow_cancel"] as? Bool) ?? true
            ))
        case "quota", "quota.exhausted":
            return .quota(AorusAIClient.quota(from: object))
        case "response.done":
            return .responseDone
        case "done":
            // `state` decides whether this is the end of the turn or a successful
            // intermediate stop that the client has to answer (§17).
            return .done(ok: (object["ok"] as? Bool) ?? false, state: object["state"] as? String)
        default:
            return .unknown(name: raw.name)
        }
    }

    /// `arguments.username` without the decorative `@`, or nil when absent.
    private static func username(from arguments: [String: Any]?) -> String? {
        guard let raw = arguments?["username"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        return value.isEmpty ? nil : value
    }
}
