// Layer 1 — DeviceActivityReport Extension
//
// 职责：读取 ActivitySegment 的 longestActivity / totalActivityDuration / dateInterval，
// 以及 DeviceActivityData 的 lastUpdatedDate（v0.4 第七节 POC 1 明确要求观测数据更新延迟），
// 全部写入 App Group 共享存储，供主 App 与 Monitor 扩展决策。
//
// ⚠️ 平台限制（重要）：
//    DeviceActivityReport 是 SwiftUI View，只有主 App 前台显示它时扩展才会渲染。
//    也就是说 longestActivity 只在用户打开 EyeBreak 时才刷新，
//    用户在别的 App 里连续刷屏时这个值是不会更新的。
//    因此 Layer 1 只作为「打开 App 时的校准/验证信号」，
//    真正的后台触发依赖 Monitor 扩展的 Layer 2 递增阈值密度判定。
//    正因为数据可能陈旧，写入时必须带时间戳，消费方一律做新鲜度校验。
//
// ⚠️ 若编译报错指向 @Environment(\.deviceActivityResults) 或 lastUpdatedDate，
//    说明本版本 SDK 的属性名不同。在 Xcode 中 Option+点击 DeviceActivityReport
//    查看实际属性名替换即可，下面的换算与写入逻辑不用动。

import DeviceActivity
import SwiftUI

extension DeviceActivityReport.Context {
    static let eyeBreakActivity = Self(rawValue: "com.eyebreak.report.activity")
}

@main
struct EyeBreakReportScene: DeviceActivityReportScene {
    var body: some DeviceActivityReportScene {
        EyeBreakActivityReport(context: .eyeBreakActivity)
    }
}

struct EyeBreakActivityReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context

    var body: some View {
        EyeBreakDataExtractorView()
    }
}

struct EyeBreakDataExtractorView: View {

    @Environment(\.deviceActivityResults) private var activityResults

    private var defaults: UserDefaults { UserDefaults.eyeBreak }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task { await extractAndPersist() }
    }

    // DateComponents → 秒
    private func seconds(from components: DateComponents) -> TimeInterval {
        Double(components.hour ?? 0) * 3600
            + Double(components.minute ?? 0) * 60
            + Double(components.second ?? 0)
    }

    private func extractAndPersist() async {
        var maxContinuousSeconds: TimeInterval = 0
        var totalSeconds: TimeInterval = 0
        var segments = 0
        var earliestStart: Date?
        var latestEnd: Date?
        var appleUpdatedAt: Date?

        for await data in activityResults {
            // POC 1：系统最后一次更新该设备活动数据的时间
            let updated = data.lastUpdatedDate
            if appleUpdatedAt == nil || updated > appleUpdatedAt! {
                appleUpdatedAt = updated
            }

            for segment in data.activitySegments {
                segments += 1

                // POC 1：片段对应的时间区间
                let interval = segment.dateInterval
                if earliestStart == nil || interval.start < earliestStart! {
                    earliestStart = interval.start
                }
                if latestEnd == nil || interval.end > latestEnd! {
                    latestEnd = interval.end
                }

                // totalActivityDuration 是 DateComponents，须换算成秒
                totalSeconds += seconds(from: segment.totalActivityDuration)

                // longestActivity 是 DateInterval?，.duration 直接给秒
                if let longest = segment.longestActivity {
                    maxContinuousSeconds = max(maxContinuousSeconds, longest.duration)
                }
            }
        }

        defaults.eb_resetDailyStateIfNeeded()

        defaults.set(maxContinuousSeconds, forKey: EyeBreakKey.longestActivitySeconds)
        defaults.set(totalSeconds,         forKey: EyeBreakKey.totalActivitySeconds)
        defaults.set(segments,             forKey: EyeBreakKey.segmentCount)
        defaults.set(Date(),               forKey: EyeBreakKey.longestActivityUpdatedAt)
        if let appleUpdatedAt { defaults.set(appleUpdatedAt, forKey: EyeBreakKey.appleLastUpdatedDate) }
        if let earliestStart  { defaults.set(earliestStart,  forKey: EyeBreakKey.segmentIntervalStart) }
        if let latestEnd      { defaults.set(latestEnd,      forKey: EyeBreakKey.segmentIntervalEnd) }

        // Layer 1 触发判断，阈值从共享配置读取（与主 App / Monitor 完全一致）
        let thresholdSeconds = Double(defaults.eb_targetMinutes * 60)
        guard maxContinuousSeconds >= thresholdSeconds,
              !defaults.eb_inCooldown,
              !defaults.eb_alreadyTriggered
        else { return }

        defaults.set(true, forKey: EyeBreakKey.shouldShowEyeBreak)
        defaults.set("1",  forKey: EyeBreakKey.activeLayer)
    }
}
