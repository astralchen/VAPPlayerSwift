// VAPMP4ParserTests.swift
import Testing
import Foundation
@testable import VAPPlayer

@Suite("VAPMP4Parser")
struct VAPMP4ParserTests {

    // MARK: - Byte utilities

    @Test func readU32BE_basic() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(VAPMP4Parser.readU32BE(data, offset: 0) == 0x01020304)
    }

    @Test func readU32BE_withOffset() {
        let data = Data([0x00, 0x00, 0xAB, 0xCD, 0xEF, 0x01])
        #expect(VAPMP4Parser.readU32BE(data, offset: 2) == 0xABCDEF01)
    }

    @Test func readU32BE_outOfBounds() {
        let data = Data([0x01, 0x02])
        #expect(VAPMP4Parser.readU32BE(data, offset: 0) == 0)
    }

    @Test func readU64BE_basic() {
        let data = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        #expect(VAPMP4Parser.readU64BE(data, offset: 0) == 0x0000000100000000)
    }

    @Test func readU16BE_basic() {
        let data = Data([0x12, 0x34])
        #expect(VAPMP4Parser.readU16BE(data, offset: 0) == 0x1234)
    }

    // MARK: - Box tree helpers

    @Test func boxFirstChild_found() {
        let child1 = VAPMP4Box(type: "mdhd", payload: .unknown)
        let child2 = VAPMP4Box(type: "hdlr", payload: .unknown)
        let parent = VAPMP4Box(type: "mdia", payload: .container, children: [child1, child2])
        #expect(parent.firstChild(type: "hdlr")?.type == "hdlr")
    }

    @Test func boxFirstChild_notFound() {
        let parent = VAPMP4Box(type: "mdia", payload: .container)
        #expect(parent.firstChild(type: "stbl") == nil)
    }

    @Test func boxAllChildren_count() {
        let a = VAPMP4Box(type: "trak", payload: .container)
        let b = VAPMP4Box(type: "trak", payload: .container)
        let c = VAPMP4Box(type: "udta", payload: .container)
        let moov = VAPMP4Box(type: "moov", payload: .container, children: [a, b, c])
        #expect(moov.allChildren(type: "trak").count == 2)
        #expect(moov.allChildren(type: "udta").count == 1)
        #expect(moov.allChildren(type: "mdia").count == 0)
    }

    @Test func boxBfsFirst_deep() {
        let stbl = VAPMP4Box(type: "stbl", payload: .container)
        let minf = VAPMP4Box(type: "minf", payload: .container, children: [stbl])
        let mdia = VAPMP4Box(type: "mdia", payload: .container, children: [minf])
        let trak = VAPMP4Box(type: "trak", payload: .container, children: [mdia])
        #expect(trak.bfsFirst(type: "stbl")?.type == "stbl")
        #expect(trak.bfsFirst(type: "moov") == nil)
    }

    // MARK: - Payload pattern matching

    @Test func mvhdPayload() {
        let box = VAPMP4Box(type: "mvhd", payload: .mvhd(timeScale: 1000, duration: 50000))
        guard case .mvhd(let ts, let dur) = box.payload else { Issue.record("wrong payload"); return }
        #expect(ts == 1000)
        #expect(dur == 50000)
    }

    @Test func hdlrPayload() {
        let box = VAPMP4Box(type: "hdlr", payload: .hdlr(handlerType: "vide"))
        guard case .hdlr(let ht) = box.payload else { Issue.record("wrong payload"); return }
        #expect(ht == "vide")
    }

    @Test func sttsPayload() {
        let entries = [VAPMP4Payload.SttsEntry(count: 100, delta: 512)]
        let box = VAPMP4Box(type: "stts", payload: .stts(entries: entries))
        guard case .stts(let e) = box.payload else { Issue.record("wrong payload"); return }
        #expect(e.count == 1)
        #expect(e[0].count == 100)
        #expect(e[0].delta == 512)
    }

    @Test func avcCPayload() {
        var avcC = VAPAvcCData()
        avcC.sps = [Data([0x67, 0x42])]
        avcC.pps = [Data([0x68, 0xCE])]
        let box = VAPMP4Box(type: "avcC", payload: .avcC(avcC))
        guard case .avcC(let d) = box.payload else { Issue.record("wrong payload"); return }
        #expect(d.sps.count == 1)
        #expect(d.pps.count == 1)
    }

    @Test func vapcPayload() {
        let json = Data("{\"test\":1}".utf8)
        let box = VAPMP4Box(type: "vapc", payload: .vapc(jsonData: json))
        guard case .vapc(let data) = box.payload else { Issue.record("wrong payload"); return }
        #expect(data == json)
    }

    @Test func parseMissingFile() {
        #expect(throws: (any Error).self) {
            try VAPMP4Parser.parse(filePath: "/nonexistent/file.mp4")
        }
    }
}
