import Foundation
import CryptoKit

// The account-backup archive. v1 sealed each path and each body as an independent AES-GCM box
// with no associated data and no manifest, so every box authenticated itself and nothing else:
// paths and bodies could be swapped between entries, entries could be deleted and the normal
// end marker appended, and entries from another archive of the same user could be spliced in —
// all with valid tags. The tests below are that attack, run against the format.

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusBackupArchive test failed: \(message)\n", stderr)
        exit(1)
    }
}

private let limits = AorusBackupArchive.Limits(
    maxEntryCount: 50_000,
    maxSealedPathSize: 64 * 1024,
    maxSealedEntrySize: 4 * 1024 * 1024,
    maxSealedArchiveSize: 256 * 1024 * 1024,
    maxSealedManifestSize: 32 * 1024 * 1024
)

private let scratch: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("aorus-backup-archive-tests-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

private func scratchFile(_ name: String) -> URL {
    return scratch.appendingPathComponent(name)
}

private let sample: [AorusBackupArchive.Entry] = [
    AorusBackupArchive.Entry(path: "accounts-metadata/atomic-state", body: Data("{\"currentRecordId\":\"1\"}".utf8)),
    AorusBackupArchive.Entry(path: "account-1/network", body: Data(repeating: 0xA1, count: 4096)),
    AorusBackupArchive.Entry(path: "account-2/network", body: Data(repeating: 0xB2, count: 128)),
]

@discardableResult
private func writeSample(to url: URL, key: SymmetricKey,
                         entries: [AorusBackupArchive.Entry] = sample) throws -> AorusBackupArchive.Manifest {
    var cursor = 0
    return try AorusBackupArchive.write(to: url, key: key, limits: limits) {
        guard cursor < entries.count else { return nil }
        defer { cursor += 1 }
        return entries[cursor]
    }
}

private func readAll(_ url: URL, key: SymmetricKey) throws -> [AorusBackupArchive.Entry] {
    var out: [AorusBackupArchive.Entry] = []
    try AorusBackupArchive.read(url: url, key: key, limits: limits) { out.append($0) }
    return out
}

private func rejects(_ url: URL, key: SymmetricKey, _ message: String) {
    do {
        _ = try readAll(url, key: key)
        fputs("AorusBackupArchive test failed: \(message)\n", stderr)
        exit(1)
    } catch {
        // Rejected, which is the point. Which failure it is does not matter: the reader
        // refuses before the caller can raise the pending-restore flag either way.
    }
}

// MARK: - Framing, so a test can tamper the way an attacker would

private struct ParsedArchive {
    var magic: Data
    var archiveId: Data
    var entries: [(path: Data, body: Data)]
    var manifest: Data
}

private func parse(_ url: URL) -> ParsedArchive {
    let bytes = [UInt8](try! Data(contentsOf: url))
    var offset = 0
    func take(_ count: Int) -> Data {
        require(offset + count <= bytes.count, "the archive is long enough to parse")
        let slice = Data(bytes[offset ..< offset + count])
        offset += count
        return slice
    }
    let magic = take(AorusBackupArchive.magicV2.count)
    let archiveId = take(AorusBackupArchive.archiveIdSize)
    var entries: [(path: Data, body: Data)] = []
    while true {
        let pathLen = AorusBackupArchive.readUInt32LE(take(4))
        if pathLen == 0 { break }
        let path = take(Int(pathLen))
        let bodyLen = AorusBackupArchive.readUInt64LE(take(8))
        entries.append((path: path, body: take(Int(bodyLen))))
    }
    let manifestLen = AorusBackupArchive.readUInt32LE(take(4))
    return ParsedArchive(magic: magic, archiveId: archiveId, entries: entries, manifest: take(Int(manifestLen)))
}

private func serialize(_ archive: ParsedArchive) -> Data {
    var out = Data()
    out.append(archive.magic)
    out.append(archive.archiveId)
    for entry in archive.entries {
        out.append(AorusBackupArchive.uint32LE(UInt32(entry.path.count)))
        out.append(entry.path)
        out.append(AorusBackupArchive.uint64LE(UInt64(entry.body.count)))
        out.append(entry.body)
    }
    out.append(AorusBackupArchive.uint32LE(0))
    out.append(AorusBackupArchive.uint32LE(UInt32(archive.manifest.count)))
    out.append(archive.manifest)
    return out
}

// MARK: - Tests

private func roundTrips() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("round-trip.enc")
    let written = try! writeSample(to: url, key: key)
    require(written.entryCount == sample.count, "the manifest counts every entry")
    require(written.entries.map { $0.path } == sample.map { $0.path }, "in archive order")

    let read = try! readAll(url, key: key)
    require(read.count == sample.count, "every entry comes back")
    for (index, entry) in read.enumerated() {
        require(entry.path == sample[index].path, "path \(index) survives the round trip")
        require(entry.body == sample[index].body, "body \(index) survives the round trip")
    }

    // A different key is a different archive, not a partially readable one.
    rejects(url, key: SymmetricKey(size: .bits256), "another key opens the archive")
}

private func refusesASwappedPath() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("swapped-path.enc")
    try! writeSample(to: url, key: key)
    var archive = parse(url)
    let first = archive.entries[0].path
    archive.entries[0].path = archive.entries[1].path
    archive.entries[1].path = first
    try! serialize(archive).write(to: url)
    // This is the v1 attack verbatim: both boxes are genuine and open under the key. Only the
    // index in their associated data says they have moved.
    rejects(url, key: key, "a path moved to another entry is accepted")
}

private func refusesASwappedBody() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("swapped-body.enc")
    try! writeSample(to: url, key: key)
    var archive = parse(url)
    let first = archive.entries[0].body
    archive.entries[0].body = archive.entries[1].body
    archive.entries[1].body = first
    try! serialize(archive).write(to: url)
    rejects(url, key: key, "a body moved under another path is accepted")
}

private func refusesADeletedEntry() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("deleted-entry.enc")
    try! writeSample(to: url, key: key)
    var archive = parse(url)
    archive.entries.remove(at: 1)
    try! serialize(archive).write(to: url)
    // The remaining entries still carry valid tags, and the end marker is exactly where the
    // format says it should be. The manifest is what notices — it is sealed against the count.
    rejects(url, key: key, "an archive with an entry removed is accepted")
}

private func refusesATransplantedEntry() {
    let key = SymmetricKey(size: .bits256)
    let mine = scratchFile("mine.enc")
    let other = scratchFile("other.enc")
    try! writeSample(to: mine, key: key)
    try! writeSample(to: other, key: key, entries: [
        AorusBackupArchive.Entry(path: "account-1/network", body: Data("stale session".utf8)),
        AorusBackupArchive.Entry(path: "account-9/network", body: Data("a third account".utf8)),
        AorusBackupArchive.Entry(path: "accounts-metadata/atomic-state", body: Data("{}".utf8)),
    ])
    var archive = parse(mine)
    let donor = parse(other)
    // Same key, same position, an entry the user really did have once.
    archive.entries[0] = donor.entries[0]
    try! serialize(archive).write(to: mine)
    rejects(mine, key: key, "an entry from another archive is accepted")
}

private func refusesATruncatedArchive() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("truncated.enc")
    try! writeSample(to: url, key: key)
    let whole = try! Data(contentsOf: url)
    try! whole.prefix(whole.count - 16).write(to: url)
    rejects(url, key: key, "a truncated archive is accepted")
}

private func refusesAMissingManifest() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("no-manifest.enc")
    try! writeSample(to: url, key: key)
    var archive = parse(url)
    archive.manifest = Data()
    try! serialize(archive).write(to: url)
    rejects(url, key: key, "an archive with its manifest stripped is accepted")
}

private func refusesADuplicatePath() {
    let key = SymmetricKey(size: .bits256)
    let url = scratchFile("duplicate-write.enc")
    let duplicated = [
        AorusBackupArchive.Entry(path: "account-1/network", body: Data("first".utf8)),
        AorusBackupArchive.Entry(path: "account-1/network", body: Data("second".utf8)),
    ]
    do {
        try writeSample(to: url, key: key, entries: duplicated)
        require(false, "the writer emits an archive with two entries for one path")
    } catch {
        // Refused at the writing end.
    }

    // And at the reading end, for an archive some other holder of the key produced: both
    // boxes below are sealed with the associated data of the position they sit in, so only
    // the duplicate-path rule can catch them.
    let forged = scratchFile("duplicate-read.enc")
    let archiveId = AorusBackupArchive.randomArchiveId()!
    var out = Data()
    out.append(Data(AorusBackupArchive.magicV2))
    out.append(archiveId)
    var manifestEntries: [AorusBackupArchive.ManifestEntry] = []
    for (index, entry) in duplicated.enumerated() {
        let pathData = Data(entry.path.utf8)
        let sealedPath = try! AES.GCM.seal(
            pathData, using: key,
            authenticating: AorusBackupArchive.associatedData(
                archiveId: archiveId, tag: AorusBackupArchive.pathTag, index: UInt64(index))).combined!
        let sealedBody = try! AES.GCM.seal(
            entry.body, using: key,
            authenticating: AorusBackupArchive.associatedData(
                archiveId: archiveId, tag: AorusBackupArchive.bodyTag, index: UInt64(index),
                extra: AorusBackupArchive.sha256(pathData))).combined!
        out.append(AorusBackupArchive.uint32LE(UInt32(sealedPath.count)))
        out.append(sealedPath)
        out.append(AorusBackupArchive.uint64LE(UInt64(sealedBody.count)))
        out.append(sealedBody)
        manifestEntries.append(AorusBackupArchive.ManifestEntry(
            path: entry.path, size: Int64(entry.body.count),
            digest: AorusBackupArchive.digest(of: entry.body)))
    }
    let manifest = AorusBackupArchive.Manifest(
        archiveId: AorusBackupArchive.hex(archiveId),
        entryCount: manifestEntries.count,
        entries: manifestEntries)
    let manifestData = try! JSONEncoder().encode(manifest)
    let sealedManifest = try! AES.GCM.seal(
        manifestData, using: key,
        authenticating: AorusBackupArchive.associatedData(
            archiveId: archiveId, tag: AorusBackupArchive.manifestTag,
            index: UInt64(manifestEntries.count))).combined!
    out.append(AorusBackupArchive.uint32LE(0))
    out.append(AorusBackupArchive.uint32LE(UInt32(sealedManifest.count)))
    out.append(sealedManifest)
    try! out.write(to: forged)
    rejects(forged, key: key, "two entries claiming one path are accepted")
}

// MARK: - v1

/// A v1 archive, written the way the shipped code wrote it: bare boxes, no associated data,
/// no manifest, a zero UInt32 for "end".
private func writeLegacy(to url: URL, key: SymmetricKey, entries: [AorusBackupArchive.Entry]) {
    var out = Data()
    out.append(Data(AorusBackupArchive.magicV1))
    for entry in entries {
        let sealedPath = try! AES.GCM.seal(Data(entry.path.utf8), using: key).combined!
        let sealedBody = try! AES.GCM.seal(entry.body, using: key).combined!
        out.append(AorusBackupArchive.uint32LE(UInt32(sealedPath.count)))
        out.append(sealedPath)
        out.append(AorusBackupArchive.uint64LE(UInt64(sealedBody.count)))
        out.append(sealedBody)
    }
    out.append(AorusBackupArchive.uint32LE(0))
    try! out.write(to: url)
}

private func migratesTheLegacyFormat() {
    let key = SymmetricKey(size: .bits256)
    let legacy = scratchFile("legacy.enc")
    let migrated = scratchFile("migrated.enc")
    writeLegacy(to: legacy, key: key, entries: sample)

    // Exactly what AccountBackupManager.migrateLegacyArchive does: pull each entry out of the
    // old archive and re-seal it into a new one, one entry in memory at a time.
    let reader = try! AorusBackupArchive.LegacyReader(url: legacy, key: key, limits: limits)
    try! AorusBackupArchive.write(to: migrated, key: key, limits: limits) { try reader.next() }
    try! reader.finish()

    let read = try! readAll(migrated, key: key)
    require(read.count == sample.count, "migration keeps every entry")
    for (index, entry) in read.enumerated() {
        require(entry.path == sample[index].path, "migrated path \(index) is unchanged")
        require(entry.body == sample[index].body, "migrated body \(index) is unchanged")
    }

    // The v2 reader must not accept the old file itself, or the migration would be optional
    // in practice and the guarantees above would only hold for people who made a new backup.
    rejects(legacy, key: key, "a v1 archive is read by the v2 reader")

    // And this is why migration, not acceptance: in v1 the same swap that v2 refuses above
    // goes through undetected, which is the defect the format change exists to close.
    let tampered = scratchFile("legacy-tampered.enc")
    writeLegacy(to: tampered, key: key, entries: sample)
    let bytes = [UInt8](try! Data(contentsOf: tampered))
    var offset = AorusBackupArchive.magicV1.count
    var boxes: [(path: Data, body: Data)] = []
    while true {
        let pathLen = AorusBackupArchive.readUInt32LE(Data(bytes[offset ..< offset + 4]))
        offset += 4
        if pathLen == 0 { break }
        let path = Data(bytes[offset ..< offset + Int(pathLen)])
        offset += Int(pathLen)
        let bodyLen = AorusBackupArchive.readUInt64LE(Data(bytes[offset ..< offset + 8]))
        offset += 8
        let body = Data(bytes[offset ..< offset + Int(bodyLen)])
        offset += Int(bodyLen)
        boxes.append((path: path, body: body))
    }
    let firstBody = boxes[0].body
    boxes[0].body = boxes[1].body
    boxes[1].body = firstBody
    var forged = Data()
    forged.append(Data(AorusBackupArchive.magicV1))
    for box in boxes {
        forged.append(AorusBackupArchive.uint32LE(UInt32(box.path.count)))
        forged.append(box.path)
        forged.append(AorusBackupArchive.uint64LE(UInt64(box.body.count)))
        forged.append(box.body)
    }
    forged.append(AorusBackupArchive.uint32LE(0))
    try! forged.write(to: tampered)
    let legacyReader = try! AorusBackupArchive.LegacyReader(url: tampered, key: key, limits: limits)
    let firstEntry = try! legacyReader.next()
    require(firstEntry?.path == sample[0].path, "v1 still reports the original path")
    require(firstEntry?.body == sample[1].body, "with another entry's body under it, undetected")
}

@main
private enum AorusBackupArchiveTests {
    static func main() {
        roundTrips()
        refusesASwappedPath()
        refusesASwappedBody()
        refusesADeletedEntry()
        refusesATransplantedEntry()
        refusesATruncatedArchive()
        refusesAMissingManifest()
        refusesADuplicatePath()
        migratesTheLegacyFormat()
        try? FileManager.default.removeItem(at: scratch)
        print("AorusBackupArchive tests: OK")
    }
}
