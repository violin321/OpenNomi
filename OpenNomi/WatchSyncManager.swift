//
//  WatchSyncManager.swift
//  OpenNomi
//

import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

final class WatchSyncManager: NSObject {
    static let shared = WatchSyncManager()

    static let primaryActionCommand = "primaryAction"
    static let disconnectCommand = "disconnect"
    static let refreshCommand = "refresh"
    static let bootstrapWatchCommand = "bootstrapWatch"
    static let relayTextCommand = "relayText"

    private let webSocketURLKey = "xiaozhiWebSocketURL"
    private let consoleURLKey = "xiaozhiConsoleURL"
    private let wakeWordKey = "xiaozhiWakeWord"
    private let wakeWordEnabledKey = "xiaozhiWakeWordEnabled"
    private let continuousConversationKey = "xiaozhiContinuousConversationEnabled"
    private let watchCommandKey = "watchCommand"
    private let connectionPhaseKey = "xiaozhiConnectionPhase"
    private let conversationPhaseKey = "xiaozhiConversationPhase"
    private let moodKey = "xiaozhiMood"
    private let statusTextKey = "xiaozhiStatusText"
    private let audioLevelKey = "xiaozhiAudioLevel"
    private let relayTextKey = "relayText"
    private let watchDeviceIdKey = "watchDeviceId"
    private let watchBoardUuidKey = "watchBoardUuid"

    private var currentSettings: [String: Any] = [:]
    private var currentStatus: [String: Any] = [:]

    var commandHandler: ((String) -> Void)?
    var textRelayHandler: ((String) -> Void)?

    private override init() {
        super.init()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    func syncCurrentSettingsFromStorage() {
        let defaults = UserDefaults.standard
        syncSettings(
            webSocketURL: defaults.string(forKey: webSocketURLKey) ?? "wss://api.tenclass.net/xiaozhi/v1/",
            consoleURL: defaults.string(forKey: consoleURLKey) ?? "https://xiaozhi.me/console/agents",
            wakeWord: defaults.string(forKey: wakeWordKey) ?? "你好诺米",
            isWakeWordEnabled: defaults.object(forKey: wakeWordEnabledKey) as? Bool ?? true,
            isContinuousConversationEnabled: defaults.object(forKey: continuousConversationKey) as? Bool ?? false
        )
    }

    func syncSettings(
        webSocketURL: String,
        consoleURL: String,
        wakeWord: String,
        isWakeWordEnabled: Bool,
        isContinuousConversationEnabled: Bool
    ) {
        currentSettings = [
            webSocketURLKey: webSocketURL,
            consoleURLKey: consoleURL,
            wakeWordKey: wakeWord,
            wakeWordEnabledKey: isWakeWordEnabled,
            continuousConversationKey: isContinuousConversationEnabled
        ]
        sendCurrentContext()
    }

    func syncStatus(
        connectionPhase: XiaozhiConnectionPhase,
        conversationPhase: XiaozhiConversationPhase,
        mood: NomiMood,
        audioLevel: Double
    ) {
        currentStatus = [
            connectionPhaseKey: connectionPhase.watchValue,
            conversationPhaseKey: conversationPhase.watchValue,
            moodKey: mood.watchValue,
            statusTextKey: conversationPhase == .idle ? connectionPhase.statusText : conversationPhase.statusText,
            audioLevelKey: audioLevel
        ]
        sendCurrentContext(shouldSendLiveMessage: true)
    }

    private func sendCurrentContext(shouldSendLiveMessage: Bool = true) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let payload = currentSettings.merging(currentStatus) { _, latest in latest }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        do {
            try session.updateApplicationContext(payload)
        } catch {
            print("Failed to sync watch settings: \(error.localizedDescription)")
        }

        if shouldSendLiveMessage && session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("Failed to send live watch settings: \(error.localizedDescription)")
            }
        }
        #endif
    }
}

private extension NomiMood {
    var watchValue: String {
        switch self {
        case .idle:
            return "idle"
        case .talking:
            return "talking"
        case .loading:
            return "loading"
        case .sleep:
            return "sleep"
        case .lookLeft:
            return "lookLeft"
        case .lookRight:
            return "lookRight"
        case .scan:
            return "scan"
        case .strive:
            return "strive"
        case .focus:
            return "focus"
        case .drowsy:
            return "drowsy"
        case .happy:
            return "happy"
        case .sad:
            return "sad"
        case .surprise:
            return "surprise"
        case .curious:
            return "curious"
        case .wink:
            return "wink"
        case .error:
            return "error"
        }
    }
}

private extension XiaozhiConnectionPhase {
    var watchValue: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .bootstrapping:
            return "bootstrapping"
        case .connecting:
            return "connecting"
        case .pairing:
            return "pairing"
        case .connected:
            return "connected"
        case .failed:
            return "failed"
        }
    }
}

private extension XiaozhiConversationPhase {
    var watchValue: String {
        switch self {
        case .idle:
            return "idle"
        case .listening:
            return "listening"
        case .thinking:
            return "thinking"
        case .speaking:
            return "speaking"
        }
    }
}

#if canImport(WatchConnectivity)
extension WatchSyncManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            syncCurrentSettingsFromStorage()
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchMessage(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleWatchMessage(userInfo)
    }

    private func handleWatchMessage(_ message: [String: Any]) {
        guard let command = message[watchCommandKey] as? String else { return }
        DispatchQueue.main.async {
            if command == Self.relayTextCommand,
               let text = message[self.relayTextKey] as? String {
                self.textRelayHandler?(text)
            } else {
                self.commandHandler?(command)
            }
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let command = message[watchCommandKey] as? String else {
            replyHandler(["error": "未知请求"])
            return
        }

        if command == Self.bootstrapWatchCommand {
            Task {
                let response = await bootstrapWatchDevice(message)
                replyHandler(response)
            }
        } else if command == Self.relayTextCommand {
            guard let text = message[relayTextKey] as? String else {
                replyHandler(["error": "没有收到内容"])
                return
            }
            DispatchQueue.main.async {
                self.textRelayHandler?(text)
            }
            replyHandler(["ok": true])
        } else {
            DispatchQueue.main.async {
                self.commandHandler?(command)
            }
            replyHandler(["ok": true])
        }
    }

    private func bootstrapWatchDevice(_ message: [String: Any]) async -> [String: Any] {
        guard let deviceId = message[watchDeviceIdKey] as? String,
              let boardUuid = message[watchBoardUuidKey] as? String,
              let url = URL(string: "https://api.tenclass.net/xiaozhi/ota/") else {
            return ["error": "手表身份不完整"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(deviceId, forHTTPHeaderField: "Device-Id")
        request.addValue(boardUuid, forHTTPHeaderField: "Client-Id")
        request.addValue("1", forHTTPHeaderField: "Activation-Version")
        request.addValue("ESP32-S3-BOX-3/2.2.4", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "version": 2,
            "mac_address": deviceId,
            "uuid": boardUuid,
            "chip_model_name": "esp32s3",
            "application": [
                "name": "xiaozhi",
                "version": "2.2.4"
            ],
            "ota": ["label": "ota_0"],
            "board": ["type": "box-3"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            let urlSession = URLSession(configuration: configuration)
            let (data, response) = try await urlSession.data(for: request)
            urlSession.invalidateAndCancel()

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return ["error": "设备登记失败 \((response as? HTTPURLResponse)?.statusCode ?? 0)"]
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let websocket = json["websocket"] as? [String: Any],
                  let urlString = websocket["url"] as? String else {
                return ["error": "没有拿到服务入口"]
            }

            var responsePayload: [String: Any] = [
                "ok": true,
                "url": urlString,
                "token": websocket["token"] as? String ?? ""
            ]
            if let activation = json["activation"] as? [String: Any],
               let code = activation["code"] as? String {
                responsePayload["activationCode"] = code
            }
            return responsePayload
        } catch {
            return ["error": "iPhone 代登记失败"]
        }
    }
}
#endif
