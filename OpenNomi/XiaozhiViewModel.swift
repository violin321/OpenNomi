//
//  XiaozhiViewModel.swift
//  OpenNomi
//

import SwiftUI
import Combine
import AVFoundation

enum XiaozhiConnectionPhase: Equatable {
    case disconnected
    case bootstrapping
    case connecting
    case pairing
    case connected
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .bootstrapping, .connecting:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .disconnected:
            return "点击按钮唤醒 NOMI"
        case .bootstrapping:
            return "NOMI 正在醒来"
        case .connecting:
            return "正在靠近你"
        case .pairing:
            return "需要你帮忙完成配对"
        case .connected:
            return "NOMI 醒着"
        case .failed:
            return "NOMI 睡着了"
        }
    }

    var detailText: String? {
        switch self {
        case .disconnected:
            return "点一下下方按钮，它会尝试醒来。"
        case .bootstrapping:
            return "正在整理自己的小身份。"
        case .connecting:
            return "马上就能听见你了。"
        case .pairing:
            return "它会念出验证码，也会显示在字幕里。打开绑定页面填好后，点“我已完成”。"
        case .connected:
            return nil
        case .failed(let message):
            return message.nomiFriendlyErrorMessage
        }
    }
}

private extension String {
    var nomiFriendlyErrorMessage: String {
        let lowercasedMessage = lowercased()

        if lowercasedMessage.contains("cancelled") || lowercasedMessage.contains("canceled") {
            return "刚刚没醒成功，点一下按钮再唤醒它。"
        }
        if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
            return "它醒得有点慢，确认网络正常后再点一下唤醒。"
        }
        if lowercasedMessage.contains("network connection was lost") {
            return "网络刚刚断了一下，点一下按钮让它重新醒来。"
        }
        if lowercasedMessage.contains("could not connect") || lowercasedMessage.contains("cannot connect") {
            return "暂时叫不醒 NOMI，稍后再点一下唤醒。"
        }
        if lowercasedMessage.contains("not connected to the internet") {
            return "现在没有网络，连上网络后再唤醒 NOMI。"
        }
        if lowercasedMessage.contains("ssl") || lowercasedMessage.contains("secure connection") {
            return "这次没有安全连上服务，稍后再唤醒它。"
        }
        if lowercasedMessage.contains("unsupported url") || lowercasedMessage.contains("bad url") {
            return "服务地址可能不太对，可以去高级设置看一眼。"
        }

        if unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) {
            return self
        }

        return "NOMI 暂时没醒过来，稍后再点一下唤醒。"
    }
}

enum XiaozhiConversationPhase: Equatable {
    case idle
    case listening
    case thinking
    case speaking

    var statusText: String {
        switch self {
        case .idle:
            return "我在这儿"
        case .listening:
            return "我在认真听"
        case .thinking:
            return "让我想一想"
        case .speaking:
            return "我在回应你"
        }
    }

    var iconName: String {
        switch self {
        case .idle:
            return "mic.slash.fill"
        case .listening:
            return "mic.fill"
        case .thinking:
            return "brain.head.profile"
        case .speaking:
            return "speaker.wave.2.fill"
        }
    }
}

class XiaozhiViewModel: ObservableObject, XiaozhiWebSocketClientDelegate, XiaozhiAudioManagerDelegate, WakeWordListenerDelegate {
    @Published var currentMood: NomiMood = .idle
    @Published var isConnected: Bool = false
    @Published var conversationPhase: XiaozhiConversationPhase = .idle
    @Published var connectionPhase: XiaozhiConnectionPhase = .disconnected
    @Published var spokenText: String = ""
    @Published var aiResponseText: String = ""
    @Published var inputText: String = ""
    @Published var pairingCode: String?
    @Published var audioLevel: Double = 0

    private var webSocketClient: XiaozhiWebSocketClient?
    private let audioManager = XiaozhiAudioManager()
    private let wakeWordListener = WakeWordListener()
    private var connectionGeneration = 0
    private var hasCompletedPairingForCurrentIdentity = false
    private var lastAnnouncedPairingCode: String?
    private var pendingPairingConfirmationCode: String?
    private var hasDetectedSpeechInCurrentTurn = false
    private var lastVoiceActivityAt: Date?
    private var autoStopTimer: AnyCancellable?
    private var isTextOnlyConversationTurn = false
    private var suppressIncomingAudioUntil = Date.distantPast

    @AppStorage("xiaozhiWebSocketURL") private var webSocketURL: String = "wss://api.tenclass.net/xiaozhi/v1/"
    @AppStorage("xiaozhiConsoleURL") var consoleURL: String = "https://xiaozhi.me/console/agents"
    @AppStorage("xiaozhiWakeWordEnabled") var isWakeWordEnabled: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("xiaozhiWakeWord") var wakeWord: String = "你好诺米" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("xiaozhiContinuousConversationEnabled") var isContinuousConversationEnabled: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("xiaozhiDeviceToken") private var deviceToken: String = ""
    @AppStorage("xiaozhiDeviceId") private var deviceId: String = ""
    @AppStorage("xiaozhiBoardUuid") private var boardUuid: String = ""
    @AppStorage("xiaozhiHasConnected") var hasConnectedKey: Bool = false {
        willSet { objectWillChange.send() }
    }

    private var cancellables = Set<AnyCancellable>()
    private var idleActionTimer: AnyCancellable?

    var isListening: Bool {
        conversationPhase == .listening
    }

    var canToggleListening: Bool {
        isConnected && connectionPhase != .pairing
    }

    var canSendTextConversation: Bool {
        isConnected && connectionPhase != .pairing
    }

    var deviceIdentitySummary: String {
        "\(deviceId) / \(boardUuid)"
    }

    var shortDeviceId: String {
        deviceId
    }

    var shortBoardUuid: String {
        guard boardUuid.count > 13 else { return boardUuid }
        return "\(boardUuid.prefix(8))...\(boardUuid.suffix(4))"
    }

    init() {
        audioManager.delegate = self
        wakeWordListener.delegate = self
        if deviceId.isEmpty {
            let macParts = (0..<6).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
            deviceId = macParts.joined(separator: ":")
        }
        if boardUuid.isEmpty {
            boardUuid = UUID().uuidString.lowercased()
        }

        setupIdleActionTimer()
        setupWakeWordListener()
        setupWatchStatusSync()
        WatchSyncManager.shared.commandHandler = { [weak self] command in
            self?.handleWatchCommand(command)
        }
        WatchSyncManager.shared.textRelayHandler = { [weak self] text in
            self?.sendTextFromWatch(text)
        }
        WatchSyncManager.shared.activate()
    }

    private func setupWakeWordListener() {
        updateWakeWordSettings()
        Publishers.CombineLatest($connectionPhase, $conversationPhase)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshWakeWordListening()
            }
            .store(in: &cancellables)
    }

    private func setupWatchStatusSync() {
        Publishers.CombineLatest4($connectionPhase, $conversationPhase, $currentMood, $audioLevel)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { connectionPhase, conversationPhase, currentMood, audioLevel in
                WatchSyncManager.shared.syncStatus(
                    connectionPhase: connectionPhase,
                    conversationPhase: conversationPhase,
                    mood: currentMood,
                    audioLevel: audioLevel
                )
            }
            .store(in: &cancellables)
    }

    func updateWakeWordSettings() {
        wakeWordListener.configure(wakeWord: wakeWord, isEnabled: isWakeWordEnabled)
        refreshWakeWordListening()
    }

    private func refreshWakeWordListening() {
        let canListenForWakeWord = isWakeWordEnabled &&
        !wakeWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !connectionPhase.isBusy &&
        connectionPhase != .pairing &&
        conversationPhase == .idle

        if canListenForWakeWord {
            wakeWordListener.startListeningIfNeeded()
        } else {
            wakeWordListener.stopListening()
        }
    }

    private func scheduleWakeWordRestartAfterSpeech() {
        guard isWakeWordEnabled else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self,
                  self.conversationPhase == .idle,
                  self.connectionPhase == .connected else { return }

            self.audioManager.stopPlaying()
            self.audioManager.invalidateAudioSessionConfiguration()
            self.refreshWakeWordListening()
        }
    }

    private func scheduleContinuousListeningAfterSpeech() {
        guard isContinuousConversationEnabled else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self = self,
                  self.isConnected,
                  self.connectionPhase == .connected,
                  self.conversationPhase == .idle else { return }

            self.audioManager.stopPlaying()
            self.audioManager.invalidateAudioSessionConfiguration()
            self.startListening()
        }
    }

    private func startAutoStopTimerIfNeeded() {
        stopAutoStopTimer()
        guard isContinuousConversationEnabled else { return }

        autoStopTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkAutoStopListening()
            }
    }

    private func stopAutoStopTimer() {
        autoStopTimer?.cancel()
        autoStopTimer = nil
    }

    private func updateVoiceActivity(level: Double) {
        guard conversationPhase == .listening,
              isContinuousConversationEnabled else { return }

        if level > 0.08 {
            hasDetectedSpeechInCurrentTurn = true
            lastVoiceActivityAt = Date()
        }
    }

    private func checkAutoStopListening() {
        guard conversationPhase == .listening,
              hasDetectedSpeechInCurrentTurn,
              let lastVoiceActivityAt else { return }

        if Date().timeIntervalSince(lastVoiceActivityAt) > 1.2 {
            stopListening()
        }
    }

    private func setupIdleActionTimer() {
        idleActionTimer = Timer.publish(every: 8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.performRandomIdleAction()
            }
    }

    private func performRandomIdleAction() {
        guard isConnected && conversationPhase == .idle && currentMood == .idle else { return }

        // 30% chance to look around briefly
        if Double.random(in: 0...1) < 0.3 {
            let nextMood: NomiMood = Bool.random() ? .lookLeft : .lookRight
            self.currentMood = nextMood

            // Return to idle after 1.5 - 2.5 seconds
            let duration = Double.random(in: 1.5...2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                if self.currentMood == nextMood {
                    self.currentMood = .idle
                }
            }
        }
    }

    func connect() {
        guard !isConnected, !connectionPhase.isBusy else { return }
        let trimmedURL = webSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            connectionPhase = .failed("我还不知道要去哪里。请先在高级设置里确认服务地址。")
            currentMood = .error
            return
        }
        let configuration: XiaozhiServerConfiguration
        do {
            configuration = try XiaozhiServerConfiguration.parse(trimmedURL)
        } catch {
            connectionPhase = .failed(error.localizedDescription)
            currentMood = .error
            return
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        pairingCode = nil
        aiResponseText = ""
        connectionPhase = .connecting
        currentMood = .loading

        if let otaURL = configuration.bootstrapURL {
            connectionPhase = .bootstrapping
            Task {
                await bootstrapAndConnect(otaURL: otaURL, audioProtocol: configuration.audioProtocol, generation: generation)
            }
        } else {
            performConnect(urlString: configuration.url.absoluteString, token: deviceToken, deviceId: deviceId, boardUuid: boardUuid, audioProtocol: configuration.audioProtocol, generation: generation)
        }
    }

    private func bootstrapAndConnect(otaURL: URL, audioProtocol: XiaozhiAudioProtocol, generation: Int) async {
        print(">>> XIAOZHI >>> Starting device bootstrap")

        var request = URLRequest(url: otaURL)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(deviceId, forHTTPHeaderField: "Device-Id")
        request.addValue(boardUuid, forHTTPHeaderField: "Client-Id")
        request.addValue("1", forHTTPHeaderField: "Activation-Version")
        request.addValue("ESP32-S3-BOX-3/2.2.4", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print(">>> XIAOZHI >>> Starting Bootstrap...")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print(">>> XIAOZHI >>> Bootstrap FAILED (Status: \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                await MainActor.run {
                    self.failConnection("设备登记没完成，检查网络后再唤醒 NOMI。", generation: generation)
                }
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let websocket = json["websocket"] as? [String: Any],
               let urlString = websocket["url"] as? String {
                let token = websocket["token"] as? String ?? ""
                let selectedProtocol: XiaozhiAudioProtocol
                if let version = websocket["version"] as? Int {
                    guard let supportedProtocol = XiaozhiAudioProtocol(rawValue: version) else {
                        await MainActor.run {
                            self.failConnection("服务器要求的语音协议版本暂不支持：\(version)。", generation: generation)
                        }
                        return
                    }
                    selectedProtocol = supportedProtocol
                } else {
                    selectedProtocol = audioProtocol
                }

                print(">>> XIAOZHI >>> Bootstrap successful (audio protocol \(selectedProtocol.rawValue))")

                var activationCode: String?
                if let activation = json["activation"] as? [String: Any],
                   let code = activation["code"] as? String {
                    print(">>> XIAOZHI >>> Activation is required")
                    activationCode = code
                } else {
                    print(">>> XIAOZHI >>> No activation code found (already bound?)")
                }

                Task { @MainActor in
                    guard generation == self.connectionGeneration else { return }
                    if let activationCode {
                        self.hasCompletedPairingForCurrentIdentity = false
                        self.pairingCode = activationCode
                        self.connectionPhase = .pairing
                        self.currentMood = .lookLeft
                        if self.pendingPairingConfirmationCode == activationCode {
                            self.aiResponseText = "我还没找到你的绑定。请确认服务端已输入验证码 \(activationCode)，然后再点“我已完成”。"
                        }
                    } else {
                        self.hasCompletedPairingForCurrentIdentity = true
                        self.pendingPairingConfirmationCode = nil
                        self.connectionPhase = .connecting
                    }
                    self.hasConnectedKey = activationCode == nil
                    self.performConnect(urlString: urlString, token: token, deviceId: deviceId, boardUuid: boardUuid, audioProtocol: selectedProtocol, generation: generation)
                }
            } else {
                await MainActor.run {
                    self.failConnection("服务返回的数据不完整，无法建立连接。", generation: generation)
                }
            }
        } catch {
            print(">>> XIAOZHI >>> Bootstrap error: \(error)")
            await MainActor.run {
                self.failConnection("连接 OTA 服务失败：\(error.localizedDescription.nomiFriendlyErrorMessage)", generation: generation)
            }
        }
    }

    private func performConnect(urlString: String, token: String, deviceId: String, boardUuid: String, audioProtocol: XiaozhiAudioProtocol, generation: Int) {
        guard generation == connectionGeneration else { return }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme), url.host != nil else {
            connectionPhase = .failed("WebSocket 地址无效，请在设置中检查。")
            currentMood = .error
            return
        }

        print(">>> XIAOZHI >>> Starting WebSocket connection")
        if pairingCode == nil {
            connectionPhase = .connecting
        }
        webSocketClient = XiaozhiWebSocketClient(urlString: urlString, token: token, deviceId: deviceId, boardUuid: boardUuid, audioProtocol: audioProtocol)
        webSocketClient?.delegate = self
        webSocketClient?.connect()
    }

    func disconnect() {
        connectionGeneration += 1
        stopAutoStopTimer()
        closeCurrentClient()
        isConnected = false
        conversationPhase = .idle
        connectionPhase = .disconnected
        pairingCode = nil
        audioLevel = 0
        audioManager.stopRecording()

        DispatchQueue.main.async {
            self.currentMood = .idle
        }
    }

    func toggleListening() {
        guard canToggleListening else { return }
        switch conversationPhase {
        case .listening:
            stopListening()
        case .thinking:
            stopTalkingAndAbort()
        case .idle, .speaking:
            startListening()
        }
    }

    private func handleWatchCommand(_ command: String) {
        if command == WatchSyncManager.refreshCommand {
            syncWatchNow()
            return
        }

        if command == WatchSyncManager.disconnectCommand {
            disconnect()
            syncWatchNow()
            return
        }

        guard command == WatchSyncManager.primaryActionCommand else { return }

        switch connectionPhase {
        case .disconnected, .failed:
            retryConnection()
            return
        default:
            break
        }

        toggleListening()
    }

    private func syncWatchNow() {
        WatchSyncManager.shared.syncCurrentSettingsFromStorage()
        WatchSyncManager.shared.syncStatus(
            connectionPhase: connectionPhase,
            conversationPhase: conversationPhase,
            mood: currentMood,
            audioLevel: audioLevel
        )
    }

    private func startListening() {
        guard isConnected else { return }
        wakeWordListener.stopListening()
        audioManager.invalidateAudioSessionConfiguration()
        requestMicrophonePermissionIfNeeded { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.beginListening()
            } else {
            self.connectionPhase = .failed("我还听不见你。请在系统设置里允许 OpenNomi 使用麦克风。")
                self.currentMood = .error
            }
        }
    }

    private func beginListening() {
        guard isConnected else { return }

        if conversationPhase == .speaking || conversationPhase == .thinking {
            stopTalkingAndAbort()
        }
        finishTextOnlyTurn()
        completePairingIfNeeded()

        conversationPhase = .listening
        spokenText = ""
        aiResponseText = ""
        hasDetectedSpeechInCurrentTurn = false
        lastVoiceActivityAt = nil
        startAutoStopTimerIfNeeded()

        DispatchQueue.main.async {
            self.currentMood = .scan
        }

        webSocketClient?.sendListen(state: "start", mode: "manual")
        audioManager.startRecording()
    }

    private func stopListening() {
        guard conversationPhase == .listening else { return }
        stopAutoStopTimer()
        conversationPhase = .thinking

        DispatchQueue.main.async {
            self.currentMood = .strive // Thinking
        }

        audioManager.stopRecording()
        audioLevel = 0
        webSocketClient?.sendListen(state: "stop", mode: "manual")
        refreshWakeWordListening()
    }

    func sendTextConversation() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendTextConversation, !text.isEmpty else { return }

        // Interrupt current talking if any
        stopTalkingAndAbort()
        completePairingIfNeeded()
        beginTextOnlyTurn()
        conversationPhase = .thinking
        currentMood = .strive

        print(">>> XIAOZHI >>> Sending text dialogue")
        webSocketClient?.sendTextDialogue(text: text)
        inputText = ""
    }

    private func sendTextFromWatch(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if !isConnected || connectionPhase == .disconnected {
            retryConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.canSendTextConversation else { return }
                self.sendRelayedText(trimmedText)
            }
            return
        }

        guard canSendTextConversation else { return }
        sendRelayedText(trimmedText)
    }

    private func sendRelayedText(_ text: String) {
        stopTalkingAndAbort()
        completePairingIfNeeded()
        beginTextOnlyTurn()
        conversationPhase = .thinking
        currentMood = .strive
        aiResponseText = ""
        spokenText = text
        webSocketClient?.sendTextDialogue(text: text)
    }

    private func stopTalkingAndAbort() {
        // Explicitly send abort to server
        webSocketClient?.sendAbort()
        // Stop local playback immediately
        audioManager.stopPlaying()
        // Reset mood
        conversationPhase = .idle
        audioLevel = 0
        currentMood = .idle
        stopAutoStopTimer()
        refreshWakeWordListening()
    }

    private func beginTextOnlyTurn() {
        isTextOnlyConversationTurn = true
        suppressIncomingAudioUntil = Date.distantFuture
        stopAutoStopTimer()
    }

    private func finishTextOnlyTurn() {
        isTextOnlyConversationTurn = false
        suppressIncomingAudioUntil = Date().addingTimeInterval(5)
        stopAutoStopTimer()
    }

    // MARK: - XiaozhiWebSocketClientDelegate

    func webSocketClientDidConnect(_ client: XiaozhiWebSocketClient) {
        DispatchQueue.main.async {
            guard client === self.webSocketClient else { return }
            let isWaitingForPairing = self.pairingCode != nil
            self.isConnected = true
            self.connectionPhase = isWaitingForPairing ? .pairing : .connected
            self.conversationPhase = .idle
            self.hasConnectedKey = !isWaitingForPairing
            self.currentMood = isWaitingForPairing ? .lookLeft : .happy
            self.requestPairingAnnouncementIfNeeded()

            // Revert to idle after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self.currentMood == .happy && self.conversationPhase == .idle {
                    self.currentMood = .idle
                }
            }
        }
    }

    func webSocketClientDidDisconnect(_ client: XiaozhiWebSocketClient, error: Error?) {
        DispatchQueue.main.async {
            guard client === self.webSocketClient else { return }
            self.isConnected = false
            self.conversationPhase = .idle
            self.audioLevel = 0
            self.stopAutoStopTimer()
            self.finishTextOnlyTurn()
            self.audioManager.stopRecording()

            if let error {
                self.connectionPhase = .failed(error.localizedDescription.nomiFriendlyErrorMessage)
                self.currentMood = .error
            } else {
                self.connectionPhase = .disconnected
                self.currentMood = .idle
            }
        }
    }

    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveSTT text: String) {
        DispatchQueue.main.async {
            if self.isTextOnlyConversationTurn {
                self.checkForPairingCode(in: text)
                return
            }
            self.spokenText = text
            self.conversationPhase = .thinking
            self.checkForPairingCode(in: text)
        }
    }

    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveResponseText text: String) {
        DispatchQueue.main.async {
            self.aiResponseText = text
            self.spokenText = "" // Clear user text when AI responds
            if self.isTextOnlyConversationTurn {
                self.webSocketClient?.sendAbort()
                self.audioManager.stopPlaying()
                self.suppressIncomingAudioUntil = Date().addingTimeInterval(30)
                self.conversationPhase = .idle
                self.audioLevel = 0
                self.currentMood = .idle
                return
            }
            if self.conversationPhase != .speaking {
                self.conversationPhase = .thinking
            }
        }
    }

    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveLLM emotion: String) {
        DispatchQueue.main.async {
            let mappedMood = self.mapEmotionToMood(emotion)
            self.currentMood = mappedMood
            print(">>> XIAOZHI >>> AI Emotion: \(emotion) -> \(mappedMood)")
        }
    }

    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveTTSState state: String) {
        DispatchQueue.main.async {
            if self.isTextOnlyConversationTurn {
                self.audioManager.stopPlaying()
                self.audioLevel = 0
                return
            }

            if state == "start" {
                self.conversationPhase = .speaking
                self.currentMood = .talking
            } else if state == "stop" {
                self.conversationPhase = .idle
                self.audioLevel = 0
                if self.isContinuousConversationEnabled {
                    self.scheduleContinuousListeningAfterSpeech()
                } else {
                    self.scheduleWakeWordRestartAfterSpeech()
                }
                // Reset to idle expression when finishing speech
                self.currentMood = .idle
            }
        }
    }

    private func checkForPairingCode(in text: String) {
        guard !hasCompletedPairingForCurrentIdentity else { return }
        if text.contains("配对码") || text.contains("验证码") {
            let digits = text.filter { $0.isNumber }
            if digits.count >= 6 {
                self.pairingCode = String(digits.suffix(6))
                self.connectionPhase = .pairing
                self.requestPairingAnnouncementIfNeeded()
            }
        }
    }

    func webSocketClient(_ client: XiaozhiWebSocketClient, didReceiveAudioData data: Data) {
        if isTextOnlyConversationTurn || Date() < suppressIncomingAudioUntil {
            return
        }
        audioManager.playAudioData(data)
    }

    // MARK: - XiaozhiAudioManagerDelegate

    func audioManager(_ manager: XiaozhiAudioManager, didCaptureAudio data: Data) {
        if conversationPhase == .listening {
            webSocketClient?.sendAudioData(data)
        }
    }

    func audioManager(_ manager: XiaozhiAudioManager, didUpdateAudioLevel level: Double) {
        DispatchQueue.main.async {
            if self.conversationPhase == .listening || self.conversationPhase == .speaking {
                let visualLevel = min(level, 0.65)
                self.audioLevel = (self.audioLevel * 0.7) + (visualLevel * 0.3)
                self.updateVoiceActivity(level: level)
            } else {
                self.audioLevel = 0
            }
        }
    }

    // MARK: - Helpers

    private func mapEmotionToMood(_ emotion: String) -> NomiMood {
        switch emotion.lowercased() {
        case "happy", "joy": return .happy
        case "sad": return .sad
        case "angry", "strive": return .strive
        case "surprised", "surprise": return .surprise
        case "confused", "curious": return .curious
        case "focus", "processing", "thinking": return .focus
        case "sleep", "dream": return .sleep
        default: return .idle
        }
    }

    func retryConnection() {
        disconnect()
        connect()
    }

    func resetDeviceIdentity() {
        disconnect()
        let macParts = (0..<6).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        deviceId = macParts.joined(separator: ":")
        boardUuid = UUID().uuidString.lowercased()
        deviceToken = ""
        hasConnectedKey = false
        hasCompletedPairingForCurrentIdentity = false
        lastAnnouncedPairingCode = nil
        pendingPairingConfirmationCode = nil
        connectionPhase = .disconnected
        conversationPhase = .idle
        currentMood = .idle
        aiResponseText = ""
        spokenText = ""
        pairingCode = nil
        audioLevel = 0
    }

    func confirmPairingAndReconnect() {
        guard connectionPhase == .pairing else { return }
        pendingPairingConfirmationCode = pairingCode
        pairingCode = nil
        hasCompletedPairingForCurrentIdentity = true
        closeCurrentClient()
        isConnected = false
        conversationPhase = .idle
        audioLevel = 0
        connect()
    }

    @MainActor
    private func failConnection(_ message: String, generation: Int? = nil) {
        if let generation, generation != connectionGeneration { return }
        stopAutoStopTimer()
        closeCurrentClient()
        isConnected = false
        conversationPhase = .idle
        connectionPhase = .failed(message.nomiFriendlyErrorMessage)
        audioLevel = 0
        currentMood = .error
    }

    private func completePairingIfNeeded() {
        guard pairingCode != nil, isConnected else { return }
        pairingCode = nil
        hasCompletedPairingForCurrentIdentity = true
        hasConnectedKey = true
        connectionPhase = .connected
    }

    private func requestPairingAnnouncementIfNeeded() {
        guard let pairingCode,
              isConnected,
              !hasCompletedPairingForCurrentIdentity,
              lastAnnouncedPairingCode != pairingCode else { return }

        lastAnnouncedPairingCode = pairingCode
        aiResponseText = "验证码 \(pairingCode)。我会念给你听，填好后点“我已完成”。"
        webSocketClient?.sendTextDialogue(text: "请播报配对码 \(pairingCode)")
    }

    private func closeCurrentClient() {
        webSocketClient?.delegate = nil
        webSocketClient?.disconnect()
        webSocketClient = nil
    }

    // MARK: - WakeWordListenerDelegate

    func wakeWordListenerDidDetectWakeWord(_ listener: WakeWordListener) {
        audioManager.invalidateAudioSessionConfiguration()
        aiResponseText = "我醒啦。"
        currentMood = .happy

        if !isConnected {
            connect()
        } else if conversationPhase == .idle && connectionPhase == .connected {
            startListening()
        }
    }

    func wakeWordListener(_ listener: WakeWordListener, didFail message: String) {
        guard isWakeWordEnabled else { return }
        connectionPhase = .failed(message.nomiFriendlyErrorMessage)
        currentMood = .sad
    }

    private func requestMicrophonePermissionIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                await MainActor.run {
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }
}
