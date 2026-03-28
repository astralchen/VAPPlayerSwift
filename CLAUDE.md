# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
swift build

# Run all tests
swift test

# Run a single test by name
swift test --filter VAPPlayerTests/<TestName>

# Release build
swift build -c release
```

The `Demo/` directory is a standalone Xcode project and is not part of the Swift package; open it separately in Xcode.

## Package

- **Platform**: iOS 14+ only (no macOS/tvOS targets)
- **Swift**: tools-version 6.0, strict Swift 6 concurrency (`swiftLanguageMode(.v6)`)
- **No external dependencies** — links Metal, MetalKit, VideoToolbox, CoreVideo, CoreMedia, AVFoundation

## VAP Format

VAP (Video Alpha Protocol) encodes a transparent animation as a standard H.264/H.265 MP4 where one spatial half of each frame carries the RGB content and the other half carries the alpha channel mask. `VAPTextureBlendMode` (`.alphaLeft/.alphaRight/.alphaTop/.alphaBottom`) tells the Metal shader which half is the mask. The MP4 may also embed a `vapc` box containing a JSON config that describes dynamic attachment slots (images, text overlays) composited per-frame using mask shapes.

## Architecture

### Public API surface

- **`VAPView: UIView`** (`@MainActor`) — the only integration point callers need. Owns a `VAPPlayer` internally, exposes `play(...)`, `stop()`, `pause()`, `resume()`. Playback events are delivered via the `onEvent: ((VAPEvent) -> Void)?` callback passed to `play`.
- **`VAPPlayConfig`** — value type passed to `play(...)`. Carries `filePath` (local path or `http(s)://` URL), `blendMode`, `loopCount`, `attachmentSources`, `imageLoader`, `backgroundPolicy`, `contentMode`, etc.
- **`VAPEvent`** — `AsyncStream`-based enum: `.didStart`, `.didPlayFrame`, `.didLoopFinish`, `.didFinish`, `.didStop`, `.downloading`, `.didFail`.
- **`VAPResourceLoader` / `VAPDiskCache`** — protocol + default implementation for downloading remote URLs to a local cache before playback.

### Internal pipeline

```
VAPView (UIView, @MainActor)
  └─ VAPPlayer (@MainActor final class)
       ├─ VAPVideoDecoder (actor)          // VideoToolbox HW decode (H.264/H.265 → NV12 CVPixelBuffer)
       │    └─ VAPFrameBufferActor (actor) // ring-buffer between decoder and render loop
       ├─ VAPRenderer (@MainActor)         // Metal compositor
       │    ├─ yuvPipelineState            // vap_vertexShader + vap_yuvFragmentShader
       │    └─ attachPipelineState         // vapAttachment_VertexShader + vapAttachment_FragmentShader
       ├─ VAPHWDRenderer (@MainActor)      // alternate renderer path (hardware-decoded frames)
       ├─ VAPMetalView (CAMetalLayer-backed UIView)
       └─ VAPParser (VAPMP4Parser)         // reads MP4 boxes, extracts VAPMP4Info + vapc JSON
```

### Concurrency model

`VAPPlayer` is `@MainActor`. `VAPVideoDecoder` is an `actor` — decode work runs off the main thread via `withCheckedThrowingContinuation` into the VideoToolbox callback, then the decoded `CVPixelBuffer` is posted back to `VAPFrameBufferActor`. The render loop runs on `@MainActor`, pulling frames from the buffer and calling `VAPRenderer.render(...)` each display-link tick.

`CVPixelBuffer` is bridged across the actor boundary via the private `SendableCVPixelBuffer(@unchecked Sendable)` wrapper because `CVPixelBuffer` (a `CFTypeRef`) is thread-safe but not formally `Sendable` in Swift 6.

### Attachment system

The `vapc` JSON config (parsed by `VAPMP4Parser`) describes per-frame attachment slots with source IDs, fit types, and mask shapes. `VAPPlayConfig.attachmentSources` maps `srcId` → `VAPAttachmentSource` (`.image`, `.url`, `.text`). The renderer composites attachment textures on top of the YUV base layer each frame using the `attachPipelineState`.

### Shaders

Metal shader source lives in `Sources/VAPPlayer/Shaders/` and is bundled via `.process("Shaders")`. Loaded at runtime with `device.makeDefaultLibrary(bundle: .module)`.
