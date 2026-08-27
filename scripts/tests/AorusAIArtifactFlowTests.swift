import Foundation

/// The spec's artifact checklist, exercised by the release preflight instead of by a
/// device: decode, attachment to the right assistant turn, survival across the events
/// that follow, multiplicity, token hygiene, trusted-base URL construction, hostile
/// paths, persistence and the expired states.
///
/// Everything here runs against the same `AorusAIArtifactFlow` the transport calls,
/// so a regression in the production path fails the build in seconds.
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusAIArtifactFlow test failed: \(message)\n", stderr)
        exit(1)
    }
}

/// The exact payload the backend ships today.
private let productionPayload = """
{
  "artifact_id": "cf962f69-a3b8-4824-a107-00aea794318c",
  "filename": "ai-2026-development.pptx",
  "mime": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "size": 59789,
  "format": "pptx",
  "expires_at": 1787686101878,
  "download": { "path": "/download/cf962f69-a3b8-4824-a107-00aea794318c", "expires_at": 1787603301881 },
  "session_id": "5ef77a34-5cd0-41c0-a795-106df17ba5a1"
}
"""

private func object(_ json: String) -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("AorusAIArtifactFlow test failed: fixture is not an object\n", stderr)
        exit(1)
    }
    return object
}

/// The client's SSE dispatch calls `AorusAIArtifactFlow.decode` for `artifact.ready`
/// and ignores unknown names; this mirrors that routing over the real parser so the
/// ordering tests run against real byte parsing.
private func replay(_ stream: String, into messages: inout [AorusAIMessage], activeAssistantId: UUID?) -> [String] {
    let parser = AorusAISSEParser()
    var seen: [String] = []
    var events = parser.append(Data(stream.utf8))
    events.append(contentsOf: parser.finish())
    for event in events {
        seen.append(event.name)
        guard event.name == "artifact.ready" else { continue }
        guard let payload = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any],
              let artifact = AorusAIArtifactFlow.decode(payload) else { continue }
        AorusAIArtifactFlow.attach(artifact, to: &messages, activeAssistantId: activeAssistantId)
    }
    return seen
}

private func decodesProductionPayload() {
    guard let artifact = AorusAIArtifactFlow.decode(object(productionPayload)) else {
        fputs("AorusAIArtifactFlow test failed: production payload did not decode\n", stderr)
        exit(1)
    }
    require(artifact.artifactId == "cf962f69-a3b8-4824-a107-00aea794318c", "artifact id")
    require(artifact.filename == "ai-2026-development.pptx", "filename")
    require(artifact.mime == "application/vnd.openxmlformats-officedocument.presentationml.presentation", "mime")
    require(artifact.size == 59789, "size")
    require(artifact.format == "pptx", "format")
    require(artifact.downloadPath == "/download/cf962f69-a3b8-4824-a107-00aea794318c", "download path")
    require(artifact.expiresAt == 1787686101878, "artifact expiry")
    require(artifact.downloadExpiresAt == 1787603301881, "download expiry")
    require(AorusAIArtifactFlow.iconName(for: artifact) == "rectangle.on.rectangle.angled", "pptx icon")
    let detail = AorusAIArtifactFlow.cardDetail(for: artifact)
    require(detail.hasSuffix("PPTX"), "card detail carries the format")
    require(!detail.contains(artifact.artifactId), "card detail never carries the id")
    require(!detail.contains("/download/"), "card detail never carries the path")
    require(!detail.contains("1787686101878"), "card detail never carries a raw expiry")

    // A payload without an id or a filename is not an artifact.
    require(AorusAIArtifactFlow.decode(object("{\"filename\":\"a.pdf\"}")) == nil, "id is required")
    require(AorusAIArtifactFlow.decode(object("{\"artifact_id\":\"abc\"}")) == nil, "filename is required")

    // Formats we must icon natively.
    let families: [(String, String, String)] = [
        ("a.pdf", "pdf", "doc.richtext"),
        ("a.docx", "docx", "doc.text"),
        ("a.xlsx", "xlsx", "tablecells"),
        ("a.zip", "zip", "doc.zipper"),
        ("a.apk", "apk", "shippingbox"),
        ("a.bin", "bin", "doc")
    ]
    for (filename, format, expected) in families {
        let candidate = AorusAIArtifact(artifactId: "id-1", filename: filename, mime: "application/octet-stream", size: 1, format: format, downloadPath: "/download/id-1", expiresAt: nil)
        require(AorusAIArtifactFlow.iconName(for: candidate) == expected, "icon for \(format)")
    }
}

private func attachesToTheActiveAssistantTurn() {
    let firstAssistant = AorusAIMessage(role: .assistant, rawText: "старый ответ")
    let user = AorusAIMessage(role: .user, rawText: "Создай презентацию")
    let active = AorusAIMessage(role: .assistant, rawText: "", state: .streaming)
    var messages = [firstAssistant, user, active]
    guard let artifact = AorusAIArtifactFlow.decode(object(productionPayload)) else { exit(1) }
    require(AorusAIArtifactFlow.attach(artifact, to: &messages, activeAssistantId: active.id), "attach reports success")
    require(messages[0].artifacts.isEmpty, "older assistant turn untouched")
    require(messages[1].artifacts.isEmpty, "user turn untouched")
    require(messages[2].artifacts.count == 1, "artifact landed on the active turn")

    // A repeated event for the same file must not produce a second card.
    require(!AorusAIArtifactFlow.attach(artifact, to: &messages, activeAssistantId: active.id), "duplicate is refused")
    require(messages[2].artifacts.count == 1, "duplicate produced no second card")

    // No turn to attach to: nothing is invented, nothing crashes.
    var empty: [AorusAIMessage] = [AorusAIMessage(role: .user, rawText: "привет")]
    require(!AorusAIArtifactFlow.attach(artifact, to: &empty, activeAssistantId: nil), "no assistant turn to attach to")
}

private func survivesTheEventsThatFollow() {
    let active = AorusAIMessage(role: .assistant, rawText: "", state: .streaming)
    var messages = [AorusAIMessage(role: .user, rawText: "Создай презентацию на 6 слайдов"), active]
    let stream = """
    event: agent.start
    data: {"turn_id":"t-1"}

    event: status
    data: {"phase":"thinking","label":"Анализирую запрос…"}

    event: response.start
    data: {"turn_id":"t-1"}

    event: reasoning.summary
    data: {"summary":"Проектирую структуру презентации…"}

    event: render.start
    data: {"format":"pptx","label":"Рендеринг презентации…"}

    event: render.phase
    data: {"phase":"render","format":"pptx","label":"Создаю слайды…"}

    event: response.delta
    data: {"text":"Презентация готова."}

    event: artifact.ready
    data: \(productionPayload.replacingOccurrences(of: "\n", with: ""))

    event: status
    data: {"phase":"done","label":"Готово"}

    event: response.done
    data: {"turn_id":"t-1"}

    event: done
    data: {"turn_id":"t-1","ok":true}


    """
    let seen = replay(stream, into: &messages, activeAssistantId: active.id)
    require(seen.contains("artifact.ready"), "artifact.ready reached the dispatcher")
    require(Array(seen.suffix(3)) == ["status", "response.done", "done"], "artifact arrived before the closing events")
    require(messages[1].artifacts.count == 1, "artifact survived status/response.done/done")
    require(messages[1].artifacts[0].filename == "ai-2026-development.pptx", "the surviving artifact is the right one")
}

private func supportsMultipleArtifacts() {
    let active = AorusAIMessage(role: .assistant, rawText: "", state: .streaming)
    var messages = [active]
    let second = """
    {"artifact_id":"11111111-2222-3333-4444-555555555555","filename":"report.pdf","mime":"application/pdf","size":2048,"format":"pdf","expires_at":1787686101878,"download":{"path":"/download/11111111-2222-3333-4444-555555555555","expires_at":1787603301881}}
    """
    let stream = """
    event: artifact.ready
    data: \(productionPayload.replacingOccurrences(of: "\n", with: ""))

    event: artifact.ready
    data: \(second)

    event: done
    data: {"ok":true}


    """
    _ = replay(stream, into: &messages, activeAssistantId: active.id)
    require(messages[0].artifacts.count == 2, "two events produced two cards")
    require(messages[0].artifacts[0].format == "pptx", "first card keeps its order")
    require(messages[0].artifacts[1].format == "pdf", "second card keeps its order")
}

private func dropsAnyTokenAndSessionId() {
    let hostile = """
    {
      "artifact_id": "cf962f69-a3b8-4824-a107-00aea794318c",
      "filename": "ai-2026-development.pptx",
      "mime": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "size": 59789,
      "format": "pptx",
      "token": "vault-secret-token",
      "vault_token": "another-secret",
      "session_id": "5ef77a34-5cd0-41c0-a795-106df17ba5a1",
      "download": { "path": "/download/cf962f69-a3b8-4824-a107-00aea794318c?token=vault-secret-token", "token": "third-secret", "expires_at": 1787603301881 }
    }
    """
    guard let artifact = AorusAIArtifactFlow.decode(object(hostile)) else {
        fputs("AorusAIArtifactFlow test failed: hostile payload must still decode the file\n", stderr)
        exit(1)
    }
    // A query string is not a path, so the whole value is refused and the canonical
    // path is used instead: the token never becomes part of a request we sign.
    require(artifact.downloadPath == "/download/cf962f69-a3b8-4824-a107-00aea794318c", "tokenised path is replaced by the canonical one")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(artifact), let text = String(data: encoded, encoding: .utf8) else {
        fputs("AorusAIArtifactFlow test failed: artifact is not encodable\n", stderr)
        exit(1)
    }
    for secret in ["vault-secret-token", "another-secret", "third-secret", "5ef77a34-5cd0-41c0-a795-106df17ba5a1", "token"] {
        require(!text.contains(secret), "persisted artifact must not carry \(secret)")
    }
    require(AorusAIArtifactFlow.downloadURL(for: artifact)?.query == nil, "signed URL carries no query")
    require(!AorusAIArtifactFlow.cardDetail(for: artifact).contains("5ef77a34"), "card detail carries no session id")
}

private func buildsTheURLOnlyFromTheTrustedBase() {
    guard let artifact = AorusAIArtifactFlow.decode(object(productionPayload)),
          let url = AorusAIArtifactFlow.downloadURL(for: artifact) else {
        fputs("AorusAIArtifactFlow test failed: production payload has no download URL\n", stderr)
        exit(1)
    }
    require(url.absoluteString == "https://ai.aorusgram.com/download/cf962f69-a3b8-4824-a107-00aea794318c", "absolute download URL")
    require(url.scheme == "https", "https only")
    require(url.host == "ai.aorusgram.com", "trusted host only")
    require(AorusAIArtifactFlow.signingPath(for: artifact) == "/download/cf962f69-a3b8-4824-a107-00aea794318c", "signing path is relative")

    // Nothing else may ever become a request.
    let id = "cf962f69-a3b8-4824-a107-00aea794318c"
    let rejected = [
        "https://evil.example.com/download/\(id)",
        "http://ai.aorusgram.com/download/\(id)",
        "//evil.example.com/download/\(id)",
        "javascript:alert(1)/\(id)",
        "/download/../../etc/passwd/\(id)",
        "/download/\(id)?token=x",
        "/download/\(id)#fragment",
        "/download/\(id)\nX-Injected: 1",
        "/download/\(id)/../\(id)",
        "download/\(id)",
        "/download/00000000-0000-0000-0000-000000000000",
        ""
    ]
    for candidate in rejected {
        require(AorusAIArtifactFlow.sanitizedPath(candidate, artifactId: id) == nil, "path must be rejected: \(candidate)")
        let forged = AorusAIArtifact(artifactId: id, filename: "a.pptx", mime: "application/pdf", size: 1, format: "pptx", downloadPath: candidate, expiresAt: nil)
        require(AorusAIArtifactFlow.signingPath(for: forged) == nil, "forged artifact must not be signable: \(candidate)")
        require(AorusAIArtifactFlow.downloadURL(for: forged) == nil, "forged artifact must have no URL: \(candidate)")
    }

    // A nested but still local path is legitimate.
    require(AorusAIArtifactFlow.sanitizedPath("/v1/artifacts/\(id)/file", artifactId: id) == "/v1/artifacts/\(id)/file", "nested local path is accepted")
    // Surrounding whitespace is trimmed rather than treated as a different path.
    require(AorusAIArtifactFlow.sanitizedPath("  /download/\(id)\n", artifactId: id) == "/download/\(id)", "surrounding whitespace is trimmed")
    // A hostile filename cannot escape the download directory.
    require(AorusAIArtifactFlow.safeFilename("../../../../etc/passwd") == "passwd", "filename is a single component")
    require(AorusAIArtifactFlow.safeFilename("/") == "AorusAI-file", "degenerate filename gets a fallback")
    require(AorusAIArtifactFlow.safeMIME("text/plain\r\nX: 1") == nil, "header injection through MIME is refused")
}

/// The signature of a `GET`/`HEAD` covers the SHA-256 of zero bytes. The transport is
/// what enforces that (`request.httpBody` is only set for other methods, and the hash
/// is taken over the empty `Data()` handed to `signedRequest`); the invariant the flow
/// owns is that a download is always a bodyless request to a bare relative path — no
/// query, so nothing about the request depends on client-side secrets.
private func downloadIsABodylessRequest() {
    let empty = Data()
    require(empty.isEmpty, "a GET download body is empty")
    guard let artifact = AorusAIArtifactFlow.decode(object(productionPayload)),
          let url = AorusAIArtifactFlow.downloadURL(for: artifact) else { exit(1) }
    require(url.query == nil, "no token query parameter is ever built client-side")
    require(url.path == AorusAIArtifactFlow.canonicalPath(artifactId: artifact.artifactId), "the signed path is the artifact's own path")
    require(AorusAIArtifactFlow.canonicalPath(artifactId: "abc") == "/download/abc", "canonical path shape")
    require(!AorusAIArtifactFlow.isSafeArtifactId("../abc"), "unsafe id")
    require(!AorusAIArtifactFlow.isSafeArtifactId(""), "empty id")
    require(AorusAIArtifactFlow.isSafeArtifactId("cf962f69-a3b8-4824-a107-00aea794318c"), "uuid id")
}

private func persistsAcrossARestart() {
    guard let artifact = AorusAIArtifactFlow.decode(object(productionPayload)) else { exit(1) }
    let second = AorusAIArtifact(artifactId: "id-2", filename: "report.pdf", mime: "application/pdf", size: 2048, format: "pdf", downloadPath: "/download/id-2", expiresAt: 1787686101878, downloadExpiresAt: nil)
    // Millisecond precision, because that is what the store writes to disk.
    let stamp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    let conversation = AorusAIConversation(
        title: "Презентация",
        createdAt: stamp,
        updatedAt: stamp,
        messages: [
            AorusAIMessage(role: .user, rawText: "Создай презентацию", createdAt: stamp),
            AorusAIMessage(role: .assistant, rawText: "Презентация готова.", createdAt: stamp, artifacts: [artifact, second])
        ]
    )
    // The same coder settings the store uses on disk.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let data = try? encoder.encode([conversation]),
          let restored = try? decoder.decode([AorusAIConversation].self, from: data) else {
        fputs("AorusAIArtifactFlow test failed: conversation did not round-trip\n", stderr)
        exit(1)
    }
    require(restored == [conversation], "the whole conversation survives a restart")
    let restoredArtifacts = restored[0].messages[1].artifacts
    require(restoredArtifacts.count == 2, "both artifacts survive a restart")
    require(restoredArtifacts[0].artifactId == artifact.artifactId, "artifactId persisted")
    require(restoredArtifacts[0].filename == artifact.filename, "filename persisted")
    require(restoredArtifacts[0].mime == artifact.mime, "mime persisted")
    require(restoredArtifacts[0].size == artifact.size, "size persisted")
    require(restoredArtifacts[0].format == artifact.format, "format persisted")
    require(restoredArtifacts[0].expiresAt == artifact.expiresAt, "expiresAt persisted")
    require(restoredArtifacts[0].downloadPath == artifact.downloadPath, "downloadPath persisted")
    require(restoredArtifacts[0].downloadExpiresAt == artifact.downloadExpiresAt, "downloadExpiresAt persisted")
}

private func rendersTheExpiredStates() {
    let past = Int64(Date().timeIntervalSince1970 - 3600) * 1000
    let future = Int64(Date().timeIntervalSince1970 + 3600) * 1000

    let alive = AorusAIArtifact(artifactId: "id-1", filename: "a.pptx", mime: "application/pdf", size: 1, format: "pptx", downloadPath: "/download/id-1", expiresAt: future, downloadExpiresAt: future)
    require(!alive.isExpired && !alive.isDownloadExpired, "a live artifact is not expired")

    // The link died first: the card stays as a historical fact, only the tap changes.
    let staleLink = AorusAIArtifact(artifactId: "id-1", filename: "a.pptx", mime: "application/pdf", size: 1, format: "pptx", downloadPath: "/download/id-1", expiresAt: future, downloadExpiresAt: past)
    require(!staleLink.isExpired, "a stale link does not expire the artifact")
    require(staleLink.isDownloadExpired, "a stale link is reported as such")

    let dead = AorusAIArtifact(artifactId: "id-1", filename: "a.pptx", mime: "application/pdf", size: 1, format: "pptx", downloadPath: "/download/id-1", expiresAt: past, downloadExpiresAt: past)
    require(dead.isExpired && dead.isDownloadExpired, "an expired artifact is expired")

    // Seconds and milliseconds are both understood, and a missing expiry never expires.
    let seconds = AorusAIArtifact(artifactId: "id-1", filename: "a.pptx", mime: "application/pdf", size: 1, format: "pptx", downloadPath: "/download/id-1", expiresAt: Int64(Date().timeIntervalSince1970) - 60, downloadExpiresAt: nil)
    require(seconds.isExpired, "second-precision expiry is understood")
    require(!seconds.isDownloadExpired, "a missing link expiry never expires")
}

/// The profile block is what makes `@handle` mean something to the model, so its
/// shape and its clamps are pinned here rather than trusted to the view layer.
private func buildsTheProfileTransportBlock() {
    let labels = AorusAIProfileLabels(profile: "Профиль", kind: "Тип", participants: "Участников", about: "Описание")

    let channel = AorusAIProfileSummary(title: "Aorus News", username: "aorusnews", kind: "канал", bio: "Официальный канал", participantCount: 4213)
    let lines = channel.transportBlock(labels: labels).components(separatedBy: "\n")
    require(lines.count == 4, "a full profile renders four lines")
    require(lines[0] == "Профиль: Aorus News (@aorusnews)", "the head carries the title and the handle")
    require(lines[1] == "Тип: канал", "the kind follows the head")
    require(lines[2] == "Участников: 4213", "the member count is plain")
    require(lines[3] == "Описание: Официальный канал", "the bio comes last")

    // Nothing empty is ever transported, so a bare user does not ship blank labels.
    let bare = AorusAIProfileSummary(title: "Иван", username: nil, kind: "пользователь", bio: "   ", participantCount: 0)
    let bareLines = bare.transportBlock(labels: labels).components(separatedBy: "\n")
    require(bareLines == ["Профиль: Иван", "Тип: пользователь"], "empty facts are dropped")

    // The clamps are what keep a hostile bio out of the request budget.
    let long = AorusAIProfileSummary(title: String(repeating: "t", count: 400), username: nil, kind: "", bio: String(repeating: "b", count: 2000), participantCount: nil)
    let longLines = long.transportBlock(labels: labels).components(separatedBy: "\n")
    require(longLines.count == 2, "a clamped profile is still two lines")
    require(longLines[0] == "Профиль: " + String(repeating: "t", count: 160), "the head is clamped to 160")
    require(longLines[1] == "Описание: " + String(repeating: "b", count: 700), "the bio is clamped to 700")
}

private func describesTheCard() {
    let artifact = AorusAIArtifact(artifactId: "id-1", filename: "deck.pptx", mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation", size: 59_800, format: "pptx", downloadPath: "/download/id-1", expiresAt: nil, downloadExpiresAt: nil)
    let detail = AorusAIArtifactFlow.cardDetail(for: artifact)
    require(detail.contains("PPTX"), "the card names the format in caps")
    require(detail.contains("·"), "size and format are separated")
}

@main
private enum AorusAIArtifactFlowTests {
    static func main() {
        decodesProductionPayload()
        attachesToTheActiveAssistantTurn()
        survivesTheEventsThatFollow()
        supportsMultipleArtifacts()
        dropsAnyTokenAndSessionId()
        buildsTheURLOnlyFromTheTrustedBase()
        downloadIsABodylessRequest()
        persistsAcrossARestart()
        rendersTheExpiredStates()
        buildsTheProfileTransportBlock()
        describesTheCard()
        print("AorusAIArtifactFlow tests: OK")
    }
}
