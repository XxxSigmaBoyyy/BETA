import Foundation
import UIKit
import QuartzCore
import Darwin
import Display
import AorusGram

private struct AorusPerformanceSnapshot {
    var ramMB: Double
    var cpuPercent: Double
    var fps: Int
    var batteryPercent: Int?
    var batteryCharging: Bool
    var rxBytesPerSecond: UInt64
    var txBytesPerSecond: UInt64
    var freeDiskBytes: UInt64
    var thermalState: ProcessInfo.ThermalState
}

private final class AorusPerformanceGraphView: UIView {
    private let ramLayer = CAShapeLayer()
    private let cpuLayer = CAShapeLayer()
    private let fpsLayer = CAShapeLayer()
    private var ramSamples: [CGFloat] = []
    private var cpuSamples: [CGFloat] = []
    private var fpsSamples: [CGFloat] = []
    private let maxSamples = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear

        for layer in [ramLayer, cpuLayer, fpsLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 1.4
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }
        ramLayer.strokeColor = UIColor(red: 0.22, green: 0.86, blue: 0.78, alpha: 0.95).cgColor
        cpuLayer.strokeColor = UIColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 0.95).cgColor
        fpsLayer.strokeColor = UIColor.white.withAlphaComponent(0.88).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func append(snapshot: AorusPerformanceSnapshot) {
        let ramMax = max(1024.0, snapshot.ramMB * 1.35)
        append(&ramSamples, CGFloat(min(1.0, snapshot.ramMB / ramMax)))
        append(&cpuSamples, CGFloat(min(1.0, snapshot.cpuPercent / 100.0)))
        append(&fpsSamples, CGFloat(min(1.0, Double(snapshot.fps) / 60.0)))
        setNeedsLayout()
    }

    private func append(_ samples: inout [CGFloat], _ value: CGFloat) {
        samples.append(max(0.0, min(1.0, value)))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds.insetBy(dx: 1.0, dy: 3.0)
        ramLayer.frame = bounds
        cpuLayer.frame = bounds
        fpsLayer.frame = bounds
        ramLayer.path = path(samples: ramSamples, rect: rect).cgPath
        cpuLayer.path = path(samples: cpuSamples, rect: rect).cgPath
        fpsLayer.path = path(samples: fpsSamples, rect: rect).cgPath
    }

    private func path(samples: [CGFloat], rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        guard samples.count > 1, rect.width > 1.0, rect.height > 1.0 else { return path }

        let step = rect.width / CGFloat(max(1, samples.count - 1))
        for i in 0 ..< samples.count {
            let x = rect.minX + CGFloat(i) * step
            let y = rect.maxY - samples[i] * rect.height
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private final class AorusPerformanceHUDView: UIView {
    private let blurView: UIVisualEffectView
    private let stackView = UIStackView()
    private let graphView = AorusPerformanceGraphView()
    private var rows: [String: UILabel] = [:]
    private var graphHeightConstraint: NSLayoutConstraint?
    private var isGraphVisible = false
    private var glassEffectsEnabled: Bool?

    override init(frame: CGRect) {
        if #available(iOS 13.0, *) {
            blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        } else {
            blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear

        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.isUserInteractionEnabled = false
        blurView.clipsToBounds = true
        blurView.layer.cornerRadius = 13.0
        blurView.layer.borderWidth = 0.5
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        blurView.layer.shadowColor = UIColor.black.cgColor
        blurView.layer.shadowOpacity = 0.22
        blurView.layer.shadowRadius = 12.0
        blurView.layer.shadowOffset = CGSize(width: 0.0, height: 4.0)
        addSubview(blurView)

        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 3.0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(stackView)

        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphHeightConstraint = graphView.heightAnchor.constraint(equalToConstant: 0.0)
        graphHeightConstraint?.isActive = true
        stackView.addArrangedSubview(graphView)
        graphView.isHidden = true

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 10.0),
            stackView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -10.0),
            stackView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 8.0),
            stackView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -8.0),
        ])
        updateGlassAppearance(enabled: UserDefaults.standard.object(forKey: "aorusgram_feature_glass_ui") as? Bool ?? true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: AorusPerformanceSnapshot, settings: AorusGramManager, l10n: AorusL10n) {
        updateGlassAppearance(enabled: settings.glassUI)
        var visibleKeys: [String] = []
        if settings.performanceShowRAM {
            setRow("ram", title: l10n.performanceRAM, value: "\(Int(snapshot.ramMB.rounded())) MB", style: .normal)
            visibleKeys.append("ram")
        }
        if settings.performanceShowCPU {
            setRow("cpu", title: l10n.performanceCPU, value: "\(Int(snapshot.cpuPercent.rounded()))%", style: snapshot.cpuPercent >= 85.0 ? .warning : .normal)
            visibleKeys.append("cpu")
        }
        if settings.performanceShowFPS {
            setRow("fps", title: l10n.performanceFPS, value: "\(snapshot.fps)", style: snapshot.fps < 45 ? .warning : .normal)
            visibleKeys.append("fps")
        }
        if settings.performanceShowBattery {
            if let battery = snapshot.batteryPercent {
                setRow("battery", title: l10n.performanceBattery, value: "\(battery)%", style: .normal, trailingSymbolName: snapshot.batteryCharging ? "bolt.fill" : nil)
            } else {
                setRow("battery", title: l10n.performanceBattery, value: "-", style: .normal)
            }
            visibleKeys.append("battery")
        }
        if settings.performanceShowNetwork {
            let down = formatRate(snapshot.rxBytesPerSecond)
            let up = formatRate(snapshot.txBytesPerSecond)
            setRow("network", title: l10n.performanceNetwork, value: "↓ \(down) ↑ \(up)", style: .normal)
            visibleKeys.append("network")
        }
        if settings.performanceShowDisk {
            setRow("disk", title: l10n.performanceDisk, value: formatDisk(snapshot.freeDiskBytes), style: .normal)
            visibleKeys.append("disk")
        }
        if settings.performanceShowThermal {
            let thermal = thermalText(snapshot.thermalState, l10n: l10n)
            setRow("thermal", title: l10n.performanceThermal, value: thermal.text, style: thermal.style)
            visibleKeys.append("thermal")
        }

        for (key, label) in rows where !visibleKeys.contains(key) {
            stackView.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        rows = rows.filter { visibleKeys.contains($0.key) }
        reorderVisibleRows(visibleKeys)

        let graphVisible = settings.performanceShowGraph && !visibleKeys.isEmpty
        if graphVisible != isGraphVisible {
            isGraphVisible = graphVisible
            graphView.isHidden = !graphVisible
            graphHeightConstraint?.constant = graphVisible ? 34.0 : 0.0
            UIView.animate(withDuration: 0.22) {
                self.layoutIfNeeded()
                self.graphView.alpha = graphVisible ? 1.0 : 0.0
            }
        }
        if graphVisible {
            graphView.append(snapshot: snapshot)
        }
    }

    private func updateGlassAppearance(enabled: Bool) {
        guard glassEffectsEnabled != enabled else { return }
        glassEffectsEnabled = enabled
        if enabled {
            if #available(iOS 13.0, *) {
                blurView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            } else {
                blurView.effect = UIBlurEffect(style: .dark)
            }
            blurView.contentView.backgroundColor = .clear
            blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            blurView.layer.shadowOpacity = 0.22
            blurView.layer.shadowRadius = 12.0
            blurView.layer.shadowOffset = CGSize(width: 0.0, height: 4.0)
        } else {
            blurView.effect = nil
            blurView.contentView.backgroundColor = UIColor(white: 0.08, alpha: 0.97)
            blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
            blurView.layer.shadowOpacity = 0.10
            blurView.layer.shadowRadius = 4.0
            blurView.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        }
    }

    private func reorderVisibleRows(_ visibleKeys: [String]) {
        for key in visibleKeys {
            if let label = rows[key] {
                stackView.removeArrangedSubview(label)
            }
        }
        stackView.removeArrangedSubview(graphView)

        for key in visibleKeys {
            if let label = rows[key] {
                stackView.addArrangedSubview(label)
            }
        }
        stackView.addArrangedSubview(graphView)
    }

    private enum RowStyle {
        case normal
        case warning
        case critical
    }

    private func setRow(_ key: String, title: String, value: String, style: RowStyle, trailingSymbolName: String? = nil) {
        let label = rows[key] ?? makeLabel(key)
        let color: UIColor
        switch style {
        case .normal:
            color = .white
        case .warning:
            color = UIColor(red: 1.0, green: 0.75, blue: 0.28, alpha: 1.0)
        case .critical:
            color = UIColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
        }
        label.textColor = color
        if let trailingSymbolName = trailingSymbolName,
           let attributedText = attributedRow(title: title, value: value, color: color, trailingSymbolName: trailingSymbolName) {
            label.attributedText = attributedText
        } else {
            label.attributedText = nil
            label.text = "\(title): \(value)"
        }
    }

    private func attributedRow(title: String, value: String, color: UIColor, trailingSymbolName: String) -> NSAttributedString? {
        let font = Font.with(size: 12.0, weight: .semibold)
        let text = NSMutableAttributedString(string: "\(title): \(value) ", attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        if #available(iOS 13.0, *),
           let image = UIImage(systemName: trailingSymbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)) {
            let attachment = NSTextAttachment()
            attachment.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0.0, y: -1.0, width: 8.5, height: 10.5)
            text.append(NSAttributedString(attachment: attachment))
            return text
        }
        return nil
    }

    private func makeLabel(_ key: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        label.font = Font.with(size: 12.0, weight: .semibold)
        label.textColor = .white
        label.shadowColor = UIColor.black.withAlphaComponent(0.55)
        label.shadowOffset = CGSize(width: 0.0, height: 1.0)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        rows[key] = label

        let insertIndex = max(0, stackView.arrangedSubviews.count - 1)
        stackView.insertArrangedSubview(label, at: insertIndex)
        return label
    }

    private func thermalText(_ state: ProcessInfo.ThermalState, l10n: AorusL10n) -> (text: String, style: RowStyle) {
        switch state {
        case .nominal:
            return (l10n.thermalNominal, .normal)
        case .fair:
            return (l10n.thermalFair, .normal)
        case .serious:
            return (l10n.thermalSerious, .warning)
        case .critical:
            return (l10n.thermalCritical, .critical)
        @unknown default:
            return (l10n.thermalNominal, .normal)
        }
    }

    private func formatRate(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB/s", Double(bytes) / 1024.0 / 1024.0)
        }
        return "\(Int(Double(bytes) / 1024.0)) KB/s"
    }

    private func formatDisk(_ bytes: UInt64) -> String {
        return String(format: "%.1f GB", Double(bytes) / 1024.0 / 1024.0 / 1024.0)
    }
}

public final class AorusPerformanceHUDManager {
    public static let shared = AorusPerformanceHUDManager()
    private init() {}

    private var window: UIWindow?
    private weak var hudView: AorusPerformanceHUDView?
    private var statsTimer: Timer?
    private var cleanupTimer: Timer?
    private var cleanupIntervalSeconds: Int?
    private var displayLink: CADisplayLink?
    private var observing = false
    private var frameCount = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var currentFPS = 0
    private var scheduledHUDRetryCount = 0
    private var launchRestorationToken = 0
    private var previousNetworkBytes: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread {
            f()
        } else {
            DispatchQueue.main.async {
                f()
            }
        }
    }

    public func refresh() {
        DispatchQueue.main.async { [weak self] in
            self?._refresh()
        }
    }

    public func restorePersistedHUDAfterLaunch() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self._refresh()
            self.scheduleLaunchRestorationPasses()
        }
    }

    private func _refresh() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(onSettingsChanged),
                                                   name: .aorusSettingsChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(onDidBecomeActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(onDidEnterBackground),
                                                   name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(onOrientationChanged),
                                                   name: UIDevice.orientationDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(onThermalChanged),
                                                   name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            if #available(iOS 13.0, *) {
                NotificationCenter.default.addObserver(self, selector: #selector(onSceneDidActivate),
                                                       name: UIScene.didActivateNotification, object: nil)
            }
        }

        let manager = AorusGramManager.shared
        let licensed = AorusLicenseAccess.isAllowed
        applyHUD(enabled: licensed && manager.performanceStatsEnabled)
        applyCleanup(enabled: licensed && manager.ramAutoClean, intervalSeconds: manager.ramCleanInterval)
    }

    @objc private func onSettingsChanged() {
        refresh()
        DispatchQueue.main.async { [weak self] in
            self?.updateSnapshot()
        }
    }

    @objc private func onDidBecomeActive() {
        restorePersistedHUDAfterLaunch()
    }

    @objc private func onSceneDidActivate() {
        restorePersistedHUDAfterLaunch()
    }

    @objc private func onDidEnterBackground() {
        onMain { [weak self] in
            self?.stopDisplayLink()
            self?.statsTimer?.invalidate()
            self?.statsTimer = nil
            self?.discardHUDWindow()
        }
    }

    @objc private func onOrientationChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.layoutHUD()
        }
    }

    @objc private func onThermalChanged() {
        onMain { [weak self] in
            self?.updateSnapshot()
        }
    }

    private func applyHUD(enabled: Bool) {
        if enabled {
            guard ensureHUD() else {
                scheduleHUDStartupRetry()
                return
            }
            startDisplayLink()
            if statsTimer == nil {
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.updateSnapshot()
                }
                statsTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            updateSnapshot()
        } else {
            scheduledHUDRetryCount = 0
            statsTimer?.invalidate()
            statsTimer = nil
            stopDisplayLink()
            UIDevice.current.isBatteryMonitoringEnabled = false
            launchRestorationToken += 1
            hideHUD()
        }
    }

    private func applyCleanup(enabled: Bool, intervalSeconds: Int) {
        let seconds = max(30, intervalSeconds)
        if !enabled {
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            cleanupIntervalSeconds = nil
            return
        }
        if cleanupTimer != nil, cleanupIntervalSeconds == seconds {
            return
        }
        cleanupTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: true) { _ in
            AorusPerformanceHUDManager.performRAMCleanup()
        }
        cleanupTimer = timer
        cleanupIntervalSeconds = seconds
        RunLoop.main.add(timer, forMode: .common)
    }

    public static func performRAMCleanup() {
        URLCache.shared.removeAllCachedResponses()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
    }

    @discardableResult
    private func ensureHUD() -> Bool {
        if let window = window, !isWindowUsable(window) {
            discardHUDWindow()
        }

        if window == nil {
            guard let window = makeWindow() else {
                return false
            }
            let host = UIViewController()
            host.view.backgroundColor = .clear

            window.backgroundColor = .clear
            window.rootViewController = host
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1.0)
            window.isUserInteractionEnabled = false
            window.isHidden = false
            self.window = window

            let hud = AorusPerformanceHUDView()
            hud.translatesAutoresizingMaskIntoConstraints = false
            hud.alpha = 0.0
            host.view.addSubview(hud)
            hudView = hud
            layoutHUD()
            UIView.animate(withDuration: 0.18) {
                hud.alpha = 1.0
            }
        } else {
            window?.isHidden = false
            layoutHUD()
        }
        scheduledHUDRetryCount = 0
        return true
    }

    private func scheduleHUDStartupRetry() {
        guard AorusLicenseAccess.isAllowed,
              AorusGramManager.shared.performanceStatsEnabled,
              scheduledHUDRetryCount < 6 else { return }
        let delays: [TimeInterval] = [0.15, 0.35, 0.75, 1.5, 3.0, 6.0]
        let delay = delays[min(scheduledHUDRetryCount, delays.count - 1)]
        scheduledHUDRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard AorusLicenseAccess.isAllowed, AorusGramManager.shared.performanceStatsEnabled else { return }
            self?._refresh()
        }
    }

    private func scheduleLaunchRestorationPasses() {
        guard AorusLicenseAccess.isAllowed, AorusGramManager.shared.performanceStatsEnabled else { return }
        launchRestorationToken += 1
        let token = launchRestorationToken
        let delays: [TimeInterval] = [0.2, 0.6, 1.2, 2.5, 5.0, 10.0, 20.0, 40.0, 60.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      token == self.launchRestorationToken,
                      AorusLicenseAccess.isAllowed,
                      AorusGramManager.shared.performanceStatsEnabled else {
                    return
                }
                self._refresh()
                self.updateSnapshot()
            }
        }
    }

    private func isWindowUsable(_ window: UIWindow) -> Bool {
        guard !window.isHidden else { return false }
        if #available(iOS 13.0, *), let scene = window.windowScene {
            return scene.activationState == .foregroundActive
        }
        return true
    }

    private func makeWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let activeScene = scenes.first(where: { scene in
                scene.activationState == .foregroundActive && scene.windows.contains(where: { !$0.isHidden && $0.isKeyWindow })
            }) ?? scenes.first(where: { scene in
                scene.activationState == .foregroundActive && scene.windows.contains(where: { !$0.isHidden })
            }) ?? scenes.first(where: { $0.activationState == .foregroundActive })
            if let scene = activeScene {
                return UIWindow(windowScene: scene)
            }
            return nil
        }
        return UIWindow(frame: UIScreen.main.bounds)
    }

    private func layoutHUD() {
        guard let root = window?.rootViewController?.view, let hud = hudView else { return }
        window?.frame = UIScreen.main.bounds
        NSLayoutConstraint.deactivate(root.constraints.filter { constraint in
            constraint.firstItem === hud || constraint.secondItem === hud
        })

        let guide = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hud.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12.0),
            hud.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14.0),
            hud.widthAnchor.constraint(lessThanOrEqualToConstant: 228.0),
            hud.widthAnchor.constraint(greaterThanOrEqualToConstant: 132.0),
        ])
        root.setNeedsLayout()
        root.layoutIfNeeded()
    }

    private func hideHUD() {
        guard let hud = hudView else {
            discardHUDWindow()
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            discardHUDWindow()
            return
        }
        UIView.animate(withDuration: 0.16, animations: {
            hud.alpha = 0.0
        }, completion: { [weak self] _ in
            self?.discardHUDWindow()
        })
    }

    private func discardHUDWindow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.discardHUDWindow()
            }
            return
        }
        hudView?.removeFromSuperview()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hudView = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        frameCount = 0
        fpsWindowStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        currentFPS = 0
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            currentFPS = Int((Double(frameCount) / elapsed).rounded())
            frameCount = 0
            fpsWindowStart = now
        }
    }

    private func updateSnapshot() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSnapshot()
            }
            return
        }
        guard UIApplication.shared.applicationState != .background else { return }
        guard let hud = hudView,
              AorusLicenseAccess.isAllowed,
              AorusGramManager.shared.performanceStatsEnabled else { return }
        guard let root = window?.rootViewController?.view, hud.superview === root else {
            discardHUDWindow()
            return
        }
        let snapshot = collectSnapshot()
        hud.update(snapshot: snapshot, settings: AorusGramManager.shared, l10n: AorusL10n.current)
        layoutHUD()
    }

    private func collectSnapshot() -> AorusPerformanceSnapshot {
        let network = networkRate()
        return AorusPerformanceSnapshot(
            ramMB: memoryFootprintMB(),
            cpuPercent: processCPUPercent(),
            fps: currentFPS,
            batteryPercent: batteryPercent(),
            batteryCharging: UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
            rxBytesPerSecond: network.rx,
            txBytesPerSecond: network.tx,
            freeDiskBytes: freeDiskBytes(),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }

    private func processCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return 0.0
        }
        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        }

        var total: Double = 0.0
        for i in 0 ..< Int(threadCount) {
            var info = thread_basic_info_data_t()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
                }
            }
            if result == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return min(100.0, max(0.0, total))
    }

    private func batteryPercent() -> Int? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0.0 else { return nil }
        return Int((level * 100.0).rounded())
    }

    private func networkRate() -> (rx: UInt64, tx: UInt64) {
        let totals = networkTotals()
        let now = Date().timeIntervalSince1970
        defer { previousNetworkBytes = (totals.rx, totals.tx, now) }
        guard let previous = previousNetworkBytes else { return (0, 0) }
        let elapsed = max(0.25, now - previous.time)
        let rx = totals.rx >= previous.rx ? UInt64(Double(totals.rx - previous.rx) / elapsed) : 0
        let tx = totals.tx >= previous.tx ? UInt64(Double(totals.tx - previous.tx) / elapsed) : 0
        return (rx, tx)
    }

    private func networkTotals() -> (rx: UInt64, tx: UInt64) {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return (0, 0) }
        defer { freeifaddrs(addressList) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let interface = ptr.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("lo"), let data = interface.ifa_data {
                    let counters = data.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(counters.ifi_ibytes)
                    tx += UInt64(counters.ifi_obytes)
                }
            }
            cursor = interface.ifa_next
        }
        return (rx, tx)
    }

    private func freeDiskBytes() -> UInt64 {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return free.uint64Value
    }
}
