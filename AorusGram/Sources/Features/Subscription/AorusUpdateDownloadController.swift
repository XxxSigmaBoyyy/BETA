import Foundation
import UIKit

private final class AorusUpdateDownloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    enum Failure: Error { case invalidManifest, unavailable, invalidFile, cancelled }

    var onRelease: ((AorusUpdateRelease) -> Void)?
    var onProgress: ((Double, Int64) -> Void)?
    var onComplete: ((Result<URL, Failure>) -> Void)?

    private let allowedHost = "download.aorusgram.com"
    private let maximumManifestSize = 2 * 1024 * 1024
    private let maximumIPASize: Int64 = 768 * 1024 * 1024
    private var release: AorusUpdateRelease?
    private var downloadTask: URLSessionDownloadTask?
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedBytesPerSecond: Double = 0
    private var cancelled = false
    private var finished = false
    private let stateLock = NSLock()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func start() {
        stateLock.lock()
        cancelled = false
        finished = false
        stateLock.unlock()
        release = nil
        downloadTask = nil
        guard let url = URL(string: SubscriptionConfig.updateManifestURL), isAllowed(url) else {
            finish(.failure(.invalidManifest)); return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(SubscriptionConfig.userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard !self.cancelled else { return }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  !data.isEmpty,
                  data.count <= self.maximumManifestSize,
                  let release = AorusUpdateManifestParser.newestRelease(
                    in: data, allowedHost: self.allowedHost, maximumSize: self.maximumIPASize
                  ) else {
                self.finish(.failure(.invalidManifest)); return
            }
            self.release = release
            DispatchQueue.main.async { self.onRelease?(release) }
            self.beginDownload(release)
        }.resume()
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
        downloadTask?.cancel()
        session.invalidateAndCancel()
    }

    private func beginDownload(_ release: AorusUpdateRelease) {
        var request = URLRequest(url: release.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(SubscriptionConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        downloadTask = task
        lastSampleTime = Date()
        lastSampleBytes = 0
        smoothedBytesPerSecond = 0
        task.resume()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(isAllowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let expected = release?.size ?? (totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0)
        if totalBytesWritten > maximumIPASize || (expected > 0 && expected > maximumIPASize) {
            downloadTask.cancel()
            finish(.failure(.invalidFile))
            return
        }
        let now = Date()
        let interval = now.timeIntervalSince(lastSampleTime)
        if interval >= 0.25 {
            let instant = Double(totalBytesWritten - lastSampleBytes) / interval
            smoothedBytesPerSecond = smoothedBytesPerSecond == 0
                ? instant
                : smoothedBytesPerSecond * 0.72 + instant * 0.28
            lastSampleTime = now
            lastSampleBytes = totalBytesWritten
        }
        let progress = expected > 0 ? min(1, Double(totalBytesWritten) / Double(expected)) : 0
        DispatchQueue.main.async {
            self.onProgress?(progress, max(0, Int64(self.smoothedBytesPerSecond)))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !cancelled, let release else { return }
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize,
                  fileSize > 4,
                  Int64(fileSize) <= maximumIPASize,
                  release.size == nil || Int64(fileSize) == release.size else {
                finish(.failure(.invalidFile)); return
            }
            let handle = try FileHandle(forReadingFrom: location)
            let signature = handle.readData(ofLength: 4)
            try? handle.close()
            guard signature.starts(with: [0x50, 0x4B]) else {
                finish(.failure(.invalidFile)); return
            }

            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let safeVersion = release.version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            let target = downloads.appendingPathComponent("AorusGram-\(safeVersion).ipa")
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: target.path
            )
            var targetValues = URLResourceValues()
            targetValues.isExcludedFromBackup = true
            var protectedTarget = target
            try protectedTarget.setResourceValues(targetValues)
            finish(.success(target))
        } catch {
            finish(.failure(.invalidFile))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        if cancelled || (error as? URLError)?.code == .cancelled { return }
        finish(.failure(.unavailable))
    }

    private func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == allowedHost
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
    }

    private func finish(_ result: Result<URL, Failure>) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        stateLock.unlock()
        DispatchQueue.main.async { self.onComplete?(result) }
    }
}

private final class RGBProgressView: UIView {
    private let track = CALayer()
    private let gradient = CAGradientLayer()
    private let maskLayer = CALayer()
    private var progress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor(white: 1, alpha: 0.12).cgColor
        layer.addSublayer(track)
        gradient.colors = [
            UIColor.systemRed.cgColor, UIColor.systemPink.cgColor,
            UIColor.systemPurple.cgColor, UIColor.systemBlue.cgColor,
            UIColor.systemTeal.cgColor, UIColor.systemGreen.cgColor,
            UIColor.systemYellow.cgColor, UIColor.systemRed.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = maskLayer
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        track.frame = bounds
        gradient.frame = bounds
        track.cornerRadius = bounds.height / 2
        gradient.cornerRadius = bounds.height / 2
        maskLayer.backgroundColor = UIColor.white.cgColor
        maskLayer.cornerRadius = bounds.height / 2
        maskLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }

    func setProgress(_ value: Double, animated: Bool) {
        progress = CGFloat(max(0, min(1, value)))
        let changes = {
            self.maskLayer.frame.size.width = self.bounds.width * self.progress
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            changes()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }
}

final class AorusUpdateDownloadController: SubscriptionBaseController, UIDocumentInteractionControllerDelegate {
    private let downloader = AorusUpdateDownloader()
    private let progress = RGBProgressView()
    private let statusLabel = SubscriptionStyle.body(SubL10n.checkingUpdate)
    private let speedLabel = SubscriptionStyle.body("", size: 14)
    private let completionIcon = UIImageView()
    private let openButton = SubscriptionStyle.primaryButton(SubL10n.openInFiles)
    private var downloadedURL: URL?
    private var documentInteractionController: UIDocumentInteractionController?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SubL10n.updateTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(closeTapped)
        )

        completionIcon.tintColor = SubscriptionStyle.success
        completionIcon.contentMode = .scaleAspectFit
        completionIcon.translatesAutoresizingMaskIntoConstraints = false
        completionIcon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        addContent(completionIcon)
        completionIcon.isHidden = true

        addContent(SubscriptionStyle.title(SubL10n.preparingUpdate))
        addContent(statusLabel)
        addSpacing(14)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 6).isActive = true
        addContent(progress)
        addContent(speedLabel)

        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        addBottomButton(openButton)

        downloader.onRelease = { [weak self] release in
            guard let self else { return }
            self.statusLabel.text = SubL10n.downloadingVersion(release.version)
        }
        downloader.onProgress = { [weak self] value, bytesPerSecond in
            guard let self else { return }
            self.progress.setProgress(value, animated: true)
            self.speedLabel.text = Self.speedText(bytesPerSecond)
        }
        downloader.onComplete = { [weak self] result in
            self?.handle(result)
        }
        downloader.start()
    }

    deinit { downloader.cancel() }

    private func handle(_ result: Result<URL, AorusUpdateDownloader.Failure>) {
        switch result {
        case .success(let url):
            downloadedURL = url
            progress.setProgress(1, animated: true)
            speedLabel.text = nil
            statusLabel.text = SubL10n.downloadComplete
            completionIcon.image = UIImage(systemName: "checkmark.circle.fill")
            completionIcon.isHidden = false
            completionIcon.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
            completionIcon.alpha = 0
            openButton.isHidden = false
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.68,
                           initialSpringVelocity: 0.6, options: [.allowUserInteraction]) {
                self.completionIcon.transform = .identity
                self.completionIcon.alpha = 1
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure:
            statusLabel.text = SubL10n.updateFailed
            speedLabel.text = nil
            let retry = SubscriptionStyle.primaryButton(SubL10n.retry)
            retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
            buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            addBottomButton(retry)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    @objc private func retryTapped() {
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addBottomButton(openButton)
        openButton.isHidden = true
        completionIcon.isHidden = true
        progress.setProgress(0, animated: false)
        statusLabel.text = SubL10n.checkingUpdate
        downloader.start()
    }

    @objc private func closeTapped() {
        downloader.cancel()
        navigationController?.popViewController(animated: true)
    }

    @objc private func openTapped() {
        guard let url = downloadedURL else { return }
        if #available(iOS 14.0, *) {
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.modalPresentationStyle = .formSheet
            present(picker, animated: true)
        } else {
            let controller = UIDocumentInteractionController(url: url)
            controller.delegate = self
            documentInteractionController = controller
            controller.presentOptionsMenu(from: view.bounds, in: view, animated: true)
        }
    }

    private static func speedText(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return SubL10n.connecting }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return SubL10n.downloadSpeed(formatter.string(fromByteCount: bytesPerSecond))
    }
}
