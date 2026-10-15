import Foundation

@main
struct ConnectionRegression {
    static func main() throws {
        let ota = try XiaozhiServerConfiguration.parse("  http://100.106.157.3:18062/xiaozhi/ota/\n")
        precondition(ota.bootstrapURL?.absoluteString == "http://100.106.157.3:18062/xiaozhi/ota/")
        precondition(ota.audioProtocol == .rawOpus)
        let root = try XiaozhiServerConfiguration.parse("https://voice.example:8443")
        precondition(root.bootstrapURL?.absoluteString == "https://voice.example:8443/xiaozhi/ota/")

        let direct = try XiaozhiServerConfiguration.parse("ws://100.106.157.3:18060/xiaozhi/v1/")
        precondition(direct.bootstrapURL == nil)
        precondition(direct.audioProtocol == .rawOpus)
        let official = try XiaozhiServerConfiguration.parse("wss://api.tenclass.net/xiaozhi/v1/")
        precondition(official.bootstrapURL?.absoluteString == "https://api.tenclass.net/xiaozhi/ota/")
        precondition(official.audioProtocol == .framedOpus)
        let lookalike = try XiaozhiServerConfiguration.parse("wss://tenclass.net.example/xiaozhi/v1/")
        precondition(lookalike.bootstrapURL == nil && lookalike.audioProtocol == .rawOpus)

        for invalid in ["", "hello", "ftp://example/", "ws:///xiaozhi/v1/", "https://user:secret@example/"] {
            do {
                _ = try XiaozhiServerConfiguration.parse(invalid)
                preconditionFailure("Accepted an invalid service address")
            } catch { }
        }

        // Actual OVH replies start with 0x6b. The old client dropped these
        // packets because it treated that first byte as a v3 message type.
        let opus = Data([0x6b, 0x41, 0x22, 0x13, 0xff, 0xaa])
        precondition(XiaozhiAudioProtocol.rawOpus.encodeAudio(opus) == opus)
        precondition(XiaozhiAudioProtocol.rawOpus.decodeAudio(opus) == opus)
        let framed = Data([0, 0, 0, 6]) + opus
        precondition(XiaozhiAudioProtocol.framedOpus.encodeAudio(opus) == framed)
        precondition(XiaozhiAudioProtocol.framedOpus.decodeAudio(framed) == opus)
        precondition(XiaozhiAudioProtocol.framedOpus.decodeAudio(Data([0, 0, 0, 7]) + opus) == nil)
        precondition(XiaozhiAudioProtocol.framedOpus.decodeAudio(Data([1, 0, 0, 6]) + opus) == nil)
        precondition(XiaozhiAudioProtocol.framedOpus.decodeAudio(Data([0, 0, 0])) == nil)
        precondition(XiaozhiAudioProtocol.rawOpus.decodeAudio(Data()) == nil)
        precondition(XiaozhiAudioProtocol.framedOpus.encodeAudio(Data(count: 65_536)) == nil)
        print("PASS: OTA routing, official routing, address validation, raw Opus and v3 framing")
    }
}
