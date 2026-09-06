#!/usr/bin/env python3
"""Fast, deterministic release-security checks for AorusGram CI."""

from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
from pathlib import Path


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def git_ignored(root: Path) -> set[str]:
    """Repo-relative paths git is told to ignore; empty when this is not a checkout.

    In CI the tree is a fresh clone with nothing ignored, so this is a no-op there. It exists
    so the same check can be run on a working copy that holds untracked local files.
    """
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--others", "--ignored", "--exclude-standard"],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return set()
    return {line for line in result.stdout.splitlines() if line}


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors: list[str] = []

    workflow_path = root / ".github/workflows/build-aorusgram.yml"
    workflow = workflow_path.read_text(encoding="utf-8")
    if "contents: read" not in workflow or "contents: write" in workflow:
        fail(errors, "workflow permissions must be read-only")
    if re.search(r"uses:\s+[^\s@]+@v\d+\b", workflow):
        fail(errors, "GitHub Actions must be pinned to immutable commit SHAs")
    if "path: telegram-ios\n" in workflow:
        fail(errors, "the mutable Telegram working tree must never be cached")
    if "path: telegram-ios-pristine" not in workflow:
        fail(errors, "the immutable Telegram source cache is missing")
    commit = re.search(r"TELEGRAM_IOS_COMMIT:\s*([0-9a-f]{40})\b", workflow)
    if commit is None:
        fail(errors, "Telegram iOS must be pinned to an exact 40-character commit")
    upstream_version_match = re.search(r"TELEGRAM_IOS_VERSION:\s*([0-9]+(?:\.[0-9]+)+)\b", workflow)
    if upstream_version_match is None:
        fail(errors, "Telegram iOS version must be declared explicitly")
        upstream_version = None
    else:
        upstream_version = upstream_version_match.group(1)
    if 'json.load(open("telegram-ios/versions.json"))["app"]' not in workflow:
        fail(errors, "the pinned Telegram commit version must be verified before patching")
    if not re.search(r"Pillow==\$PILLOW_VERSION", workflow):
        fail(errors, "Pillow must be version-pinned")
    if re.search(r"pip[^\n]*Pillow[^\n]*(?:\|\|\s*true|\|\|\s*pip)", workflow):
        fail(errors, "Pillow installation must fail closed")
    for marker in (
        "--configuration=release_arm64",
        "--outputBuildArtifactsPath $RUNNER_TEMP/artifacts",
        "LIBXRAY_VERSION: v26.7.28",
        "07f7ed7697277930e1c517755855950f594f41435b0dfc5917a66eea6278aeb9",
        "PROXY_HMAC_KEY_HEX: ${{ secrets.PROXY_HMAC_KEY_HEX }}",
    ):
        if marker not in workflow:
            fail(errors, f"release/REALITY workflow invariant is missing {marker}")
    # Every push has to produce a device IPA. A build gated on a mode input, or one that
    # only compiles for the simulator, looks green while shipping nothing installable.
    for marker in ("BUILD_MODE", "debug_sim_arm64"):
        if marker in workflow:
            fail(errors, f"workflow must build a device IPA unconditionally — found {marker}")

    # iCloud must stay OFF. Enabling it bakes com.apple.developer.icloud-* into the app's
    # code signature, and this IPA is re-signed downstream with certificates that carry no
    # iCloud capability. iOS validates entitlements against the profile at launch, so the
    # app installs and then refuses to start — a failure with no crash log in the app and
    # no relation to any feature. Nothing needs the capability: the Files upload path is
    # upstream-stock and reads the picked document through its security-scoped URL, no
    # iCloud container involved.
    for marker in (
        "'com.apple.developer.icloud-services'",
        "'com.apple.developer.icloud-container-identifiers'",
        "'com.apple.developer.ubiquity-kvstore-identifier'",
        "'com.apple.developer.icloud-container-environment'",
        '"enable_icloud": True',
    ):
        if marker in workflow:
            fail(errors, f"workflow must not request iCloud entitlements — found {marker}")

    build_config = json.loads((root / "build-config/appstore-configuration.json").read_text(encoding="utf-8"))
    if build_config.get("enable_icloud") is not False:
        fail(errors, "checked-in build configuration must keep iCloud disabled")
    apply_build_config = (root / "scripts/apply_build_config.py").read_text(encoding="utf-8")
    if '"enable_icloud": False' not in apply_build_config:
        fail(errors, "default build configuration must keep iCloud disabled")

    aorus_build = (root / "patches/submodules/AorusGram/BUILD").read_text(encoding="utf-8")
    for marker in ('name = "LibXraySystemLibraries"', '"libresolv"', '":LibXraySystemLibraries"'):
        if marker not in aorus_build:
            fail(errors, f"LibXray system dependency invariant is missing {marker}")

    # rules_swift dropped sdk_frameworks from swift_library: a stray one fails Bazel
    # analysis in a few seconds, but only after the runner has spent ~40 minutes
    # preparing the tree. Catch it here, in the check that runs first.
    for build_file in sorted((root / "patches").rglob("BUILD")):
        text = build_file.read_text(encoding="utf-8")
        for match in re.finditer(r"swift_library\((.*?)^\)", text, re.DOTALL | re.MULTILINE):
            if re.search(r"^\s*sdk_frameworks\s*=", match.group(1), re.MULTILINE):
                fail(errors, f"{build_file.relative_to(root)}: swift_library does not accept sdk_frameworks")

    if upstream_version is not None:
        spoof_paths = [
            root / "AorusGram/Sources/Core/ClientSpoofManager.swift",
            root / "patches/submodules/AorusGramUI/Sources/Core/ClientSpoofManager.swift",
        ]
        for path in spoof_paths:
            text = path.read_text(encoding="utf-8")
            version = re.search(r'officialAppVersion\s*=\s*"([^"]+)"', text)
            if version is None or version.group(1) != upstream_version:
                fail(errors, f"client spoof version is out of sync in {path.relative_to(root)}")

        branding_text = (root / "scripts/aorus_branding.py").read_text(encoding="utf-8")
        branding_version = re.search(r'official_version\s*=\s*"([^"]+)"', branding_text)
        if branding_version is None or branding_version.group(1) != upstream_version:
            fail(errors, "branding app version is out of sync with Telegram iOS")

    provider = (root / "AorusGram/Sources/Features/Subscription/LicenseKeyProvider.swift").read_text(encoding="utf-8")
    if "withLicenseHmacKey" not in provider or "licenseHmacKeyBytes()" in provider:
        fail(errors, "license HMAC material must be scoped to one operation")
    if "/*__AORUS_LICENSE_KEY_OBFUSCATED__*/" not in provider:
        fail(errors, "license HMAC injection marker is missing")

    proxy = (root / "AorusGram/Sources/Features/Network/AorusProxyManager.swift").read_text(encoding="utf-8")
    if "withRevealedBytes(Obf.k" not in proxy or "Obf.reveal(Obf.k)" in proxy:
        fail(errors, "proxy HMAC material must be scoped to one operation")
    if "/*__AORUS_PROXY_KEY_OBFUSCATED__*/" not in proxy:
        fail(errors, "proxy HMAC injection marker is missing")
    for marker in (
        'forHTTPHeaderField: "X-Aorus-Device-Key"',
        'forHTTPHeaderField: "X-Aorus-Device-Proof"',
        "AorusRealityDeviceIdentity.proof",
        "AorusRealityEnvelopeVerifier.decode",
        "scheduleProvisioningRetry()",
        "guard licenseAllowsReality else",
        'mtprotoUnhealthyKey = "aorusgram_proxy_unhealthy_since"',
        'mtprotoConnectionStateKey = "aorusgram_vless_connection_state"',
        "mtprotoStallThreshold",
        "penalizedEndpoints[endpointKey(activeEndpoint)]",
    ):
        if marker not in proxy:
            fail(errors, f"dynamic REALITY provisioner invariant is missing {marker}")

    retry_start = proxy.find("private func scheduleProvisioningRetry()")
    retry_end = proxy.find("private func buildSignedRequest()", retry_start)
    retry_block = proxy[retry_start:retry_end]
    for marker in (
        "guard licenseAllowsReality else",
        "self.licenseAllowsReality",
        "self.refresh(force: true)",
    ):
        if marker not in retry_block:
            fail(errors, f"VLESS provisioning retry is not license-gated: {marker}")

    signed_guard_start = proxy.find("guard let signedRequest = buildSignedRequest()")
    signed_guard_end = proxy.find("let task = apiSession.dataTask", signed_guard_start)
    signed_guard = proxy[signed_guard_start:signed_guard_end]
    if "handleFetchFailure" not in signed_guard:
        fail(errors, "an unavailable VLESS device signature can permanently strand provisioning")
    if "apiSession" in signed_guard or ".resume()" in signed_guard:
        fail(errors, "VLESS must never send a request before device/build signing succeeds")
    for status in ("http.statusCode == 401", "http.statusCode == 403"):
        if status not in proxy:
            fail(errors, f"VLESS authorization failure must fail closed: {status}")
    if "handleProvisioningRejection(generation:" not in proxy:
        fail(errors, "VLESS authorization rejection recovery is missing")
    if "http.statusCode == 408 || http.statusCode == 429 || (500 ... 599).contains(http.statusCode)" not in proxy:
        fail(errors, "transient VLESS HTTP failures must preserve a still-valid signed profile")
    rejection_start = proxy.find("private func handleProvisioningRejection(")
    rejection_end = proxy.find("private func finish(", rejection_start)
    rejection_block = proxy[rejection_start:rejection_end]
    for marker in (
        "clearProvisioning(stopTunnel: true, cancelProvisioningRetry: false)",
        "if licenseAllowsReality",
        "scheduleProvisioningRetry()",
    ):
        if marker not in rejection_block:
            fail(errors, f"VLESS rejection recovery must stay fail-closed and license-gated: {marker}")
    if "cachedProfile" in rejection_block or "shared.apply" in rejection_block:
        fail(errors, "an authorization-rejected VLESS profile must never be reused")
    for marker in (
        "let endpointPriority: Int",
        "active: $0.endpointPriority == endpoint.priority",
        "guard $0.endpointPriority == endpoint.priority else { return $0 }",
    ):
        if marker not in proxy:
            fail(errors, f"VLESS diagnostics/failover must identify one signed endpoint exactly: {marker}")

    call_proxy = (root / "patches/submodules/TelegramCallsUI/Sources/AorusCallProxy.swift").read_text(encoding="utf-8")
    for marker in (
        'requirementPid = requirement?["pid"] as? NSNumber',
        "requirementPid?.int32Value == currentPid",
        "required?.boolValue == true",
    ):
        if marker not in call_proxy:
            fail(errors, f"call tunnel requirement must be bound to the current process: {marker}")

    web_tunnel = (root / "patches/submodules/WebUI/Sources/AorusWebTunnel.swift").read_text(encoding="utf-8")
    for marker in (
        'let pid = requirement["pid"] as? NSNumber',
        "pid.int32Value == ProcessInfo.processInfo.processIdentifier",
    ):
        if marker not in web_tunnel:
            fail(errors, f"web tunnel requirement must be bound to the current process: {marker}")

    branding = (root / "scripts/aorus_branding.py").read_text(encoding="utf-8")
    for marker in (
        "patch_tgcalls_v2_set_proxy(tg)",
        "patch_tgcalls_reflector_socks5_udp(tg)",
    ):
        if branding.count(marker) != 1:
            fail(errors, f"call transport must apply exactly once: {marker}")
    if "    patch_tgcalls_reflector_socks5(tg)" in branding:
        fail(errors, "legacy reflector TCP SOCKS5 patch is enabled")
    if branding.count("refusing a previously injected source tree") < 2:
        fail(errors, "build injection must reject stale source trees")
    for marker in (
        'dictionary(forKey: \\"71d447f8-9128-4d18-b63c-ec11ef43ba26\\")',
        'dictionary(forKey: \\"b4f013e2-54e9-4e4d-b2e1-30edc1e5b7ca\\")',
        'aorusRequirementPid?.int32Value == aorusCurrentPid',
        'aorusPid.int32Value == aorusCurrentPid',
        'Bundle.main.bundleURL.pathExtension.lowercased() == \\"appex\\"',
        'MTSocksProxySettings(ip: \\"127.0.0.1\\"',
        'port: 38190',
        'aorusgram_vless_connection_state',
        'secret: nil',
        "def patch_unauthorized_system_proxy_runtime_monitor",
        "patch_unauthorized_system_proxy_runtime_monitor(tg)",
        "AorusGram: hot-apply REALITY to the unauthorized login network",
        "private var aorusProxyObserver: NSObjectProtocol?",
        "private var aorusConnectionStatusDisposable: Disposable?",
        'aorusgram_vless_unauthorized_connection_state',
        '\\"since\\": aorusStateSince',
        "NotificationCenter.default.removeObserver(aorusProxyObserver)",
        "self.aorusConnectionStatusDisposable?.dispose()",
        "AorusGram: publish the exact authorized-context transition",
        "AorusRealityManager.shared.ensureRunning()",
    ):
        if marker not in branding:
            fail(errors, f"REALITY loopback bridge invariant is missing {marker}")
    if "for aorusDelay in [2.0, 5.0, 12.0, 30.0]" in branding:
        fail(errors, "authorized-account VLESS handoff must not depend on launch timers")
    if 'anchor = "            self.contextValue = context\\n"' not in branding or "t.replace(anchor, anchor + hook, 1)" not in branding:
        fail(errors, "authorized-account VLESS handoff must run after contextValue assignment")
    for forbidden in (
        "aorusSecret.insert(0xdd, at: 0)",
        "aorusIsPadded",
    ):
        if forbidden in branding:
            fail(errors, f"legacy dd proxy downgrade remains in branding: {forbidden}")

    reality_profile_path = root / "AorusGram/Sources/Features/Network/AorusRealityProfile.swift"
    reality_manager_path = root / "AorusGram/Sources/Features/Network/AorusRealityManager.swift"
    reality_proxy_path = root / "AorusGram/Sources/Features/Network/AorusProxyManager.swift"
    if not reality_profile_path.is_file() or not reality_manager_path.is_file() or not reality_proxy_path.is_file():
        fail(errors, "embedded REALITY sources are missing")
    else:
        reality_profile = reality_profile_path.read_text(encoding="utf-8")
        reality_manager = reality_manager_path.read_text(encoding="utf-8")
        reality_proxy = reality_proxy_path.read_text(encoding="utf-8")
        for marker in (
            "AorusRealityEnvelopeVerifier",
            "Curve25519.Signing.PublicKey",
            "AorusRealityDeviceIdentity",
            "ecdsaSignatureMessageX962SHA256",
            "envelope.requestNonce",
        ):
            if marker not in reality_profile:
                fail(errors, f"REALITY profile invariant is missing {marker}")
        for marker in (
            "import LibXray",
            '"runXrayFromJson"',
            '"packetEncoding": "xudp"',
            '"security": "reality"',
            '"127.0.0.1"',
            "publishRequirement(required: AorusHybridRoute.shared.tunnelIsRequired)",
            '"required": required',
            "AorusSessionMetrics.metricFlag",
            "isReadyForAuthorizedTraffic",
            "waitForCoreAndLocalSocks(",
            "localSocksIsReady(port:",
            "realityPreflight(port:",
            "nextRanked.contains(activeEndpoint)",
            "telegramPreflightTargets",
            "reality_preflight_ready",
            "reality_preflight_failed",
            "local_socks_connect_timeout",
            "local_socks_negotiation_timeout",
            "reality_connect_timeout",
            "var isRemotePathFailure: Bool",
            "case .tunnelConnectFailed, .tunnelConnectTimedOut:",
            "socksConnectRequest(host:",
            "aorusgram_reality_bootstrap_trace",
            "AorusParallelProbeResults",
            "DispatchQueue.global(qos: .userInitiated).async",
            "results.snapshot().values.contains(.ready)",
            "profileDidVerify()",
            "recordEndpointProbe(priority:",
            "bridge_tcp_reachable",
            "profile_applied",
            "realityEndpointDidFail(endpoint)",
            "rankedEndpoints.remove(at: index)",
            "rankedEndpoints.append(endpoint)",
            "rankedEndpoints = [endpoint] + rankedEndpoints.filter",
            "Data([0x05, 0x01, 0x00])",
            "Data([0x05, 0x00])",
            "waitForCoreStop()",
            "restartRetryDelays",
            "scheduleRestartRetryLocked()",
            "cancelRestartRetryLocked(resetAttempt: true)",
            "let endpointOrder = rankedEndpoints.isEmpty ? profile.validEndpoints : rankedEndpoints",
            "let activeEndpoint = self.activeEndpoint",
            "nextRanked.contains(activeEndpoint)",
            "previousCredential == profile.credential",
        ):
            if marker not in reality_manager:
                fail(errors, f"REALITY manager invariant is missing {marker}")
        keep_start = reality_manager.find("if previousCredential == profile.credential")
        keep_end = reality_manager.find("self.recordDiagnostic(stage: \"profile_applied\")", keep_start)
        keep_block = reality_manager[keep_start:keep_end]
        if "let preflight = self.realityPreflight(" not in keep_block or "canKeepRunning = preflight == .ready" not in keep_block:
            fail(errors, "REALITY must retain the active ranked endpoint only after a fresh full preflight")
        for marker in (
            "AorusRealityManager.shared.profileDidVerify()",
            "AorusRealityManager.shared.recordEndpointProbe(",
            "func realityEndpointDidFail(_ endpoint:",
            "penalizedEndpoints[endpointKey(endpoint)]",
        ):
            if marker not in reality_proxy:
                fail(errors, f"REALITY provisioner trace invariant is missing {marker}")
        preflight_index = reality_manager.find("let preflight = realityPreflight(")
        publish_index = reality_manager.find("publishEndpoint(port: localPort)", preflight_index)
        if preflight_index < 0 or publish_index < 0 or publish_index < preflight_index:
            fail(errors, "REALITY endpoint can be published before the full tunnel preflight")
        if 'normalizedAddress != "0.0.0.0"' not in reality_profile:
            fail(errors, "REALITY endpoint validation accepts an unspecified address")
        for forbidden in ("104.143.218.253", "7c2fb9b6-fcb9-4715-8752-49f6534e3017"):
            if forbidden in reality_profile or forbidden in reality_manager:
                fail(errors, "test REALITY credentials must not be committed")
        for forbidden in (
            "AorusRealityProfileProvider",
            "__AORUS_REALITY_PROFILE_CIPHERTEXT__",
            "__AORUS_REALITY_PROFILE_MASK__",
        ):
            if forbidden in reality_profile or forbidden in reality_manager:
                fail(errors, f"static REALITY profile path remains: {forbidden}")

        # The hybrid route decides whether Telegram is redirected at all. Its whole point is
        # that `required` is true only while a proven local inbound exists: every other state
        # leaves the client on the route it already had instead of on a closed loopback port.
        hybrid_route_path = root / "AorusGram/Sources/Features/Network/AorusHybridRoute.swift"
        preferences_path = root / "AorusGram/Sources/Features/Network/AorusConnectionPreferences.swift"
        if not hybrid_route_path.is_file() or not preferences_path.is_file():
            fail(errors, "hybrid route sources are missing")
        else:
            hybrid_route = hybrid_route_path.read_text(encoding="utf-8")
            preferences = preferences_path.read_text(encoding="utf-8")
            for marker in (
                "return self.mode == .tunnel",
                "AorusRealityManager.shared.standDownForDirectRoute()",
                "AorusProxyManager.shared.beginTunnelEscalation(reason: reason)",
                "guard AorusRealityManager.shared.tunnelIsAuthorized else {",
                "requiredDirectSuccesses = 2",
                "directHoldInterval",
                "directUnreliableUntil",
                "AorusConnectionPreferences.shared.bypassEnabled",
            ):
                if marker not in hybrid_route:
                    fail(errors, f"hybrid route invariant is missing {marker}")
            for marker in (
                "private func publishTunnelRequirement()",
                "AorusHybridRoute.shared.tunnelDidActivate()",
                "AorusHybridRoute.shared.tunnelDidExhaustEndpoints()",
                "AorusHybridRoute.shared.tunnelDidStandDown()",
                "AorusConnectionPreferences.shared.bypassEnabled",
            ):
                if marker not in reality_manager:
                    fail(errors, f"tunnel requirement is not route-derived: {marker}")
            if "publishRequirement(required: true)" in reality_manager:
                fail(errors, "the tunnel requirement must never be published unconditionally")
            activate_index = reality_manager.find("AorusHybridRoute.shared.tunnelDidActivate()")
            port_index = reality_manager.find('"port": port,')
            if port_index < 0 or activate_index < port_index:
                fail(errors, "the tunnel requirement can be taken before the live port is published")
            for marker in (
                "AorusHybridRoute.shared.networkDidChange()",
                "AorusHybridRoute.shared.directRouteDidStall()",
                "AorusHybridRoute.shared.allowsTunnelBringUp",
                "AorusConnectionPreferences.shared.bypassEnabled",
            ):
                if marker not in reality_proxy:
                    fail(errors, f"route escalation invariant is missing {marker}")
            # The switches are the user's, stored locally, and reachable by nothing remote.
            for marker in (
                "kSecClassGenericPassword",
                "kSecAttrAccessibleAfterFirstUnlock",
                "aorusgram_connection_bypass_enabled",
                "aorusgram_connection_stable_calls_enabled",
            ):
                if marker not in preferences:
                    fail(errors, f"connection preferences invariant is missing {marker}")
            for forbidden in ("URLSession", "URLRequest", "https://"):
                if forbidden in preferences:
                    fail(errors, f"connection preferences must not be remotely settable: {forbidden}")
            for marker in (
                'aorusConnectionSwitchIsOff(store: store, key: "aorusgram_connection_bypass_enabled")',
                'aorusConnectionSwitchIsOff(store: store, key: "aorusgram_connection_stable_calls_enabled")',
                'guard store.object(forKey: key) != nil else { return false }',
            ):
                if marker not in call_proxy:
                    fail(errors, f"call transport must honour the connection switches: {marker}")
            if 'aorusStore.object(forKey: \\"aorusgram_connection_bypass_enabled\\") != nil' not in branding:
                fail(errors, "the MTProto override must honour the bypass switch")

    atunnel_status_path = root / "patches/submodules/AorusGramUI/Sources/ATunnelStatusViewController.swift"
    atunnel_status = atunnel_status_path.read_text(encoding="utf-8")
    for marker in (
        "processBoundTunnelState()",
        'UserDefaults(suiteName: "ng.session.store")',
        'requirement?["pid"] as? NSNumber',
        "requirementPID == currentPID",
        'requirement?["required"] as? NSNumber',
        'endpoint?["pid"] as? NSNumber',
        "endpointPID == currentPID",
        "currentTunnelBlocked()",
    ):
        if marker not in atunnel_status:
            fail(errors, f"ATunnel process-bound diagnostic invariant is missing {marker}")

    connection_status_path = root / "patches/submodules/ChatListUI/Sources/AorusConnectionStatus.swift"
    connection_status = connection_status_path.read_text(encoding="utf-8")
    for marker in (
        'let pid = requirement["pid"] as? NSNumber',
        "pid.int32Value == ProcessInfo.processInfo.processIdentifier",
    ):
        if marker not in connection_status:
            fail(errors, f"connection title process binding is missing {marker}")

    license_gate_path = root / "AorusGram/Sources/Features/Subscription/LicenseGate.swift"
    if not license_gate_path.is_file():
        fail(errors, "license gate source is missing")
    else:
        license_gate = license_gate_path.read_text(encoding="utf-8")
        for marker in (
            "setFeatureAccess(active: initialStatus.allowsAppAccess)",
            "upgradeSystemProxy()",
            "AorusRealityManager.shared.startIfAuthorized()",
        ):
            if marker not in license_gate:
                fail(errors, f"cold-login VLESS bootstrap invariant is missing {marker}")
        if "unlockAfterTunnelReady" in license_gate:
            fail(errors, "cold login must not restore the redundant VLESS loading overlay")

    settings_controller = (root / "patches/submodules/AorusGramUI/Sources/AorusGramController.swift").read_text(encoding="utf-8")
    if "vlessStatus" in settings_controller or "_aorusPresentVLESSStatus" in settings_controller:
        fail(errors, "the removed VLESS settings item must not be restored")

    aorus_build = (root / "patches/submodules/AorusGram/BUILD").read_text(encoding="utf-8")
    for marker in ("apple_static_xcframework_import", 'name = "LibXray"', '":LibXray"'):
        if marker not in aorus_build:
            fail(errors, f"libXray Bazel invariant is missing {marker}")

    store = (root / "AorusGram/Sources/Features/Subscription/LicenseStore.swift").read_text(encoding="utf-8")
    offline_block = store[store.find("func effectiveOfflineStatus"):store.find("func needsRecheck")]
    missing_timing_guard = re.search(
        r"guard let until = snap\.activeUntil, let now = estimatedServerNow\(snap\) else \{\s*return \.expired",
        offline_block,
    )
    if missing_timing_guard is None:
        fail(errors, "active offline licenses with missing timing data must fail closed")

    env_guard = (root / "AorusGram/Sources/Features/Subscription/AorusEnvGuard.swift").read_text(encoding="utf-8")
    if "selfDestruct" in env_guard or "abort()" in env_guard:
        fail(errors, "environment checks must deny access instead of crashing")

    # The license-lock gate key must not ship as a readable literal: `strings | grep
    # license` used to map every feature gate at once. It is now an opaque UUID, written by
    # one place and read everywhere under the same value. This is self-checking — a missed
    # site would leave the plaintext token behind and fail here, in CI, not leak in prod.
    LOCK_KEY_OPAQUE = "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04"
    import subprocess as _sp
    shipped = _sp.run(
        ["grep", "-rl", "aorusgram_license_locked", "--include=*.swift", "AorusGram", "patches"],
        cwd=str(root), capture_output=True, text=True,
    ).stdout.strip()
    if shipped:
        fail(errors, f"license-lock key still ships as a plaintext literal in: {shipped.replace(chr(10), ', ')}")
    branding = (root / "scripts/aorus_branding.py").read_text(encoding="utf-8")
    if "aorusgram_license_locked" in branding:
        fail(errors, "aorus_branding.py still injects the plaintext license-lock key")
    profile_patch = (root / "scripts/profile_personalization_patch.py").read_text(encoding="utf-8")
    if "aorusgram_license_locked" in profile_patch:
        fail(errors, "profile_personalization_patch.py still injects the plaintext license-lock key")
    if LOCK_KEY_OPAQUE not in profile_patch:
        fail(errors, "profile_personalization_patch.py does not use the opaque license-lock key")
    # The single writer and the two crown-jewel gates must use the opaque value.
    gate_files = [
        "AorusGram/Sources/Features/Subscription/LicenseGate.swift",
        "AorusGram/Sources/Features/Network/AorusProxyManager.swift",
        "AorusGram/Sources/Features/Network/AorusRealityManager.swift",
    ]
    for gf in gate_files:
        if LOCK_KEY_OPAQUE not in (root / gf).read_text(encoding="utf-8"):
            fail(errors, f"{gf} does not use the opaque license-lock key")
    # The paid resource must not rest on the client bool alone: both proxy gates re-derive
    # the HMAC-signed, device-bound snapshot, which a client-side patch cannot forge.
    for gf in gate_files[1:]:
        if "effectiveOfflineStatus().allowsAppAccess" not in (root / gf).read_text(encoding="utf-8"):
            fail(errors, f"{gf} no longer re-derives the signed license snapshot")

    # AorusEnvGuard is the detector on the license/proxy path, so its indicators must not
    # ship as readable literals either. It is generated and obfuscated; pin that, and keep
    # the API and server-contract surface intact.
    env_guard = (root / "AorusGram/Sources/Features/Subscription/AorusEnvGuard.swift").read_text(encoding="utf-8")
    if "GENERATED by scripts/gen_env_guard.py" not in env_guard:
        fail(errors, "AorusEnvGuard is not the generated, obfuscated file — run gen_env_guard.py")
    env_code = "\n".join(l for l in env_guard.splitlines() if not l.lstrip().startswith("//"))
    for leak in ("Cydia", "Sileo", "MobileSubstrate", "frida", "substrate", "DYLD_INSERT",
                 "jailbroken", "hasSuspiciousPaths", "hasJailbreakSymlinks", "isDebuggerAttached"):
        if leak in env_code:
            fail(errors, f"AorusEnvGuard leaks '{leak}' outside comments")
    for keep in ("func enforceBeforeRequest()", "func enforceAtGate()", "func flags()",
                 "func denyDebuggerAttach()", '"jb"', '"hook"', '"dbg"'):
        if keep not in env_guard:
            fail(errors, f"AorusEnvGuard lost required API/contract token {keep}")

    ui_bootstrap = (root / "patches/submodules/AorusGramUI/Sources/Core/AorusGramBootstrap.swift").read_text(
        encoding="utf-8"
    )
    if 'removeObject(forKey: "c0a8b1e2-6f4d-4a9c-b3e7-1d520f8a6b34")' in ui_bootstrap:
        fail(errors, "UI bootstrap must not clear persistent tamper evidence")
    accumulator = (root / "AorusGram/Sources/Security/AorusTamperAccumulator.swift").read_text(encoding="utf-8")
    if "resetForCleanLaunch" in accumulator:
        fail(errors, "tamper evidence must not expose a launch-reset path")

    backup_paths = [
        root / "AorusGram/Sources/Features/Accounts/AccountBackupManager.swift",
        root / "patches/submodules/AorusGramUI/Sources/Features/Accounts/AccountBackupManager.swift",
    ]
    for path in backup_paths:
        text = path.read_text(encoding="utf-8")
        if "kSecAttrAccessibleAfterFirstUnlock\n" in text:
            fail(errors, f"migratable backup Keychain item remains in {path.relative_to(root)}")
        required = (
            "maxEncryptedEntrySize",
            "maxEncryptedArchiveSize",
            "maxArchiveEntryCount",
            "reachedEndMarker",
            "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
        )
        for marker in required:
            if marker not in text:
                fail(errors, f"backup hardening marker {marker} missing in {path.relative_to(root)}")
    if backup_paths[0].read_bytes() != backup_paths[1].read_bytes():
        fail(errors, "core and UI backup managers must remain byte-identical")

    forbidden_suffixes = {".p12", ".pfx", ".mobileprovision"}
    ignored = git_ignored(root)
    for path in root.rglob("*"):
        if ".git" in path.parts or not path.is_file():
            continue
        if path.resolve() == Path(__file__).resolve():
            continue
        # Only what git would actually carry: a gitignored file is in the working copy by
        # intent (the push token lives there) and cannot reach a commit, so scanning it
        # reports a leak that does not exist and hides the ones that do.
        if path.relative_to(root).as_posix() in ignored:
            continue
        if path.suffix.lower() in forbidden_suffixes:
            fail(errors, f"private signing material is tracked: {path.relative_to(root)}")
        if path.stat().st_size <= 2 * 1024 * 1024:
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if "-----BEGIN PRIVATE KEY-----" in text or "-----BEGIN RSA PRIVATE KEY-----" in text:
                fail(errors, f"private key material is tracked: {path.relative_to(root)}")
            if re.search(r"\bghp_[A-Za-z0-9]{30,}\b", text):
                fail(errors, f"GitHub token is tracked: {path.relative_to(root)}")

    # The AorusAI artifact flow. Its logic is covered by the swiftc preflight tests, but
    # three invariants live in code the tests cannot reach: the signature of a bodyless
    # method must be taken over empty bytes, the client must never hold a vault token,
    # and a file must open in the native preview rather than in Safari.
    ai_client = (root / "AorusGram/Sources/Features/AI/AorusAIClient.swift").read_text(encoding="utf-8")
    if 'if method != "GET" && method != "HEAD" { request.httpBody = body }' not in ai_client:
        fail(errors, "artifact GET/HEAD must be signed over an empty body")
    if "AorusAIArtifactFlow.decode(object)" not in ai_client:
        fail(errors, "artifact.ready must be decoded through AorusAIArtifactFlow")
    if "AorusAIArtifactFlow.signingPath(for: artifact)" not in ai_client:
        fail(errors, "artifact downloads must use the sanitized signing path")
    for marker in ("vaultToken", "vault_token", "?token=", "&token="):
        if marker in ai_client:
            fail(errors, f"AorusAI client must not deal in vault tokens — found {marker}")

    ai_models = (root / "AorusGram/Sources/Features/AI/AorusAIModels.swift").read_text(encoding="utf-8")
    if "public var artifacts: [AorusAIArtifact]" not in ai_models:
        fail(errors, "an assistant message must carry a list of artifacts, not one optional")
    for marker in ("public var downloadExpiresAt: Int64?", "public var expiresAt: Int64?", "public var downloadPath: String"):
        if marker not in ai_models:
            fail(errors, f"persisted artifact metadata is missing {marker}")
    if "vaultToken" in ai_models:
        fail(errors, "the artifact model must have no token field")

    ai_flow = root / "AorusGram/Sources/Features/AI/AorusAIArtifactFlow.swift"
    if not ai_flow.is_file():
        fail(errors, "AorusAIArtifactFlow.swift is missing")
    ai_tests = root / "scripts/tests/AorusAIArtifactFlowTests.swift"
    if not ai_tests.is_file():
        fail(errors, "AorusAIArtifactFlowTests.swift is missing")
    workflow_text = (root / ".github/workflows/build-aorusgram.yml").read_text(encoding="utf-8")
    if "AorusAIArtifactFlowTests.swift" not in workflow_text:
        fail(errors, "the artifact flow tests are not wired into the preflight")

    ai_controllers = (root / "patches/submodules/AorusGramUI/Sources/Features/AI/AorusAIControllers.swift").read_text(encoding="utf-8")
    if "QLPreviewController" not in ai_controllers:
        fail(errors, "a downloaded artifact must open in Quick Look")
    if re.search(r"UIApplication\.shared\.open\(", ai_controllers):
        fail(errors, "an artifact must never be handed to Safari")
    if "case let .artifactReady(artifact)" not in ai_controllers:
        fail(errors, "artifact.ready must have its own branch in the event dispatcher")

    # A mention has to reach the model as resolved facts, and only through the clamped
    # value type — never as a raw peer dump assembled in the view layer.
    if "resolveProfileContext(usernames:" not in ai_controllers:
        fail(errors, "mentioned profiles must be resolved before the request is sent")
    if "transportBlock(labels: labels)" not in ai_controllers:
        fail(errors, "profile context must travel through AorusAIProfileSummary.transportBlock")
    if "timeout(2.5, queue: Queue.mainQueue()" not in ai_controllers:
        fail(errors, "the profile lookup must have a ceiling so a turn can never hang on it")
    for marker in ("phoneNumber", "peer.phone"):
        if marker in ai_controllers:
            fail(errors, f"a phone number must never be transported — found {marker}")

    # The integrator writes a versioned sentinel and the verifier demands one. When the
    # two drift the build dies six minutes in, after the clone — so they are compared
    # here, where it costs nothing.
    integrator_text = (root / "scripts/aorus_ai_integration.py").read_text(encoding="utf-8")
    verifier_text = (root / "scripts/verify_aorus_branding.py").read_text(encoding="utf-8")
    sentinels = re.findall(r'"(// AorusGram: AorusAI message action v\d+)"', integrator_text)
    current = [s for s in sentinels if f'sentinel = "{s}"' in integrator_text]
    if len(current) != 1:
        fail(errors, "AorusAI integrator must declare exactly one current menu sentinel")
    else:
        if f'"{current[0]}" not in ai_menu_text' not in verifier_text:
            fail(errors, f"verify_aorus_branding.py does not require the current sentinel ({current[0]})")
        for legacy in sentinels:
            if legacy == current[0]:
                continue
            if legacy.rsplit(" ", 1)[-1] not in verifier_text:
                fail(errors, f"verify_aorus_branding.py does not reject the legacy sentinel ({legacy})")

    # Every AorusAI request carries the prompt and, once approved, a slice of a real
    # conversation. It is the most sensitive payload this client sends anywhere and may
    # never fall back to system trust.
    subscription_config = (root / "AorusGram/Sources/Features/Subscription/SubscriptionConfig.swift").read_text(encoding="utf-8")
    if '"ai.aorusgram.com": aiAPISPKIPins' not in subscription_config:
        fail(errors, "AorusAI: ai.aorusgram.com is not SPKI-pinned")

    # A link the model wrote shows where it goes before it is opened: markdown lets the
    # visible words differ from the address, and these words are not written by a person.
    if "private func presentExternalLink(" not in ai_controllers:
        fail(errors, "AorusAI: an external link must show its destination before opening")
    if 'scheme == "http" || scheme == "https"' not in ai_controllers:
        fail(errors, "AorusAI: only http(s) links may be opened")

    # Consent. The words that decide what is being agreed to are the client's, and the
    # silent profile lookup is limited to handles the conversation actually names.
    if "AorusAIShareScopeController(" not in ai_controllers:
        fail(errors, "AorusAI: the chat-history consent must be the client's own sheet")
    if "AorusAIChatDefaults.optionTitle(option)" not in ai_controllers:
        fail(errors, "AorusAI: consent choices must state what they share, not the server's label")
    if "static func optionTitle(" not in ai_controllers:
        fail(errors, "AorusAI: the client-authoritative choice title is missing")
    if "option.limit ?? historyLimit" not in ai_controllers:
        fail(errors, "AorusAI: a consent choice must name the same default the executor uses")
    if "limit ?? AorusAIChatDefaults.historyLimit" not in ai_controllers:
        fail(errors, "AorusAI: the history executor must use the documented default limit")
    if "AorusAIChatDefaults.messageCount(for: option)" not in ai_controllers:
        fail(errors, "AorusAI: the drawn count and the shared count must come from one place")
    if "request.requiresUserApproval || !conversationMentions(request.username)" not in ai_controllers:
        fail(errors, "AorusAI: a silent profile lookup must be limited to handles the conversation names")
    if "private func conversationMentions(" not in ai_controllers:
        fail(errors, "AorusAI: the mentioned-handle check is missing")

    # Mentions. The pill is a drawing; the transport is still the handles that were typed.
    ai_mention_model_path = root / "AorusGram/Sources/Features/AI/AorusAIMentionModel.swift"
    ai_mention_path = root / "patches/submodules/AorusGramUI/Sources/Features/AI/AorusAIMention.swift"
    if not ai_mention_model_path.is_file() or not ai_mention_path.is_file():
        fail(errors, "AorusAI: the inline mention sources are missing")
    else:
        ai_mention_model = ai_mention_model_path.read_text(encoding="utf-8")
        if "textView.attributedText?.aorusAIPlainText" not in ai_controllers:
            fail(errors, "AorusAI: the composer must send the source handles, not the rendered pills")
        if "public var aorusAIPlainText: String" not in ai_mention_model:
            fail(errors, "AorusAI: the pill-to-source reconstruction is missing")
        if "removingResolvedEntitySources" in ai_controllers:
            fail(errors, "AorusAI: a resolved handle must stay in the text, not be cut out of it")
        if "override func isEqual" in ai_mention_model:
            fail(errors, "AorusAI: mention boxes must compare by identity, or two adjacent pills merge into one")
        mention_tests = root / "scripts/tests/AorusAIMentionTests.swift"
        if not mention_tests.is_file():
            fail(errors, "AorusAI: the mention tests are missing")
        elif "AorusAIMentionTests.swift" not in workflow_text:
            fail(errors, "AorusAI: the mention tests are not wired into the preflight")

    # Ceilings on everything the server drives.
    ai_parser = (root / "AorusGram/Sources/Features/AI/AorusAISSEParser.swift").read_text(encoding="utf-8")
    for marker in ("static let maximumLineBytes", "static let maximumEventBytes"):
        if marker not in ai_parser:
            fail(errors, f"AorusAI: the SSE parser has no ceiling — {marker} is missing")
    for marker in ("static let responseCharacters", "static let responseArtifactCount"):
        if marker not in ai_models:
            fail(errors, f"AorusAI: a streamed answer has no ceiling — {marker} is missing")
    if "AorusAIRequestLimits.responseCharacters" not in ai_controllers:
        fail(errors, "AorusAI: the streamed answer ceiling is declared but never applied")
    sse_tests = root / "scripts/tests/AorusAISSEParserTests.swift"
    if sse_tests.is_file():
        sse_body = sse_tests.read_text(encoding="utf-8")
        for name in ("overlongLineIsDiscardedAndStreamRecovers", "overlongEventIsDroppedWholeAndStreamRecovers"):
            if sse_body.count(name) < 2:
                fail(errors, f"AorusAI: {name} is defined but never run")

    # The patch pipeline is 23k lines and main() is a flat list of ~150 calls, so a function
    # deleted or renamed without updating the call is a NameError that only surfaces ninety
    # seconds into the build — after the clone. py_compile does not catch it. Resolve every
    # call main() makes against the module's own definitions here instead: this runs first
    # and takes a second.
    branding = root / "scripts" / "aorus_branding.py"
    if branding.is_file():
        try:
            tree = ast.parse(branding.read_text(encoding="utf-8"))
        except SyntaxError as error:
            fail(errors, f"aorus_branding.py does not parse: {error}")
        else:
            defined = {
                node.name
                for node in tree.body
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            }
            defined |= {
                target.id
                for node in tree.body
                if isinstance(node, ast.Assign)
                for target in node.targets
                if isinstance(target, ast.Name)
            }
            # Several patches live in sibling modules and arrive through `from ... import`.
            for node in ast.walk(tree):
                if isinstance(node, (ast.Import, ast.ImportFrom)):
                    defined |= {alias.asname or alias.name.split(".")[0] for alias in node.names}
            main_def = next(
                (
                    node
                    for node in tree.body
                    if isinstance(node, ast.FunctionDef) and node.name == "main"
                ),
                None,
            )
            if main_def is None:
                fail(errors, "aorus_branding.py has no main()")
            else:
                for node in ast.walk(main_def):
                    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
                        continue
                    name = node.func.id
                    if not name.startswith(("patch_", "_add_", "_ensure_", "write_", "apply_")):
                        continue
                    if name not in defined:
                        fail(errors, f"aorus_branding.py main() calls {name}(), which is not defined")

    check_mirrored_sources(root, errors)

    if errors:
        print("Release security check failed:")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("Release security check: OK")
    return 0


# Files that exist under both `AorusGram/Sources` (the core module) and
# `patches/submodules/AorusGramUI/Sources` (the UI module) and are *allowed* to differ,
# each with the reason. Everything else with a shared filename has to stay identical.
#
# Two modules carrying a type of the same name is deliberate: AppDelegate imports only the
# core module, because importing both makes a reference like `AorusGramBootstrap.shared`
# ambiguous. The consequence is that for a mirrored type, the core copy is the one that
# runs — and a change made only to the UI copy is a change to code nothing calls.
#
# That is not hypothetical. Anti-spam's "never auto-block a peer the user un-blocked by
# hand" was written into the UI copy alone; the decision is taken in `processIncoming`,
# which the core bootstrap calls, so the feature did nothing while both copies wrote the
# same UserDefaults keys over each other. This check exists so the next one is caught here
# instead of in a bug report.
_MIRROR_DIVERGENCE_ALLOWED = {
    "AorusGramConfig.swift": "core is public for TelegramUI to read; the UI copy is internal",
    "AorusTamperGuard.swift": "AorusSessionCounter is core-only, so the UI copy reports through the mirrored flag",
    "VoiceTranscriberView.swift": "each module localises through its own table (SubL10n / aorusL)",
    "AorusGramBootstrap.swift": "different entry points: the core one runs at launch, before the account stack",
    "AorusPerformanceHUDManager.swift": "two implementations, not one drifted: the UI copy is written against AorusGramManager/AorusL10n",
    "AntiSpoofManager.swift": "status separator differs per module (• / -)",
}


def check_mirrored_sources(root: Path, errors: list[str]) -> None:
    """A file that exists in both modules must be identical, or listed above with a reason."""
    core_root = root / "AorusGram/Sources"
    ui_root = root / "patches/submodules/AorusGramUI/Sources"
    if not core_root.is_dir() or not ui_root.is_dir():
        return
    core = {p.name: p for p in core_root.rglob("*.swift")}
    ui = {p.name: p for p in ui_root.rglob("*.swift")}
    for name in sorted(set(core) & set(ui)):
        if core[name].read_bytes() == ui[name].read_bytes():
            if name in _MIRROR_DIVERGENCE_ALLOWED:
                fail(
                    errors,
                    f"{name} is listed as an allowed mirror divergence but the two copies are "
                    f"now identical — drop it from _MIRROR_DIVERGENCE_ALLOWED",
                )
            continue
        if name in _MIRROR_DIVERGENCE_ALLOWED:
            continue
        fail(
            errors,
            f"{name} differs between AorusGram/Sources and AorusGramUI/Sources. Only the core "
            f"copy runs, so a change to the UI copy alone does nothing. Sync them, or add the "
            f"file to _MIRROR_DIVERGENCE_ALLOWED with the reason.",
        )


if __name__ == "__main__":
    raise SystemExit(main())
