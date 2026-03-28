// VAPRenderer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// VAP-x renderer: composites YUV base video + attachment images/text using mask.

import Metal
import MetalKit
import CoreVideo
import UIKit
import simd

@MainActor
final class VAPRenderer {

    // MARK: - Metal objects
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let yuvPipelineState: MTLRenderPipelineState
    private let attachPipelineState: MTLRenderPipelineState
    private var colorParams: VAPColorParameters = .bt601Full
    private var textureCache: CVMetalTextureCache?

    // MARK: - Init

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw VAPError.metalUnavailable
        }
        self.commandQueue = queue
        let (yuv, attach) = try Self.makePipelines(device: device)
        self.yuvPipelineState    = yuv
        self.attachPipelineState = attach
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - Render

    func render(pixelBuffer: CVPixelBuffer,
                into metalView: VAPMetalView,
                blendMode: VAPTextureBlendMode,
                config: VAPConfig?,
                attachmentTextures: [String: MTLTexture],
                maskTexture: MTLTexture?,
                frameIndex: Int) {
        if metalView.metalLayer.device == nil {
            metalView.metalLayer.device = device
        }
        guard let drawable = metalView.metalLayer.nextDrawable() else { return }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture     = drawable.texture
        desc.colorAttachments[0].loadAction  = .clear
        desc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }

        // 1. Draw base YUV layer (with optional mask)
        if let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: desc) {
            drawYUVBase(pixelBuffer: pixelBuffer,
                        blendMode: blendMode,
                        metalView: metalView,
                        maskTexture: maskTexture,
                        encoder: encoder)
            encoder.endEncoding()
        }

        // 2. Draw attachment layers on top
        if let config, let frameInfo = config.frame?.first(where: { $0.i == frameIndex }) {
            for item in (frameInfo.obj ?? []) {
                guard let tex = attachmentTextures[item.srcId] else { continue }
                let loadDesc = MTLRenderPassDescriptor()
                loadDesc.colorAttachments[0].texture     = drawable.texture
                loadDesc.colorAttachments[0].loadAction  = .load
                loadDesc.colorAttachments[0].storeAction = .store
                if let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: loadDesc) {
                    drawAttachment(item: item,
                                   texture: tex,
                                   maskTexture: maskTexture,
                                   metalView: metalView,
                                   config: config,
                                   encoder: encoder)
                    encoder.endEncoding()
                }
            }
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - Draw YUV base

    private func drawYUVBase(pixelBuffer: CVPixelBuffer,
                             blendMode: VAPTextureBlendMode,
                             metalView: VAPMetalView,
                             maskTexture: MTLTexture?,
                             encoder: MTLRenderCommandEncoder) {
        updateColorParams(from: pixelBuffer)
        let textures = makeYUVTextures(from: pixelBuffer)
        guard textures.count == 2 else { return }

        let vw = CVPixelBufferGetWidth(pixelBuffer)
        let vh = CVPixelBufferGetHeight(pixelBuffer)
        let videoSize = CGSize(width: vw, height: vh)
        let viewRect  = metalView.vertexRect(videoSize: videoSize)

        let verts = makeFullQuad(viewRect: viewRect)
        guard let vBuf = device.makeBuffer(bytes: verts,
                                           length: verts.count * MemoryLayout<VAPHWDVertex>.stride,
                                           options: .storageModeShared) else { return }
        var params = colorParams
        guard let pBuf = device.makeBuffer(bytes: &params,
                                           length: MemoryLayout<VAPColorParameters>.stride,
                                           options: .storageModeShared) else { return }

        encoder.setRenderPipelineState(yuvPipelineState)
        encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(textures[0], index: 0)  // Y plane (R8Unorm)
        encoder.setFragmentTexture(textures[1], index: 1)  // UV plane (RG8Unorm)
        encoder.setFragmentTexture(maskTexture,  index: 2)
        encoder.setFragmentBuffer(pBuf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Draw attachment

    private func drawAttachment(item: VAPSourceDisplayItem,
                                texture: MTLTexture,
                                maskTexture: MTLTexture?,
                                metalView: VAPMetalView,
                                config: VAPConfig,
                                encoder: MTLRenderCommandEncoder) {
        let viewSize  = metalView.bounds.size
        let canvasW   = CGFloat(config.info.w)
        let canvasH   = CGFloat(config.info.h)
        guard viewSize.width > 0, viewSize.height > 0, canvasW > 0, canvasH > 0 else { return }

        // Convert canvas rect -> NDC
        let scaleX = 2.0 / canvasW
        let scaleY = 2.0 / canvasH
        let ndcX = Float(item.x * scaleX - 1.0)
        let ndcY = Float(1.0 - (item.y + item.h) * scaleY)
        let ndcW = Float(item.w * scaleX)
        let ndcH = Float(item.h * scaleY)

        // Mask coords (if present)
        var mTL = SIMD2<Float>(0, 0)
        var mBR = SIMD2<Float>(1, 1)
        if let mf = item.mFrame {
            let videoW = Float(config.info.videoW)
            let videoH = Float(config.info.videoH)
            if videoW > 0, videoH > 0 {
                mTL = SIMD2(Float(mf.x) / videoW, Float(mf.y) / videoH)
                mBR = SIMD2(Float(mf.x + mf.w) / videoW, Float(mf.y + mf.h) / videoH)
            }
        }

        let vertices: [VAPAttachmentVertex] = [
            VAPAttachmentVertex(position: SIMD4(ndcX,        ndcY + ndcH, 0, 1),
                                texCoord: SIMD2(0, 0), maskCoord: SIMD2(mTL.x, mTL.y)),
            VAPAttachmentVertex(position: SIMD4(ndcX + ndcW, ndcY + ndcH, 0, 1),
                                texCoord: SIMD2(1, 0), maskCoord: SIMD2(mBR.x, mTL.y)),
            VAPAttachmentVertex(position: SIMD4(ndcX,        ndcY,        0, 1),
                                texCoord: SIMD2(0, 1), maskCoord: SIMD2(mTL.x, mBR.y)),
            VAPAttachmentVertex(position: SIMD4(ndcX + ndcW, ndcY,        0, 1),
                                texCoord: SIMD2(1, 1), maskCoord: SIMD2(mBR.x, mBR.y))
        ]

        guard let vBuf = device.makeBuffer(bytes: vertices,
                                           length: vertices.count * MemoryLayout<VAPAttachmentVertex>.stride,
                                           options: .storageModeShared) else { return }

        encoder.setRenderPipelineState(attachPipelineState)
        encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(texture,     index: 0)
        encoder.setFragmentTexture(maskTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Helpers

    private func makeFullQuad(viewRect: CGRect) -> [VAPHWDVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)
        return [
            VAPHWDVertex(position: SIMD4(l, t, 0, 1), rgbTexCoord: SIMD2(0, 0), alphaTexCoord: SIMD2(0, 0)),
            VAPHWDVertex(position: SIMD4(r, t, 0, 1), rgbTexCoord: SIMD2(1, 0), alphaTexCoord: SIMD2(1, 0)),
            VAPHWDVertex(position: SIMD4(l, b, 0, 1), rgbTexCoord: SIMD2(0, 1), alphaTexCoord: SIMD2(0, 1)),
            VAPHWDVertex(position: SIMD4(r, b, 0, 1), rgbTexCoord: SIMD2(1, 1), alphaTexCoord: SIMD2(1, 1))
        ]
    }

    private func makeYUVTextures(from pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        guard let cache = textureCache else { return [] }
        CVMetalTextureCacheFlush(cache, 0)
        let yWidth   = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight  = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        func make(_ plane: Int, _ w: Int, _ h: Int, _ fmt: MTLPixelFormat) -> MTLTexture? {
            var mt: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, fmt, w, h, plane, &mt) == kCVReturnSuccess,
                  let mt else { return nil }
            return CVMetalTextureGetTexture(mt)
        }
        guard let y  = make(0, yWidth,  yHeight,  .r8Unorm),
              let uv = make(1, uvWidth, uvHeight, .rg8Unorm) else { return [] }
        return [y, uv]
    }

    private func updateColorParams(from pixelBuffer: CVPixelBuffer) {
        let matrix = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil).map { $0.takeUnretainedValue() as? String } ?? nil
        colorParams = (matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)) ? .bt709Full : .bt601Full
    }

    // MARK: - Pipeline factory

    private static func makePipelines(device: MTLDevice)
        throws -> (MTLRenderPipelineState, MTLRenderPipelineState) {
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw VAPError.metalUnavailable
        }

        func blendedPipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction                = library.makeFunction(name: vertex)
            desc.fragmentFunction              = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat           = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled     = true
            desc.colorAttachments[0].rgbBlendOperation     = .add
            desc.colorAttachments[0].alphaBlendOperation   = .add
            desc.colorAttachments[0].sourceRGBBlendFactor  = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        let yuv    = try blendedPipeline(vertex: "vap_vertexShader",
                                         fragment: "vap_yuvFragmentShader")
        let attach = try blendedPipeline(vertex: "vapAttachment_VertexShader",
                                         fragment: "vapAttachment_FragmentShader")
        return (yuv, attach)
    }
}
