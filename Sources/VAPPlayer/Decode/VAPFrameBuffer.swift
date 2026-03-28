// VAPFrameBuffer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import CoreVideo
import Foundation

// MARK: - Decoded frame

struct VAPDecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    var frameIndex: Int
    var pts: Double   // seconds
}

// MARK: - Thread-safe FIFO buffer

actor VAPFrameBufferActor {
    private var frames: [VAPDecodedFrame] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { frames.count }
    var isFull: Bool { frames.count >= capacity }
    var isEmpty: Bool { frames.isEmpty }

    func push(_ frame: VAPDecodedFrame) {
        frames.append(frame)
    }

    func pop() -> VAPDecodedFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    func clear() {
        frames.removeAll()
    }
}
