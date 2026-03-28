// VAPView.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// Drop-in UIView replacement for QGVAPWrapView.
// Embeds VAPMetalView and drives VAPPlayer internally.

import UIKit

@MainActor
public final class VAPView: UIView {

    // MARK: - Public properties

    /// Destroy the player automatically after playback finishes.
    /// Defaults to false — keeps Metal objects alive for efficient reuse (e.g. in lists).
    public var autoDestroyAfterFinish: Bool = false

    /// Override FPS (0 = use MP4 header value).
    public var fps: Int = 0

    /// Mutes audio when true.
    public var isMuted: Bool = false {
        didSet { player?.setMute(isMuted) }
    }

    /// Called before playback starts. Return false to cancel playback.
    public var shouldStartPlay: ((VAPPlayConfig) -> Bool)?

    /// Resource loader used to resolve remote `http(s)://` URLs to local file paths.
    /// Defaults to `VAPDiskCache.shared`. Replace with a custom implementation to
    /// control download and caching behaviour.
    public var resourceLoader: VAPResourceLoader = VAPDiskCache.shared

    // MARK: - Private

    private var player: VAPPlayer?
    private var playTask: Task<Void, Never>?
    private var onEvent: ((VAPEvent) -> Void)?
    private var gestureHandlers: [(UIGestureRecognizer, (UIGestureRecognizer) -> Void)] = []

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Gesture API

    /// Add a tap gesture on the Metal view. The handler fires on each tap.
    /// The gesture persists across repeat cycles and is only removed when `teardown()` is called.
    public func addVapTapGesture(_ handler: @escaping (UITapGestureRecognizer) -> Void) {
        let tap = UITapGestureRecognizer()
        addVapGesture(tap) { gesture in
            guard let tap = gesture as? UITapGestureRecognizer else { return }
            handler(tap)
        }
    }

    /// Add any UIGestureRecognizer on the Metal view.
    /// The gesture persists across repeat cycles and is only removed when `teardown()` is called.
    public func addVapGesture(_ gesture: UIGestureRecognizer,
                               callback: @escaping (UIGestureRecognizer) -> Void) {
        gestureHandlers.append((gesture, callback))
        gesture.addTarget(self, action: #selector(handleVapGesture(_:)))
        // Attach to metalView if already created, otherwise attached on next play.
        player?.metalView.addGestureRecognizer(gesture)
    }

    /// Remove a previously registered gesture and detach it from the Metal view.
    public func removeVapGesture(_ gesture: UIGestureRecognizer) {
        gestureHandlers.removeAll { $0.0 === gesture }
        gesture.removeTarget(self, action: #selector(handleVapGesture(_:)))
        player?.metalView.removeGestureRecognizer(gesture)
    }

    /// VAPView itself does not handle gestures — use addVapTapGesture / addVapGesture.
    @available(*, unavailable, message: "Use addVapTapGesture or addVapGesture instead.")
    override public func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
    }

    @objc private func handleVapGesture(_ sender: UIGestureRecognizer) {
        for (g, cb) in gestureHandlers where g === sender { cb(sender) }
    }

    // MARK: - Public API

    /// Play a VAP/HWD animation file.
    ///
    /// Example:
    /// ```swift
    /// let config = VAPPlayConfig(
    ///     filePath: Bundle.main.path(forResource: "animation", ofType: "mp4")!,
    ///     blendMode: .alphaRight,
    ///     backgroundPolicy: .pauseAndResume,
    ///     contentMode: .aspectFit,
    ///     attachmentSources: [
    ///         "avatar": .image(UIImage(named: "avatar")!),
    ///         "name":   .text("张三"),
    ///         "banner": .url("https://example.com/banner.png"),
    ///     ],
    ///     loopCount: 3
    /// )
    /// vapView.play(config: config) { event in
    ///     switch event {
    ///     case .didStart:
    ///         print("playback started")
    ///     case .didFinish(let totalFrames):
    ///         print("finished, total frames: \(totalFrames)")
    ///     case .didFail(let error):
    ///         print("error: \(error)")
    ///     default:
    ///         break
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - config: Full play configuration.
    ///   - onEvent: Optional closure called for each `VAPEvent`.
    public func play(config: VAPPlayConfig, onEvent: ((VAPEvent) -> Void)? = nil) {
        var cfg = config
        cfg.fps = fps > 0 ? fps : config.fps

        // shouldStart gate
        if let gate = shouldStartPlay, !gate(cfg) { return }

        // Stop any existing playback but keep player/metalView alive for reuse.
        playTask?.cancel()
        playTask = nil
        player?.stop()
        self.onEvent = onEvent

        ensurePlayer()
        guard let p = player else { return }

        // Wrap caller's onEvent to handle autoDestroyAfterFinish internally.
        let wrappedOnEvent: ((VAPEvent) -> Void)? = { [weak self] event in
            guard let self else { return }
            onEvent?(event)
            switch event {
            case .didFinish, .didStop:
                if self.autoDestroyAfterFinish { self.teardown() }
            default:
                break
            }
        }

        let isRemote = cfg.filePath.hasPrefix("http://") || cfg.filePath.hasPrefix("https://")
        if isRemote {
            let loader = resourceLoader
            playTask = Task { [weak self] in
                do {
                    let localPath = try await loader.localPath(for: cfg.filePath, onProgress: { progress in
                        wrappedOnEvent?(.downloading(progress: progress))
                    })
                    guard let self, !Task.isCancelled else { return }
                    var localCfg = cfg
                    localCfg.filePath = localPath
                    self.player?.play(config: localCfg, onEvent: wrappedOnEvent)
                    self.player?.setMute(self.isMuted)
                } catch {
                    let vapErr = error as? VAPError ?? .unknown(error.localizedDescription)
                    wrappedOnEvent?(.didFail(vapErr))
                }
            }
        } else {
            p.play(config: cfg, onEvent: wrappedOnEvent)
            p.setMute(isMuted)
        }
    }

    /// Convenience overload accepting individual parameters.
    public func play(filePath: String,
                     blendMode: VAPTextureBlendMode = .alphaRight,
                     backgroundPolicy: VAPBackgroundPolicy = .stop,
                     contentMode: VAPContentMode = .scaleToFill,
                     attachmentSources: [String: VAPAttachmentSource] = [:],
                     imageLoader: VAPImageLoader? = nil,
                     bufferCount: Int = 3,
                     maskInfo: VAPMaskInfo? = nil,
                     playAudio: Bool = true,
                     onEvent: ((VAPEvent) -> Void)? = nil) {
        let config = VAPPlayConfig(
            filePath: filePath,
            blendMode: blendMode,
            backgroundPolicy: backgroundPolicy,
            contentMode: contentMode,
            attachmentSources: attachmentSources,
            imageLoader: imageLoader,
            bufferCount: bufferCount,
            fps: fps,
            playAudio: playAudio,
            maskInfo: maskInfo
        )
        play(config: config, onEvent: onEvent)
    }

    public func stop() {
        playTask?.cancel()
        playTask = nil
        player?.stop()
        teardown()
    }

    public func pause() {
        player?.pause()
    }

    public func resume() {
        player?.resume()
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        player?.metalView.frame = bounds
    }

    // MARK: - Private

    private func ensurePlayer() {
        guard player == nil else { return }
        let p = VAPPlayer(frame: bounds)
        p.metalView.frame = bounds
        p.metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(p.metalView)
        // Attach any pre-registered gestures to the new metalView.
        for (g, _) in gestureHandlers {
            p.metalView.addGestureRecognizer(g)
        }
        player = p
    }

    private func teardown() {
        playTask?.cancel()
        playTask = nil
        // Remove gestures before removing metalView so they can be re-attached later.
        if let mv = player?.metalView {
            for (g, _) in gestureHandlers { mv.removeGestureRecognizer(g) }
            mv.removeFromSuperview()
        }
        player = nil
    }
}
