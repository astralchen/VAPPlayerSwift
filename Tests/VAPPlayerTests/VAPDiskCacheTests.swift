// VAPDiskCacheTests.swift
import Testing
import Foundation
import CryptoKit
@testable import VAPPlayer

// MARK: - Mock URLProtocol

nonisolated(unsafe) private var mockResponseData: Data = Data()
nonisolated(unsafe) private var mockShouldFail: Bool = false
nonisolated(unsafe) private var mockError: Error = NSError(domain: "MockError", code: -1)

final class VAPMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if mockShouldFail {
            client?.urlProtocol(self, didFailWithError: mockError)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(mockResponseData.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mockResponseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helper

private func makeMockCache(tmpDir: URL) -> VAPDiskCache {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VAPMockURLProtocol.self]
    return VAPDiskCache(configuration: config, cacheDirectory: tmpDir)
}

private func tmpCacheDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - VAPDiskCacheTests

// MARK: - Real network integration test

@Suite("VAPDiskCache_Network", .serialized)
struct VAPDiskCacheNetworkTests {

    private static let realURL = "https://qiniu-xbyy.yinyou.live/channel/gift/QFB6BC-1774343076586.mp4"

    @Test @MainActor func realDownloadWritesFileToDisk() async throws {
        let dir = tmpCacheDir()
        let cache = VAPDiskCache(configuration: .default, cacheDirectory: dir)
        var progressValues: [Double] = []
        let localPath = try await cache.localPath(for: Self.realURL) { p in
            progressValues.append(p)
        }
        #expect(FileManager.default.fileExists(atPath: localPath))
        #expect(localPath.hasSuffix(".mp4"))
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int) ?? 0
        #expect(fileSize > 0)
        #expect(progressValues.last == 1.0)
    }

    @Test func realCacheHitSkipsDownload() async throws {
        let dir = tmpCacheDir()
        let cache = VAPDiskCache(configuration: .default, cacheDirectory: dir)
        let first = try await cache.localPath(for: Self.realURL, onProgress: { _ in })
        // Second call — file already on disk, no network request needed
        let second = try await cache.localPath(for: Self.realURL, onProgress: { _ in })
        #expect(first == second)
    }
}

@Suite("VAPDiskCache", .serialized)
struct VAPDiskCacheTests {

    // MARK: Local path passthrough

    @Test func localPathReturnedUnchanged() async throws {
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        let path = "/local/some/animation.mp4"
        let result = try await cache.localPath(for: path, onProgress: { _ in })
        #expect(result == path)
    }

    // MARK: Invalid URL

    @Test func invalidURLThrows() async throws {
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        // String that starts with http:// but is not a valid URL
        let bad = "http://[invalid url]"
        await #expect(throws: VAPError.self) {
            _ = try await cache.localPath(for: bad, onProgress: { _ in })
        }
    }

    // MARK: Download success

    @Test func downloadWritesFileToDisk() async throws {
        mockShouldFail = false
        mockResponseData = Data("fake mp4 bytes".utf8)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        let url = "https://example.com/test.mp4"
        let localPath = try await cache.localPath(for: url, onProgress: { _ in })
        #expect(FileManager.default.fileExists(atPath: localPath))
        #expect(localPath.hasSuffix(".mp4"))
    }

    // MARK: Cache hit

    @Test func cacheHitReturnsSamePathWithoutRedownload() async throws {
        mockShouldFail = false
        mockResponseData = Data("cached content".utf8)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        let url = "https://example.com/cached.mp4"
        let first  = try await cache.localPath(for: url, onProgress: { _ in })
        // Replace mock data — second call must NOT download again
        mockResponseData = Data("new data".utf8)
        let second = try await cache.localPath(for: url, onProgress: { _ in })
        #expect(first == second)
        let content = try Data(contentsOf: URL(fileURLWithPath: first))
        #expect(content == Data("cached content".utf8))
    }

    // MARK: Progress callback

    @Test @MainActor func progressCallbackFired() async throws {
        mockShouldFail = false
        mockResponseData = Data(repeating: 0xAB, count: 1024)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        var lastProgress: Double = -1
        _ = try await cache.localPath(for: "https://example.com/progress.mp4") { p in
            lastProgress = p
        }
        // Final progress must be 1.0 (set by didFinishDownloadingTo)
        #expect(lastProgress == 1.0)
    }

    // MARK: Download failure

    @Test func downloadFailurePropagatesError() async throws {
        mockShouldFail = true
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        var threw = false
        do {
            _ = try await cache.localPath(for: "https://example.com/fail.mp4", onProgress: { _ in })
        } catch {
            threw = true
        }
        #expect(threw)
    }

    // MARK: clearCache

    @Test func clearCacheRemovesFiles() async throws {
        mockShouldFail = false
        mockResponseData = Data("data".utf8)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        _ = try await cache.localPath(for: "https://example.com/a.mp4", onProgress: { _ in })
        let beforeClear = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!beforeClear.isEmpty)
        try cache.clearCache()
        let afterClear = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(afterClear.isEmpty)
    }
}
