import XCTest
import CoreMedia

@testable import ScreenRecorder

final class PauseTimeTrackerTests: XCTestCase {
    // MARK: - Brief Step 1 四条断言

    func testShiftAfterPauseResumeSubtractsPauseDuration() {
        var tracker = PauseTimeTracker()
        tracker.pause(at: CMTime(seconds: 10, preferredTimescale: 600))
        tracker.resume(at: CMTime(seconds: 40, preferredTimescale: 600))

        XCTAssertEqual(tracker.shifted(CMTime(seconds: 50, preferredTimescale: 600)),
                       CMTime(seconds: 20, preferredTimescale: 600))
    }

    func testMultiplePauseResumeCyclesAccumulate() {
        var tracker = PauseTimeTracker()
        tracker.pause(at: CMTime(seconds: 10, preferredTimescale: 600))
        tracker.resume(at: CMTime(seconds: 40, preferredTimescale: 600))
        tracker.pause(at: CMTime(seconds: 60, preferredTimescale: 600))
        tracker.resume(at: CMTime(seconds: 90, preferredTimescale: 600))

        // 累计暂停 30s + 30s = 60s；按 brief 公式 shifted(100) = 100 − 60 = 40
        // （brief 文字 "shifted(100s)==20s" 为笔误，见任务报告 Concerns 1）
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 100, preferredTimescale: 600)),
                       CMTime(seconds: 40, preferredTimescale: 600))
        // brief 期望的 20s 在 t=80 处成立
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 80, preferredTimescale: 600)),
                       CMTime(seconds: 20, preferredTimescale: 600))
        XCTAssertEqual(tracker.accumulatedPause, CMTime(seconds: 60, preferredTimescale: 600))
    }

    func testShiftedIsIdentityWhenNeverPaused() {
        let tracker = PauseTimeTracker()

        XCTAssertEqual(tracker.accumulatedPause, .zero)
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 50, preferredTimescale: 600)),
                       CMTime(seconds: 50, preferredTimescale: 600))
    }

    func testShiftedResultIsNeverNegative() {
        var tracker = PauseTimeTracker()
        tracker.pause(at: CMTime(seconds: 10, preferredTimescale: 600))
        tracker.resume(at: CMTime(seconds: 40, preferredTimescale: 600))

        // 20 − 30 = −10 → 钳为 .zero；t 恰等于累计暂停时长时为 0，同样不为负
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 20, preferredTimescale: 600)), .zero)
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 30, preferredTimescale: 600)), .zero)
    }

    // MARK: - 幂等性（Task 10 采集管线依赖）

    func testRepeatPauseKeepsFirstPauseTimestamp() {
        var tracker = PauseTimeTracker()
        tracker.pause(at: CMTime(seconds: 10, preferredTimescale: 600))
        tracker.pause(at: CMTime(seconds: 30, preferredTimescale: 600)) // 已暂停，忽略
        tracker.resume(at: CMTime(seconds: 40, preferredTimescale: 600))

        // 首次 pause 时间戳生效：40 − 10 = 30s（而非 40 − 30 = 10s）
        XCTAssertEqual(tracker.accumulatedPause, CMTime(seconds: 30, preferredTimescale: 600))
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 50, preferredTimescale: 600)),
                       CMTime(seconds: 20, preferredTimescale: 600))
    }

    func testResumeWhenNotPausedIsNoOp() {
        var tracker = PauseTimeTracker()
        tracker.resume(at: CMTime(seconds: 40, preferredTimescale: 600)) // 未暂停，无操作
        XCTAssertEqual(tracker.accumulatedPause, .zero)

        // 真实 pause/resume 之后多余的 resume 同样不改变累计值
        tracker.pause(at: CMTime(seconds: 10, preferredTimescale: 600))
        tracker.resume(at: CMTime(seconds: 40, preferredTimescale: 600))
        tracker.resume(at: CMTime(seconds: 90, preferredTimescale: 600))

        XCTAssertEqual(tracker.accumulatedPause, CMTime(seconds: 30, preferredTimescale: 600))
        XCTAssertEqual(tracker.shifted(CMTime(seconds: 50, preferredTimescale: 600)),
                       CMTime(seconds: 20, preferredTimescale: 600))
    }
}
