import Foundation
import UIKit

// Root-level subscription gate.
//
// ENFORCEMENT MODEL:
//  - Production CI requires a provisioned key. A malformed local build fails closed
//    for protected features instead of silently becoming an unlocked client.
//  - The SERVER is the source of truth. The user reaches the chat list only on an
//    active verdict (trial_active / paid_active).
//  - Offline grace (per spec §12): a cached active license whose active_until has not
//    passed is honoured while offline. Cached-expired → locked. No usable cache and
//    no network → a connection-error lock screen (NOT free access).
//
// LOCK MECHANISM (root-swap-equivalent): a dedicated opaque UIWindow above
// everything. While visible it covers and intercepts all input, so nothing behind it
// (chat list, search, deeplink target, back/swipe) is reachable.
final class LicenseGate {
    static let shared = LicenseGate()
    private init() {}

    private enum LockKind { case none, loading, trial, expired, banned, outdated, connection }

    private var started = false
    private var lockWindow: UIWindow?
    private var modalWindow: UIWindow?
    private var lockKind: LockKind = .none
    private var telegramUserId: Int64?
    private var bannerShownThisLaunch = false
    private var inFlight = false
    /// Which round of licence traffic is current.
    ///
    /// `inFlight` only stopped a second `refresh()`; it did nothing about the five other
    /// places that write a verdict. A `/check` that left before an activation and arrived
    /// after it was a correctly signed answer to its own older question — and it put the
    /// pre-activation `expired` back, locking a user who had just paid. Every write now
    /// carries the generation it was asked in, and anything from an older one is dropped.
    /// Activation, bootstrap and a change of account all move the generation on.
    private static var licenseGeneration: UInt64 = 0
    /// Starts a new round and returns its number.
    static func beginLicenseGeneration() -> UInt64 {
        licenseGeneration &+= 1
        return licenseGeneration
    }
    /// Whether a verdict asked for in `generation` is still the current answer.
    static func licenseGenerationIsCurrent(_ generation: UInt64) -> Bool {
        return generation == licenseGeneration
    }
    private var lockSweepTimer: Timer?
    /// Fires at the second the current licence stops being valid. See `armExpiryTimer`.
    private var expiryTimer: Timer?
    // When the lock is temporarily hidden so the user can reach the bot to buy, this
    // forces a re-check (and re-lock if still not active) on the next foreground.
    private var pendingRelock = false

    // Binding hook: called once the Telegram account id is known (published from
    // AppDelegate after login). De-duped so a re-publish of the same id never
    // triggers a redundant /license/check.
    func setTelegramUserId(_ id: Int64?) {
        guard let id = id, id != 0 else { return }
        guard id != telegramUserId else { return }
        telegramUserId = id
        // Persist so check/bootstrap/activate keep sending the real id across launches.
        LicenseStore.shared.setTelegramUserId(id)
        if started { refresh() }
    }

    // Entry point — called once from AorusGramBootstrap.setup().
    func start() {
        guard !started else { return }
        started = true
        guard LicenseKeyProvider.isProvisioned, AorusBuildKeyProvider.isProvisioned else {
            setFeatureAccess(active: false)
            DispatchQueue.main.async { [weak self] in self?.showConnection() }
            return
        }
        guard AorusEnvGuard.enforceAtGate() else {
            setFeatureAccess(active: false)
            DispatchQueue.main.async { [weak self] in self?.showConnection() }
            return
        }
        LicenseStore.shared.load()
        if telegramUserId == nil { telegramUserId = LicenseStore.shared.telegramUserId }
        let initialStatus = LicenseStore.shared.effectiveOfflineStatus()
        setFeatureAccess(active: initialStatus.allowsAppAccess)

        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

        // Any signed License endpoint may revoke this build, including activation.
        // Centralizing the transition prevents one UI flow from overlooking 426.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.clientOutdated"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let response = note.userInfo?["response"] as? LicenseResponse,
                  response.status == .clientOutdated else { return }
            _ = Self.beginLicenseGeneration()
            LicenseStore.shared.save(response: response, telegramUserId: self.telegramUserId)
            self.showOutdated()
        }

        // Key activation deep link (aorusgram://activate?key=…), routed from AppDelegate.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.activateKeyDeepLink"), object: nil, queue: .main
        ) { [weak self] note in
            if let key = note.userInfo?["key"] as? String, !key.isEmpty {
                self?.presentActivateConfirm(key: key)
            }
        }

        // "Subscription" button in AorusGram settings opens the management screen.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("aorusgram.openSubscriptionManagement"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.presentPurchaseModally()
        }

        // Defer so the app's scene/window exists before we draw the overlay.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let cached = initialStatus
            if cached.allowsAppAccess {
                // Valid offline grace — let the app through; confirm with the server.
            } else if cached.isLocked {
                if cached == .clientOutdated {
                    self.showOutdated()
                } else {
                    self.showExpired(banned: cached == .banned)
                }
            } else {
                // Unknown / not_started — cover with a splash until the first verdict.
                self.showLoading()
            }
            self.refresh()
        }
    }

    @objc private func didBecomeActive() {
        guard started else { return }
        // The licence can simply have run out while the app was away, and asking the
        // network is throttled to once every half hour. Nothing checked the date itself,
        // so a subscription that expired twenty minutes ago left the client open with
        // every paid feature on until something else happened to move the gate.
        enforceLocalExpiry()
        // pendingRelock: the lock was lifted so the user could reach the bot — always
        // re-verify now (ignores the throttle) so access is re-locked if still expired.
        if pendingRelock || lockWindow != nil
            || LicenseStore.shared.needsRecheck(interval: SubscriptionConfig.recheckInterval) {
            refresh()
        }
    }

    /// Close the client the moment the stored licence stops being valid, without waiting
    /// for the network.
    ///
    /// `effectiveOfflineStatus()` is the same authority `hideLock` consults, so this can
    /// only ever agree with it. What it adds is a MOMENT at which the question is asked:
    /// on returning to the app, and on a timer armed for the exact second the current
    /// licence runs out. Before this the only periodic timer ran after the lock was
    /// already up, so an expiry that happened with the app open was not noticed at all.
    private func enforceLocalExpiry() {
        guard started else { return }
        let cached = LicenseStore.shared.effectiveOfflineStatus()
        guard !cached.allowsAppAccess else {
            armExpiryTimer()
            return
        }
        setFeatureAccess(active: false)
        switch cached {
        case .clientOutdated:
            showOutdated()
        case .banned:
            showExpired(banned: true)
        case .notStarted:
            // Never had a verdict: the first one is on its way, so do not accuse the user
            // of an expiry that has not been established.
            break
        default:
            showExpired(banned: false)
        }
        refresh()
    }

    /// Fire once at the second the current licence stops being valid.
    private func armExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let deadline = LicenseStore.shared.secondsUntilOfflineExpiry() else { return }
        // A second past it, so the check runs on the far side of the boundary rather than
        // on it, and never sooner than a second so a stale clock cannot spin the timer.
        // Built and added to the common modes rather than `scheduledTimer`, so it still
        // fires while a list is being dragged — the licence does not pause because the
        // user is scrolling.
        let timer = Timer(timeInterval: max(1.0, deadline + 1.0), repeats: false) { [weak self] _ in
            self?.enforceLocalExpiry()
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: - Resolution

    private func refresh() {
        guard started, !inFlight else { return }
        inFlight = true
        let uid = telegramUserId
        let generation = Self.beginLicenseGeneration()
        LicenseAPIClient.shared.check(telegramUserId: uid) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                // An answer to a question that has since been superseded — by an
                // activation, a bootstrap or a change of account — is not the current
                // verdict, however correctly it is signed.
                guard Self.licenseGenerationIsCurrent(generation) else { return }
                switch result {
                case .success(let response):
                    // A verdict the store refuses to remember is one this screen must not
                    // act on either: an unreadable 2xx and an "active" with no usable dates
                    // are protocol failures, not the server revoking anything.
                    guard LicenseStore.isStorableVerdict(response) else {
                        self.applyNetworkFailure()
                        return
                    }
                    LicenseStore.shared.save(response: response, telegramUserId: uid)
                    self.apply(status: response.status, response: response)
                case .failure:
                    self.applyNetworkFailure()
                }
            }
        }
    }

    // The license just became active. Start the embedded REALITY core immediately;
    // its loopback SOCKS endpoint is hot-applied by TelegramCore without relaunching.
    private func upgradeSystemProxy() {
        AorusRealityManager.shared.startIfAuthorized()
    }

    private func apply(status: LicenseStatus, response: LicenseResponse?) {
        pendingRelock = false   // the server just gave a definitive verdict
        switch status {
        case .trialActive, .paidActive:
            // Do not cover the login UI with a second readiness screen. The system
            // proxy patch is already fail-closed on its reserved loopback endpoint
            // until AorusRealityManager publishes the live process-bound port.
            hideLock()
            upgradeSystemProxy()
            maybeShowEntryBanner(status: status, response: response)
        case .notStarted:
            showTrialWelcome()
        case .expired:
            showExpired(banned: false)
        case .banned:
            showExpired(banned: true)
        case .clientOutdated:
            showOutdated()
        case .networkError:
            applyNetworkFailure()
        }
    }

    // No permissive fall-through: unknown + offline = locked (connection screen).
    private func applyNetworkFailure() {
        pendingRelock = false
        let cached = LicenseStore.shared.effectiveOfflineStatus()
        switch cached {
        case .trialActive, .paidActive:
            // Honour valid offline grace without a visual launch wait. Telegram's
            // network layer still cannot fall through to a direct connection.
            hideLock()
        case .expired, .banned:
            showExpired(banned: cached == .banned)
        case .clientOutdated:
            showOutdated()
        default:
            showConnection()
        }
    }

    // MARK: - Lock screens

    private func showLoading() {
        guard lockKind != .loading else { return }
        lockKind = .loading
        setLockRoot(SubscriptionLoadingController())
    }

    private func showTrialWelcome() {
        setFeatureAccess(active: false)
        guard lockKind != .trial else { return }
        lockKind = .trial
        let vc = TrialWelcomeController()
        vc.onActivateTrial = { [weak self, weak vc] in
            guard let self = self else { return }
            vc?.setLoading(true)
            let uid = self.telegramUserId
            LicenseAPIClient.shared.bootstrap(telegramUserId: uid) { [weak self, weak vc] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    vc?.setLoading(false)
                    switch result {
                    case .success(let response):
                        _ = Self.beginLicenseGeneration()
                        LicenseStore.shared.save(response: response, telegramUserId: uid)
                        if response.status.allowsAppAccess {
                            self.bannerShownThisLaunch = true
                            self.hideLock()
                            self.upgradeSystemProxy()
                            self.showToast(SubL10n.toastTrialActivated)
                        } else {
                            self.apply(status: response.status, response: response)
                        }
                    case .failure(let error):
                        self.presentAlert(self.message(for: error))
                    }
                }
            }
        }
        vc.onHaveKey = { [weak self] in self?.pushActivateKeyInLock() }
        setLockRoot(vc)
    }

    private func showExpired(banned: Bool) {
        setFeatureAccess(active: false)
        let kind: LockKind = banned ? .banned : .expired
        guard lockKind != kind else { return }
        lockKind = kind
        let vc = SubscriptionExpiredController()
        if banned {
            vc.titleTextOverride = SubL10n.bannedTitle
            vc.bodyTextOverride = SubL10n.bannedBody
        }
        vc.onBuy = { [weak self] in self?.openPurchaseBotFromLock() }
        vc.onEnterKey = { [weak self] in self?.pushActivateKeyInLock() }
        setLockRoot(vc)
    }

    private func showConnection() {
        setFeatureAccess(active: false)
        guard lockKind != .connection else { return }
        lockKind = .connection
        let vc = SubscriptionExpiredController()
        vc.titleTextOverride = SubL10n.noConnTitle
        vc.bodyTextOverride = SubL10n.noConnBody
        vc.primaryTitleOverride = SubL10n.retry
        vc.secondaryTitleOverride = SubL10n.enterKey
        vc.hidePriceCard = true
        vc.hideFootnote = true
        vc.onBuy = { [weak self] in self?.refresh() }            // primary = retry
        vc.onEnterKey = { [weak self] in self?.pushActivateKeyInLock() }
        setLockRoot(vc)
    }

    private func showOutdated() {
        setFeatureAccess(active: false)
        guard lockKind != .outdated else { return }
        lockKind = .outdated
        let vc = ClientOutdatedController()
        vc.onUpdate = { [weak self] in self?.pushUpdateDownloader() }
        vc.onChannel = { [weak self] in self?.openOfficialChannelFromLock() }
        setLockRoot(vc)
    }

    private func pushUpdateDownloader() {
        guard let nav = lockWindow?.rootViewController as? UINavigationController else { return }
        nav.pushViewController(AorusUpdateDownloadController(), animated: true)
    }

    private func openOfficialChannelFromLock() {
        NotificationCenter.default.post(
            name: NSNotification.Name("aorusgram.openPurchaseBotInApp"),
            object: nil,
            userInfo: [
                "url": SubscriptionConfig.officialChannelLink,
                "mainNav": NSNumber(value: false),
            ]
        )
    }

    private func pushActivateKeyInLock() {
        guard let nav = lockWindow?.rootViewController as? UINavigationController else { return }
        let vc = ActivateKeyController()
        vc.telegramUserId = telegramUserId
        vc.onActivated = { [weak self] _ in
            self?.bannerShownThisLaunch = true
            self?.hideLock()
            self?.upgradeSystemProxy()
            self?.showToast(SubL10n.toastSubActivated)
        }
        nav.pushViewController(vc, animated: true)
    }

    // MARK: - Lock window plumbing

    private func setLockRoot(_ controller: UIViewController) {
        ensureWindow()
        if let nav = lockWindow?.rootViewController as? UINavigationController {
            nav.setViewControllers([controller], animated: false)
        } else {
            lockWindow?.rootViewController = makeNav(controller)
        }
        lockWindow?.makeKeyAndVisible()
    }

    private func ensureWindow() {
        if lockWindow != nil { return }
        let window: UIWindow
        if let scene = activeScene() {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = SubscriptionStyle.background
        window.overrideUserInterfaceStyle = .dark
        lockWindow = window
    }

    private func hideLock() {
        // DEFENSE IN DEPTH — the single authority for lifting the cover.
        //
        // The lock lifts on ONE condition: the signed, device-bound license snapshot
        // says access is allowed. Every legitimate caller (a trial/paid verdict, a key
        // activation) has already written that snapshot to LicenseStore before reaching
        // here, so this never blocks a real unlock. What it does block is every OTHER
        // caller: a UI path that lifts the lock to show the purchase bot, a future edit
        // that forgets the invariant, a replayed notification. None of them can drop the
        // cover or re-enable the client, because none of them can forge the HMAC-signed
        // snapshot. This is why "tap Buy" could never again reveal a working Telegram.
        guard AorusLicenseAccess.canUnlock else {
            // Not actually licensed — keep the cover exactly as it is and make sure the
            // feature kill-switch stays engaged, in case a caller expected a grant.
            setFeatureAccess(active: false)
            return
        }
        lockKind = .none
        setFeatureAccess(active: true)   // access granted → re-enable AorusGram features
        // The grant has an end. Arm the timer for it now, while the deadline is known.
        armExpiryTimer()
        guard let window = lockWindow else { return }
        window.isHidden = true
        window.rootViewController = nil
        lockWindow = nil
    }

    // Authoritative feature kill-switch. The lock window only covers the UI; the
    // background AorusGram features (ghost mode, deleted-message capture, anti-spam,
    // link protection, aorus-code, phone/device spoof, bypass, the proxy, …) read flat
    // `aorusgram_*` UserDefaults flags and would keep running while the subscription is
    // expired. On every verdict we:
    //   - publish `a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04` (AorusGramConfig also gates on it), and
    //   - force EVERY `aorusgram_*` boolean flag OFF while locked — not a hand-written
    //     list (which would silently miss features), but every CFBoolean in the
    //     namespace, so current AND future feature toggles are covered with no holes.
    // The real values are backed up first and restored verbatim on unlock, so a
    // returning subscriber loses nothing. The license flag itself and the license
    // cache mirror (`aorusgram_lic*`) are never touched. Fail-open: only ever engaged
    // when the gate actually locks, so an active / offline-grace user is never hit.
    private static let lockBackupKey = "aorusgram_lock_backup_v1"
    private func setFeatureAccess(active: Bool) {
        let locked = !active
        let ud = UserDefaults.standard
        ud.set(locked, forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04")

        if locked {
            startLockSweep()
            AorusProxyManager.shared.licenseDidLock()
            AorusRealityManager.shared.licenseDidLock()
            // Snapshot the real values ONCE (don't overwrite an existing backup — a
            // repeated locked verdict must not capture the already-zeroed state).
            if ud.object(forKey: LicenseGate.lockBackupKey) == nil {
                var backup: [String: Bool] = [:]
                for (k, v) in aorusBooleanFlags(in: ud) {
                    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                        backup[k] = n.boolValue
                    }
                }
                ud.set(backup, forKey: LicenseGate.lockBackupKey)
            }
            // Force every current aorusgram boolean off (idempotent — corrects any
            // drift and covers feature keys created after the original backup).
            for (k, _) in aorusBooleanFlags(in: ud) { ud.set(false, forKey: k) }
        } else {
            stopLockSweep()
            // Restore the real values captured at lock time, then drop the backup.
            if let backup = ud.dictionary(forKey: LicenseGate.lockBackupKey) {
                for (k, v) in backup { if let b = v as? Bool { ud.set(b, forKey: k) } }
                ud.removeObject(forKey: LicenseGate.lockBackupKey)
            }
            AorusRealityManager.shared.startIfAuthorized()
        }

        // In-memory side effects (Anti-Screenshot, cached manager state) can't be
        // reverted by a raw key write — the manager reacts to this on the main thread.
        NotificationCenter.default.post(
            name: NSNotification.Name("aorusgram.licenseLockChanged"),
            object: nil, userInfo: ["locked": locked])
    }

    private func aorusBooleanFlags(in ud: UserDefaults) -> [(String, Any)] {
        ud.dictionaryRepresentation().filter { key, value in
            guard key.hasPrefix("aorusgram_"),
                  key != "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04",
                  key != LicenseGate.lockBackupKey,
                  !key.hasPrefix("aorusgram_lic") else {
                return false
            }
            guard let n = value as? NSNumber else { return false }
            return CFGetTypeID(n) == CFBooleanGetTypeID()
        }
    }

    private func startLockSweep() {
        guard lockSweepTimer == nil else { return }
        lockSweepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let ud = UserDefaults.standard
            guard ud.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04") else { return }
            var backup = ud.dictionary(forKey: LicenseGate.lockBackupKey) ?? [:]
            var changed = false
            for (key, _) in self.aorusBooleanFlags(in: ud) {
                if backup[key] == nil {
                    backup[key] = ud.bool(forKey: key)
                    changed = true
                }
                ud.set(false, forKey: key)
            }
            if changed { ud.set(backup, forKey: LicenseGate.lockBackupKey) }
        }
    }

    private func stopLockSweep() {
        lockSweepTimer?.invalidate()
        lockSweepTimer = nil
    }

    private func makeNav(_ root: UIViewController) -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        nav.overrideUserInterfaceStyle = .dark
        nav.navigationBar.tintColor = SubscriptionStyle.accent
        nav.navigationBar.setBackgroundImage(UIImage(), for: .default)
        nav.navigationBar.shadowImage = UIImage()
        nav.navigationBar.isTranslucent = true
        nav.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.view.backgroundColor = SubscriptionStyle.background
        return nav
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return active
        }
        return scenes.compactMap { $0 as? UIWindowScene }.first
    }

    // MARK: - Entry banner (active license)

    private func maybeShowEntryBanner(status: LicenseStatus, response: LicenseResponse?) {
        guard !bannerShownThisLaunch else { return }
        bannerShownThisLaunch = true
        let days = response?.daysLeft ?? LicenseStore.shared.daysLeft ?? -1
        let duck: SubscriptionDuck
        let title: String
        switch status {
        case .trialActive: duck = .fire;  title = SubL10n.bannerTrialActive
        case .paidActive:  duck = .boost; title = SubL10n.bannerPaidActive
        default: return
        }
        let subtitle = remainingText(days)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            SubscriptionBanner.show(duck: duck, title: title, subtitle: subtitle) {
                self?.presentPurchaseModally()
            }
        }
    }

    // MARK: - Active-mode purchase/activate (own window over the running app)
    //
    // Presented in a dedicated full-screen window (same proven mechanism as the lock
    // screens) instead of UIViewController.present on Telegram's custom main window,
    // whose rootViewController-based presentation is unreliable — that was why the
    // banner tap appeared to "do nothing".

    private func presentPurchaseModally() {
        let vc = PurchaseController()
        // Active (not locked): close the sheet and open the bot as a normal chat in
        // AorusGram's main chat list (in-app, never the browser).
        vc.onBuy = { [weak self] in
            self?.dismissModal()
            self?.openPurchaseBotViaScheme()
        }
        vc.onHaveKey = { [weak self] in self?.pushActivateKeyInModal() }
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(dismissModalAction))
        setModalRoot(vc)
    }

    private func makeActivateController() -> ActivateKeyController {
        let vc = ActivateKeyController()
        vc.telegramUserId = telegramUserId
        vc.onActivated = { [weak self] _ in
            self?.dismissModal()
            self?.pendingRelock = false
            self?.bannerShownThisLaunch = true
            self?.hideLock()                       // no-op if not locked
            self?.upgradeSystemProxy()
            self?.showToast(SubL10n.toastSubActivated)
        }
        return vc
    }

    // MARK: - Activation confirmation (deep link)

    private func presentActivateConfirm(key: String) {
        let vc = ActivateConfirmController(key: key)
        vc.telegramUserId = telegramUserId
        vc.onActivated = { [weak self] in
            self?.dismissModal()
            self?.pendingRelock = false
            self?.bannerShownThisLaunch = true
            self?.hideLock()
            self?.upgradeSystemProxy()
            self?.showToast(SubL10n.toastSubActivated)
        }
        vc.onClose = { [weak self] in
            self?.dismissModal()
            self?.relockIfNeeded()
        }
        vc.onEnterKeyManually = { [weak self] in
            self?.pushActivateKeyInModal(asRoot: true)
        }
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(dismissModalAction))
        setModalRoot(vc)
    }

    // MARK: - Locked purchase

    // From the lock screen: open the purchase bot ABOVE the lock as the only reachable
    // screen, WITHOUT lifting the cover.
    //
    // This used to call hideLock() and open the bot in the main navigation. hideLock()
    // now refuses without a signed active license, so it would be a no-op — but the real
    // fault was the intent: revealing the main navigation put a fully working, fully
    // unlocked Telegram on screen behind (and instead of) the bot, and only re-locked on
    // the next foreground. The bot is opened in its own presentation over the lock window
    // instead (AppDelegate, inMainNav:false); the app behind the cover is never revealed,
    // and dismissing the bot returns to the lock. pendingRelock re-verifies on foreground.
    private func openPurchaseBotFromLock() {
        pendingRelock = true
        openPurchaseBot(inMainNav: false)
    }

    private func relockIfNeeded() {
        guard pendingRelock else { return }
        pendingRelock = false
        let cached = LicenseStore.shared.effectiveOfflineStatus()
        if !cached.allowsAppAccess {
            showExpired(banned: cached == .banned)
        }
        refresh()
    }

    private func pushActivateKeyInModal(asRoot: Bool = false) {
        let vc = makeActivateController()
        if !asRoot, let nav = modalWindow?.rootViewController as? UINavigationController {
            nav.pushViewController(vc, animated: true)
        } else {
            vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close, target: self, action: #selector(dismissModalAction))
            setModalRoot(vc)
        }
    }

    private func setModalRoot(_ controller: UIViewController) {
        // Animate only the first appearance of the modal window (e.g. the
        // "Subscription" button opening the management screen). Subsequent root
        // swaps inside an already-visible window are left instant — nav-level
        // pushes handle their own animation.
        let firstShow = (modalWindow == nil)
        ensureModalWindow()
        modalWindow?.rootViewController = makeNav(controller)
        modalWindow?.makeKeyAndVisible()

        guard firstShow, let rootView = modalWindow?.rootViewController?.view else { return }
        rootView.alpha = 0
        rootView.transform = CGAffineTransform(translationX: 0, y: 36)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0.5, options: [.allowUserInteraction]) {
            rootView.alpha = 1
            rootView.transform = .identity
        }
    }

    private func ensureModalWindow() {
        if modalWindow != nil { return }
        let window: UIWindow
        if let scene = activeScene() {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = SubscriptionStyle.background
        window.overrideUserInterfaceStyle = .dark
        modalWindow = window
    }

    @objc private func dismissModalAction() {
        dismissModal()
        relockIfNeeded()   // no-op unless the lock was lifted for a purchase
    }

    private func dismissModal() {
        guard let window = modalWindow else { return }
        window.isHidden = true
        window.rootViewController = nil
        modalWindow = nil
    }

    private func showToast(_ text: String) {
        SubscriptionBanner.toast(duck: .boost, text: text)
    }

    private func presentAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        let presenter = modalWindow?.rootViewController ?? lockWindow?.rootViewController
        var top = presenter
        while let p = top?.presentedViewController { top = p }
        top?.present(alert, animated: true)
    }

    // MARK: - Purchase bot (opened IN-APP, never the browser)

    // AppDelegate (which holds the Telegram context) resolves the bot with Telegram's
    // own internal resolver (openExternalUrl, forceExternal: false), so it never
    // escapes to Safari. Two modes:
    //   - inMainNav == true  → open as a normal chat in the main navigation (active user)
    //   - inMainNav == false → present above the lock window so the bot is the only
    //     reachable screen while the subscription is expired
    private func openPurchaseBot(inMainNav: Bool = false) {
        NotificationCenter.default.post(
            name: NSNotification.Name("aorusgram.openPurchaseBotInApp"),
            object: nil,
            userInfo: [
                "url": SubscriptionConfig.purchaseBotLink,
                "mainNav": NSNumber(value: inMainNav),
            ])
    }

    // Active flow: open the bot through the app's own aorusgram:// deep link so it
    // resolves inside AorusGram's main chat list. If the scheme can't be opened, fall
    // back to the in-app resolver (openExternalUrl) — never the browser.
    private func openPurchaseBotViaScheme() {
        guard let url = URL(string: SubscriptionConfig.purchaseBotScheme) else {
            openPurchaseBot(inMainNav: true); return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            if !success { self?.openPurchaseBot(inMainNav: true) }
        }
    }

    // MARK: - Remaining-time text (localized + RU pluralization)

    private func remainingText(_ days: Int) -> String { SubL10n.remaining(days: days) }

    private func message(for error: LicenseError) -> String {
        switch error {
        case .network: return SubL10n.errNetwork
        case .notProvisioned: return SubL10n.errService
        default: return SubL10n.errActivateRetry
        }
    }
}
