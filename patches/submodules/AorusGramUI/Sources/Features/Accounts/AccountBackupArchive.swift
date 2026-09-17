import Foundation
import CryptoKit
import Security

// MARK: - Account backup archive format
//
// Format v1 sealed each path and each body as an independent AES-GCM box under one key, with
// no associated data, no manifest, and a bare `UInt32(0)` for "end". Every box authenticated
// only itself and said nothing about where it sat, so anyone able to write the file could:
//
//   * put the path of entry A in front of the body of entry B,
//   * delete whole entries and append the normal end marker,
//   * splice in entries taken from a different archive of the same user,
//
// and every remaining tag still verified. The archive was confidential; its *structure* was
// not authenticated at all.
//
// v2 binds every box to its position and to the archive it belongs to:
//
//     magic(7)          "AORSBK" 0x02
//     archiveId(16)     random, per archive
//     entries*          u32 sealedPathLen (0 ends) | sealedPath
//                       u64 sealedBodyLen          | sealedBody
//     u32 0             end marker
//     u32 manifestLen   | sealedManifest
//
//     AAD(path)     = magic ‖ archiveId ‖ 'P' ‖ u64(index)
//     AAD(body)     = magic ‖ archiveId ‖ 'B' ‖ u64(index) ‖ sha256(path)
//     AAD(manifest) = magic ‖ archiveId ‖ 'M' ‖ u64(entryCount)
//
// The trailing manifest lists every path with its plaintext size and SHA-256 and is itself
// sealed against the entry count, so a reader also refuses an archive that lost entries off
// the end, gained a duplicate path, or had its manifest removed — and it refuses before the
// caller raises the pending-restore flag, so live account data is never touched on the way.
//
// v1 archives are not read by the restore path any more. They are migrated to v2 in one
// streaming pass first (`AccountBackupManager.migrateLegacyArchive`), which needs no account
// data and never holds more than one entry in memory.
enum AorusBackupArchive {
    struct Entry {
        let path: String
        let body: Data

        init(path: String, body: Data) {
            self.path = path
            self.body = body
        }
    }

    struct ManifestEntry: Codable, Equatable {
        var path: String
        var size: Int64
        var digest: String
    }

    struct Manifest: Codable, Equatable {
        var archiveId: String
        var entryCount: Int
        var entries: [ManifestEntry]
    }

    struct Limits {
        var maxEntryCount: Int
        var maxSealedPathSize: UInt32
        var maxSealedEntrySize: UInt64
        var maxSealedArchiveSize: UInt64
        var maxSealedManifestSize: UInt64

        init(maxEntryCount: Int,
             maxSealedPathSize: UInt32,
             maxSealedEntrySize: UInt64,
             maxSealedArchiveSize: UInt64,
             maxSealedManifestSize: UInt64) {
            self.maxEntryCount = maxEntryCount
            self.maxSealedPathSize = maxSealedPathSize
            self.maxSealedEntrySize = maxSealedEntrySize
            self.maxSealedArchiveSize = maxSealedArchiveSize
            self.maxSealedManifestSize = maxSealedManifestSize
        }
    }

    enum Failure: Error, Equatable {
        case truncated
        case corrupt
        case tooLarge
        case encryption
        case io
    }

    static let magicV1: [UInt8] = [0x41, 0x4F, 0x52, 0x53, 0x42, 0x4B, 0x01]
    static let magicV2: [UInt8] = [0x41, 0x4F, 0x52, 0x53, 0x42, 0x4B, 0x02]
    static let archiveIdSize = 16

    static let pathTag: UInt8 = 0x50     // 'P'
    static let bodyTag: UInt8 = 0x42     // 'B'
    static let manifestTag: UInt8 = 0x4D // 'M'

    // MARK: - Associated data

    /// The associated data one box is sealed under. Everything that fixes a box's meaning —
    /// the format, the archive it belongs to, what kind of box it is and where it sits — goes
    /// in here, which is exactly what v1 left unauthenticated.
    static func associatedData(archiveId: Data, tag: UInt8, index: UInt64, extra: Data = Data()) -> Data {
        var aad = Data(magicV2)
        aad.append(archiveId)
        aad.append(tag)
        aad.append(uint64LE(index))
        aad.append(extra)
        return aad
    }

    static func sha256(_ data: Data) -> Data {
        return Data(SHA256.hash(data: data))
    }

    static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of data: Data) -> String {
        return hex(sha256(data))
    }

    static func randomArchiveId() -> Data? {
        var bytes = [UInt8](repeating: 0, count: archiveIdSize)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }

    // MARK: - Write

    /// Streams entries pulled from `next` into a v2 archive at `url`.
    ///
    /// `next` returns nil when there is nothing left, so a caller can produce entries lazily —
    /// one body is in memory at a time. Only the manifest (a path, a size and a digest per
    /// entry) accumulates. On any throw the partially written file is left for the caller to
    /// remove; nothing else is touched, which is what makes the caller's atomic commit safe.
    @discardableResult
    static func write(to url: URL,
                      key: SymmetricKey,
                      limits: Limits,
                      next: () throws -> Entry?) throws -> Manifest {
        guard let archiveId = randomArchiveId() else { throw Failure.encryption }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw Failure.io }
        var closed = false
        func closeHandle() {
            if !closed {
                closed = true
                handle.closeFile()
            }
        }
        defer { closeHandle() }

        handle.write(Data(magicV2))
        handle.write(archiveId)
        var sealedBytes = UInt64(magicV2.count + archiveIdSize)
        var manifestEntries: [ManifestEntry] = []
        var seenPaths = Set<String>()
        var index: UInt64 = 0

        while let entry = try next() {
            guard manifestEntries.count < limits.maxEntryCount else { throw Failure.tooLarge }
            // A duplicate path would make the archive ambiguous about which body wins on
            // restore, so it is refused at both ends of the format.
            guard !seenPaths.contains(entry.path) else { throw Failure.corrupt }
            seenPaths.insert(entry.path)

            let pathData = Data(entry.path.utf8)
            let pathDigest = sha256(pathData)
            guard let sealedPath = (try? AES.GCM.seal(
                    pathData,
                    using: key,
                    authenticating: associatedData(archiveId: archiveId, tag: pathTag, index: index)
                  ))?.combined,
                  let sealedBody = (try? AES.GCM.seal(
                    entry.body,
                    using: key,
                    authenticating: associatedData(archiveId: archiveId, tag: bodyTag, index: index, extra: pathDigest)
                  ))?.combined else {
                throw Failure.encryption
            }

            let (nextBytes, overflow) = sealedBytes.addingReportingOverflow(
                UInt64(4 + 8) + UInt64(sealedPath.count) + UInt64(sealedBody.count)
            )
            guard sealedPath.count <= Int(limits.maxSealedPathSize),
                  UInt64(sealedBody.count) <= limits.maxSealedEntrySize,
                  !overflow,
                  nextBytes <= limits.maxSealedArchiveSize - UInt64(MemoryLayout<UInt32>.size) else {
                throw Failure.tooLarge
            }
            sealedBytes = nextBytes

            handle.write(uint32LE(UInt32(sealedPath.count)))
            handle.write(sealedPath)
            handle.write(uint64LE(UInt64(sealedBody.count)))
            handle.write(sealedBody)
            manifestEntries.append(ManifestEntry(path: entry.path,
                                                 size: Int64(entry.body.count),
                                                 digest: digest(of: entry.body)))
            index += 1
        }

        let manifest = Manifest(archiveId: hex(archiveId),
                                entryCount: manifestEntries.count,
                                entries: manifestEntries)
        guard let manifestData = try? JSONEncoder().encode(manifest),
              let sealedManifest = (try? AES.GCM.seal(
                manifestData,
                using: key,
                authenticating: associatedData(archiveId: archiveId,
                                               tag: manifestTag,
                                               index: UInt64(manifestEntries.count))
              ))?.combined else {
            throw Failure.encryption
        }
        guard UInt64(sealedManifest.count) <= limits.maxSealedManifestSize else { throw Failure.tooLarge }

        handle.write(uint32LE(0))
        handle.write(uint32LE(UInt32(sealedManifest.count)))
        handle.write(sealedManifest)
        closeHandle()
        return manifest
    }

    // MARK: - Read

    /// Streams a v2 archive, verifying every entry's position and the trailing manifest.
    ///
    /// `accept` is called in archive order, before the manifest has been checked — a caller
    /// that materialises entries must put them somewhere it is willing to throw away, because
    /// the manifest is what decides whether the archive is whole. It returns the verified
    /// manifest, and throws rather than returning anything at all if it is not.
    @discardableResult
    static func read(url: URL,
                     key: SymmetricKey,
                     limits: Limits,
                     accept: (Entry) throws -> Void) throws -> Manifest {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.io }
        defer { handle.closeFile() }

        let head = handle.readData(ofLength: magicV2.count)
        guard Array(head) == magicV2 else { throw Failure.corrupt }
        let archiveId = handle.readData(ofLength: archiveIdSize)
        guard archiveId.count == archiveIdSize else { throw Failure.truncated }

        var sealedBytes = UInt64(magicV2.count + archiveIdSize)
        var observed: [ManifestEntry] = []
        var seenPaths = Set<String>()
        var index: UInt64 = 0
        // The flag is the loop's condition rather than something checked after it: every
        // other way out of the loop throws, so a guard below would never have run.
        var reachedEndMarker = false

        while !reachedEndMarker {
            let pathLenData = handle.readData(ofLength: 4)
            guard pathLenData.count == 4 else { throw Failure.truncated }
            let sealedPathLen = readUInt32LE(pathLenData)
            if sealedPathLen == 0 {
                reachedEndMarker = true
                continue
            }
            guard sealedPathLen <= limits.maxSealedPathSize else { throw Failure.corrupt }
            guard observed.count < limits.maxEntryCount else { throw Failure.corrupt }

            let sealedPath = handle.readData(ofLength: Int(sealedPathLen))
            guard sealedPath.count == Int(sealedPathLen) else { throw Failure.truncated }
            let bodyLenData = handle.readData(ofLength: 8)
            guard bodyLenData.count == 8 else { throw Failure.truncated }
            let sealedBodyLen = readUInt64LE(bodyLenData)
            guard sealedBodyLen <= limits.maxSealedEntrySize,
                  sealedBodyLen <= UInt64(Int.max) else { throw Failure.corrupt }
            let (nextBytes, overflow) = sealedBytes.addingReportingOverflow(
                UInt64(4 + 8) + UInt64(sealedPathLen) + sealedBodyLen
            )
            guard !overflow, nextBytes <= limits.maxSealedArchiveSize else { throw Failure.corrupt }
            sealedBytes = nextBytes
            let sealedBody = handle.readData(ofLength: Int(sealedBodyLen))
            guard sealedBody.count == Int(sealedBodyLen) else { throw Failure.truncated }

            guard let pathBox = try? AES.GCM.SealedBox(combined: sealedPath),
                  let pathData = try? AES.GCM.open(
                    pathBox,
                    using: key,
                    authenticating: associatedData(archiveId: archiveId, tag: pathTag, index: index)),
                  let path = String(data: pathData, encoding: .utf8) else {
                throw Failure.corrupt
            }
            guard !seenPaths.contains(path) else { throw Failure.corrupt }
            seenPaths.insert(path)

            guard let bodyBox = try? AES.GCM.SealedBox(combined: sealedBody),
                  let body = try? AES.GCM.open(
                    bodyBox,
                    using: key,
                    authenticating: associatedData(archiveId: archiveId,
                                                   tag: bodyTag,
                                                   index: index,
                                                   extra: sha256(pathData))) else {
                throw Failure.corrupt
            }

            observed.append(ManifestEntry(path: path, size: Int64(body.count), digest: digest(of: body)))
            try accept(Entry(path: path, body: body))
            index += 1
        }

        let manifestLenData = handle.readData(ofLength: 4)
        guard manifestLenData.count == 4 else { throw Failure.truncated }
        let sealedManifestLen = readUInt32LE(manifestLenData)
        guard sealedManifestLen > 0,
              UInt64(sealedManifestLen) <= limits.maxSealedManifestSize else { throw Failure.corrupt }
        let sealedManifest = handle.readData(ofLength: Int(sealedManifestLen))
        guard sealedManifest.count == Int(sealedManifestLen) else { throw Failure.truncated }
        guard handle.readData(ofLength: 1).isEmpty else { throw Failure.corrupt }

        guard let manifestBox = try? AES.GCM.SealedBox(combined: sealedManifest),
              let manifestData = try? AES.GCM.open(
                manifestBox,
                using: key,
                authenticating: associatedData(archiveId: archiveId,
                                               tag: manifestTag,
                                               index: UInt64(observed.count))),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            throw Failure.corrupt
        }
        guard manifest.archiveId == hex(archiveId),
              manifest.entryCount == observed.count,
              manifest.entries == observed else {
            throw Failure.corrupt
        }
        return manifest
    }

    // MARK: - Legacy (v1) reader

    /// A v1 archive read one entry at a time, so it can be re-sealed into v2 without ever
    /// holding the whole thing — or its plaintext — in memory or on disk.
    final class LegacyReader {
        private let handle: FileHandle
        private let key: SymmetricKey
        private let limits: Limits
        private var sealedBytes: UInt64
        private var entryCount = 0
        private var seenPaths = Set<String>()
        private var reachedEndMarker = false

        init(url: URL, key: SymmetricKey, limits: Limits) throws {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw Failure.io
            }
            let head = handle.readData(ofLength: AorusBackupArchive.magicV1.count)
            guard Array(head) == AorusBackupArchive.magicV1 else {
                handle.closeFile()
                throw Failure.corrupt
            }
            self.handle = handle
            self.key = key
            self.limits = limits
            self.sealedBytes = UInt64(AorusBackupArchive.magicV1.count)
        }

        deinit {
            handle.closeFile()
        }

        /// The next entry, or nil once the end marker is reached.
        func next() throws -> Entry? {
            if reachedEndMarker { return nil }
            let pathLenData = handle.readData(ofLength: 4)
            guard pathLenData.count == 4 else { throw Failure.truncated }
            let sealedPathLen = AorusBackupArchive.readUInt32LE(pathLenData)
            if sealedPathLen == 0 {
                reachedEndMarker = true
                return nil
            }
            guard sealedPathLen <= limits.maxSealedPathSize else { throw Failure.corrupt }
            entryCount += 1
            guard entryCount <= limits.maxEntryCount else { throw Failure.corrupt }

            let sealedPath = handle.readData(ofLength: Int(sealedPathLen))
            guard sealedPath.count == Int(sealedPathLen) else { throw Failure.truncated }
            let bodyLenData = handle.readData(ofLength: 8)
            guard bodyLenData.count == 8 else { throw Failure.truncated }
            let sealedBodyLen = AorusBackupArchive.readUInt64LE(bodyLenData)
            guard sealedBodyLen <= limits.maxSealedEntrySize,
                  sealedBodyLen <= UInt64(Int.max) else { throw Failure.corrupt }
            let (nextBytes, overflow) = sealedBytes.addingReportingOverflow(
                UInt64(4 + 8) + UInt64(sealedPathLen) + sealedBodyLen
            )
            guard !overflow, nextBytes <= limits.maxSealedArchiveSize else { throw Failure.corrupt }
            sealedBytes = nextBytes
            let sealedBody = handle.readData(ofLength: Int(sealedBodyLen))
            guard sealedBody.count == Int(sealedBodyLen) else { throw Failure.truncated }

            guard let pathBox = try? AES.GCM.SealedBox(combined: sealedPath),
                  let pathData = try? AES.GCM.open(pathBox, using: key),
                  let path = String(data: pathData, encoding: .utf8),
                  let bodyBox = try? AES.GCM.SealedBox(combined: sealedBody),
                  let body = try? AES.GCM.open(bodyBox, using: key) else {
                throw Failure.corrupt
            }
            guard !seenPaths.contains(path) else { throw Failure.corrupt }
            seenPaths.insert(path)
            return Entry(path: path, body: body)
        }

        /// Verifies the end marker was reached and that nothing trails it.
        func finish() throws {
            guard reachedEndMarker, handle.readData(ofLength: 1).isEmpty else {
                throw Failure.corrupt
            }
        }
    }

    // MARK: - Byte helpers (little-endian, version-safe)

    static func uint32LE(_ v: UInt32) -> Data {
        return Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }

    static func uint64LE(_ v: UInt64) -> Data {
        var bytes = [UInt8]()
        for i in 0..<8 { bytes.append(UInt8((v >> (UInt64(i) * 8)) & 0xFF)) }
        return Data(bytes)
    }

    static func readUInt32LE(_ d: Data) -> UInt32 {
        guard d.count >= 4 else { return 0 }
        let b = [UInt8](d)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    static func readUInt64LE(_ d: Data) -> UInt64 {
        guard d.count >= 8 else { return 0 }
        let b = [UInt8](d)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (UInt64(i) * 8) }
        return v
    }
}
