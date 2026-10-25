import XCTest

@testable import ScreenRecorder

/// 可编程假 provider：直接返回预设字节数；置 nil 模拟卷查询失败（路径不存在等）。
private final class FakeFreeSpaceProvider: DiskFreeSpaceProviding {
    var freeBytesValue: Int64?

    func freeBytes(at url: URL) -> Int64? { freeBytesValue }
}

final class DiskSpaceMonitorTests: XCTestCase {
    // MARK: - 阈值（生产默认值，与 brief 逐字一致）

    private let warnBelow: Int64 = 2_000_000_000
    private let stopBelow: Int64 = 500_000_000
    private let hysteresis: Int64 = 500_000_000

    /// 假 provider 不触碰真实卷，路径仅作透传参数。
    private let url = URL(fileURLWithPath: "/tmp/screen-recorder-tests/disk-probe")

    // MARK: - 回调计数（测试方法运行在主线程、回调同步内联，无需锁）

    private var warnCount = 0
    private var stopCount = 0
    private var offMainDeliveries = 0

    private func makeMonitor(provider: FakeFreeSpaceProvider) -> DiskSpaceMonitor {
        let monitor = DiskSpaceMonitor(provider: provider, url: url)
        monitor.onWarn = { [weak self] in
            guard let self = self else { return }
            self.warnCount += 1
            if !Thread.isMainThread { self.offMainDeliveries += 1 }
        }
        monitor.onStop = { [weak self] in
            guard let self = self else { return }
            self.stopCount += 1
            if !Thread.isMainThread { self.offMainDeliveries += 1 }
        }
        return monitor
    }

    // MARK: - Brief Step 1 五条场景（逐字）

    func testInitial3GBProducesNoCallback() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)

        monitor.checkNow()

        XCTAssertEqual(warnCount, 0)
        XCTAssertEqual(stopCount, 0)
    }

    func testDroppingTo1_5GBFiresOnWarnOnce() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()

        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()

        XCTAssertEqual(warnCount, 1)
        XCTAssertEqual(stopCount, 0)
        // 同一低值再查一次：warn 已锁存，不重复触发
        monitor.checkNow()
        XCTAssertEqual(warnCount, 1)
    }

    func testDroppingTo400MBFiresOnStopWithoutRefiringWarn() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()

        provider.freeBytesValue = 400_000_000
        monitor.checkNow()

        // 1.5GB 时已 warn 过，未回升越过 warnBelow + 迟滞，不得再次 warn
        XCTAssertEqual(warnCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testConsecutive400MBReadsFireOnStopOnlyOnce() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()
        provider.freeBytesValue = 400_000_000
        monitor.checkNow()

        monitor.checkNow()
        monitor.checkNow()

        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(warnCount, 1)
    }

    func testNilProviderReadingDoesNotCrashOrCallbackOrChangeState() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()

        provider.freeBytesValue = nil
        monitor.checkNow() // 不崩溃、不回调

        XCTAssertEqual(warnCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(offMainDeliveries, 0)

        // nil 读取不得改变锁存状态：恢复 400MB 后 stop 恰好触发一次（而非被 nil 重置后行为异常）
        provider.freeBytesValue = 400_000_000
        monitor.checkNow()
        XCTAssertEqual(warnCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - 迟滞重武装（controller 决策 4 钉死语义）

    func testWarnDoesNotReArmInsideHysteresisBand() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()
        XCTAssertEqual(warnCount, 1)

        // 回升到 warnBelow + 迟滞带内（2.4GB < 2.5GB）：不重武装
        provider.freeBytesValue = 2_400_000_000
        monitor.checkNow()
        provider.freeBytesValue = 1_900_000_000
        monitor.checkNow()

        XCTAssertEqual(warnCount, 1)
    }

    func testWarnReArmsOnlyAboveHysteresisBand() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()
        XCTAssertEqual(warnCount, 1)

        // 回升越过 warnBelow + 500MB（2.6GB > 2.5GB）：重武装
        provider.freeBytesValue = 2_600_000_000
        monitor.checkNow()
        provider.freeBytesValue = 1_900_000_000
        monitor.checkNow()

        XCTAssertEqual(warnCount, 2)
    }

    func testExactHysteresisBoundaryDoesNotReArm() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 1_500_000_000
        monitor.checkNow()

        // 恰等于 warnBelow + 迟滞：语义为「回升越过」才重武装，等于不算
        provider.freeBytesValue = warnBelow + hysteresis
        monitor.checkNow()
        provider.freeBytesValue = 1_900_000_000
        monitor.checkNow()

        XCTAssertEqual(warnCount, 1)
    }

    func testStopReArmsAboveItsOwnHysteresisBand() {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 3_000_000_000
        let monitor = makeMonitor(provider: provider)
        monitor.checkNow()
        provider.freeBytesValue = 400_000_000
        monitor.checkNow()
        XCTAssertEqual(stopCount, 1)

        // 900MB < stopBelow + 迟滞（1GB）：stop 不重武装
        provider.freeBytesValue = 900_000_000
        monitor.checkNow()
        provider.freeBytesValue = 400_000_000
        monitor.checkNow()
        XCTAssertEqual(stopCount, 1)

        // 1.1GB > 1GB：stop 重武装，再次跌破 400MB 触发第二次
        provider.freeBytesValue = 1_100_000_000
        monitor.checkNow()
        provider.freeBytesValue = 400_000_000
        monitor.checkNow()

        XCTAssertEqual(stopCount, 2)
        XCTAssertEqual(warnCount, 1) // warn 全程只下探一次
        XCTAssertEqual(offMainDeliveries, 0)
    }
}
