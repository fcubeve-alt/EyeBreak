import SwiftUI
import AVKit

struct EyeExerciseView: View {
    @EnvironmentObject var manager: ScreenTimeManager
    @State private var phase: Phase = .prompt

    enum Phase: Equatable, Hashable {
        case prompt
        case video
        case exercise(Int)
        case done
    }

    let exercises: [Exercise] = [
        Exercise(id: 0, title: "看远方",       detail: "望向6米以外的物体，完全放松眼部肌肉", icon: "binoculars.fill", seconds: 20),
        Exercise(id: 1, title: "主动眨眼",     detail: "缓慢、完整地眨眼 10 次",            icon: "eye.fill",        seconds: 15),
        Exercise(id: 2, title: "闭眼休息",     detail: "轻轻闭上眼睛，什么都不用想",         icon: "moon.zzz.fill",   seconds: 20),
        Exercise(id: 3, title: "近远焦点切换", detail: "看手指 → 看远处，交替 5 次",        icon: "scope",           seconds: 25),
    ]

    private var videoURL: URL? {
        Bundle.main.url(forResource: "eye_exercise", withExtension: "mp4")
    }

    /// 文案按真实阈值与触发层级生成，不写死「30 分钟」
    private var subtitle: String {
        UserDefaults.eyeBreak.eb_triggerSubtitle
    }

    var body: some View {
        ZStack {
            if phase != .video {
                background.ignoresSafeArea()
            }

            switch phase {
            case .prompt:
                promptView
            case .video:
                if let url = videoURL {
                    VideoExerciseView(
                        url: url,
                        onComplete: { phase = .done },
                        onSkip: { manager.finishEyeBreak(.skipped) }
                    )
                } else {
                    Color.black.ignoresSafeArea().onAppear { phase = .exercise(0) }
                }
            case .exercise(let idx):
                ExerciseActiveView(
                    exercise: exercises[idx],
                    onComplete: {
                        if idx + 1 < exercises.count { phase = .exercise(idx + 1) }
                        else { phase = .done }
                    },
                    onSkip: { manager.finishEyeBreak(.skipped) }
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .done:
                doneView
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    // MARK: - Prompt
    //
    // 整页可滚动：小屏、横屏或最大字号下，底部的「稍后再说」必须仍然够得到，
    // 否则用户会被一个无法退出的全屏页困住。

    var promptView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "eye.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .accessibilityHidden(true)

                    Text("眼睛需要休息了")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 40)

                VStack(spacing: 12) {
                    if videoURL != nil {
                        Button { phase = .video } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .frame(width: 36)
                                    .foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("播放护眼视频")
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                    Text("跟随视频做护眼操")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding()
                            .background(Color.white.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                            )
                        }
                        .accessibilityLabel("播放护眼视频，跟随视频做护眼操")

                        Text("— 或选择以下动作 —")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 4)
                    } else {
                        Text("选一个护眼动作")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .textCase(.uppercase)
                            .tracking(1)
                    }

                    ForEach(exercises) { ex in
                        Button { phase = .exercise(ex.id) } label: {
                            ExerciseRow(exercise: ex)
                        }
                        .accessibilityLabel("\(ex.title)，\(ex.seconds) 秒，\(ex.detail)")
                    }

                    Button(action: { manager.finishEyeBreak(.snoozed) }) {
                        Text("稍后再说")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityHint("关闭本次提醒并进入冷却期")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Done

    var doneView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            Text("眼睛充好电了！")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Text("继续加油 💪")
                .foregroundStyle(.white.opacity(0.8))

            Button(action: { manager.finishEyeBreak(.completed) }) {
                Text("回到 App")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.teal)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(24)
    }

    var background: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.45, blue: 0.55), Color(red: 0.05, green: 0.30, blue: 0.50)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 视频播放

struct VideoExerciseView: View {
    let url: URL
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onReceive(
                        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime),
                        perform: { _ in onComplete() }
                    )
            }

            Button(action: { player?.pause(); onSkip() }) {
                HStack(spacing: 4) {
                    Text("跳过")
                    Image(systemName: "forward.end.fill").font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
            }
            .padding(.top, 60)
            .padding(.trailing, 20)
            .accessibilityLabel("跳过护眼视频")
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - 动作条目

struct ExerciseRow: View {
    let exercise: Exercise
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: exercise.icon)
                .font(.title3)
                .frame(width: 36)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.title).fontWeight(.semibold).foregroundStyle(.white)
                Text("\(exercise.seconds) 秒").font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.4))
        }
        .padding()
        .background(.white.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 动作进行页

struct ExerciseActiveView: View {
    let exercise: Exercise
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var remaining: Int
    @State private var endDate: Date = .distantFuture
    @State private var timer: Timer?

    init(exercise: Exercise, onComplete: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.exercise = exercise
        self.onComplete = onComplete
        self.onSkip = onSkip
        _remaining = State(initialValue: exercise.seconds)
    }

    var progress: Double {
        1 - Double(remaining) / Double(exercise.seconds)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: exercise.icon)
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)
                    .padding(.top, 40)

                Text(exercise.title)
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text(exercise.detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 32)

                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remaining)
                    Text("\(remaining)")
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 120, height: 120)
                .accessibilityLabel("剩余 \(remaining) 秒")

                VStack(spacing: 12) {
                    Button(action: { stop(); onComplete() }) {
                        Text("完成 ✓")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(red: 0.08, green: 0.45, blue: 0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button(action: { stop(); onSkip() }) {
                        Text("跳过全部，返回 App")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // 倒计时以结束时刻为准，而不是累计 tick 次数。
    // 这样既不会多走一秒，切到后台再回来也不会漂移。
    private func start() {
        endDate = Date().addingTimeInterval(Double(exercise.seconds))
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let left = max(0, Int(endDate.timeIntervalSinceNow.rounded(.up)))
            if left != remaining { remaining = left }
            if left == 0 {
                stop()
                onComplete()
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Model

struct Exercise: Identifiable {
    let id: Int
    let title: String
    let detail: String
    let icon: String
    let seconds: Int
}
