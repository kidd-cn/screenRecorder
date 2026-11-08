import XCTest

@testable import ScreenRecorder

// MARK: - RestartOrchestrator（Q3 重新录制）无头单测

/// 有界等待 idle 后重开的可测编排：轮询判定全部确定（poll 闭包由测试注入、零真实等待——
/// 生产接线的 0.1s 让步收在装配层闭包内，「含等待」语义归 poll 自身）。钉定三条路径：
/// idle 中途到达 → start 恰一次返回 true；预算耗尽 → start 零次返回 false（超时静默放弃
/// ——不重开、不通知、不循环）；idle 首拍即到 → start 恰一次（收尾已完成零等待直通）。
final class RestartOrchestratorTests: XCTestCase {

    /// 计数缝（闭包捕获局部 class 实例承载可变计数，跨 await 聚合观测）。
    private final class CallCounter {
        var polls = 0
        var starts = 0
    }

    // MARK: idle 中途到达

    /// poll false×2 后 true：start 恰执行一次、编排返回 true——idle 到达前绝不提前开录，
    /// 到达后恰好开录一次（不重复、不遗漏）。
    func testRunsStartOnceWhenIdleArrives() async {
        let counter = CallCounter()
        let answers: [Bool] = [false, false, true]
        var cursor = 0

        let started = await RestartOrchestrator.run(
            poll: {
                counter.polls += 1
                let answer = answers[cursor]
                cursor += 1
                return answer
            },
            pollBudget: 50,
            start: { counter.starts += 1 })

        XCTAssertTrue(started, "idle 已到达：编排必须受理重开")
        XCTAssertEqual(counter.starts, 1, "start 恰一次（不重复不遗漏）")
        XCTAssertEqual(counter.polls, 3, "第三次 poll（首次 true）即消费，不多拍")
    }

    // MARK: 预算耗尽

    /// poll 恒 false：恰好轮询 budget 次后放弃——start 零次、返回 false（超时纪律钉定：
    /// 不重开、不通知、不循环）。
    func testNeverStartsWhenBudgetExhausted() async {
        let counter = CallCounter()

        let started = await RestartOrchestrator.run(
            poll: {
                counter.polls += 1
                return false
            },
            pollBudget: 5,
            start: { counter.starts += 1 })

        XCTAssertFalse(started, "预算耗尽：编排必须放弃")
        XCTAssertEqual(counter.starts, 0, "预算耗尽绝不执行 start")
        XCTAssertEqual(counter.polls, 5, "恰好 budget 次轮询（无额外拍）")
    }

    // MARK: idle 首拍即到

    /// poll 首次即 true：start 恰一次、零等待直通（收尾已完成的场景）。
    func testStartsImmediatelyWhenIdleInitially() async {
        let counter = CallCounter()

        let started = await RestartOrchestrator.run(
            poll: {
                counter.polls += 1
                return true
            },
            pollBudget: 50,
            start: { counter.starts += 1 })

        XCTAssertTrue(started)
        XCTAssertEqual(counter.starts, 1)
        XCTAssertEqual(counter.polls, 1, "首拍即受理，不多拍")
    }
}
