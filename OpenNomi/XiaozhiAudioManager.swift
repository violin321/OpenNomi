//
//  XiaozhiAudioManager.swift
//  OpenNomi
//

import Foundation
import AVFoundation
import Opus

protocol XiaozhiAudioManagerDelegate: AnyObject {
    func audioManager(_ manager: XiaozhiAudioManager, didCaptureAudio data: Data)
    func audioManager(_ manager: XiaozhiAudioManager, didUpdateAudioLevel level: Double)
}

class XiaozhiAudioManager {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioFormat: AVAudioFormat
    private var opusDecoder: Opus.Decoder?
    private var opusEncoder: Opus.Encoder?
    private var pcmAccumulator = Data()
    private let sessionQueue = DispatchQueue(label: "open-nomi.audio-session")
    private var isAudioSessionConfigured = false
    private var hasInputTap = false
    private var wantsRecording = false
    private var isPreparingRecording = false

    weak var delegate: XiaozhiAudioManagerDelegate?

    init() {
        // Xiaozhi uses 16000 Hz, 1 channel, 16-bit PCM (for the "pcm" format we requested)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false) else {
            fatalError("Failed to create audio format")
        }
        self.audioFormat = format

        do {
            // alta/swift-opus typically initializes with an AVAudioFormat
            self.opusDecoder = try Opus.Decoder(format: audioFormat)
            // Initialize encoder for 16kHz mono VOIP
            self.opusEncoder = try Opus.Encoder(format: audioFormat, application: .voip)
        } catch {
            print(">>> XIAOZHI >>> Failed to initialize Opus codec: \(error)")
        }

        setupEngine()
    }

    private func prepareAudioSession(_ completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if self.isAudioSessionConfigured {
                DispatchQueue.main.async {
                    completion(true)
                }
                return
            }

            do {
                let session = AVAudioSession.sharedInstance()
                // .playAndRecord + .defaultToSpeaker should go to bottom speaker.
                try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
                try session.setPreferredSampleRate(16000)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                try session.overrideOutputAudioPort(.speaker)

                self.isAudioSessionConfigured = true
                DispatchQueue.main.async {
                    completion(true)
                }
            } catch {
                print("Failed to setup audio session: \(error)")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }

    private func setupEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
    }

    // MARK: - Input Handle

    func startRecording() {
        guard !hasInputTap, !isPreparingRecording else { return }
        wantsRecording = true
        isPreparingRecording = true
        prepareAudioSession { [weak self] isReady in
            guard let self = self else { return }
            self.isPreparingRecording = false
            guard isReady, self.wantsRecording else { return }
            self.startRecordingWithPreparedSession()
        }
    }

    private func startRecordingWithPreparedSession() {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("Invalid microphone input format: \(inputFormat)")
            wantsRecording = false
            return
        }

        inputNode.removeTap(onBus: 0)
        hasInputTap = false

        // Convert from hardware input format to our desired 16kHz format
        guard let converter = AVAudioConverter(from: inputFormat, to: audioFormat) else {
            print("Failed to create audio converter")
            wantsRecording = false
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] (buffer, time) in
            guard let self = self else { return }

            let capacity = max(1, AVAudioFrameCount(self.audioFormat.sampleRate) * buffer.frameLength / max(1, AVAudioFrameCount(inputFormat.sampleRate)))
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self.audioFormat, frameCapacity: capacity) else { return }

            var error: NSError? = nil
            let status = converter.convert(to: pcmBuffer, error: &error) { packetCount, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .haveData || status == .endOfStream, let channelData = pcmBuffer.int16ChannelData {
                let frameCount = Int(pcmBuffer.frameLength)
                let bytesLength = frameCount * 2
                let data = Data(bytes: channelData[0], count: bytesLength)
                self.reportAudioLevel(samples: channelData[0], frameCount: frameCount)

                self.pcmAccumulator.append(data)

                // 16kHz, 60ms = 960 frames = 1920 bytes
                let targetBytes = 960 * 2
                while self.pcmAccumulator.count >= targetBytes {
                    let chunk = self.pcmAccumulator.prefix(targetBytes)
                    self.pcmAccumulator.removeFirst(targetBytes)

                    if let encoder = self.opusEncoder {
                        do {
                            // Create a temporary buffer for encoding
                            let encodeFormat = self.audioFormat
                            guard let encodeBuffer = AVAudioPCMBuffer(pcmFormat: encodeFormat, frameCapacity: 960) else { return }
                            encodeBuffer.frameLength = 960
                            chunk.withUnsafeBytes { ptr in
                                if let base = ptr.baseAddress, let destination = encodeBuffer.int16ChannelData?[0] {
                                    let count = targetBytes / 2 // Int16 count
                                    destination.initialize(from: base.assumingMemoryBound(to: Int16.self), count: count)
                                }
                            }

                            var opusData = Data(count: 1500)
                            let bytesEncoded = try encoder.encode(encodeBuffer, to: &opusData)
                            let finalOpusData = opusData.prefix(bytesEncoded)
                            self.delegate?.audioManager(self, didCaptureAudio: finalOpusData)
                        } catch {
                            print(">>> XIAOZHI >>> Opus encoding error: \(error)")
                        }
                    } else {
                        // Fallback
                        self.delegate?.audioManager(self, didCaptureAudio: chunk)
                    }
                }
            }
        }
        hasInputTap = true

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            print("Could not start audio engine: \(error)")
        }
    }

    func stopRecording() {
        wantsRecording = false
        isPreparingRecording = false
        let inputNode = audioEngine.inputNode
        if hasInputTap {
            inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        pcmAccumulator = Data()
        delegate?.audioManager(self, didUpdateAudioLevel: 0)
    }

    func invalidateAudioSessionConfiguration() {
        sessionQueue.async { [weak self] in
            self?.isAudioSessionConfigured = false
        }
    }

    // MARK: - Output Handle

    func playAudioData(_ data: Data) {
        prepareAudioSession { [weak self] isReady in
            guard let self = self, isReady else { return }
            self.playAudioDataWithPreparedSession(data)
        }
    }

    private func playAudioDataWithPreparedSession(_ data: Data) {
        // If we have an Opus decoder, assume incoming data is Opus
        if let decoder = opusDecoder {
            do {
                // alta/swift-opus decode returns an AVAudioPCMBuffer directly
                let buffer = try decoder.decode(data)

                let outputGain: Float = 3.8
                if let channelData = buffer.int16ChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        let samples = channelData[channel]
                        if channel == 0 {
                            self.reportAudioLevel(samples: samples, frameCount: Int(buffer.frameLength))
                        }
                        for i in 0..<Int(buffer.frameLength) {
                            let normalized = Float(samples[i]) / Float(Int16.max)
                            let shaped = tanh(normalized * outputGain)
                            samples[i] = Int16(shaped * Float(Int16.max))
                        }
                    }
                }

                if !audioEngine.isRunning {
                    try audioEngine.start()
                }

                if !playerNode.isPlaying {
                    playerNode.play()
                }

                playerNode.scheduleBuffer(buffer, completionHandler: nil)
            } catch {
                print(">>> XIAOZHI >>> Opus decoding error: \(error)")
            }
        } else {
            // Fallback to raw PCM if decoder fails
            guard let buffer = data.toPCMBuffer(format: audioFormat) else { return }
            if let channelData = buffer.int16ChannelData {
                reportAudioLevel(samples: channelData[0], frameCount: Int(buffer.frameLength))
            }

            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    print("Failed to start engine for playback: \(error)")
                }
            }

            if !playerNode.isPlaying {
                playerNode.play()
            }

            playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    func stopPlaying() {
        playerNode.stop()
        delegate?.audioManager(self, didUpdateAudioLevel: 0)
    }

    private func reportAudioLevel(samples: UnsafePointer<Int16>, frameCount: Int) {
        guard frameCount > 0 else { return }

        var sum: Double = 0
        for index in 0..<frameCount {
            let sample = Double(samples[index]) / Double(Int16.max)
            sum += sample * sample
        }

        let rms = sqrt(sum / Double(frameCount))
        let level = min(max(rms * 8, 0), 1)
        delegate?.audioManager(self, didUpdateAudioLevel: level)
    }
}

extension Data {
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCapacity = UInt32(count) / format.streamDescription.pointee.mBytesPerFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCapacity)) else { return nil }

        buffer.frameLength = buffer.frameCapacity
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers

        withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            audioBuffer.mData?.copyMemory(from: baseAddress, byteCount: Int(audioBuffer.mDataByteSize))
        }

        return buffer
    }
}
