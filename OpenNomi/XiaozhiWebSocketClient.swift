//
//  XiaozhiWebSocketClient.swift
//  OpenNomi
//

import Foundation

protocol XiaozhiWebSocketClientDelegate: AnyObject {
    func webSocketClientDidConnect(_ client: XiaozhiWebSocketClient)
    func webSocketClientDidDisconnect(_ client: XiaozhiWebSocketClient, error: Error?)
    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveSTT text: String)
    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveResponseText text: String)
    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveLLM emotion: String)
    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveTTSState state: String)
    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveAudioData data: Data)
}

@MainActor
class XiaozhiWebSocketClient: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private let urlString: String
    private let token: String
    private let deviceId: String
    private let boardUuid: String
    private var currentSessionId: String?
    private var heartbeatTimer: Timer?
    private var didNotifyDisconnect = false

    weak var delegate: XiaozhiWebSocketClientDelegate?

    init(urlString: String, token: String, deviceId: String, boardUuid: String) {
        self.urlString = urlString
        self.token = token
        self.deviceId = deviceId
        self.boardUuid = boardUuid
        super.init()
    }

    func connect() {
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        if !token.isEmpty {
            let authValue = token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
            request.addValue(authValue, forHTTPHeaderField: "Authorization")
        }
        request.addValue("3", forHTTPHeaderField: "Protocol-Version")
        request.addValue(deviceId, forHTTPHeaderField: "Device-Id")
        request.addValue(boardUuid, forHTTPHeaderField: "Client-Id")
        request.addValue("ESP32-S3-BOX-3/2.2.4", forHTTPHeaderField: "User-Agent")
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        print("WebSocket Connecting to \(urlString)...")
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: request)
        didNotifyDisconnect = false
        webSocketTask?.resume()

        // Heartbeat is started in didOpenWithProtocol
        receiveMessage()
    }

    func disconnect() {
        stopHeartbeat()
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        webSocketTask = nil
        session = nil
    }

    // MARK: - Emitting
    private func sendHello() {
        // Official protocol.cc GetHelloMessage field order:
        // type -> version -> features (aec, mcp) -> transport -> audio_params
        let jsonString = """
        {
            "type": "hello",
            "version": 3,
            "transport": "websocket",
            "features": {
                "mcp": true
            },
            "audio_params": {
                "format": "opus",
                "sample_rate": 16000,
                "channels": 1,
                "frame_duration": 60
            }
        }
        """
        // Remove newlines and extra spaces if needed, although standard parsers should be fine
        let compactJson = jsonString.components(separatedBy: .whitespacesAndNewlines).joined()
        sendMessage(string: compactJson)
    }

    func sendListen(state: String = "start", mode: String = "manual") {
        let sid = currentSessionId ?? ""
        // Official protocol.cc order: session_id -> type -> state -> mode
        let jsonString = "{\"session_id\":\"\(sid)\",\"type\":\"listen\",\"state\":\"\(state)\",\"mode\":\"\(mode)\"}"
        sendMessage(string: jsonString)
    }

    func sendAbort() {
        let sid = currentSessionId ?? ""
        // Official protocol.cc order: session_id -> type
        let jsonString = "{\"session_id\":\"\(sid)\",\"type\":\"abort\"}"
        sendMessage(string: jsonString)
    }

    func sendTextDialogue(text: String) {
        let sid = currentSessionId ?? ""
        // Mimic a wake word detection but with full text payload
        // Official format: {"session_id":"...", "type":"listen", "state":"detect", "text":"..."}
        let jsonString = "{\"session_id\":\"\(sid)\",\"type\":\"listen\",\"state\":\"detect\",\"text\":\"\(text)\"}"
        sendMessage(string: jsonString)
    }

    func sendAudioData(_ data: Data) {
        // Official BinaryProtocol3:
        // uint8_t type (0 for audio)
        // uint8_t reserved (0)
        // uint16_t payload_size (Big-endian)
        // uint8_t payload[]

        let payloadSize = UInt16(data.count)
        var header = Data()
        header.append(0) // type
        header.append(0) // reserved
        header.append(UInt8((payloadSize >> 8) & 0xFF)) // size high
        header.append(UInt8(payloadSize & 0xFF))        // size low

        var fullPacket = header
        fullPacket.append(data)

        let message = URLSessionWebSocketTask.Message.data(fullPacket)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("WebSocket sending audio error: \(error)")
            }
        }
    }

    private func sendMessage(string: String) {
        let message = URLSessionWebSocketTask.Message.string(string)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("WebSocket sending string error: \(error)")
            } else {
                // Successfully sent, reset outgoing idle timer if needed
            }
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        print(">>> XIAOZHI >>> Starting Heartbeat Timer (30s)")
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.sendPing()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendPing() {
        guard isConnected else { return }
        print(">>> XIAOZHI >>> Sending WebSocket Ping")
        webSocketTask?.sendPing { error in
            if let error = error {
                print(">>> XIAOZHI >>> Heartbeat Ping error: \(error)")
            }
        }
    }

    // MARK: - Receiving

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                switch result {
                case .failure(let error):
                    print("WebSocket receiving error: \(error)")
                    self.notifyDisconnected(error: error)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                            self.handleJson(json)
                        } else {
                            print("WebSocket received non-JSON string: \(text)")
                        }
                    case .data(let data):
                        // Check for BinaryProtocol3 header (4 bytes)
                        if data.count > 4 {
                            let pktType = data[0]
                            // payloadSize is part of the header but unused for now
                            _ = (UInt16(data[2]) << 8) | UInt16(data[3])

                            if pktType == 0 { // Audio
                                let audioData = data.advanced(by: 4)
                                // Only call delegate if length matches or we want to ignore framing error for now
                                self.delegate?.webSocketClient(self, didReceiveAudioData: audioData)
                            } else {
                                print(">>> XIAOZHI >>> Received non-audio binary packet (type: \(pktType))")
                            }
                        } else {
                            // Version 1 (no header) or unexpected data
                            self.delegate?.webSocketClient(self, didReceiveAudioData: data)
                        }
                    @unknown default:
                        break
                    }

                    // Continue receiving
                    self.receiveMessage()
                }
            }
        }
    }

    private func handleJson(_ json: [String: Any]) {
        guard let typeString = json["type"] as? String else { return }

        print(">>> XIAOZHI >>> Received JSON: \(typeString)")

        switch typeString {
        case "hello":
            if let sid = json["session_id"] as? String {
                currentSessionId = sid
                print(">>> XIAOZHI >>> Captured Session ID: \(sid)")
            }
            if let audioParams = json["audio_params"] as? [String: Any] {
                print(">>> XIAOZHI >>> Server Audio Params: \(audioParams)")
            }
            delegate?.webSocketClientDidConnect(self)
        case "mcp":
            handleMcp(json)
        case "stt":
            if let text = json["text"] as? String {
                delegate?.webSocketClient(self, didReceiveSTT: text)
            }
        case "llm":
            if let emotion = json["emotion"] as? String {
                delegate?.webSocketClient(self, didReceiveLLM: emotion)
            }
        case "tts":
            if let state = json["state"] as? String {
                delegate?.webSocketClient(self, didReceiveTTSState: state)
            }
            if let text = json["text"] as? String {
                delegate?.webSocketClient(self, didReceiveResponseText: text)
            }
            if let emotion = json["emotion"] as? String {
                delegate?.webSocketClient(self, didReceiveLLM: emotion)
            }
        case "error":
            if let msg = json["message"] as? String {
                print(">>> XIAOZHI >>> Server ERROR: \(msg)")
            }
        default:
            print(">>> XIAOZHI >>> Unknown JSON: \(typeString)")
        }
    }

    private func handleMcp(_ json: [String: Any]) {
        guard let payload = json["payload"] as? [String: Any],
              let method = payload["method"] as? String else {
            print(">>> XIAOZHI >>> Invalid MCP payload structure: \(json)")
            return
        }

        let requestId = payload["id"] as? Int

        if let rid = requestId {
            print(">>> XIAOZHI >>> MCP Request: \(method) (ID: \(rid))")
            if method == "initialize" {
                sendMcpInitializeResponse(requestId: rid)
            } else if method == "tools/list" {
                sendMcpToolsListResponse(requestId: rid)
            } else {
                print(">>> XIAOZHI >>> Unhandled MCP method: \(method)")
            }
        } else {
            // Notification
            print(">>> XIAOZHI >>> MCP Notification: \(method)")
        }
    }

    private func sendMcpToolsListResponse(requestId: Int) {
        let sid = currentSessionId ?? ""
        let result: [String: Any] = [
            "tools": []
        ]

        if let resultData = try? JSONSerialization.data(withJSONObject: result),
           let resultString = String(data: resultData, encoding: .utf8) {
            let mcpPayload = "{\"jsonrpc\":\"2.0\",\"id\":\(requestId),\"result\":\(resultString)}"
            let fullMessage = "{\"session_id\":\"\(sid)\",\"type\":\"mcp\",\"payload\":\(mcpPayload)}"
            sendMessage(string: fullMessage)
            print(">>> XIAOZHI >>> Sent MCP ToolsList Response")
        }
    }

    private func sendMcpInitializeResponse(requestId: Int) {
        let sid = currentSessionId ?? ""
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "OpenNomi", "version": "1.0.0"]
        ]

        if let resultData = try? JSONSerialization.data(withJSONObject: result),
           let resultString = String(data: resultData, encoding: .utf8) {
            let mcpPayload = "{\"jsonrpc\":\"2.0\",\"id\":\(requestId),\"result\":\(resultString)}"
            // Match official protocol.cc pattern
            let fullMessage = "{\"session_id\":\"\(sid)\",\"type\":\"mcp\",\"payload\":\(mcpPayload)}"
            sendMessage(string: fullMessage)
            print(">>> XIAOZHI >>> Sent MCP Init Response")
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let protocolStr = `protocol` ?? "none"
        print(">>> XIAOZHI >>> Connection OPEN (Protocol: \(protocolStr))")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isConnected = true
            self.startHeartbeat()
            // Wait a small amount to ensure stream is ready
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.sendHello()
            self.delegate?.webSocketClientDidConnect(self)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print(">>> XIAOZHI >>> Connection ERROR: \(error)")
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.notifyDisconnected(error: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print(">>> XIAOZHI >>> Connection CLOSED (Code: \(closeCode.rawValue))")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.notifyDisconnected(error: nil)
        }
    }

    private func notifyDisconnected(error: Error?) {
        guard !didNotifyDisconnect else { return }
        didNotifyDisconnect = true
        isConnected = false
        stopHeartbeat()
        webSocketTask = nil
        session = nil
        delegate?.webSocketClientDidDisconnect(self, error: error)
    }
}
