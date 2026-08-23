//
//  SettingsView.swift
//  OpenNomi
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: XiaozhiViewModel

    @AppStorage("xiaozhiWebSocketURL") private var webSocketURL: String = "wss://api.tenclass.net/xiaozhi/v1/"
    @AppStorage("xiaozhiConsoleURL") private var consoleURL: String = "https://xiaozhi.me/console/agents"
    @AppStorage("xiaozhiWakeWordEnabled") private var isWakeWordEnabled: Bool = true
    @AppStorage("xiaozhiWakeWord") private var wakeWord: String = "你好诺米"
    @AppStorage("xiaozhiContinuousConversationEnabled") private var isContinuousConversationEnabled: Bool = false
    @AppStorage("xiaozhiDeviceToken") private var deviceToken: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingResetConfirmation = false

    private let rowBackground = Color.white.opacity(0.08)
    private let switchTint = Color(red: 0.35, green: 0.82, blue: 0.58)
    private let pageBackground = Color.black.opacity(0.94)
    private let warningTint = Color(red: 1.0, green: 0.69, blue: 0.28)

    private var connectionStatus: String {
        if viewModel.isConnected {
            return "\(viewModel.connectionPhase.statusText) · \(viewModel.conversationPhase.statusText)"
        }
        return viewModel.connectionPhase.statusText
    }

    private var statusColor: Color {
        switch viewModel.connectionPhase {
        case .connected:
            return .green
        case .bootstrapping, .connecting, .pairing:
            return .yellow
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: viewModel.isConnected ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .frame(width: 30)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(connectionStatus)
                                .font(.headline)
                            if let detail = viewModel.connectionPhase.detailText, !viewModel.isConnected {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    connectionButton
                }
                .listRowBackground(rowBackground)

                Section("对话方式") {
                    Toggle(isOn: $isContinuousConversationEnabled) {
                        Label("连续对话", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .tint(switchTint)
                    Text(isContinuousConversationEnabled ? "NOMI 会自动听完你的停顿，并在说完后继续听下一句。" : "关闭时，每轮对话需要手动开始，或用唤醒词重新叫醒 NOMI。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(rowBackground)

                Section("唤醒词") {

                    Toggle(isOn: $isWakeWordEnabled) {
                        Label("听唤醒词", systemImage: "ear.fill")
                    }
                    .tint(switchTint)

                    LabeledContent {
                        TextField("你好诺米", text: $wakeWord)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                    } label: {
                        Label("唤醒词", systemImage: "quote.bubble.fill")
                    }
                    .disabled(!isWakeWordEnabled)
                    .opacity(isWakeWordEnabled ? 1.0 : 0.45)

                    Text("建议说“你好诺米”。NOMI、诺米、糯米等常见识别结果都会尝试匹配。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(rowBackground)

                Section {
                    NavigationLink {
                        resetPairingView
                    } label: {
                        Label("重新配对", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .disabled(viewModel.connectionPhase.isBusy)

                    NavigationLink {
                        advancedSettingsView
                    } label: {
                        Label("高级设置", systemImage: "slider.horizontal.3")
                    }
                }
                .listRowBackground(rowBackground)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(pageBackground)
            .environment(\.colorScheme, .dark)
            .navigationTitle("OpenNomi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(pageBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(switchTint)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .tint(.white)
                }
            }
            .onChange(of: webSocketURL) { _, _ in
                if viewModel.isConnected || viewModel.connectionPhase.isBusy {
                    viewModel.disconnect()
                }
                syncWatchSettings()
            }
            .onChange(of: deviceToken) { _, _ in
                if viewModel.isConnected || viewModel.connectionPhase.isBusy {
                    viewModel.disconnect()
                }
            }
            .onChange(of: isWakeWordEnabled) { _, _ in
                viewModel.updateWakeWordSettings()
                syncWatchSettings()
            }
            .onChange(of: wakeWord) { _, _ in
                viewModel.updateWakeWordSettings()
                syncWatchSettings()
            }
            .onChange(of: isContinuousConversationEnabled) { _, _ in
                viewModel.updateWakeWordSettings()
                syncWatchSettings()
            }
            .onChange(of: consoleURL) { _, _ in
                syncWatchSettings()
            }
            .onAppear {
                syncWatchSettings()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var resetPairingView: some View {
        Form {
            Section("重新认识你") {
                Label("NOMI 会换一个新的身份。", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(warningTint)

                Text("下一次唤醒时，它会重新念出验证码，并显示在字幕里。打开绑定页面填入验证码后，回到主界面点“我已完成”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(rowBackground)

            Section {
                Button(role: .destructive) {
                    isShowingResetConfirmation = true
                } label: {
                    Label("让 NOMI 重新配对", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(warningTint)
                .disabled(viewModel.connectionPhase.isBusy)
            }
            .listRowBackground(rowBackground)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(pageBackground)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .navigationTitle("重新配对")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(pageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(switchTint)
        .confirmationDialog("确认重新配对？", isPresented: $isShowingResetConfirmation, titleVisibility: .visible) {
            Button("重新配对", role: .destructive) {
                viewModel.resetDeviceIdentity()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("NOMI 会换一个新的身份，之后需要重新输入验证码。")
        }
    }

    private var advancedSettingsView: some View {
        Form {
            Section("连接到哪里") {
                LabeledContent {
                    TextField("wss://...", text: $webSocketURL, axis: .vertical)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label("服务地址", systemImage: "network")
                }

                LabeledContent {
                    SecureField("可留空", text: $deviceToken)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label("Token", systemImage: "key.fill")
                }

                Button {
                    webSocketURL = "wss://api.tenclass.net/xiaozhi/v1/"
                } label: {
                    Label("恢复官方地址", systemImage: "arrow.counterclockwise")
                }
                .tint(switchTint)
            }
            .listRowBackground(rowBackground)

            Section("在哪里填验证码") {
                LabeledContent {
                    TextField("https://...", text: $consoleURL, axis: .vertical)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label("绑定页面", systemImage: "safari.fill")
                }

                if let url = URL(string: consoleURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Link(destination: url) {
                        Label("打开绑定页面", systemImage: "arrow.up.forward.app.fill")
                    }
                    .tint(switchTint)
                }

                Button {
                    consoleURL = "https://xiaozhi.me/console/agents"
                } label: {
                    Label("恢复官方绑定页面", systemImage: "arrow.counterclockwise")
                }
                .tint(switchTint)
            }
            .listRowBackground(rowBackground)

            Section("NOMI 的身份") {
                LabeledContent {
                    Text(viewModel.shortDeviceId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label("设备 ID", systemImage: "iphone.gen3")
                }

                LabeledContent {
                    Text(viewModel.shortBoardUuid)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label("UUID", systemImage: "number")
                }
            }
            .listRowBackground(rowBackground)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(pageBackground)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .navigationTitle("高级设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(pageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(switchTint)
    }

    private func syncWatchSettings() {
        WatchSyncManager.shared.activate()
        WatchSyncManager.shared.syncSettings(
            webSocketURL: webSocketURL,
            consoleURL: consoleURL,
            wakeWord: wakeWord,
            isWakeWordEnabled: isWakeWordEnabled,
            isContinuousConversationEnabled: isContinuousConversationEnabled
        )
    }

    @ViewBuilder
    private var connectionButton: some View {
        if viewModel.isConnected {
            Button(role: .destructive) {
                viewModel.disconnect()
            } label: {
                Label("让 NOMI 休息", systemImage: "power")
            }
        } else {
            Button {
                viewModel.retryConnection()
            } label: {
                Label(viewModel.connectionPhase.isBusy ? "正在唤醒" : "唤醒 NOMI", systemImage: "bolt.horizontal.circle.fill")
            }
            .disabled(viewModel.connectionPhase.isBusy)
        }
    }
}

#Preview {
    SettingsView(viewModel: XiaozhiViewModel())
}
