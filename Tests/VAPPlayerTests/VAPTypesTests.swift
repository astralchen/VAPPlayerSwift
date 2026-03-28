// VAPTypesTests.swift
import Testing
import Foundation
import UIKit
@testable import VAPPlayer

@Suite("VAPTypes")
struct VAPTypesTests {

    // MARK: - VAPTextureBlendMode

    @Test func blendModeRawValues() {
        #expect(VAPTextureBlendMode.alphaLeft.rawValue   == 0)
        #expect(VAPTextureBlendMode.alphaRight.rawValue  == 1)
        #expect(VAPTextureBlendMode.alphaTop.rawValue    == 2)
        #expect(VAPTextureBlendMode.alphaBottom.rawValue == 3)
    }

    @Test func blendModeFromRawValue() {
        #expect(VAPTextureBlendMode(rawValue: 1) == .alphaRight)
        #expect(VAPTextureBlendMode(rawValue: 99) == nil)
    }

    // MARK: - VAPOrientation

    @Test func orientationRawValues() {
        #expect(VAPOrientation.none.rawValue      == 0)
        #expect(VAPOrientation.portrait.rawValue  == 1)
        #expect(VAPOrientation.landscape.rawValue == 2)
    }

    // MARK: - VAPError

    @Test func errorFileNotFound() {
        let e = VAPError.fileNotFound("/some/path.mp4")
        guard case .fileNotFound(let path) = e else { Issue.record("wrong case"); return }
        #expect(path == "/some/path.mp4")
    }

    @Test func errorIncompatibleVersion() {
        let e = VAPError.incompatibleVersion(3)
        guard case .incompatibleVersion(let v) = e else { Issue.record("wrong case"); return }
        #expect(v == 3)
    }

    @Test func errorDecodeFailed() {
        let underlying = NSError(domain: "test", code: 42)
        let e = VAPError.decodeFailed(underlying)
        guard case .decodeFailed(let inner) = e else { Issue.record("wrong case"); return }
        #expect((inner as NSError).code == 42)
    }

    // MARK: - Constants

    @Test func constants() {
        #expect(kVAPDefaultFPS == 25)
        #expect(kVAPMinFPS == 1)
        #expect(kVAPMaxFPS == 60)
        #expect(kVAPMaxCompatibleVersion == 2)
        #expect(kVAPMinFPS < kVAPDefaultFPS)
        #expect(kVAPDefaultFPS < kVAPMaxFPS)
    }

    // MARK: - VAPAttachmentSourceType

    @Test func attachmentSourceTypeRawValues() {
        #expect(VAPAttachmentSourceType.text.rawValue     == "txt")
        #expect(VAPAttachmentSourceType.textStr.rawValue  == "txtStr")
        #expect(VAPAttachmentSourceType.image.rawValue    == "img")
        #expect(VAPAttachmentSourceType.imageURL.rawValue == "imgUrl")
    }

    @Test func attachmentSourceTypeFromRawValue() {
        #expect(VAPAttachmentSourceType(rawValue: "img") == .image)
        #expect(VAPAttachmentSourceType(rawValue: "unknown") == nil)
    }

    // MARK: - VAPAttachmentFitType

    @Test func fitTypeRawValues() {
        #expect(VAPAttachmentFitType.fitXY.rawValue      == "fitXY")
        #expect(VAPAttachmentFitType.centerFull.rawValue == "centerFull")
    }

    // MARK: - VAPEvent

    @Test func eventDidPlayFrame() {
        let event = VAPEvent.didPlayFrame(index: 5)
        guard case .didPlayFrame(let idx) = event else { Issue.record("wrong case"); return }
        #expect(idx == 5)
    }

    @Test func eventDidFinish() {
        let event = VAPEvent.didFinish(totalFrames: 100)
        guard case .didFinish(let total) = event else { Issue.record("wrong case"); return }
        #expect(total == 100)
    }

    @Test func eventDidStop() {
        let event = VAPEvent.didStop(lastFrame: 42)
        guard case .didStop(let last) = event else { Issue.record("wrong case"); return }
        #expect(last == 42)
    }

    @Test func eventDidFail() {
        let event = VAPEvent.didFail(.metalUnavailable)
        guard case .didFail(let err) = event else { Issue.record("wrong case"); return }
        guard case .metalUnavailable = err else { Issue.record("wrong error"); return }
    }

    @Test func eventDidLoopFinish() {
        let event = VAPEvent.didLoopFinish(loop: 2, totalFrames: 60)
        guard case .didLoopFinish(let loop, let total) = event else { Issue.record("wrong case"); return }
        #expect(loop == 2)
        #expect(total == 60)
    }

    @Test func eventDownloading() {
        let event = VAPEvent.downloading(progress: 0.75)
        guard case .downloading(let p) = event else { Issue.record("wrong case"); return }
        #expect(p == 0.75)
    }

    // MARK: - VAPAttachmentSource

    @Test func attachmentSourceImage() {
        let img = UIImage()
        let src = VAPAttachmentSource.image(img)
        guard case .image(let i) = src else { Issue.record("wrong case"); return }
        #expect(i === img)
    }

    @Test func attachmentSourceURL() {
        let src = VAPAttachmentSource.url("https://example.com/img.png")
        guard case .url(let s) = src else { Issue.record("wrong case"); return }
        #expect(s == "https://example.com/img.png")
    }

    @Test func attachmentSourceText() {
        let src = VAPAttachmentSource.text("Hello")
        guard case .text(let t) = src else { Issue.record("wrong case"); return }
        #expect(t == "Hello")
    }

    // MARK: - VAPMaskInfo

    @Test func maskInfoDefaults() {
        let data = Data([0, 1, 0, 1])
        let mask = VAPMaskInfo(data: data, dataSize: CGSize(width: 2, height: 2))
        #expect(mask.data == data)
        #expect(mask.dataSize == CGSize(width: 2, height: 2))
        #expect(mask.sampleRect == .zero)
        #expect(mask.blurLength == 0)
    }

    @Test func maskInfoCustomValues() {
        let data = Data(repeating: 1, count: 100)
        let mask = VAPMaskInfo(data: data,
                               dataSize: CGSize(width: 10, height: 10),
                               sampleRect: CGRect(x: 1, y: 2, width: 8, height: 8),
                               blurLength: 4)
        #expect(mask.sampleRect == CGRect(x: 1, y: 2, width: 8, height: 8))
        #expect(mask.blurLength == 4)
    }

    // MARK: - VAPImageContext

    @Test func imageContextFields() {
        let ctx = VAPImageContext(srcId: "avatar",
                                  fitType: .fitXY,
                                  targetSize: CGSize(width: 100, height: 50),
                                  loadType: .network)
        #expect(ctx.srcId == "avatar")
        #expect(ctx.fitType == .fitXY)
        #expect(ctx.targetSize == CGSize(width: 100, height: 50))
        #expect(ctx.loadType == .network)
    }

    @Test func imageContextNilOptionals() {
        let ctx = VAPImageContext(srcId: "bg",
                                  fitType: .centerFull,
                                  targetSize: nil,
                                  loadType: nil)
        #expect(ctx.targetSize == nil)
        #expect(ctx.loadType == nil)
    }
}
