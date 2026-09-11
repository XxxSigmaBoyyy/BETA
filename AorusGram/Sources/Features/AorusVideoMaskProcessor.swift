import AVFoundation
import CoreImage
import Foundation
import UIKit
import Vision

/// Real-time face-mask compositor shared by round videos and outgoing calls.
///
/// Vision landmarks anchor the artwork to the eyes, while yaw, pitch and roll
/// produce a perspective quad. Detection is throttled, but the pose is retained
/// and smoothed between detections so short occlusions do not make the mask fall
/// off the face. Processing is fail-open: callers use the original frame on any
/// unsupported input or transient failure.
@objcMembers
public final class AorusVideoMaskProcessor: NSObject {
    public static let shared = AorusVideoMaskProcessor()
    public static let roundVideoBack = AorusVideoMaskProcessor()
    public static let roundVideoFront = AorusVideoMaskProcessor()

    public static let enabledKey = "aorusgram_video_masks_enabled"
    public static let presetKey = "aorusgram_video_mask_preset"
    public static let customPreset = "custom"
    private static let callPhaseKey = "aorusgram_video_mask_call_phase"

    /// The picker's first entry. Selecting it has to stop the mask being composited without
    /// making the user go to Settings to switch the whole feature off — so it is a preset
    /// value rather than a second flag, and the gate below treats it as "not active".
    public static let offPreset = "none"

    /// The one place that decides whether a frame gets a mask at all. Was three copies of the
    /// same expression; they now cannot drift, and the off entry is honoured everywhere at once.
    static var isMaskingActive: Bool {
        let defaults = UserDefaults.standard
        if !AorusLicenseAccess.isAllowed {
            return false
        }
        guard defaults.bool(forKey: Self.enabledKey) else {
            return false
        }
        return (defaults.string(forKey: Self.presetKey) ?? "skull") != Self.offPreset
    }

    public static var supportedPresets: [String] {
        return ["skull", "cyber", "oni", "phantom", "chrome", "aurora", "neonCat", Self.customPreset]
    }

    private struct FacePose {
        var face: CGRect
        var leftEye: CGPoint
        var rightEye: CGPoint
        var nose: CGPoint
        var mouth: CGPoint
        var roll: CGFloat
        var yaw: CGFloat
        var pitch: CGFloat

        var eyeMidpoint: CGPoint {
            return CGPoint(x: (leftEye.x + rightEye.x) * 0.5, y: (leftEye.y + rightEye.y) * 0.5)
        }

        var eyeDistance: CGFloat {
            return hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
        }
    }

    /// Immutable per-frame state. Vision updates the next snapshot while Core
    /// Image renders the current one, so detector work cannot leak an unmasked
    /// frame into the outgoing video.
    private struct RenderSnapshot {
        let pose: FacePose?
        let template: CIImage?
        let preset: String
        let generation: UInt
        let needsDetection: Bool
    }

    private struct FrameGeometry: Equatable {
        let orientation: Int32
        let mirrored: Bool
        let width: Int
        let height: Int
    }

    private struct DetectionFrame {
        let image: CGImage
        let sourceExtent: CGRect
    }

    private let stateLock = NSLock()
    private let poolLock = NSLock()
    private let callRenderLock = NSLock()
    private let detectionQueue = DispatchQueue(label: "com.aorusgram.video-masks.detection", qos: .userInitiated)
    private let callRenderQueue = DispatchQueue(label: "com.aorusgram.video-masks.call-render", qos: .userInitiated)
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .name: "AorusVideoMasks"
    ])
    /// Keep Vision's proxy generation off the serial camera callback and away
    /// from the context that renders the outgoing call frame.
    private let detectionContext = CIContext(options: [
        .cacheIntermediates: false,
        .name: "AorusVideoMasks.Detection"
    ])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var lastDetectionTime: CFTimeInterval = 0.0
    private var detectionInFlight = false
    private var trackingGeneration: UInt = 0
    private var smoothedPose: FacePose?
    private var missedDetections = 0
    private var lastSuccessfulDetectionTime: CFTimeInterval = 0.0
    private var frameGeometry: FrameGeometry?
    private var processingEnabled = false
    private var hasRenderedMaskedFrame = false
    private var publishesPreview = true
    private var lastPreset = ""
    private var templates: [String: CIImage] = [:]
    private var templateImages: [String: UIImage] = [:]
    private var pools: [String: CVPixelBufferPool] = [:]
    private var customMaskModificationDates: [String: Date] = [:]
    private var callRenderInFlight = false
    private var callRenderGeneration: UInt = 0
    private var latestCallFrame: CVPixelBuffer?
    private var latestCallGeometry: FrameGeometry?
    private var lastCallRenderTime: CFTimeInterval = 0.0

    private override init() {
        super.init()
    }

    public static var customMaskURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AorusGram/VideoMasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("custom-mask.png")
    }

    public static var hasCustomMask: Bool {
        return FileManager.default.fileExists(atPath: Self.customMaskURL.path)
    }

    private static func customMaskURL(for preset: String) -> URL? {
        if preset == Self.customPreset {
            return Self.customMaskURL
        }
        let prefix = Self.customPreset + ":"
        guard preset.hasPrefix(prefix) else { return nil }
        let identifier = String(preset.dropFirst(prefix.count))
        guard UUID(uuidString: identifier) != nil else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AorusGram/VideoMasks/Custom", isDirectory: true)
            .appendingPathComponent(identifier.lowercased())
            .appendingPathExtension("png")
    }

    private static func isSupportedPreset(_ preset: String) -> Bool {
        if Self.supportedPresets.contains(preset) {
            return preset != Self.customPreset || Self.hasCustomMask
        }
        guard let url = Self.customMaskURL(for: preset) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func resetTracking() {
        self.stateLock.lock()
        self.resetTrackingLocked(clearGeometry: true)
        self.stateLock.unlock()
    }

    /// Round-video recording must not accept the original camera frame before
    /// the first masked frame has actually been rendered. After that initial
    /// gate, preserve the fail-open behavior from Telegram's capture path so a
    /// transient Vision miss cannot reduce the encoded video's frame rate.
    public var shouldDiscardUnmaskedVideoFrame: Bool {
        let enabled = Self.isMaskingActive
        guard enabled else { return false }

        self.stateLock.lock()
        let result = self.processingEnabled && !self.hasRenderedMaskedFrame
        self.stateLock.unlock()
        return result
    }

    private func resetTrackingLocked(clearGeometry: Bool) {
        self.trackingGeneration &+= 1
        self.smoothedPose = nil
        self.missedDetections = 0
        self.lastSuccessfulDetectionTime = 0.0
        self.lastDetectionTime = 0.0
        self.hasRenderedMaskedFrame = false
        if clearGeometry {
            self.frameGeometry = nil
        }
    }

    private func deactivateTrackingIfNeeded() {
        self.stateLock.lock()
        let wasEnabled = self.processingEnabled
        if wasEnabled {
            self.processingEnabled = false
            self.resetTrackingLocked(clearGeometry: true)
        }
        self.stateLock.unlock()
        if wasEnabled {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .aorusVideoMaskPreviewHidden, object: nil)
            }
        }
    }

    @objc(processPixelBuffer:orientation:)
    public func process(pixelBuffer: CVPixelBuffer, orientation rawOrientation: Int32) -> CVPixelBuffer? {
        return self.process(pixelBuffer: pixelBuffer, orientation: rawOrientation, mirrored: false, publishesPreview: true)
    }

    public func process(pixelBuffer: CVPixelBuffer, orientation rawOrientation: Int32, mirrored: Bool) -> CVPixelBuffer? {
        return self.process(pixelBuffer: pixelBuffer, orientation: rawOrientation, mirrored: mirrored, publishesPreview: true)
    }

    /// Keeps Core Image and mask composition away from WebRTC's camera callback.
    /// Only one render may be in flight; newer camera frames are dropped instead
    /// of building latency, while WebRTC receives the most recent completed frame.
    public func processCallFrame(
        pixelBuffer: CVPixelBuffer,
        orientation rawOrientation: Int32,
        mirrored: Bool
    ) -> CVPixelBuffer? {
        let enabled = Self.isMaskingActive
        guard enabled else {
            self.callRenderLock.lock()
            self.callRenderGeneration &+= 1
            self.latestCallFrame = nil
            self.latestCallGeometry = nil
            self.callRenderLock.unlock()
            self.deactivateTrackingIfNeeded()
            return nil
        }

        let geometry = FrameGeometry(
            orientation: rawOrientation,
            mirrored: mirrored,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let callPhase = UserDefaults.standard.integer(forKey: Self.callPhaseKey)
        let now = CACurrentMediaTime()
        self.callRenderLock.lock()
        if self.latestCallGeometry != geometry {
            self.callRenderGeneration &+= 1
            self.latestCallFrame = nil
            self.latestCallGeometry = geometry
            self.lastCallRenderTime = 0.0
        }
        let completedFrame = self.latestCallFrame
        // Before the peer answers, prepare one masked frame and then leave the
        // shared AVCaptureSession entirely to Telegram's native preview layer.
        // Once connected, refresh the outgoing mask at a bounded cadence while
        // WebRTC keeps receiving the most recent completed frame.
        let isWaitingForPeer = callPhase == 1
        let renderInterval: CFTimeInterval = isWaitingForPeer ? 0.10 : 0.05
        let needsPreparedFrame = isWaitingForPeer && completedFrame == nil
        let needsActiveRefresh = !isWaitingForPeer && now - self.lastCallRenderTime >= renderInterval
        if !self.callRenderInFlight,
           (needsPreparedFrame || needsActiveRefresh),
           now - self.lastCallRenderTime >= renderInterval {
            self.callRenderInFlight = true
            self.lastCallRenderTime = now
            let generation = self.callRenderGeneration
            self.callRenderQueue.async { [weak self] in
                guard let self else { return }
                let output = autoreleasepool {
                    self.process(
                        pixelBuffer: pixelBuffer,
                        orientation: rawOrientation,
                        mirrored: mirrored,
                        publishesPreview: false,
                        realtimeTracking: true
                    )
                }
                self.callRenderLock.lock()
                if generation == self.callRenderGeneration,
                   !UserDefaults.standard.bool(forKey: "a7f3d9e1-4b82-4c60-9a15-6f8e2d7c1b04"),
                   UserDefaults.standard.bool(forKey: Self.enabledKey) {
                    self.latestCallFrame = output
                }
                self.callRenderInFlight = false
                self.callRenderLock.unlock()
            }
        }
        self.callRenderLock.unlock()
        return completedFrame
    }

    public func process(
        pixelBuffer: CVPixelBuffer,
        orientation rawOrientation: Int32,
        mirrored: Bool,
        publishesPreview: Bool
    ) -> CVPixelBuffer? {
        return self.process(
            pixelBuffer: pixelBuffer,
            orientation: rawOrientation,
            mirrored: mirrored,
            publishesPreview: publishesPreview,
            realtimeTracking: publishesPreview
        )
    }

    private func process(
        pixelBuffer: CVPixelBuffer,
        orientation rawOrientation: Int32,
        mirrored: Bool,
        publishesPreview: Bool,
        realtimeTracking: Bool
    ) -> CVPixelBuffer? {
        let enabled = Self.isMaskingActive
        guard enabled else {
            self.deactivateTrackingIfNeeded()
            return nil
        }

        guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawOrientation)) else {
            return nil
        }
        let rawImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = rawImage.oriented(orientation)
        let image = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
        guard image.extent.width > 1.0, image.extent.height > 1.0 else {
            return nil
        }

        let now = CACurrentMediaTime()
        let snapshot: RenderSnapshot
        let previewBecameActive: Bool
        self.stateLock.lock()
        previewBecameActive = publishesPreview && !self.publishesPreview
        self.publishesPreview = publishesPreview
        if !self.processingEnabled {
            self.processingEnabled = true
            self.resetTrackingLocked(clearGeometry: true)
        }
        let configured = UserDefaults.standard.string(forKey: Self.presetKey) ?? "skull"
        let preset = Self.isSupportedPreset(configured) ? configured : "skull"
        let geometry = FrameGeometry(
            orientation: rawOrientation,
            mirrored: mirrored,
            width: Int(image.extent.width.rounded()),
            height: Int(image.extent.height.rounded())
        )
        let presetChanged = preset != self.lastPreset
        let geometryChanged = geometry != self.frameGeometry
        if presetChanged {
            self.lastPreset = preset
            self.templates.removeAll(keepingCapacity: true)
            self.templateImages.removeAll(keepingCapacity: true)
        }
        if presetChanged || geometryChanged {
            self.frameGeometry = geometry
            self.resetTrackingLocked(clearGeometry: false)
        }
        if previewBecameActive {
            // The dual-camera recorder keeps both streams warm. Detect on the
            // first frame after a native camera switch instead of waiting for
            // the inactive stream's relaxed cadence.
            self.lastDetectionTime = 0.0
        }
        let interval: CFTimeInterval
        if self.smoothedPose == nil {
            interval = 0.05
        } else {
            interval = realtimeTracking ? 0.066 : 0.18
        }
        let needsDetection = !self.detectionInFlight && now - self.lastDetectionTime >= interval
        if needsDetection {
            self.lastDetectionTime = now
            self.detectionInFlight = true
        }
        snapshot = RenderSnapshot(
            pose: self.smoothedPose,
            template: self.template(for: preset),
            preset: preset,
            generation: self.trackingGeneration,
            needsDetection: needsDetection
        )
        self.stateLock.unlock()

        if previewBecameActive, let pose = snapshot.pose {
            self.publishPreview(pose: pose, extent: image.extent, preset: snapshot.preset, mirrored: mirrored)
        }

        if snapshot.needsDetection {
            self.schedulePoseUpdate(
                image: image,
                generation: snapshot.generation,
                previous: snapshot.pose,
                preset: snapshot.preset,
                mirrored: mirrored
            )
        }

        guard let pose = snapshot.pose,
              pose.face.width > 4.0,
              pose.face.height > 4.0,
              let template = snapshot.template else {
            return nil
        }

        let quad = self.destinationQuad(for: pose, preset: snapshot.preset)
        let mask = template.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: quad.topLeft),
            "inputTopRight": CIVector(cgPoint: quad.topRight),
            "inputBottomRight": CIVector(cgPoint: quad.bottomRight),
            "inputBottomLeft": CIVector(cgPoint: quad.bottomLeft)
        ])
        // A close face can push the transformed artwork outside the camera
        // extent. Crop before restoring orientation so the union extent cannot
        // shift the frame and expose black borders.
        let composited = mask.composited(over: image).cropped(to: image.extent)
        let restored = composited.oriented(Self.inverse(orientation))
        let normalized = restored.transformed(by: CGAffineTransform(translationX: -restored.extent.minX, y: -restored.extent.minY))

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let output = self.makeOutputBuffer(width: width, height: height) else {
            return nil
        }
        self.ciContext.render(
            normalized,
            to: output,
            bounds: CGRect(x: 0.0, y: 0.0, width: CGFloat(width), height: CGFloat(height)),
            colorSpace: self.colorSpace
        )
        self.stateLock.lock()
        if self.processingEnabled, snapshot.generation == self.trackingGeneration {
            self.hasRenderedMaskedFrame = true
        }
        self.stateLock.unlock()
        return output
    }

    @objc(processSampleBuffer:orientation:)
    public func process(sampleBuffer: CMSampleBuffer, orientation: Int32) -> CMSampleBuffer? {
        return self.process(sampleBuffer: sampleBuffer, orientation: orientation, mirrored: false)
    }

    public func process(sampleBuffer: CMSampleBuffer, orientation: Int32, mirrored: Bool) -> CMSampleBuffer? {
        return self.process(sampleBuffer: sampleBuffer, orientation: orientation, mirrored: mirrored, publishesPreview: true)
    }

    public func process(
        sampleBuffer: CMSampleBuffer,
        orientation: Int32,
        mirrored: Bool,
        publishesPreview: Bool
    ) -> CMSampleBuffer? {
        guard let input = CMSampleBufferGetImageBuffer(sampleBuffer),
              let output = self.process(
                pixelBuffer: input,
                orientation: orientation,
                mirrored: mirrored,
                publishesPreview: publishesPreview
              ) else {
            return nil
        }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: output,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }
        var timing = CMSampleTimingInfo.invalid
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: output,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &result
        ) == noErr else {
            return nil
        }
        if let result,
           let attachments = CMCopyDictionaryOfAttachments(
               allocator: kCFAllocatorDefault,
               target: sampleBuffer,
               attachmentMode: kCMAttachmentMode_ShouldPropagate
           ) {
            CMSetAttachments(result, attachments: attachments, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return result
    }

    private func makeDetectionFrame(from image: CIImage) -> DetectionFrame? {
        let longestSide = max(image.extent.width, image.extent.height)
        let scale = min(1.0, 420.0 / max(longestSide, 1.0))
        var proxy = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        proxy = proxy.transformed(by: CGAffineTransform(translationX: -proxy.extent.minX, y: -proxy.extent.minY))
        guard let snapshot = self.detectionContext.createCGImage(proxy, from: proxy.extent) else {
            return nil
        }
        return DetectionFrame(image: snapshot, sourceExtent: image.extent)
    }

    private func schedulePoseUpdate(
        image: CIImage,
        generation: UInt,
        previous: FacePose?,
        preset: String,
        mirrored: Bool
    ) {
        self.detectionQueue.async { [weak self] in
            guard let self else { return }
            let result: (FacePose?, CGRect)? = autoreleasepool {
                guard let frame = self.makeDetectionFrame(from: image) else {
                    return nil
                }
                return (
                    self.detectPose(in: frame.image, sourceExtent: frame.sourceExtent, previous: previous),
                    frame.sourceExtent
                )
            }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            self.detectionInFlight = false
            guard generation == self.trackingGeneration, preset == self.lastPreset else { return }
            guard let (detected, sourceExtent) = result,
                  let detected,
                  previous.map({ self.isPlausible(detected, comparedTo: $0, extent: sourceExtent) }) ?? true else {
                self.registerMiss()
                return
            }
            self.applyDetectedPose(detected, extent: sourceExtent, preset: preset, mirrored: mirrored)
        }
    }

    private func detectPose(in image: CGImage, sourceExtent: CGRect, previous: FacePose?) -> FacePose? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        let observation: VNFaceObservation
        if let previous {
            let previousCenter = CGPoint(x: previous.face.midX / sourceExtent.width, y: previous.face.midY / sourceExtent.height)
            observation = observations.min(by: { lhs, rhs in
                let ld = hypot(lhs.boundingBox.midX - previousCenter.x, lhs.boundingBox.midY - previousCenter.y)
                let rd = hypot(rhs.boundingBox.midX - previousCenter.x, rhs.boundingBox.midY - previousCenter.y)
                return ld < rd
            }) ?? observations[0]
        } else {
            observation = observations.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }) ?? observations[0]
        }

        let extent = sourceExtent
        let box = observation.boundingBox
        let face = CGRect(
            x: extent.minX + box.minX * extent.width,
            y: extent.minY + box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        )
        let landmarks = observation.landmarks
        let fallbackLeft = CGPoint(x: face.minX + face.width * 0.33, y: face.minY + face.height * 0.62)
        let fallbackRight = CGPoint(x: face.minX + face.width * 0.67, y: face.minY + face.height * 0.62)
        var eyePoints = [
            self.center(of: landmarks?.leftEye, in: face) ?? fallbackLeft,
            self.center(of: landmarks?.rightEye, in: face) ?? fallbackRight
        ].sorted(by: { $0.x < $1.x })
        if eyePoints.count != 2 {
            eyePoints = [fallbackLeft, fallbackRight]
        }
        let detectedNose = self.center(of: landmarks?.nose, in: face)
        let detectedMouth = self.center(of: landmarks?.outerLips, in: face)
        let nose = detectedNose
            ?? CGPoint(x: face.midX, y: face.minY + face.height * 0.46)
        let mouth = detectedMouth
            ?? CGPoint(x: face.midX, y: face.minY + face.height * 0.27)
        let landmarkRoll = atan2(eyePoints[1].y - eyePoints[0].y, eyePoints[1].x - eyePoints[0].x)
        let visionRoll = CGFloat(truncating: observation.roll ?? 0.0)
        let roll = abs(landmarkRoll) < 0.8 ? landmarkRoll : visionRoll

        let eyeMidpoint = CGPoint(
            x: (eyePoints[0].x + eyePoints[1].x) * 0.5,
            y: (eyePoints[0].y + eyePoints[1].y) * 0.5
        )
        let eyeDistance = max(hypot(eyePoints[1].x - eyePoints[0].x, eyePoints[1].y - eyePoints[0].y), face.width * 0.22)
        let landmarkYaw = detectedNose.map {
            Self.clamp(($0.x - eyeMidpoint.x) / (eyeDistance * 0.42), min: -1.0, max: 1.0)
        }
        let visionYaw = observation.yaw.map {
            Self.clamp(CGFloat(truncating: $0) / 0.72, min: -1.0, max: 1.0)
        }
        let yaw: CGFloat
        if let visionYaw, let landmarkYaw {
            yaw = Self.mix(landmarkYaw, visionYaw, factor: 0.68)
        } else {
            yaw = visionYaw ?? landmarkYaw ?? 0.0
        }

        // The pitch observation is unavailable on older supported iOS versions.
        // The eye-to-nose ratio gives a stable fallback and also catches brief
        // Vision pose dropouts without tying the mask to a neutral head angle.
        let landmarkPitch = detectedNose.map {
            let eyeToNose = (eyeMidpoint.y - $0.y) / eyeDistance
            return Self.clamp((eyeToNose - 0.47) / 0.22, min: -1.0, max: 1.0)
        }
        var visionPitch: CGFloat?
        if #available(iOS 15.0, *) {
            visionPitch = observation.pitch.map {
                Self.clamp(CGFloat(truncating: $0) / 0.65, min: -1.0, max: 1.0)
            }
        }
        let pitch: CGFloat
        if let visionPitch, let landmarkPitch {
            pitch = Self.mix(landmarkPitch, visionPitch, factor: 0.72)
        } else {
            pitch = visionPitch ?? landmarkPitch ?? 0.0
        }
        return FacePose(
            face: face,
            leftEye: eyePoints[0],
            rightEye: eyePoints[1],
            nose: nose,
            mouth: mouth,
            roll: roll,
            yaw: yaw,
            pitch: pitch
        )
    }

    private func applyDetectedPose(_ detected: FacePose, extent: CGRect, preset: String, mirrored: Bool) {
        self.smoothedPose = self.smoothedPose.map { previous in
            let movement = hypot(
                detected.eyeMidpoint.x - previous.eyeMidpoint.x,
                detected.eyeMidpoint.y - previous.eyeMidpoint.y
            ) / max(detected.eyeDistance, 1.0)
            let rotation = abs(detected.roll - previous.roll) + abs(detected.yaw - previous.yaw) * 0.35
            let factor = Self.clamp(0.44 + movement * 0.72 + rotation * 0.28, min: 0.44, max: 0.82)
            return self.mix(previous, detected, factor: factor)
        } ?? detected
        self.missedDetections = 0
        self.lastSuccessfulDetectionTime = CACurrentMediaTime()
        if let pose = self.smoothedPose, self.publishesPreview {
            self.publishPreview(pose: pose, extent: extent, preset: preset, mirrored: mirrored)
        }
    }

    private func isPlausible(_ detected: FacePose, comparedTo previous: FacePose, extent: CGRect) -> Bool {
        let referenceWidth = max(max(previous.face.width, detected.face.width), 1.0)
        let centerTravel = hypot(
            detected.face.midX - previous.face.midX,
            detected.face.midY - previous.face.midY
        ) / referenceWidth
        let widthRatio = detected.face.width / max(previous.face.width, 1.0)
        let eyeRatio = detected.eyeDistance / max(previous.eyeDistance, 1.0)
        let expandedExtent = extent.insetBy(dx: -extent.width * 0.15, dy: -extent.height * 0.15)
        return detected.face.intersects(expandedExtent)
            && centerTravel < 1.35
            && widthRatio > 0.48 && widthRatio < 2.1
            && eyeRatio > 0.42 && eyeRatio < 2.35
    }

    private func center(of region: VNFaceLandmarkRegion2D?, in face: CGRect) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        var x: CGFloat = 0.0
        var y: CGFloat = 0.0
        for point in region.normalizedPoints {
            x += CGFloat(point.x)
            y += CGFloat(point.y)
        }
        let divisor = CGFloat(region.pointCount)
        return CGPoint(x: face.minX + x / divisor * face.width, y: face.minY + y / divisor * face.height)
    }

    private func registerMiss() {
        self.missedDetections += 1
        let elapsed = CACurrentMediaTime() - self.lastSuccessfulDetectionTime
        if self.missedDetections >= 14 && elapsed >= 0.9 {
            self.smoothedPose = nil
            // The inactive round-video camera keeps a low-rate tracker warm. It
            // must not hide the overlay published by the camera on screen.
            if self.publishesPreview {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .aorusVideoMaskPreviewHidden, object: nil)
                }
            }
        }
    }

    private typealias Quad = (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint)

    private func destinationQuad(for pose: FacePose, preset: String) -> Quad {
        let eyeDistance = max(pose.eyeDistance, pose.face.width * 0.30)
        let widthFactor: CGFloat = preset == "neonCat" || preset == "oni" ? 1.06 : 1.0
        // Vision's face box can end above the visible jaw. Size from both the
        // box and inter-eye distance, with enough bleed to cover cheeks and chin.
        let width = max(pose.face.width * 1.38, eyeDistance / 0.33) * widthFactor
        let heightFactor: CGFloat
        switch preset {
        case "oni":
            heightFactor = 1.24
        case "neonCat", "phantom":
            heightFactor = 1.20
        default:
            heightFactor = 1.18
        }
        let height = width * heightFactor
        // Artwork eye openings are not vertically centered. Anchor each family
        // to its actual eye line instead of pushing the rendered eyes below the
        // detected landmarks.
        let eyeAnchorY: CGFloat
        switch preset {
        case "oni":
            eyeAnchorY = 0.53
        case "neonCat":
            eyeAnchorY = 0.51
        case "skull", "cyber", "phantom", "chrome", "aurora":
            eyeAnchorY = 0.545
        default:
            eyeAnchorY = 0.55
        }
        let eyeMid = pose.eyeMidpoint
        let originX = eyeMid.x - width * 0.5
        let originY = eyeMid.y - height * eyeAnchorY
        var topLeft = CGPoint(x: originX, y: originY + height)
        var topRight = CGPoint(x: originX + width, y: originY + height)
        var bottomRight = CGPoint(x: originX + width, y: originY)
        var bottomLeft = CGPoint(x: originX, y: originY)

        let yaw = Self.clamp(pose.yaw, min: -1.0, max: 1.0)
        let yawAmount = abs(yaw) * width * 0.19
        if yaw > 0.0 {
            topLeft.x += yawAmount
            bottomLeft.x += yawAmount * 0.72
            topRight.x += yawAmount * 0.08
            bottomRight.x += yawAmount * 0.08
        } else if yaw < 0.0 {
            topRight.x -= yawAmount
            bottomRight.x -= yawAmount * 0.72
            topLeft.x -= yawAmount * 0.08
            bottomLeft.x -= yawAmount * 0.08
        }

        let pitchAmount = abs(pose.pitch) * height * 0.12
        if pose.pitch > 0.0 {
            bottomLeft.y += pitchAmount
            bottomRight.y += pitchAmount
        } else if pose.pitch < 0.0 {
            topLeft.y -= pitchAmount
            topRight.y -= pitchAmount
        }

        topLeft = Self.rotate(topLeft, around: eyeMid, angle: pose.roll)
        topRight = Self.rotate(topRight, around: eyeMid, angle: pose.roll)
        bottomRight = Self.rotate(bottomRight, around: eyeMid, angle: pose.roll)
        bottomLeft = Self.rotate(bottomLeft, around: eyeMid, angle: pose.roll)
        return (topLeft, topRight, bottomRight, bottomLeft)
    }

    private func template(for preset: String) -> CIImage? {
        if let url = Self.customMaskURL(for: preset) {
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if date != self.customMaskModificationDates[preset] {
                self.templates.removeValue(forKey: preset)
                self.templateImages.removeValue(forKey: preset)
                if let date {
                    self.customMaskModificationDates[preset] = date
                } else {
                    self.customMaskModificationDates.removeValue(forKey: preset)
                }
            }
        }
        if let cached = self.templates[preset] {
            return cached
        }
        let image: UIImage?
        if let url = Self.customMaskURL(for: preset) {
            image = UIImage(contentsOfFile: url.path)
        } else {
            image = self.bundledImage(named: preset == "neonCat" ? "neoncat" : preset)
        }
        guard let image, var result = CIImage(image: image) else {
            return nil
        }
        result = result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
        self.templateImages[preset] = image
        self.templates[preset] = result
        return result
    }

    private func bundledImage(named name: String) -> UIImage? {
        let hosts = [Bundle(for: AorusVideoMaskProcessor.self), Bundle.main]
        for host in hosts {
            guard let path = host.path(forResource: "AorusVideoMaskAssets", ofType: "bundle"),
                  let bundle = Bundle(path: path) else {
                continue
            }
            let url = bundle.url(forResource: name, withExtension: "png")
                ?? bundle.url(forResource: name, withExtension: "png", subdirectory: "VideoMasks")
            if let url, let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }
        return nil
    }

    public func previewImage(for preset: String) -> UIImage? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        let resolved = Self.isSupportedPreset(preset) ? preset : "skull"
        _ = self.template(for: resolved)
        return self.templateImages[resolved]
    }

    private func publishPreview(pose: FacePose, extent: CGRect, preset: String, mirrored: Bool) {
        let quad = self.destinationQuad(for: pose, preset: preset)
        let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomRight.x, quad.bottomLeft.x]
        let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomRight.y, quad.bottomLeft.y]
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let rect = CGRect(
            x: minX / extent.width,
            y: 1.0 - maxY / extent.height,
            width: (maxX - minX) / extent.width,
            height: (maxY - minY) / extent.height
        )
        let aspect = extent.width / max(extent.height, 1.0)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .aorusVideoMaskPreviewUpdated,
                object: nil,
                userInfo: [
                    "rect": NSValue(cgRect: rect),
                    "roll": NSNumber(value: Double(pose.roll)),
                    "yaw": NSNumber(value: Double(pose.yaw)),
                    "pitch": NSNumber(value: Double(pose.pitch)),
                    "preset": preset,
                    "mirrored": mirrored,
                    "aspect": NSNumber(value: Double(aspect))
                ]
            )
        }
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        self.poolLock.lock()
        defer { self.poolLock.unlock() }
        let key = "\(width)x\(height)"
        let pool: CVPixelBufferPool
        if let current = self.pools[key] {
            pool = current
        } else {
            let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
            let pixelAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, pixelAttributes as CFDictionary, &created) == kCVReturnSuccess,
                  let created else {
                return nil
            }
            self.pools[key] = created
            pool = created
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess else {
            return nil
        }
        return output
    }

    private func mix(_ previous: FacePose, _ next: FacePose, factor: CGFloat) -> FacePose {
        return FacePose(
            face: CGRect(
                x: Self.mix(previous.face.minX, next.face.minX, factor: factor),
                y: Self.mix(previous.face.minY, next.face.minY, factor: factor),
                width: Self.mix(previous.face.width, next.face.width, factor: factor),
                height: Self.mix(previous.face.height, next.face.height, factor: factor)
            ),
            leftEye: Self.mix(previous.leftEye, next.leftEye, factor: factor),
            rightEye: Self.mix(previous.rightEye, next.rightEye, factor: factor),
            nose: Self.mix(previous.nose, next.nose, factor: factor),
            mouth: Self.mix(previous.mouth, next.mouth, factor: factor),
            roll: Self.mix(previous.roll, next.roll, factor: factor),
            yaw: Self.mix(previous.yaw, next.yaw, factor: factor),
            pitch: Self.mix(previous.pitch, next.pitch, factor: factor)
        )
    }

    private static func mix(_ a: CGFloat, _ b: CGFloat, factor: CGFloat) -> CGFloat {
        return a + (b - a) * factor
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, factor: CGFloat) -> CGPoint {
        return CGPoint(x: mix(a.x, b.x, factor: factor), y: mix(a.y, b.y, factor: factor))
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        return Swift.max(min, Swift.min(max, value))
    }

    private static func rotate(_ point: CGPoint, around center: CGPoint, angle: CGFloat) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let c = cos(angle)
        let s = sin(angle)
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }

    private static func inverse(_ orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .right
        case .leftMirrored: return .rightMirrored
        case .right: return .left
        case .rightMirrored: return .leftMirrored
        }
    }
}

public extension Notification.Name {
    static let aorusVideoMaskPreviewUpdated = Notification.Name("aorusgram.videoMask.previewUpdated")
    static let aorusVideoMaskPreviewHidden = Notification.Name("aorusgram.videoMask.previewHidden")
}

@_cdecl("AorusVideoMaskProcessPixelBuffer")
public func AorusVideoMaskProcessPixelBuffer(_ pixelBuffer: CVPixelBuffer, _ orientation: Int32, _ mirrored: Int32) -> CVPixelBuffer? {
    return AorusVideoMaskProcessor.shared.processCallFrame(
        pixelBuffer: pixelBuffer,
        orientation: orientation,
        mirrored: mirrored != 0
    )
}
