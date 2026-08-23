//
//  XiaozhiModels.swift
//  OpenNomi
//

import Foundation

// MARK: - Handshake Models

struct XiaozhiHelloMessage: Codable, Sendable {
    let type: String
    let version: Int?
    let features: [String: Bool]?
    let transport: String?
    let audio_params: XiaozhiAudioParams?
    var session_id: String?
}

struct XiaozhiAudioParams: Codable, Sendable {
    let format: String
    let sample_rate: Int
    let channels: Int
    let frame_duration: Int
}

// MARK: - State / Control Models

struct XiaozhiListenMessage: Codable, Sendable {
    let session_id: String?
    let type: String       // "listen"
    let state: String      // "start", "stop", "detect"
    let mode: String?      // "auto", "manual", "realtime"
}

struct XiaozhiAbortMessage: Codable, Sendable {
    let session_id: String?
    let type: String       // "abort"
}

// MARK: - Server Response Models

struct XiaozhiServerMessage: Codable, Sendable {
    let type: String
    let session_id: String?
    let text: String?      // For "stt", "tts sentence_start"
    let state: String?     // For "tts" (start, stop)
    let emotion: String?   // For "llm"
}

enum XiaozhiMessageType: String {
    case hello = "hello"
    case stt = "stt"
    case llm = "llm"
    case tts = "tts"
    case system = "system"
    case custom = "custom"
    case listen = "listen"
    case abort = "abort"
    case mcp = "mcp"
}
