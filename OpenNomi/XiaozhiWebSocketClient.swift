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
    private let audioProtocol: XiaozhiAudioProtocol
    private var currentSessionId: String?
    private var heartbeatTimer: Timer?
    private var didNotifyDisconnect = false
    private var connectionTimeoutTask: Task<Void, Never>?

    weak var delegate: XiaozhiWebSocketClientDelegate?

    init(urlString: String, token: String, deviceId: String, boardUuid: String, audioProtocol: XiaozhiAudioProtocol) {
        self.urlString = urlString
        self.token = token
        self.deviceId = deviceId
        self.boardUuid = boardUuid
        self.audioProtocol = audioProtocol
        super.init()
    }

    func connect() {
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        if !token.isEmpty {
            let authValue = token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
            request.addValue(authValue, forHTTPHeaderField: "Authorization")
        }
        request.addValue(String(audioProtocol.rawValue), forHTTPHeaderField: "Protocol-Version")
        request.addValue(deviceId, forHTTPHeaderField: "Device-Id")
        request.addValue(boardUuid, forHTTPHeaderField: "Client-Id")
        request.addValue("ESP32-S3-BOX-3/2.2.4", forHTTPHeaderField: "User-Agent")
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        print("WebSocket connecting (audio protocol \(audioProtocol.rawValue))")
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: request)
        didNotifyDisconnect = false
        webSocketTask?.resume()
        connectionTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, !self.isConnected, !Task.isCancelled else { return }
            self.notifyDisconnected(error: XiaozhiServerConfiguration.connectionError(
                "连接超时，请检查服务器地址、Token 和手机的 Tailscale 连接。"))
        }

        // Heartbeat is started in didOpenWithProtocol
        receiveMessage()
    }

    func disconnect() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
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
            "version": \(audioProtocol.rawValue),
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
        let message = ["session_id": sid, "type": "listen", "state": "detect", "text": text]
        if let data = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: data, encoding: .utf8) {
            sendMessage(string: jsonString)
        }
    }

    func sendAudioData(_ data: Data) {
        guard let fullPacket = audioProtocol.encodeAudio(data) else { return }
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
                        if let audio = self.audioProtocol.decodeAudio(data) {
                            self.delegate?.webSocketClient(self, didReceiveAudioData: audio)
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
            guard let sid = json["session_id"] as? String, !sid.isEmpty, !isConnected else { return }
            currentSessionId = sid
            isConnected = true
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
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
                notifyDisconnected(error: XiaozhiServerConfiguration.connectionError(msg))
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
            self.startHeartbeat()
            // Wait a small amount to ensure stream is ready
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !self.didNotifyDisconnect else { return }
            self.sendHello()
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
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        isConnected = false
        stopHeartbeat()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        webSocketTask = nil
        session = nil
        delegate?.webSocketClientDidDisconnect(self, error: error)
    }
}
