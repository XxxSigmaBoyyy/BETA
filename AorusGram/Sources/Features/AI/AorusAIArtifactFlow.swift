import Foundation

/// Everything about an artifact that does not need UIKit, a network stack or a
/// Keychain: decoding the `artifact.ready` payload, deciding which relative path may
/// be signed, attaching the file to the assistant turn it belongs to and describing
/// it for a card.
///
/// It lives apart from the transport so the whole flow can be exercised by the
/// release preflight instead of only by a device.
public enum AorusAIArtifactFlow {
    /// The only host an artifact may ever be fetched from.
    public static let base = URL(string: "https://ai.aorusgram.com")!

    /// Decodes one `artifact.ready` payload.
    ///
    /// Unknown members — including any `token` the backend might ever add — are
    /// dropped: the model has no field for them, so they cannot be stored, shown or
    /// replayed. A payload without an id or a filename is not an artifact.
    public static func decode(_ object: [String: Any]) -> AorusAIArtifact? {
        let source = (object["artifact"] as? [String: Any]) ?? object
        guard let artifactId = source["artifact_id"] as? String ?? source["id"] as? String,
              isSafeArtifactId(artifactId) else { return nil }
        guard let rawFilename = source["filename"] as? String else { return nil }
        let filename = safeFilename(rawFilename)
        guard !filename.isEmpty else { return nil }
        let download = source["download"] as? [String: Any]
        let path = sanitizedPath(download?["path"] as? String, artifactId: artifactId) ?? canonicalPath(artifactId: artifactId)
        let size = int64(source["size"]) ?? 0
        let format = (source["format"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: filename).pathExtension
        return AorusAIArtifact(
            artifactId: artifactId,
            filename: filename,
            mime: (source["mime"] as? String).flatMap { safeMIME($0) } ?? "application/octet-stream",
            size: max(0, size),
            format: String(format.prefix(16)),
            downloadPath: path,
            expiresAt: int64(source["expires_at"]),
            downloadExpiresAt: int64(download?["expires_at"])
        )
    }

    /// Appends `artifact` to the assistant turn that is currently streaming.
    ///
    /// The event may arrive before the final text and before `response.done`, so the
    /// turn is addressed by identity — never by "the last message" — and a repeated
    /// event for the same file is ignored instead of producing a second card.
    @discardableResult
    public static func attach(_ artifact: AorusAIArtifact, to messages: inout [AorusAIMessage], activeAssistantId: UUID?) -> Bool {
        let index: Int?
        if let activeAssistantId {
            index = messages.firstIndex(where: { $0.id == activeAssistantId })
        } else {
            index = messages.lastIndex(where: { $0.role == .assistant })
        }
        guard let index else { return false }
        guard !messages[index].artifacts.contains(where: { $0.artifactId == artifact.artifactId }) else { return false }
        messages[index].artifacts.append(artifact)
        return true
    }

    /// The relative path that may be signed and requested, or nil when the backend
    /// sent something that is not a plain path on our own host.
    public static func signingPath(for artifact: AorusAIArtifact) -> String? {
        return sanitizedPath(artifact.downloadPath, artifactId: artifact.artifactId)
    }

    /// The absolute download URL, built only from the trusted base and a safe
    /// relative path. A payload carrying another host or scheme is rejected.
    public static func downloadURL(for artifact: AorusAIArtifact) -> URL? {
        guard let path = signingPath(for: artifact),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == "https",
              url.host?.lowercased() == base.host?.lowercased(),
              url.query == nil else { return nil }
        return url
    }

    public static func canonicalPath(artifactId: String) -> String {
        return "/download/" + artifactId
    }

    /// Accepts a server-relative path and nothing else: no scheme, no host, no
    /// traversal, no query — the token belongs to the gateway, never to the client.
    public static func sanitizedPath(_ value: String?, artifactId: String) -> String? {
        guard isSafeArtifactId(artifactId) else { return nil }
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 512 else { return nil }
        guard raw.hasPrefix("/"), !raw.hasPrefix("//") else { return nil }
        guard !raw.contains(".."), !raw.contains("?"), !raw.contains("#"), !raw.contains(":"),
              !raw.contains("\\"), !raw.contains("\r"), !raw.contains("\n"), !raw.contains(" ") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_.~")
        guard raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        // The path must address this very artifact: a valid-looking path pointing at
        // some other object is a server bug at best.
        guard raw.split(separator: "/").contains(where: { $0 == artifactId[...] }) else { return nil }
        return raw
    }

    public static func isSafeArtifactId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value == 45 || scalar.value == 95
        }
    }

    /// One path component and nothing else. Separators become dashes, and a name made
    /// only of dots, dashes or spaces — including `.`, `..` and a hidden-file name —
    /// is replaced rather than written to disk as given.
    public static func safeFilename(_ filename: String) -> String {
        let lastComponent = URL(fileURLWithPath: filename).lastPathComponent
        let cleaned = lastComponent
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return cleaned.isEmpty ? "AorusAI-file" : String(cleaned.prefix(180))
    }

    public static func safeMIME(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 127, !value.contains("\r"), !value.contains("\n") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-/")
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    /// `58,4 КБ · PPTX` — size and format only. Identifiers, paths, session ids and
    /// raw expiry numbers are deliberately absent.
    public static func cardDetail(for artifact: AorusAIArtifact) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: max(0, artifact.size))
        let format = artifact.format.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return format.isEmpty ? size : size + " · " + format
    }

    /// A native symbol per format family, chosen from the format first and the MIME
    /// type second so an unusual extension still gets the right icon.
    public static func iconName(for artifact: AorusAIArtifact) -> String {
        let format = artifact.format.lowercased()
        let mime = artifact.mime.lowercased()
        if ["ppt", "pptx", "key", "odp"].contains(format) || mime.contains("presentation") {
            return "rectangle.on.rectangle.angled"
        }
        if format == "pdf" || mime.contains("pdf") {
            return "doc.richtext"
        }
        if ["doc", "docx", "rtf", "odt", "pages", "txt", "md"].contains(format) || mime.contains("wordprocessing") || mime.contains("msword") {
            return "doc.text"
        }
        if ["xls", "xlsx", "csv", "numbers", "ods"].contains(format) || mime.contains("spreadsheet") || mime.contains("excel") {
            return "tablecells"
        }
        if ["zip", "tar", "gz", "7z", "rar", "ipa"].contains(format) || mime.contains("zip") || mime.contains("compressed") {
            return "doc.zipper"
        }
        if ["apk", "aab"].contains(format) || mime.contains("android") {
            return "shippingbox"
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(format) || mime.hasPrefix("image/") {
            return "photo"
        }
        if ["mp4", "mov", "m4v", "webm"].contains(format) || mime.hasPrefix("video/") {
            return "film"
        }
        if ["mp3", "m4a", "wav", "ogg", "flac"].contains(format) || mime.hasPrefix("audio/") {
            return "waveform"
        }
        if ["swift", "py", "js", "ts", "json", "html", "css", "sh", "yml", "yaml", "xml"].contains(format) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc"
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
