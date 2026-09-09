import SwiftUI
import DeviceActivity

struct ContentView: View {
    @EnvironmentObject var manager: ScreenTimeManager

    var body: some View {
        NavigationStack {
            List {
                authSection
                previewSection
                if manager.authStatus == .approved {
                    monitoringSection
                    layer1Section
                    layer2Section
                    layer3Section
                    actionsSection
                }
                logSection
            }
            .navigationTitle("EyeBreak POC")
            .listStyle(.insetGrouped)
            .refreshable { manager.syncFromDefaults() }
        }
        .fullScreenCover(isPresented: $manager.showEyeBreak) {
            EyeExerciseView().environmentObject(manager)
        }
    }

    // MARK: - 权限

    var authSection: some View {
        Section("权限") {
            HStack {
                Label("Screen Time 授权", systemImage: "lock.shield.fill")
                Spacer()
                Text(authLabel).foregroundStyle(authColor).font(.caption)
            }
            if manager.authStatus != .approved {
                Button("申请授权") { Task { await manager.requestAuthorization() } }
            }
        }
    }

    var authLabel: String {
        switch manager.authStatus {
        case .approved: return "✅ 已授权"
        case .denied:   return "❌ 已拒绝"
        default:        return "⏳ 未授权"
        }
    }

    var authColor: Color {
        switch manager.authStatus {
        case .approved: return .green
        case .denied:   return .red
        default:        return .secondary
        }
    }

    // MARK: - 预览（不需要授权）

    var previewSection: some View {
        Section {
            Button {
                manager.showEyeBreak = true
            } label: {
                Label("预览护眼界面", systemImage: "eye.fill")
            }
        } header: {
            Text("预览")
        } footer: {
            Text("不需要 Screen Time 授权即可查看护眼引导界面与视频播放，用于验证 Kill Test #2 的交互体验（存在感 / 可关闭 / 动作引导）。模拟器亦可运行。")
                .font(.caption2)
        }
    }

    // MARK: - 监测控制

    var monitoringSection: some View {
        Section {
            HStack {
                Image(systemName: manager.isMonitoring ? "circle.fill" : "circle")
                    .foregroundStyle(manager.isMonitoring ? .green : .secondary)
                    .font(.caption)
                Text(manager.isMonitoring ? "监测中" : "未启动")
                Spacer()
                if manager.activeLayer != "" {
                    Text("Layer \(manager.activeLayer) 已触发")
                        .font(.caption).bold().foregroundStyle(.orange)
                }
            }

            Stepper("目标连续用屏: \(manager.targetMinutes) 分钟",
                    value: $manager.targetMinutes, in: 2...60)
                .font(.subheadline)
                .disabled(manager.isMonitoring)

            Stepper("Layer 3 保底: \(manager.layer3Minutes) 分钟",
                    value: $manager.layer3Minutes, in: 30...90, step: 5)
                .font(.subheadline)
                .disabled(manager.isMonitoring)

            HStack(spacing: 12) {
                Button { manager.startMonitoring() } label: {
                    Label("开始", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isMonitoring)

                Button { manager.stopMonitoring() } label: {
                    Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!manager.isMonitoring)
            }
        } header: {
            Text("监测控制")
        } footer: {
            Text("真机 POC 阶段先设 2–5 分钟验证回调，通过后再改回 30 分钟做真实场景测试。启动后阈值锁定，需停止才能修改。")
                .font(.caption2)
        }
    }

    // MARK: - Layer 1

    var layer1Section: some View {
        Section {
            row("longestActivity",
                String(format: "%.1f 分钟", manager.longestActivityMinutes),
                highlight: manager.longestActivityMinutes >= Double(manager.targetMinutes))

            HStack {
                Text("数据新鲜度").font(.system(.subheadline, design: .monospaced))
                Spacer()
                if let t = manager.layer1WrittenAt {
                    Text(manager.layer1IsFresh ? "✅ 新鲜" : "⚠️ 已过期")
                        .font(.caption)
                        .foregroundStyle(manager.layer1IsFresh ? .green : .orange)
                    Text(t, style: .relative).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("尚未获取").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("lastUpdatedDate").font(.system(.subheadline, design: .monospaced))
                Spacer()
                if let t = manager.appleLastUpdatedDate {
                    Text(t, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Text("前").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("—").font(.caption).foregroundStyle(.secondary)
                }
            }

            row("activitySegments", "\(manager.segmentCount) 段")

            reportView.frame(height: 1).clipped()
        } header: {
            Text("Layer 1 — longestActivity（最优先）")
        } footer: {
            Text("由 DeviceActivityReport 扩展读取。注意：该扩展只在本 App 前台显示时才渲染，因此数据仅在打开 App 时刷新。过期数据一律不采信，避免昨日的长会话造成误触发。")
                .font(.caption2)
        }
    }

    @ViewBuilder
    var reportView: some View {
        DeviceActivityReport(
            .eyeBreakActivity,
            filter: DeviceActivityFilter(
                segment: .daily(during: DateInterval(
                    start: Calendar.current.startOfDay(for: Date()),
                    end: Date()
                )),
                users: .all,
                devices: .all
            )
        )
    }

    // MARK: - Layer 2

    var layer2Section: some View {
        Section {
            row("最近里程碑", "\(manager.lastMilestoneMinutes) 分钟用量")

            HStack {
                Text("使用密度").font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text(manager.observedDensity > 0
                     ? String(format: "%.2f", manager.observedDensity)
                     : "—")
                    .monospacedDigit()
                    .foregroundStyle(manager.observedDensity >= 1 / EyeBreakConfig.densityTolerance
                                     ? .red : .primary)
            }

            ProgressView(
                value: min(manager.observedDensity, 1.0),
                total: 1.0
            )
            .tint(manager.observedDensity >= 1 / EyeBreakConfig.densityTolerance ? .red : .teal)
        } header: {
            Text("Layer 2 — 使用密度（主力）")
        } footer: {
            Text("阈值事件在一个监测区间内只触发一次，无法反复计窗口。改用一排递增阈值（每 \(EyeBreakConfig.step(for: manager.targetMinutes)) 分钟用量一个），以相邻回调的真实时钟间隔算密度：\(EyeBreakConfig.continuityUsageSpan(for: manager.targetMinutes)) 分钟用量若在 \(EyeBreakConfig.continuityWallLimit(for: manager.targetMinutes)) 分钟内跑完即判为连续。密度 1.0 = 全程在用；中途休息超过 \(EyeBreakConfig.restGapMinutes) 分钟则连续链清零。")
                .font(.caption2)
        }
    }

    // MARK: - Layer 3

    var layer3Section: some View {
        Section {
            row("今日总活跃时间",
                String(format: "%.1f 分钟", manager.totalActivityMinutes),
                highlight: manager.totalActivityMinutes >= Double(manager.layer3Minutes))
        } header: {
            Text("Layer 3 — 日总量（保底）")
        } footer: {
            Text("当日累计用量达到 \(manager.layer3Minutes) 分钟且 Layer 1/2 均未触发时，给一次柔性提醒；之后每再累积 \(manager.layer3Minutes) 分钟才会再提醒一次。对应 v0.4 第五节 C 级的 45–60 分钟节奏。")
                .font(.caption2)
        }
    }

    // MARK: - 调试

    var actionsSection: some View {
        Section("调试工具") {
            Button {
                manager.manualTrigger()
            } label: {
                Label("手动触发护眼提醒", systemImage: "eye.trianglebadge.exclamationmark")
            }

            Button(role: .destructive) {
                manager.unshield()
                let db = UserDefaults.eyeBreak
                db.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
                db.set("",    forKey: EyeBreakKey.activeLayer)
                manager.addLog("已强制解除 Shield")
            } label: {
                Label("强制解除 Shield", systemImage: "lock.open.fill")
            }

            HStack {
                Label("今日护眼次数", systemImage: "checkmark.seal.fill")
                Spacer()
                Text("\(UserDefaults.eyeBreak.integer(forKey: EyeBreakKey.eyeBreakCount))")
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 日志

    var logSection: some View {
        Section("日志") {
            if manager.log.isEmpty {
                Text("暂无日志").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(Array(manager.log.reversed().prefix(30).enumerated()), id: \.offset) { _, entry in
                    Text(entry).font(.system(.caption2, design: .monospaced))
                }
            }
        }
    }

    // MARK: - 小工具

    private func row(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(.subheadline, design: .monospaced))
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(highlight ? .red : .primary)
        }
    }
}

// MARK: - Report context（主 App 侧）

extension DeviceActivityReport.Context {
    static let eyeBreakActivity = Self(rawValue: "com.eyebreak.report.activity")
}
