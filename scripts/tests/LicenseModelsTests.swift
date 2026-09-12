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

@main
private enum LicenseModelsTests {
    static func main() {
        rejectsMalformedNumbers()
        rejectsUnknownAccessStates()
        acceptsIntegralServerValues()
        parsesSignedPolicyAndBadges()
        print("LicenseModels tests: OK")
    }
}
