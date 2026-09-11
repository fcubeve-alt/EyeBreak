import XCTest

// Shared/Detection.swift 与 Shared/Constants.swift 直接编入本测试 target
// （见 project.yml 的 EyeBreakTests sources），因此同属一个模块、无需 import，
// 也不需要宿主 App，可在 CI 上纯逻辑运行。

final class DetectionTests: XCTestCase {

    // MARK: - 派生参数

    func testDerivedParametersForDefaultTarget() {
        XCTAssertEqual(EyeBreakConfig.step(for: 30), 5)
        XCTAssertEqual(EyeBreakConfig.continuityUsageSpan(for: 30), 25)
        XCTAssertEqual(EyeBreakConfig.continuityWallLimit(for: 30), 35)
    }

    func testMilestonesAreAscendingAndBounded() {
        let ms = EyeBreakConfig.milestones(for: 30)
        XCTAssertEqual(ms.first, 5)
        XCTAssertLessThanOrEqual(ms.count, 20)
        XCTAssertEqual(ms, ms.sorted())
        XCTAssertEqual(Set(ms).count, ms.count, "里程碑不应重复")
    }

    func testShortTestThresholdStillProducesUsableMilestones() {
        // v0.3 步骤 2 要求先用 2–5 分钟阈值验证回调
        let ms = EyeBreakConfig.milestones(for: 2)
        XCTAssertFalse(ms.isEmpty)
        XCTAssertGreaterThanOrEqual(EyeBreakConfig.step(for: 2), 1)
        XCTAssertGreaterThanOrEqual(EyeBreakConfig.continuityUsageSpan(for: 2), 1)
    }

    // MARK: - Kill Test #1 场景 1：连续使用应触发

    func testContinuousUsageIsDetected() {
        let t0 = Date()
        // 25 分钟用量在 30 分钟真实时间内跑完 → 密度足够
        let chain: [Int: Date] = [
            5:  t0,
            30: t0.addingTimeInterval(30 * 60),
        ]
        XCTAssertTrue(EyeBreakDetection.isContinuous(
            hits: chain,
            currentMinutes: 30,
            now: t0.addingTimeInterval(30 * 60),
            targetMinutes: 30
        ))
    }

    func testContinuousDetectionRespectsWallClockLimit() {
        let t0 = Date()
        // 同样 25 分钟用量，但摊在 90 分钟真实时间里 → 不是连续使用
        let chain: [Int: Date] = [
            5:  t0,
            30: t0.addingTimeInterval(90 * 60),
        ]
        XCTAssertFalse(EyeBreakDetection.isContinuous(
            hits: chain,
            currentMinutes: 30,
            now: t0.addingTimeInterval(90 * 60),
            targetMinutes: 30
        ))
    }

    func testNoAnchorYetMeansNotContinuous() {
        let t0 = Date()
        // 只积累了 10 分钟用量，还不够回看 25 分钟
        let chain: [Int: Date] = [5: t0, 10: t0.addingTimeInterval(5 * 60)]
        XCTAssertFalse(EyeBreakDetection.isContinuous(
            hits: chain,
            currentMinutes: 10,
            now: t0.addingTimeInterval(5 * 60),
            targetMinutes: 30
        ))
    }

    // MARK: - Kill Test #1 场景 2/3：充分休息应重置

    func testRestLongerThanGapResetsChain() {
        // 5 分钟用量却花了 12 分钟真实时间 → 中间休息了约 7 分钟
        XCTAssertTrue(EyeBreakDetection.didRest(
            usageDeltaMinutes: 5,
            wallDeltaMinutes: 12,
            restGapMinutes: EyeBreakConfig.restGapMinutes
        ))
    }

    func testBriefInterruptionDoesNotReset() {
        // 5 分钟用量花了 8 分钟，中断不足 5 分钟 → 仍算连续
        XCTAssertFalse(EyeBreakDetection.didRest(
            usageDeltaMinutes: 5,
            wallDeltaMinutes: 8,
            restGapMinutes: EyeBreakConfig.restGapMinutes
        ))
    }

    func testScatteredUsageIsNotAccumulatedAsContinuous() {
        // 用 5 分钟 → 长时间不用 → 再用 5 分钟，不能按累计 10 分钟处理
        XCTAssertTrue(EyeBreakDetection.didRest(
            usageDeltaMinutes: 5,
            wallDeltaMinutes: 120,
            restGapMinutes: EyeBreakConfig.restGapMinutes
        ))
    }

    // MARK: - 锚点与密度

    func testAnchorPicksNearestQualifyingMilestone() {
        let t0 = Date()
        let chain: [Int: Date] = [
            5:  t0,
            10: t0.addingTimeInterval(5 * 60),
            15: t0.addingTimeInterval(10 * 60),
        ]
        // 当前 40，span 25 → 合格锚点是 5/10/15，应取最靠近的 15
        let anchor = EyeBreakDetection.anchor(in: chain, currentMinutes: 40, spanMinutes: 25)
        XCTAssertEqual(anchor?.minutes, 15)
    }

    func testAnchorReturnsNilWhenNothingQualifies() {
        let chain: [Int: Date] = [30: Date()]
        XCTAssertNil(EyeBreakDetection.anchor(in: chain, currentMinutes: 35, spanMinutes: 25))
    }

    func testDensityOfFullyActiveUsageIsOne() {
        XCTAssertEqual(EyeBreakDetection.density(usageDeltaMinutes: 25, wallDeltaMinutes: 25),
                       1.0, accuracy: 0.001)
    }

    func testDensityHalvesWhenWallClockDoubles() {
        XCTAssertEqual(EyeBreakDetection.density(usageDeltaMinutes: 25, wallDeltaMinutes: 50),
                       0.5, accuracy: 0.001)
    }

    func testDensityDoesNotDivideByZero() {
        XCTAssertTrue(EyeBreakDetection.density(usageDeltaMinutes: 5, wallDeltaMinutes: 0).isFinite)
    }

    // MARK: - Layer 3 节奏

    func testLayer3FiresAtThreshold() {
        XCTAssertTrue(EyeBreakDetection.shouldRemindLayer3(
            currentMinutes: 45, lastLayer3Milestone: 0, layer3Minutes: 45))
    }

    func testLayer3DoesNotFireBeforeThreshold() {
        XCTAssertFalse(EyeBreakDetection.shouldRemindLayer3(
            currentMinutes: 40, lastLayer3Milestone: 0, layer3Minutes: 45))
    }

    func testLayer3RequiresAnotherFullCycle() {
        // 刚在 45 分钟提醒过，50 分钟不应再提醒
        XCTAssertFalse(EyeBreakDetection.shouldRemindLayer3(
            currentMinutes: 50, lastLayer3Milestone: 45, layer3Minutes: 45))
        // 累积到 90 分钟才是下一次
        XCTAssertTrue(EyeBreakDetection.shouldRemindLayer3(
            currentMinutes: 90, lastLayer3Milestone: 45, layer3Minutes: 45))
    }

    // MARK: - 里程碑链编解码

    func testMilestoneChainRoundTrip() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let chain: [Int: Date] = [5: t0, 10: t0.addingTimeInterval(300)]
        let decoded = MilestoneChain.decode(MilestoneChain.encode(chain))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[5]?.timeIntervalSince1970 ?? 0,
                       t0.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMilestoneChainDecodeHandlesNilAndGarbage() {
        XCTAssertTrue(MilestoneChain.decode(nil).isEmpty)
        XCTAssertTrue(MilestoneChain.decode(["not-a-number": 1]).isEmpty)
    }

    // MARK: - 文案随阈值变化（P1-4 回归防护）

    func testCopyUsesActualThresholdNotHardcodedThirty() {
        let text = EyeBreakCopy.subtitle(layer: "2", targetMinutes: 12, layer3Minutes: 45)
        XCTAssertTrue(text.contains("12"), "文案必须反映真实阈值")
        XCTAssertFalse(text.contains("30"), "不应出现写死的 30 分钟")
    }

    func testLayer3CopyMentionsDailyTotal() {
        let text = EyeBreakCopy.subtitle(layer: "3", targetMinutes: 30, layer3Minutes: 45)
        XCTAssertTrue(text.contains("45"))
        XCTAssertTrue(text.contains("累计"))
    }
}
