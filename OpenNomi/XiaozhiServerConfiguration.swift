import Foundation

enum XiaozhiAudioProtocol: Int {
    case rawOpus = 1
    case framedOpus = 3

    func encodeAudio(_ payload: Data) -> Data? {
        guard self == .framedOpus else { return payload }
        guard let size = UInt16(exactly: payload.count) else { return nil }
        return Data([0, 0, UInt8(size >> 8), UInt8(size & 0xff)]) + payload
    }

    func decodeAudio(_ packet: Data) -> Data? {
        guard self == .framedOpus else { return packet.isEmpty ? nil : packet }
        let bytes = [UInt8](packet)
        guard bytes.count > 4, bytes[0] == 0,
              (Int(bytes[2]) << 8 | Int(bytes[3])) == bytes.count - 4 else { return nil }
        return Data(bytes.dropFirst(4))
    }
}

struct XiaozhiServerConfiguration {
    let url: URL
    let bootstrapURL: URL?
    let audioProtocol: XiaozhiAudioProtocol

    static func parse(_ address: String) throws -> Self {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              ["ws", "wss", "http", "https"].contains(scheme) else {
            throw connectionError("服务地址无效，请填写 http/https OTA 地址或 ws/wss WebSocket 地址。")
        }
        parts.scheme = scheme
        parts.fragment = nil
        let normalizedHost = host.lowercased()
        let isOfficial = normalizedHost == "tenclass.net" || normalizedHost.hasSuffix(".tenclass.net") ||
            normalizedHost == "xiaozhi.me" || normalizedHost.hasSuffix(".xiaozhi.me")
        let audioProtocol: XiaozhiAudioProtocol = isOfficial ? .framedOpus : .rawOpus

        if scheme == "http" || scheme == "https" {
            if parts.path.isEmpty || parts.path == "/" {
                parts.path = "/xiaozhi/ota/"
            }
            guard let url = parts.url else { throw connectionError("OTA 地址无效。") }
            return Self(url: url, bootstrapURL: url, audioProtocol: audioProtocol)
        }
        guard let url = parts.url else { throw connectionError("WebSocket 地址无效。") }
        let bootstrapURL = isOfficial ? URL(string: "https://api.tenclass.net/xiaozhi/ota/") : nil
        return Self(url: url, bootstrapURL: bootstrapURL, audioProtocol: audioProtocol)
    }

    static func connectionError(_ message: String) -> NSError {
        NSError(domain: "OpenNomi.Connection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
