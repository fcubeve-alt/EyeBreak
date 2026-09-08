import SwiftUI
import DeviceActivity

struct ContentView: View {
    @EnvironmentObject var manager: ScreenTimeManager

    var body: some View {
        NavigationStack {
            List {
                authSection
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
            .refreshable { /* pull to force UI sync */ }
        }
        .fullScreenCover(isPresented: $manager.showEyeBreak) {
            EyeExerciseView().environmentObject(manager)
        }
    }

    // MARK: - Auth

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

    // MARK: - Monitoring controls

    var monitoringSection: some View {
        Section("监测控制") {
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

            Stepper("测试窗口阈值: \(manager.debugWindowMinutes) 分钟",
                    value: $manager.debugWindowMinutes, in: 1...30)
                .font(.subheadline)

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
        }
    }

    // MARK: - Layer 1: longestActivity

    var layer1Section: some View {
        Section {
            HStack {
                Text("longestActivity")
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text(String(format: "%.1f 分钟", manager.longestActivityMinutes))
                    .foregroundStyle(manager.longestActivityMinutes >= 30 ? .red : .primary)
                    .monospacedDigit()
            }
            HStack {
                Text("数据更新时间")
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                if let t = manager.layer1UpdatedAt {
                    Text(t, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Text("前").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("尚未获取").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Embed the DeviceActivityReport view — this triggers the extension
            // to read DeviceActivityData and write longestActivity to UserDefaults
            reportView
                .frame(height: 1)
                .clipped()
        } header: {
            Text("Layer 1 — longestActivity（最优先）")
        } footer: {
            Text("由 DeviceActivityReport 扩展实时读取，数据越新鲜越可靠。若此值 ≥ 30分钟则直接触发。")
                .font(.caption2)
        }
    }

    @ViewBuilder
    var reportView: some View {
        // DeviceActivityReport view: the system routes rendering to our
        // DeviceActivityReport extension which reads longestActivity and
        // writes to shared UserDefaults (which syncFromDefaults() picks up).
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

    // MARK: - Layer 2: consecutive windows

    var layer2Section: some View {
        Section {
            HStack {
                Text("连续活跃窗口")
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text("\(manager.consecutiveWindows) / \(manager.windowsNeeded)")
                    .monospacedDigit()
                    .foregroundStyle(manager.consecutiveWindows >= manager.windowsNeeded ? .red : .primary)
            }
            // Visual progress bar
            ProgressView(
                value: Double(min(manager.consecutiveWindows, manager.windowsNeeded)),
                total: Double(manager.windowsNeeded)
            )
            .tint(manager.consecutiveWindows >= manager.windowsNeeded ? .red : .teal)
        } header: {
            Text("Layer 2 — 短窗口连续计数（备选）")
        } footer: {
            Text("每 5 分钟窗口内有 ≥ \(EyeBreakConfig.activityThresholdMinutes) 分钟活动则计 1。连续 \(EyeBreakConfig.consecutiveWindowsNeeded) 个窗口 ≈ 30 分钟持续使用。")
                .font(.caption2)
        }
    }

    // MARK: - Layer 3: daily total

    var layer3Section: some View {
        Section {
            HStack {
                Text("今日总活跃时间")
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text(String(format: "%.1f 分钟", manager.totalActivityMinutes))
                    .monospacedDigit()
                    .foregroundStyle(manager.totalActivityMinutes >= 30 ? .orange : .primary)
            }
        } header: {
            Text("Layer 3 — 日总量（保底）")
        } footer: {
            Text("当日总屏幕活动 ≥ 30 分钟触发，仅当 Layer 1/2 均未触发时生效。对重度用户有效。")
                .font(.caption2)
        }
    }

    // MARK: - Debug actions

    var actionsSection: some View {
        Section("调试工具") {
            Button {
                manager.manualTrigger()
            } label: {
                Label("手动触发护眼提醒", systemImage: "eye.trianglebadge.exclamationmark")
            }

            Button(role: .destructive) {
                manager.unshield()
                UserDefaults.eyeBreak.set(false, forKey: EyeBreakKey.shouldShowEyeBreak)
                UserDefaults.eyeBreak.set("",    forKey: EyeBreakKey.activeLayer)
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

    // MARK: - Log

    var logSection: some View {
        Section("日志") {
            if manager.log.isEmpty {
                Text("暂无日志").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(manager.log.reversed().prefix(30), id: \.self) { entry in
                    Text(entry)
                        .font(.system(.caption2, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - DeviceActivityReport context extension (main app)

extension DeviceActivityReport.Context {
    static let eyeBreakActivity = Self(rawValue: "com.eyebreak.report.activity")
}
