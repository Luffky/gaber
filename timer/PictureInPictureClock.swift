import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit

@MainActor
final class PictureInPictureClock: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isAvailable = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var errorMessage: String?

    let displayLayer = AVSampleBufferDisplayLayer()

    private var pictureInPictureController: AVPictureInPictureController?
    private var frameTimer: DispatchSourceTimer?
    private var startAttempt = 0
    private let renderQueue = DispatchQueue(label: "timer.picture-in-picture.render", qos: .userInteractive)
    private let renderSize = CGSize(width: 960, height: 240)

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        configurePictureInPicture()
    }

    func toggle() {
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        } else {
            start()
        }
    }

    func start() {
        guard isAvailable, let controller = pictureInPictureController else {
            errorMessage = "当前设备不支持画中画"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            errorMessage = "无法启动后台播放：\(error.localizedDescription)"
            return
        }

        startRendering()
        renderFrame()
        startAttempt = 0
        startWhenReady(controller)
    }

    private func startWhenReady(_ controller: AVPictureInPictureController) {
        guard !controller.isPictureInPictureActive else { return }

        renderFrame()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }

        startAttempt += 1
        guard startAttempt < 40 else {
            stopRendering()
            errorMessage = "画中画未能就绪，请确认系统设置中已开启画中画后重试"
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.startWhenReady(controller)
        }
    }

    private func configurePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
    }

    private func startRendering() {
        guard frameTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderFrame()
            }
        }
        frameTimer = timer
        timer.resume()
    }

    private func stopRendering() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    private func renderFrame() {
        guard let sampleBuffer = makeClockSampleBuffer(date: Date()) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func makeClockSampleBuffer(date: Date) -> CMSampleBuffer? {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var optionalPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalPixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer = optionalPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        context.setFillColor(UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))

        // CVPixelBuffer/Core Graphics 使用左下角原点，UIKit 文本使用左上角原点。
        // 翻转 Y 轴，避免画中画中的时钟呈镜像/倒置状态。
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)

        let calendar = Calendar.autoupdatingCurrent
        let values = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let time = String(
            format: "%02d:%02d:%02d.%03d",
            values.hour ?? 0,
            values.minute ?? 0,
            values.second ?? 0,
            (values.nanosecond ?? 0) / 1_000_000
        )

        UIGraphicsPushContext(context)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 116, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]
        let textRect = CGRect(x: 16, y: 47, width: renderSize.width - 32, height: 150)
        (time as NSString).draw(in: textRect, withAttributes: textAttributes)
        UIGraphicsPopContext()

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        if let sampleBuffer,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

extension PictureInPictureClock: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isActive = true
            errorMessage = nil
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isActive = false
            stopRendering()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            isActive = false
            stopRendering()
            errorMessage = "画中画启动失败：\(error.localizedDescription)"
        }
    }
}

extension PictureInPictureClock: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        shouldProhibitBackgroundAudioPlaybackForApplicationWithAudioSession audioSession: AVAudioSession
    ) -> Bool {
        true
    }
}

struct PictureInPicturePreview: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView()
        view.displayLayer = displayLayer
        return view
    }

    func updateUIView(_ uiView: SampleBufferView, context: Context) {}
}

final class SampleBufferView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let displayLayer {
                layer.addSublayer(displayLayer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
