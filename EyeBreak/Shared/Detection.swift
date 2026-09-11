import Foundation

/// 检测算法的纯函数部分。
///
/// 刻意不接触 UserDefaults、ManagedSettings 或任何系统 API，
/// 以便用单元测试完整覆盖 v0.3 Kill Test #1 的各个场景
/// （连续达标 / 中途休息重置 / 分散使用不累计 / 跨 App 仍算连续）。
enum EyeBreakDetection {

    /// 相邻两个里程碑之间，真实耗时比用量增量多出 restGap 以上，
    /// 说明中途确实把设备放下了 → 连续链应当重置。
    static func didRest(usageDeltaMinutes: Double,
                        wallDeltaMinutes: Double,
                        restGapMinutes: Int) -> Bool {
        wallDeltaMinutes - usageDeltaMinutes > Double(restGapMinutes)
    }

    /// 在里程碑链中找出「用量上至少落后 spanMinutes、且尽量靠近当前」的锚点。
    static func anchor(in hits: [Int: Date],
                       currentMinutes: Int,
                       spanMinutes: Int) -> (minutes: Int, at: Date)? {
        hits.compactMap { minutes, at -> (minutes: Int, at: Date)? in
            guard currentMinutes - minutes >= spanMinutes else { return nil }
            return (minutes, at)
        }
        .max { $0.minutes < $1.minutes }
    }

    /// 使用密度 = 用量增量 ÷ 真实时钟增量。1.0 表示全程都在用屏。
    static func density(usageDeltaMinutes: Double, wallDeltaMinutes: Double) -> Double {
        usageDeltaMinutes / max(wallDeltaMinutes, 0.1)
    }

    /// 是否判定为「连续用屏」。
    ///
    /// span 分钟的用量必须在 span × densityTolerance 的真实时间内跑完。
    /// 中途休息会拉长真实时间，密度掉下来，判定自然不成立。
    static func isContinuous(hits: [Int: Date],
                             currentMinutes: Int,
                             now: Date,
                             targetMinutes: Int) -> Bool {
        let span = EyeBreakConfig.continuityUsageSpan(for: targetMinutes)
        let wallLimit = Double(EyeBreakConfig.continuityWallLimit(for: targetMinutes))
        guard let anchor = anchor(in: hits, currentMinutes: currentMinutes, spanMinutes: span)
        else { return false }
        return now.timeIntervalSince(anchor.at) / 60 <= wallLimit
    }

    /// Layer 3 是否该提醒：累计用量过线，且距上次 Layer 3 提醒又累积满一个周期。
    static func shouldRemindLayer3(currentMinutes: Int,
                                   lastLayer3Milestone: Int,
                                   layer3Minutes: Int) -> Bool {
        currentMinutes >= layer3Minutes
            && currentMinutes - lastLayer3Milestone >= layer3Minutes
    }
}

// MARK: - 里程碑链的存储编码
//
// UserDefaults 只能存 plist 类型，所以链条以 [String: Double] 落盘。
// 编解码集中在这里，避免各进程各写一套。

enum MilestoneChain {
    static func decode(_ raw: [String: Double]?) -> [Int: Date] {
        guard let raw else { return [:] }
        var out: [Int: Date] = [:]
        for (key, epoch) in raw {
            if let minutes = Int(key) {
                out[minutes] = Date(timeIntervalSince1970: epoch)
            }
        }
        return out
    }

    static func encode(_ chain: [Int: Date]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (minutes, at) in chain {
            out["\(minutes)"] = at.timeIntervalSince1970
        }
        return out
    }
}
