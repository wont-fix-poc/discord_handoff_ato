import AVFoundation
import AVKit
import UIKit

/// Keeps the app alive in the background using Picture-in-Picture.
///
/// iOS suspends an app when it moves to the background (e.g. when the user jumps to Safari to
/// complete the Discord handoff). While suspended, the local RPC server on 127.0.0.1:6463 cannot
/// receive Discord's callback. An active Picture-in-Picture session is one of the few things iOS
/// lets keep running in the background, so while PiP is active the app — and therefore the
/// HandoffServer — stays responsive.
///
/// Requires `UIBackgroundModes: ["audio"]` in Info.plist.
final class PiPKeepAlive: NSObject {
    static let shared = PiPKeepAlive()
    private override init() { super.init() }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var hostView: UIView?
    private var possibleObservation: NSKeyValueObservation?
    private var settingUp = false
    private var didStartPiP = false

    /// True once the PiP pipeline can take over, i.e. backgrounding the app now keeps it alive.
    /// The HandoffServer waits for this before auto-opening the handoff page in Safari, so the
    /// app isn't suspended mid-handoff while the keep-alive is still spinning up.
    var isKeepAliveReady: Bool {
        pipController?.isPictureInPicturePossible ?? false
    }

    func start() {
        guard player == nil, pipController == nil, !settingUp else { return }
        settingUp = true
        log("start requested")
        ensureVideo { [weak self] url in
            guard let self else { return }
            self.settingUp = false
            guard let url else { self.log("video generation FAILED — PiP unavailable"); return }
            self.log("video ready: \(url.lastPathComponent)")
            DispatchQueue.main.async { self.startPlayback(url: url) }
        }
    }

    func stop() {
        log("stop")
        possibleObservation?.invalidate()
        possibleObservation = nil
        pipController?.stopPictureInPicture()
        pipController?.delegate = nil
        pipController = nil
        player?.pause()
        player = nil
        looper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        hostView?.removeFromSuperview()
        hostView = nil
        didStartPiP = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Asset preparation

    private static var videoURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pip_keepalive_wide.mp4")
    }

    private func ensureVideo(completion: @escaping (URL?) -> Void) {
        let url = Self.videoURL
        if FileManager.default.fileExists(atPath: url.path) { completion(url); return }
        generateVideoWithAudio(at: url, completion: completion)
    }

    /// Writes a 1-second solid-black H.264 movie that ALSO contains a silent AAC audio track.
    /// AVPictureInPictureController requires the item to contain an audio track, so a video-only
    /// clip won't start PiP. We produce a single self-contained file so playback can use
    /// AVPlayerItem(url:) directly — avoiding AVURLAsset track analysis, which the app sandbox
    /// blocks ("Cannot Open" / rich-analysis XPC restriction).
    private func generateVideoWithAudio(at url: URL, completion: @escaping (URL?) -> Void) {
        // 16:9 widescreen (not square) so the floating PiP window is a short, wide strip instead
        // of a large square — less screen real estate.
        let size = CGSize(width: 64, height: 36)
        let sampleRate: Float64 = 44100
        let durationSeconds: Double = 1.0
        let fps: Int32 = 15
        let totalVideoFrames = Int(Double(fps) * durationSeconds)   // 15
        let totalAudioSamples = Int(sampleRate * durationSeconds)   // 44100

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            log("AVAssetWriter init failed"); completion(nil); return
        }

        // Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let pbAttrs: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32ARGB,
            String(kCVPixelBufferWidthKey): Int(size.width),
            String(kCVPixelBufferHeightKey): Int(size.height)
        ]
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pbAttrs)
        writer.add(videoInput)

        // Audio input: feed signed-integer PCM (silent), encode to AAC so it's valid inside mp4.
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = 1
        asbd.mBitsPerChannel = 16
        asbd.mBytesPerFrame = 2
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = 2
        var audioFormat: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &audioFormat)
        guard let audioFormat else { log("audio format create failed"); completion(nil); return }
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else {
            log("startWriting failed: \(writer.error?.localizedDescription ?? "?")"); completion(nil); return
        }
        writer.startSession(atSourceTime: .zero)

        let lock = NSLock()
        var videoFrame = 0
        var videoFinished = false
        var audioSample = 0
        var audioFinished = false
        var finishCalled = false

        func maybeFinish() {
            lock.lock()
            let shouldCall = videoFinished && audioFinished && !finishCalled
            if shouldCall { finishCalled = true }
            lock.unlock()
            guard shouldCall else { return }
            writer.finishWriting {
                let ok = (writer.status == .completed)
                DispatchQueue.main.async {
                    if !ok { self.log("finishWriting status \(writer.status): \(writer.error?.localizedDescription ?? "?")") }
                    completion(ok ? url : nil)
                }
            }
        }

        let videoQueue = DispatchQueue(label: "pip.gen.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if videoFrame >= totalVideoFrames {
                    videoInput.markAsFinished()
                    lock.lock(); videoFinished = true; lock.unlock()
                    maybeFinish()
                    return
                }
                let pts = CMTime(value: CMTimeValue(videoFrame), timescale: fps)
                if let pb = Self.makeBlackPixelBuffer(size: size) {
                    videoAdaptor.append(pb, withPresentationTime: pts)
                }
                videoFrame += 1
            }
        }

        let audioQueue = DispatchQueue(label: "pip.gen.audio")
        let chunkSize = 1024
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if audioSample >= totalAudioSamples {
                    audioInput.markAsFinished()
                    lock.lock(); audioFinished = true; lock.unlock()
                    maybeFinish()
                    return
                }
                let n = min(chunkSize, totalAudioSamples - audioSample)
                let pts = CMTime(value: CMTimeValue(audioSample), timescale: Int32(sampleRate))
                if let sb = Self.makeSilentAudioSampleBuffer(format: audioFormat, sampleRate: sampleRate,
                                                              numSamples: CMItemCount(n), pts: pts) {
                    audioInput.append(sb)
                }
                audioSample += n
            }
        }
    }

    private static func makeBlackPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) {
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private static func makeSilentAudioSampleBuffer(format: CMAudioFormatDescription, sampleRate: Float64,
                                                    numSamples: CMItemCount, pts: CMTime) -> CMSampleBuffer? {
        let bytesPerSample = 2
        let totalBytes = Int(numSamples) * bytesPerSample

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: totalBytes, flags: 0, blockBufferOut: &blockBuffer)
        guard createStatus == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }
        let fillStatus = CMBlockBufferFillDataBytes(with: 0, blockBuffer: bb,
                                                    offsetIntoDestination: 0, dataLength: totalBytes)
        guard fillStatus == kCMBlockBufferNoErr else { return nil }

        var sampleSize = bytesPerSample
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: numSamples,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Keep-alive session

    @MainActor
    private func startPlayback(url: URL) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            log("audio session active (.playback)")
        } catch {
            log("audio session error: \(error.localizedDescription)")
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        let videoLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
        log("player playing")

        // AVPlayerLayer attached to a visibly-sized view in the key window. iOS only treats a layer
        // as "inline" (and thus PiP-able) when it is on screen with a real frame.
        let layer = AVPlayerLayer(player: queuePlayer)
        layer.videoGravity = .resizeAspect
        let host = UIView()
        host.isUserInteractionEnabled = false
        host.backgroundColor = .black
        host.layer.addSublayer(layer)

        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        if let window {
            let w: CGFloat = 120, h: CGFloat = 68
            host.frame = CGRect(x: window.bounds.width - w - 8,
                                y: window.safeAreaInsets.top + 8,
                                width: w, height: h)
            layer.frame = host.bounds
            window.addSubview(host)
            log("inline view at \(host.frame)")
        } else {
            log("no key window found — inline view not added")
        }

        self.player = queuePlayer
        self.looper = videoLooper
        self.playerLayer = layer
        self.hostView = host

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log("PiP not supported on this device/scene"); return
        }
        guard let pip = AVPictureInPictureController(playerLayer: layer) else {
            log("AVPictureInPictureController init returned nil"); return
        }
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
        log("pip controller created; isPictureInPicturePossible=\(pip.isPictureInPicturePossible)")

        // Start as soon as the player is ready (isPictureInPicturePossible flips to true).
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
            DispatchQueue.main.async {
                self?.log("isPictureInPicturePossible -> \(ctrl.isPictureInPicturePossible)")
                if ctrl.isPictureInPicturePossible { self?.attemptStart() }
            }
        }
    }

    @MainActor
    private func attemptStart() {
        guard let pip = pipController, !didStartPiP, pip.isPictureInPicturePossible else { return }
        log("calling startPictureInPicture()")
        pip.startPictureInPicture()
    }

    private func log(_ msg: String) {
        print("[PiP] \(msg)")
    }
}

// MARK: - PiP delegate (diagnostics)

extension PiPKeepAlive: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        didStartPiP = true
        log("✓ PiP STARTED")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        didStartPiP = false
        log("PiP STOPPED")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        log("PiP FAILED TO START: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
