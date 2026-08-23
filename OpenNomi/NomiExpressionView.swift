import SwiftUI
import Combine
import CoreMotion
import AudioToolbox

// --- 表情状态定义 ---
enum NomiMood: String, CaseIterable, Identifiable {
    case idle = "待机"
    case talking = "说话"
    case loading = "连接"
    case sleep = "休眠"
    case lookLeft = "左看"
    case lookRight = "右看"
    case scan = "扫视"
    case strive = "发力"
    case focus = "聚焦"
    case drowsy = "犯困"
    case happy = "开心"
    case sad = "难过"
    case surprise = "惊讶"
    case curious = "好奇"
    case wink = "调皮"
    case error = "故障"

    var id: String { self.rawValue }

    var icon: String {
        switch self {
        case .idle: return "house.fill"
        case .talking: return "mic.fill"
        case .loading: return "arrow.2.circlepath"
        case .sleep: return "moon.stars.fill"
        case .lookLeft: return "arrow.left"
        case .lookRight: return "arrow.right"
        case .scan: return "eye.viewfinder"
        case .strive: return "bolt.fill"
        case .focus: return "scope"
        case .drowsy: return "moon.zzz.fill"
        case .happy: return "face.smiling.fill"
        case .sad: return "face.dashed.fill"
        case .surprise: return "bolt.circle.fill"
        case .curious: return "questionmark.circle.fill"
        case .wink: return "eye.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }
}

struct NomiExpressionView: View {
    @StateObject private var viewModel = XiaozhiViewModel()
    @StateObject private var parallax = MotionParallaxController()
    @StateObject private var keyboard = KeyboardObserver()
    @Environment(\.verticalSizeClass) var verticalSizeClass

    @State private var isBlinking: Bool = false
    @State private var breathingOffset: CGFloat = 0
    @State private var showSettings: Bool = false
    @State private var lifeMood: NomiMood?
    @State private var lastInteractionAt = Date()
    @State private var isAwakeIntroFinished = false
    @State private var isEnteringRest = false
    @State private var isResting = false
    @State private var sleepTransitionProgress: CGFloat = 0
    @State private var facePulse: CGFloat = 1.0
    @State private var phaseStartedAt = Date()
    @State private var warmthUntil = Date.distantPast
    @State private var nextBlinkAt = Date()

    let blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    let lifeTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        ZStack {
            // 背景
            Color.black.ignoresSafeArea()
                .onTapGesture {
                    hideKeyboard()
                }

            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .onAppear {
            startBreathing()
            scheduleNextBlink()
            startWakeUpIntro()
            parallax.isLandscape = isLandscape
            parallax.start()
            // Disable idle timer to prevent screen sleep
            UIApplication.shared.isIdleTimerDisabled = true
            // Auto connect if previously connected
            if viewModel.hasConnectedKey && !viewModel.isConnected {
                viewModel.connect()
            }
        }
        .onDisappear {
            // Re-enable idle timer
            UIApplication.shared.isIdleTimerDisabled = false
            parallax.stop()
        }
        .onReceive(blinkTimer) { _ in
            triggerBlinkIfNeeded()
        }
        .onReceive(lifeTimer) { _ in
            performIdleLifeBeat()
        }
        .onChange(of: isLandscape) { _, isLandscape in
            parallax.isLandscape = isLandscape
        }
        .onChange(of: viewModel.conversationPhase) { oldPhase, newPhase in
            markInteraction()
            handleConversationTransition(from: oldPhase, to: newPhase)
        }
        .onChange(of: viewModel.connectionPhase) { oldPhase, newPhase in
            markInteraction()
            handleConnectionTransition(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - 竖屏布局 (Portrait)
    var portraitLayout: some View {
        VStack {
            // 顶部状态栏
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text("OPENNOMI")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .opacity(0.3)

                Spacer()

                Button(action: {
                    HapticFeedback.touch()
                    showSettings = true
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.001))
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .opacity(0.5)
                    }
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .offset(y: keyboard.isVisible ? 10 : 0)
            .animation(.easeOut(duration: keyboard.animationDuration), value: keyboard.isVisible)

            Spacer()

            nomiFaceArea(scale: 1.0)

            Spacer()

            if shouldShowStatusPanel {
                statusPanel
            } else {
                Spacer().frame(height: 34)
            }

            portraitSubtitleArea

            controlPanel
                .offset(y: keyboard.isVisible ? -30 : 0)
                .animation(.easeOut(duration: keyboard.animationDuration), value: keyboard.isVisible)
        }
    }

    // MARK: - 横屏 HMI 布局 (Landscape)
    var landscapeLayout: some View {
        ZStack {
            // 全屏点击响应
            Color.black.opacity(0.001)
                .onTapGesture {
                    if viewModel.isConnected {
                        performPrimaryAction()
                    } else if !viewModel.connectionPhase.isBusy {
                        viewModel.connect()
                    }
                }

            VStack(spacing: 5) {
                Group {
                    if viewModel.isConnected {
                        Text(landscapeStatusText)
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(landscapeStatusColor)
                    } else if viewModel.connectionPhase.isBusy {
                        Text("CONNECTING...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow.opacity(0.8))
                    } else if case .failed = viewModel.connectionPhase {
                        Text("TAP TO WAKE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                    } else if !viewModel.isConnected {
                        Text("TAP TO CONNECT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        Text("READY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.2))
                    }
                }
                .padding(.top, 10)

                Spacer(minLength: 0)

                nomiFaceArea(scale: 1.8)

                Spacer(minLength: 12)

                if !viewModel.aiResponseText.isEmpty {
                    Text(viewModel.aiResponseText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 60)
                        .frame(minHeight: 44)
                        .padding(.bottom, 34)
                        .lineLimit(2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer().frame(height: 78)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 通用组件抽离

    private func nomiFaceArea(scale: CGFloat) -> some View {
        let spacingMultiplier: CGFloat = isLandscape ? 1.05 : 1.0
        return TimelineView(.animation) { timeline in
            let date = timeline.date.timeIntervalSinceReferenceDate
            let mood = visibleMood
            ZStack {
                // 扩散的“抚摸”点击区域
                Color.white.opacity(0.001)
                    .frame(width: 400 * scale, height: 200 * scale)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        markInteraction()
                        HapticFeedback.touch()
                        if !viewModel.isConnected {
                            if !viewModel.connectionPhase.isBusy {
                                viewModel.connect()
                            }
                        } else if isLandscape {
                            // 横屏下点击脸部也可触发录音
                            performPrimaryAction()
                        }
                    }

                HStack(spacing: (mood == .loading ? 20 : eyeSpacing(for: mood)) * scale * spacingMultiplier) {
                    EyeView(isRight: false, mood: mood, isBlinking: isBlinking, time: date, activityLevel: viewModel.audioLevel, expression: expressionState(at: timeline.date), sleepProgress: sleepTransitionProgress)
                    EyeView(isRight: true, mood: mood, isBlinking: isBlinking, time: date, activityLevel: viewModel.audioLevel, expression: expressionState(at: timeline.date), sleepProgress: sleepTransitionProgress)
                }
                .scaleEffect(scale * facePulse)
            }
            .animation(.spring(response: 0.62, dampingFraction: 0.86), value: mood)
            .offset(x: parallax.transform.offset.width * scale, y: ((mood == .idle || mood == .drowsy || mood == .sleep || mood == .curious) ? (breathingOffset * scale) : 0) + parallax.transform.offset.height * scale)
            .rotation3DEffect(.degrees(parallax.transform.tilt.width), axis: (x: 0, y: 1, z: 0), perspective: 0.7)
            .rotation3DEffect(.degrees(parallax.transform.tilt.height), axis: (x: 1, y: 0, z: 0), perspective: 0.7)
            .rotationEffect(.degrees(mood == .loading ? date * 180 : 0))
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(primaryStatusText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
            }

            if let detail = secondaryStatusText {
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 32)
            }
            if viewModel.connectionPhase == .pairing,
               let url = URL(string: viewModel.consoleURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Link(destination: url) {
                    Label("打开绑定页面", systemImage: "safari.fill")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.22))
                .padding(.top, 4)
            }
            if case .failed = viewModel.connectionPhase {
                Button(action: {
                    viewModel.retryConnection()
                }) {
                    Label("唤醒 NOMI", systemImage: "bolt.horizontal.circle.fill")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.25))
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 12)
    }

    private var primaryStatusText: String {
        if viewModel.isConnected && viewModel.conversationPhase != .idle {
            return viewModel.conversationPhase.statusText
        }
        return viewModel.connectionPhase.statusText
    }

    private var secondaryStatusText: String? {
        if viewModel.isConnected {
            return viewModel.connectionPhase == .pairing ? viewModel.connectionPhase.detailText : nil
        }
        return viewModel.connectionPhase.detailText
    }

    private var shouldShowStatusPanel: Bool {
        if viewModel.connectionPhase == .connected && viewModel.conversationPhase == .idle {
            return false
        }
        return true
    }

    private var statusColor: Color {
        switch viewModel.connectionPhase {
        case .connected:
            return .green
        case .bootstrapping, .connecting, .pairing:
            return .yellow
        case .failed:
            return .white.opacity(0.45)
        case .disconnected:
            return .white.opacity(0.35)
        }
    }

    private var landscapeStatusText: String {
        if viewModel.connectionPhase == .pairing {
            return "PAIRING"
        }
        switch viewModel.conversationPhase {
        case .idle:
            return "READY"
        case .listening:
            return "LISTENING..."
        case .thinking:
            return "THINKING..."
        case .speaking:
            return "SPEAKING..."
        }
    }

    private var landscapeStatusColor: Color {
        switch viewModel.conversationPhase {
        case .idle:
            return .white.opacity(0.2)
        case .listening:
            return .red
        case .thinking:
            return .yellow.opacity(0.85)
        case .speaking:
            return .green.opacity(0.85)
        }
    }

    // 呼吸动画逻辑
    private func startBreathing() {
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            breathingOffset = 6
        }
    }

    private func startWakeUpIntro() {
        guard !isAwakeIntroFinished else { return }
        isAwakeIntroFinished = true
        lifeMood = .sleep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            lifeMood = .curious
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            lifeMood = .happy
            warmthUntil = Date().addingTimeInterval(1.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
            lifeMood = nil
        }
    }

    private func triggerBlinkIfNeeded() {
        guard Date() >= nextBlinkAt else { return }
        scheduleNextBlink()
        triggerBlink()
    }

    private func scheduleNextBlink() {
        let interval = Double.random(in: 2.8...6.4)
        nextBlinkAt = Date().addingTimeInterval(interval)
    }

    // 眨眼逻辑
    private func triggerBlink() {
        let nonBlinkStates: [NomiMood] = [.error, .scan, .drowsy, .sleep, .loading, .strive]
        guard !nonBlinkStates.contains(visibleMood) else { return }

        withAnimation(.easeInOut(duration: 0.09)) {
            isBlinking = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.1...0.16)) {
            withAnimation(.easeOut(duration: 0.14)) {
                isBlinking = false
            }
        }
    }

    private func performIdleLifeBeat() {
        guard canPlayIdleLifeBeat else { return }
        let idleSeconds = Date().timeIntervalSince(lastInteractionAt)

        if idleSeconds > 90 {
            enterRestingMood()
            return
        }

        guard !isResting else { return }

        let candidates: [NomiMood] = idleSeconds > 30 ? [.lookLeft, .lookRight, .curious, .wink, .focus] : [.lookLeft, .lookRight, .wink]
        if Double.random(in: 0...1) < 0.56, let mood = candidates.randomElement() {
            setTemporaryLifeMood(mood, duration: mood == .wink ? 0.75 : Double.random(in: 1.8...3.2))
        }
    }

    private var canPlayIdleLifeBeat: Bool {
        !viewModel.connectionPhase.isBusy &&
        viewModel.connectionPhase != .pairing &&
        viewModel.conversationPhase == .idle &&
        (viewModel.currentMood == .idle || viewModel.currentMood == .sleep || viewModel.currentMood == .happy)
    }

    private func setTemporaryLifeMood(_ mood: NomiMood, duration: Double) {
        if (isResting || isEnteringRest) && mood != .sleep { return }
        lifeMood = mood
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if lifeMood == mood {
                lifeMood = nil
            }
        }
    }

    private func enterRestingMood() {
        guard !isResting, !isEnteringRest else { return }
        isEnteringRest = true
        lifeMood = .drowsy
        withAnimation(.easeInOut(duration: 2.6)) {
            sleepTransitionProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard isEnteringRest, lifeMood == .drowsy else { return }
            isResting = true
            isEnteringRest = false
            lifeMood = .sleep
        }
    }

    private func markInteraction() {
        lastInteractionAt = Date()
        if isResting || isEnteringRest || lifeMood == .sleep || lifeMood == .drowsy {
            isEnteringRest = false
            isResting = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                sleepTransitionProgress = 0
            }
            warmthUntil = Date().addingTimeInterval(1.4)
            setTemporaryLifeMood(.curious, duration: 1.0)
        }
    }

    private func handleConnectionTransition(from oldPhase: XiaozhiConnectionPhase, to newPhase: XiaozhiConnectionPhase) {
        guard oldPhase != newPhase else { return }

        switch newPhase {
        case .connected:
            HapticFeedback.success()
            isResting = false
            setTemporaryLifeMood(.happy, duration: 1.4)
            pulseFace(to: 1.06, duration: 0.18)
        case .pairing:
            isResting = false
            setTemporaryLifeMood(.curious, duration: 1.8)
        case .failed:
            HapticFeedback.warning()
            enterRestingMood()
        case .disconnected:
            enterRestingMood()
        case .bootstrapping, .connecting:
            isResting = false
            lifeMood = nil
        }
    }

    private func handleConversationTransition(from oldPhase: XiaozhiConversationPhase, to newPhase: XiaozhiConversationPhase) {
        guard oldPhase != newPhase else { return }
        phaseStartedAt = Date()

        switch newPhase {
        case .listening:
            HapticFeedback.listen()
            isResting = false
            lifeMood = nil
            pulseFace(to: 1.04, duration: 0.14)
        case .thinking:
            isResting = false
            lifeMood = nil
        case .speaking:
            isResting = false
            lifeMood = nil
            pulseFace(to: 1.03, duration: 0.16)
        case .idle:
            if oldPhase == .speaking {
                warmthUntil = Date().addingTimeInterval(2.4)
                HapticFeedback.soft()
                setTemporaryLifeMood(.happy, duration: 1.2)
                pulseFace(to: 1.04, duration: 0.16)
            }
        }
    }

    private func pulseFace(to scale: CGFloat, duration: Double) {
        withAnimation(.spring(response: duration, dampingFraction: 0.72)) {
            facePulse = scale
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                facePulse = 1.0
            }
        }
    }

    private func expressionState(at date: Date) -> NomiExpressionState {
        let elapsed = date.timeIntervalSince(phaseStartedAt)
        let warmth = max(0, min(1, warmthUntil.timeIntervalSince(date) / 2.4))

        switch viewModel.conversationPhase {
        case .listening:
            let attention = min(1, 0.72 + viewModel.audioLevel * 0.38)
            return NomiExpressionState(mode: .listening, attention: attention, energy: 0.78, warmth: warmth, phaseElapsed: elapsed)
        case .thinking:
            return NomiExpressionState(mode: .thinking, attention: 0.88, energy: min(1, 0.62 + elapsed * 0.08), warmth: warmth, phaseElapsed: elapsed)
        case .speaking:
            return NomiExpressionState(mode: .speaking, attention: 0.7, energy: min(1, 0.72 + viewModel.audioLevel * 0.35), warmth: max(warmth, 0.25), phaseElapsed: elapsed)
        case .idle:
            let restingEnergy = isResting ? 0.18 : 0.48
            return NomiExpressionState(mode: .idle, attention: isResting ? 0.12 : 0.38, energy: restingEnergy + warmth * 0.2, warmth: warmth, phaseElapsed: elapsed)
        }
    }

    private var portraitSubtitleArea: some View {
        ScrollView {
            Text(viewModel.aiResponseText)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.vertical, 10)
                .opacity(viewModel.aiResponseText.isEmpty ? 0 : 1)
        }
        .frame(height: 100)
    }

    // 底部控制面板 (Portrait 专用)
    private var controlPanel: some View {
        VStack(spacing: 20) {
            // 文字对话输入框
            HStack {
                TextField("给 NOMI 发消息...", text: $viewModel.inputText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(20)
                    .foregroundColor(.white)
                    .onSubmit {
                        viewModel.sendTextConversation()
                        hideKeyboard()
                    }

                if !viewModel.inputText.isEmpty {
                    Button(action: {
                        HapticFeedback.tap()
                        viewModel.sendTextConversation()
                        hideKeyboard()
                    }) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.blue)
                            .padding(10)
                    }
                }
            }
            .padding(.horizontal, 30)
            .opacity(viewModel.canSendTextConversation ? 1.0 : 0.5)
            .disabled(!viewModel.canSendTextConversation)

            primaryControlArea
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var primaryControlArea: some View {
        if shouldShowPrimaryControl {
            HStack(spacing: 30) {
                VStack(spacing: 8) {
                    Button(action: {
                        performPrimaryAction()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 80, height: 80)

                            if viewModel.connectionPhase.isBusy {
                                ProgressView()
                                    .tint(.white)
                            } else if viewModel.isConnected {
                                Image(systemName: primaryControlIconName)
                                    .font(.system(size: 30))
                                    .foregroundColor(controlIconColor)
                            } else if case .failed = viewModel.connectionPhase {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white)
                            } else {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .disabled(isPrimaryControlDisabled)
                    .opacity(isPrimaryControlDisabled ? 0.65 : 1.0)

                    if viewModel.connectionPhase == .pairing {
                        Text("我已完成")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                    }
                }
            }
        } else {
            Spacer().frame(height: 8)
        }
    }

    private var isPrimaryControlDisabled: Bool {
        viewModel.connectionPhase.isBusy || (viewModel.isConnected && viewModel.connectionPhase != .pairing && !viewModel.canToggleListening)
    }

    private var shouldShowPrimaryControl: Bool {
        true
    }

    private func performPrimaryAction() {
        markInteraction()
        HapticFeedback.tap()
        if viewModel.connectionPhase == .pairing {
            viewModel.confirmPairingAndReconnect()
        } else if viewModel.isConnected {
            viewModel.toggleListening()
        } else if !viewModel.connectionPhase.isBusy {
            viewModel.connect()
        }
    }

    private var primaryControlIconName: String {
        viewModel.connectionPhase == .pairing ? "checkmark.circle.fill" : viewModel.conversationPhase.iconName
    }

    private var visibleMood: NomiMood {
        switch viewModel.connectionPhase {
        case .bootstrapping, .connecting:
            return .loading
        case .pairing:
            return .curious
        case .failed:
            return lifeMood ?? .sleep
        case .disconnected, .connected:
            break
        }

        switch viewModel.conversationPhase {
        case .listening:
            return .focus
        case .thinking:
            return .focus
        case .speaking:
            return .talking
        case .idle:
            if isResting { return .sleep }
            return lifeMood ?? viewModel.currentMood
        }
    }

    private func eyeSpacing(for mood: NomiMood) -> CGFloat {
        switch mood {
        case .focus, .strive:
            return 48
        case .curious:
            return 54
        case .drowsy, .sleep:
            return 56
        default:
            return 60
        }
    }

    private var controlIconColor: Color {
        switch viewModel.conversationPhase {
        case _ where viewModel.connectionPhase == .pairing:
            return .yellow
        case .idle:
            return .white
        case .listening:
            return .red
        case .thinking:
            return .yellow
        case .speaking:
            return .green
        }
    }
}

// --- 单个眼睛组件 ---
struct EyeView: View {
    let isRight: Bool
    let mood: NomiMood
    let isBlinking: Bool
    let time: Double
    let activityLevel: Double
    let expression: NomiExpressionState
    let sleepProgress: CGFloat

    var body: some View {
        ZStack {
            if mood == .error {
                // 故障状态：红色 X
                Image(systemName: "xmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 45, height: 45)
                    .foregroundColor(.red)
                    .fontWeight(.black)
                    .offset(jitterOffset(intensity: 6))
                    .id("error")
                    .transition(.opacity.combined(with: .scale))
            } else if mood == .happy || mood == .sad {
                // 开心与难过：弧线
                MoodArc(isHappy: mood == .happy)
                    .stroke(mood == .sad ? Color.gray : Color.white, lineWidth: 6)
                    .frame(width: 45, height: 30)
                    // 为开心状态增加动态轻微跳动 (Pulse/Bounce for Happy)
                    .offset(y: mood == .happy ? (20 + CGFloat(sin(time * 10.0) * 3)) : -10)
                    .id("arc")
                    .transition(.opacity.combined(with: .scale))
            } else {
                // 基础形状
                Capsule()
                    .fill(eyeColor)
                    .frame(width: eyeWidth, height: eyeHeight)
                    .scaleEffect(x: perspectiveScale, y: isBlinking ? 0.01 : moodScaleY)
                    .rotationEffect(.degrees(rotationAngle))
                    .offset(x: horizontalOffset, y: verticalOffset)
                    .offset(jitterOffset(intensity: mood == .strive ? 0.8 : 0))
                    .shadow(color: eyeColor.opacity(0.22 + activityLevel * 0.24 + expression.warmth * 0.12), radius: 9 + CGFloat(activityLevel) * 12 + expression.warmth * 5)
                    .id("capsule")
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.88), value: mood)
    }

    // --- 计算属性控制形态 ---

    private var eyeColor: Color {
        if mood == .drowsy { return .white.opacity(0.72 - sleepProgress * 0.44) }
        if mood == .sleep { return .white.opacity(0.18) }
        if mood == .error { return .red.opacity(0.86) }
        let baseOpacity = 0.72 + expression.energy * 0.22 + expression.warmth * 0.06
        return .white.opacity(min(1, baseOpacity))
    }

    private var eyeWidth: CGFloat {
        let activity = CGFloat(activityLevel)
        switch mood {
        case .scan: return 65 + activity * 8
        case .strive: return thinkingWidth
        case .drowsy: return 42 + sleepProgress * 5
        case .sleep: return 45
        case .surprise: return 55
        case .focus: return focusWidth
        case .loading: return 16
        case .curious: return isRight ? 35 : 45
        case .happy, .sad: return 45
        default: return 42
        }
    }

    private var eyeHeight: CGFloat {
        let activity = CGFloat(activityLevel)
        switch mood {
        case .scan: return 12 + activity * 8
        case .strive: return thinkingHeight
        case .drowsy: return max(8, 78 - sleepProgress * 66)
        case .sleep: return 4 + CGFloat(sin(time * 1.1) * 1.2 + 1.2)
        case .surprise: return 55
        case .focus: return focusHeight
        case .loading: return 16
        case .wink: return isRight ? 2 : 40
        default: return 78
        }
    }

    private var rotationAngle: Double {
        if mood == .strive { return isRight ? -thinkingRotation : thinkingRotation }
        if mood == .curious { return 15 }
        if isThinkingExpression { return isRight ? 4 : -4 }
        if isListeningExpression { return 0 }
        return 0
    }

    private var horizontalOffset: CGFloat {
        switch mood {
        case .lookLeft: return -40
        case .lookRight: return 40
        case .scan: return CGFloat(sin(time * 3.5) * 45)
        case .strive: return thinkingHorizontalOffset
        case .focus: return focusHorizontalOffset
        default: return 0
        }
    }

    private var verticalOffset: CGFloat {
        let activity = CGFloat(activityLevel)
        switch mood {
        case .happy: return 20
        case .talking: return CGFloat(sin(time * 10.0) * 2) - activity * 4 + CGFloat(expression.warmth * 2)
        case .strive: return CGFloat(cos(time * 3.2) * (2 + expression.energy * 2))
        case .drowsy: return 4 + sleepProgress * 12 + CGFloat(sin(time * 1.2) * 1.4)
        case .curious: return isRight ? 10 : -10
        case .wink: return isRight ? 0 : -10
        default: return 0
        }
    }

    private var moodScaleY: CGFloat {
        if mood == .talking { return CGFloat(0.72 + activityLevel * 0.42 + sin(time * 8.0) * 0.06 + expression.warmth * 0.04) }
        if mood == .drowsy { return max(0.18, 1.0 - sleepProgress * 0.74) }
        if mood == .curious { return isRight ? 0.8 : 1.2 }
        if mood == .focus { return focusScaleY }
        return 1.0
    }

    private var perspectiveScale: CGFloat {
        if mood == .lookLeft { return isRight ? 1.2 : 0.8 }
        if mood == .lookRight { return isRight ? 0.8 : 1.2 }
        return 1.0
    }

    private func jitterOffset(intensity: CGFloat) -> CGSize {
        guard intensity > 0 else { return .zero }
        return CGSize(width: CGFloat(sin(time * 24.0)) * intensity, height: CGFloat(cos(time * 19.0)) * intensity)
    }

    private var thinkingStage: Int {
        if expression.phaseElapsed < 1.2 { return 0 }
        if expression.phaseElapsed < 3.2 { return 1 }
        return 2
    }

    private var isThinkingExpression: Bool {
        mood == .focus && expression.mode == .thinking
    }

    private var isListeningExpression: Bool {
        mood == .focus && expression.mode == .listening
    }

    private var focusScaleY: CGFloat {
        if isThinkingExpression {
            return CGFloat(0.82 + sin(time * 1.8) * 0.025)
        }
        if isListeningExpression {
            return CGFloat(0.9 + activityLevel * 0.12 + sin(time * 1.4) * 0.015)
        }
        return CGFloat(0.94 + expression.attention * 0.06 + sin(time * 2.0) * 0.02)
    }

    private var focusWidth: CGFloat {
        if isListeningExpression {
            return 42 + CGFloat(activityLevel * 8)
        }
        if isThinkingExpression {
            return 46 + CGFloat(min(expression.phaseElapsed, 3.0) * 2.5)
        }
        return 32 + CGFloat(expression.attention * 8)
    }

    private var focusHeight: CGFloat {
        if isListeningExpression {
            return 54 + CGFloat(activityLevel * 18)
        }
        if isThinkingExpression {
            return 44 - CGFloat(min(expression.phaseElapsed, 3.0) * 3.5)
        }
        return 78 + CGFloat(expression.attention * 12) + CGFloat(activityLevel * 8)
    }

    private var focusHorizontalOffset: CGFloat {
        if isListeningExpression {
            return CGFloat(sin(time * 1.2) * 1.8)
        }
        if isThinkingExpression {
            let amplitude = expression.phaseElapsed < 1.2 ? 2.5 : 6.0
            return CGFloat(sin(time * 2.4) * amplitude)
        }
        return CGFloat(sin(time * 1.8) * (2 + expression.attention * 2))
    }

    private var thinkingWidth: CGFloat {
        switch thinkingStage {
        case 0: return 48
        case 1: return 56
        default: return 60
        }
    }

    private var thinkingHeight: CGFloat {
        switch thinkingStage {
        case 0: return 18
        case 1: return 13
        default: return 10 + CGFloat(sin(time * 2.0) * 2)
        }
    }

    private var thinkingRotation: Double {
        switch thinkingStage {
        case 0: return 12
        case 1: return 22
        default: return 28
        }
    }

    private var thinkingHorizontalOffset: CGFloat {
        switch thinkingStage {
        case 0: return CGFloat(sin(time * 1.8) * 4)
        case 1: return CGFloat(sin(time * 4.2) * 10)
        default: return CGFloat(sin(time * 5.0) * 14)
        }
    }
}

struct NomiExpressionState {
    var mode: NomiExpressionMode = .idle
    var attention: Double = 0.4
    var energy: Double = 0.5
    var warmth: Double = 0
    var phaseElapsed: TimeInterval = 0
}

enum NomiExpressionMode {
    case idle
    case listening
    case thinking
    case speaking
}

// 预览支持
struct NomiExpressionView_Previews: PreviewProvider {
    static var previews: some View {
        NomiExpressionView()
    }
}

// --- 辅助扩展：收起键盘 ---
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - 辅助形状：弯曲的眼睛
struct MoodArc: Shape {
    var isHappy: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: isHappy ? rect.minY : rect.maxY),
                    radius: rect.width / 2,
                    startAngle: .degrees(isHappy ? 180 : 0),
                    endAngle: .degrees(isHappy ? 360 : 180),
                    clockwise: false)
        return path
    }
}

final class MotionParallaxController: ObservableObject {
    @Published var transform = MotionParallaxTransform()
    var isLandscape = false

    private let motionManager = CMMotionManager()
    private let updateQueue = OperationQueue()

    init() {
        updateQueue.name = "open-nomi.motion-parallax"
        updateQueue.qualityOfService = .userInteractive
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: updateQueue) { [weak self] motion, _ in
            guard let self = self, let attitude = motion?.attitude else { return }

            let roll = self.clamped(attitude.roll, limit: 0.42)
            let pitch = self.clamped(attitude.pitch, limit: 0.42)
            let motionX = self.isLandscape ? pitch : roll
            let motionY = self.isLandscape ? -roll : pitch
            let tiltX = self.isLandscape ? pitch : roll
            let tiltY = self.isLandscape ? roll : -pitch
            let targetOffset = CGSize(width: CGFloat(motionX * 34), height: CGFloat(motionY * 26))
            let targetTilt = CGSize(width: CGFloat(tiltX * 7), height: CGFloat(tiltY * 5))

            DispatchQueue.main.async {
                let nextTransform = MotionParallaxTransform(
                    offset: self.smoothed(current: self.transform.offset, target: targetOffset, amount: 0.18),
                    tilt: self.smoothed(current: self.transform.tilt, target: targetTilt, amount: 0.18)
                )
                guard self.shouldPublish(nextTransform) else { return }
                self.transform = nextTransform
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        transform = MotionParallaxTransform()
    }

    private func clamped(_ value: Double, limit: Double) -> Double {
        min(max(value, -limit), limit)
    }

    private func smoothed(current: CGSize, target: CGSize, amount: CGFloat) -> CGSize {
        CGSize(
            width: current.width + (target.width - current.width) * amount,
            height: current.height + (target.height - current.height) * amount
        )
    }

    private func shouldPublish(_ nextTransform: MotionParallaxTransform) -> Bool {
        abs(nextTransform.offset.width - transform.offset.width) > 0.08 ||
        abs(nextTransform.offset.height - transform.offset.height) > 0.08 ||
        abs(nextTransform.tilt.width - transform.tilt.width) > 0.03 ||
        abs(nextTransform.tilt.height - transform.tilt.height) > 0.03
    }
}

struct MotionParallaxTransform {
    var offset: CGSize = .zero
    var tilt: CGSize = .zero
}

final class KeyboardObserver: ObservableObject {
    @Published var isVisible = false
    @Published var animationDuration: Double = 0.25

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification))
            .sink { [weak self] notification in
                self?.handle(notification, isVisible: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] notification in
                self?.handle(notification, isVisible: false)
            }
            .store(in: &cancellables)
    }

    private func handle(_ notification: Notification, isVisible: Bool) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double

        DispatchQueue.main.async {
            self.animationDuration = duration ?? 0.25
            self.isVisible = isVisible
        }
    }
}

enum HapticFeedback {
    static func tap() {
        impact(style: .light, intensity: 0.62)
    }

    static func touch() {
        impact(style: .heavy, intensity: 1.0)
        AudioServicesPlaySystemSound(1519)
    }

    static func soft() {
        impact(style: .soft, intensity: 0.45)
    }

    static func listen() {
        impact(style: .medium, intensity: 0.7)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private static func impact(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred(intensity: intensity)
        }
    }
}
