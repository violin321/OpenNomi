//
//  WakeWordListener.swift
//  OpenNomi
//

import AVFoundation
import Speech

protocol WakeWordListenerDelegate: AnyObject {
    func wakeWordListenerDidDetectWakeWord(_ listener: WakeWordListener)
    func wakeWordListener(_ listener: WakeWordListener, didFail message: String)
}

final class WakeWordListener {
    weak var delegate: WakeWordListenerDelegate?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private let audioQueue = DispatchQueue(label: "open-nomi.wake-word-audio")
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var wakeWord = ""
    private var isEnabled = false
    private var isListening = false
    private var shouldRestartAfterResult = false

    func configure(wakeWord: String, isEnabled: Bool) {
        self.wakeWord = wakeWord
        self.isEnabled = isEnabled

        if !isEnabled || wakeWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stopListening()
        }
    }

    func startListeningIfNeeded() {
        guard isEnabled,
              !isListening,
              !wakeWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.delegate?.wakeWordListener(self, didFail: "我还不能听唤醒词。请在系统设置里允许语音识别和麦克风权限。")
                return
            }
            self.startRecognition()
        }
    }

    func stopListening() {
        shouldRestartAfterResult = false
        isListening = false
        stopListeningOnAudioQueue(cancelTask: true)
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            DispatchQueue.main.async {
                guard speechStatus == .authorized else {
                    completion(false)
                    return
                }

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
    }

    private func startRecognition() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopAudioEngineOnCurrentQueue()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = self.audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak request] buffer, _ in
                request?.append(buffer)
            }

            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                self.audioEngine.prepare()
                try self.audioEngine.start()

                DispatchQueue.main.async {
                    self.recognitionRequest = request
                    self.isListening = true
                    self.shouldRestartAfterResult = true
                    self.startRecognitionTask(with: request)
                }
            } catch {
                inputNode.removeTap(onBus: 0)
                DispatchQueue.main.async {
                    self.isListening = false
                    self.delegate?.wakeWordListener(self, didFail: "唤醒词监听没有启动成功。")
                }
            }
        }
    }

    private func startRecognitionTask(with request: SFSpeechAudioBufferRecognitionRequest) {
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if self.containsWakeWord(in: text) {
                    self.stopListening()
                    self.delegate?.wakeWordListenerDidDetectWakeWord(self)
                    return
                }
            }

            if error != nil || result?.isFinal == true {
                let shouldRestart = self.shouldRestartAfterResult
                self.stopListening()
                if shouldRestart {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.startListeningIfNeeded()
                    }
                }
            }
        }
    }

    private func stopListeningOnAudioQueue(cancelTask: Bool) {
        if cancelTask {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioQueue.async { [weak self] in
            guard let self = self else { return }
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
            self.audioEngine.inputNode.removeTap(onBus: 0)
            DispatchQueue.main.async {
                self.isListening = false
            }
        }
    }

    private func stopAudioEngineOnCurrentQueue() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.async {
            self.isListening = false
        }
    }

    private func containsWakeWord(in text: String) -> Bool {
        let heardText = normalized(text)
        return wakeWordCandidates.contains { candidate in
            heardText.contains(candidate)
        }
    }

    private var wakeWordCandidates: [String] {
        let target = normalized(wakeWord)
        guard !target.isEmpty else { return [] }

        var candidates = Set([target])
        let nomiAliases = ["nomi", "诺米", "糯米", "诺咪", "no米", "no咪", "n欧米"].map(normalized)
        let greetings = ["你好", "嗨", "嘿", "hello", "hi", ""].map(normalized)

        if target.contains("nomi") || nomiAliases.contains(where: { target.contains($0) }) {
            for greeting in greetings {
                for alias in nomiAliases {
                    candidates.insert(greeting + alias)
                }
            }
        }

        return Array(candidates).filter { !$0.isEmpty }
    }

    private func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}
