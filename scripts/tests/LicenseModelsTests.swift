import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("LicenseModels test failed: \(message)\n", stderr)
        exit(1)
    }
}

private func rejectsMalformedNumbers() {
    let response = LicenseResponse(json: [
        "status": "paid_active",
        "active_until": NSNumber(value: true),
        "server_now": 1.5,
        "days_left": Double.infinity,
    ])
    require(response.status == .paidActive, "known status is retained")
    require(response.activeUntil == nil, "boolean is not accepted as a timestamp")
    require(response.serverNow == nil, "fractional timestamp is not truncated")
    require(response.daysLeft == nil, "non-finite day count is rejected")
}

private func rejectsUnknownAccessStates() {
    let response = LicenseResponse(json: ["status": "future_active"])
    require(response.status == .networkError, "unknown status fails closed")
    require(!response.status.allowsAppAccess, "unknown status never grants access")
}

private func acceptsIntegralServerValues() {
    let response = LicenseResponse(json: [
        "status": "trial_active",
        "active_until": NSNumber(value: Int64(1_900_000_000)),
        "server_now": 1_800_000_000.0,
        "days_left": 14,
    ])
    require(response.activeUntil == 1_900_000_000, "Int64 timestamp is accepted")
    require(response.serverNow == 1_800_000_000, "integral JSON number is accepted")
    require(response.daysLeft == 14, "integer day count is accepted")
}

private func parsesSignedPolicyAndBadges() {
    let response = LicenseResponse(json: [
        "detail": "client_outdated",
        "badges": [
            ["id": "dev", "until": NSNull()],
            ["id": "head_admin_cat", "until": 1_900_000_000],
            ["id": "unknown", "until": 1],
        ],
    ])
    require(response.status == .clientOutdated, "426 detail maps to the hard-lock state")
    require(response.status.isLocked, "outdated builds remain locked offline")
    require(response.badges.count == 2, "unknown badge identifiers are ignored")
    require(response.badges[0].id == .dev && response.badges[0].until == nil,
            "permanent DEV badge is decoded")
    require(response.badges[1].id == .meme,
            "legacy head_admin_cat is normalized to meme")
}

private func parsesBoundedBadgeSnapshot() {
    let snapshot = BadgeSnapshotResponse(json: [
        "server_now": 1_800_000_000,
        "revision": 5,
        "badges": [
            "6297603868": [["id": "dev", "until": NSNull()]],
            "8123825459": [["id": "head_admin_cat", "until": 1_900_000_000]],
            "3956524111": [["id": "verified", "until": NSNull()]],
            "123": [["id": "unknown", "until": NSNull()]],
        ],
    ])
    require(snapshot != nil, "valid badge snapshot is decoded")
    require(snapshot?.revision == 5, "snapshot revision is retained")
    require(snapshot?.badges[6_297_603_868]?.first?.id == .dev,
            "peer id keys are decoded as Int64")
    require(snapshot?.badges[8_123_825_459]?.first?.id == .meme,
            "legacy head_admin_cat is normalized in snapshots")
    require(snapshot?.badges[123] == nil, "unknown-only assignments are omitted")
}

private func skipsUnreadablePeersInBadgeSnapshots() {
    // One unreadable peer must NOT discard the roster.
    //
    // It used to, and that is how a revoke stopped applying: the client kept the
    // previous roster, retried, failed on the same entry, and the revoked badge
    // stayed on screen for good. A peer that cannot be read simply has no badges,
    // which is the safe reading — a badge is only ever granted by an entry that
    // parsed.
    let unreadableRoster: [String: Any] = [
        "not-a-peer": [[String: Any]](),
        "-5": [["id": "dev", "until": NSNull()] as [String: Any]],
        "99": NSNull(),
        "6297603868": [["id": "verified", "until": NSNull()] as [String: Any]],
    ]
    let mixed = BadgeSnapshotResponse(json: [
        "server_now": 1_800_000_000,
        "revision": 1,
        "badges": unreadableRoster,
    ])
    require(mixed != nil, "an unreadable peer does not discard the roster")
    require(mixed?.badges[6_297_603_868]?.first?.id == .verified,
            "the readable peers survive an unreadable one")
    require(mixed?.badges.count == 1, "only the readable peer is kept")

    let malformedExpiry = BadgeSnapshotResponse(json: [
        "server_now": 1_800_000_000,
        "revision": 1,
        "badges": ["42": [["id": "dev", "until": "forever"]]],
    ])
    require(malformedExpiry?.badges[42] == nil,
            "malformed expiry cannot become an accidental permanent badge")

    let excessive = Array(repeating: ["id": "dev", "until": NSNull()],
                          count: BadgeSnapshotResponse.maximumBadgesPerPeer + 1)
    let boundedRoster: [String: Any] = [
        "42": excessive,
        "6297603868": [["id": "dev", "until": NSNull()] as [String: Any]],
    ]
    let bounded = BadgeSnapshotResponse(json: [
        "server_now": 1_800_000_000,
        "revision": 1,
        "badges": boundedRoster,
    ])
    require(bounded?.badges[42] == nil, "a peer over the per-peer bound is skipped")
    require(bounded?.badges[6_297_603_868]?.first?.id == .dev,
            "the per-peer bound does not discard the rest of the roster")

    // The response AS A WHOLE is still refused when its shape is wrong or it is
    // oversized. Those describe the response itself, and one of them is not
    // partially trustworthy.
    require(BadgeSnapshotResponse(json: [
        "server_now": 1_800_000_000,
        "revision": 1,
        "badges": "nope",
    ]) == nil, "a roster that is not an object is refused whole")

    let oneBadge: [[String: Any]] = [["id": "dev", "until": NSNull()]]
    var oversized: [String: Any] = [:]
    for index in 0...BadgeSnapshotResponse.maximumPeerCount {
        oversized[String(index + 1)] = oneBadge
    }
    require(BadgeSnapshotResponse(json: [
        "server_now": 1_800_000_000,
        "revision": 1,
        "badges": oversized,
    ]) == nil, "an oversized roster is refused whole")
}

@main
private enum LicenseModelsTests {
    static func main() {
        rejectsMalformedNumbers()
        rejectsUnknownAccessStates()
        acceptsIntegralServerValues()
        parsesSignedPolicyAndBadges()
        parsesBoundedBadgeSnapshot()
        skipsUnreadablePeersInBadgeSnapshots()
        print("LicenseModels tests: OK")
    }
}
