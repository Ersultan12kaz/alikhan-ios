import AVKit
import SwiftUI
import UIKit

/// Picture-in-Picture: айдаһар қосымшадан шыққанда кішкене терезеде қалады.
/// AVSampleBufferDisplayLayer-ге секундына бірнеше кадр саламыз.
final class DragonPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = DragonPiP()
    let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var t = 0.0
    var state: OrbState = .sleep
    private let size = CGSize(width: 360, height: 240)

    var enabled: Bool { controller != nil }

    func enable() {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        layer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c
        schedule(fps: 4)
    }

    func disable() {
        controller?.stopPictureInPicture()
        controller = nil
        timer?.invalidate()
        timer = nil
        layer.flush()
    }

    private func schedule(fps: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.frame() }
        frame()
    }

    private func frame() {
        t += timer?.timeInterval ?? 0.25
        guard let buffer = render() else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(buffer)
    }

    private func render() -> CMSampleBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pixel = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // Күйге сай жарқыл: ұйқыда баяу тыныстайды
        let breath = 0.5 + 0.5 * sin(t * (state == .sleep ? 1.2 : 3.0))
        let glow = UIColor(state.accent).withAlphaComponent(state == .sleep ? 0.18 + 0.12 * breath : 0.35 + 0.25 * breath)
        let center = CGPoint(x: size.width * 0.52, y: size.height * 0.48)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [glow.cgColor, UIColor.clear.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.height * 0.6, options: [])
        }
        if let img = UIImage(named: "dragon_big_\(state.rawValue)")?.cgImage {
            let h = size.height * 0.86
            let w = h * CGFloat(img.width) / CGFloat(img.height)
            ctx.draw(img, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        guard let fmt = format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 4),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sb = sample else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    // MARK: Ойнату делегаты: тікелей эфир сияқты, кідіртуге болмайды
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { schedule(fps: 8) }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { schedule(fps: 4) }
}

/// Қабат экранда болуы керек (iOS шарты): басты бетте кішкене алдын ала көрініс.
struct PiPHost: UIViewRepresentable {
    final class HostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            DragonPiP.shared.layer.frame = bounds
        }
    }

    func makeUIView(context: Context) -> UIView {
        let v = HostView()
        v.backgroundColor = .black
        v.layer.addSublayer(DragonPiP.shared.layer)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
