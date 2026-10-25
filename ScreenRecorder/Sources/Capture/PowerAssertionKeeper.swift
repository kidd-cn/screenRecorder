import Foundation
import IOKit
import IOKit.pwr_mgt

/// 防睡眠断言守护：录制期间持有 `kIOPMAssertionTypeNoIdleSleep`（NoIdleSleep），
/// 防止屏幕录制中系统因无用户输入而空闲睡眠。
/// IOKit 断言状态无法在单元测试中有意义地断言，按 controller 决策 2 仅构建验证，不配单测。
final class PowerAssertionKeeper {
    private let lock = NSLock()
    /// 0 表示当前未持有断言（IOPMAssertionCreateWithName 成功时返回的 ID 恒非零）。
    private var assertionID: IOPMAssertionID = 0

    deinit {
        deactivate() // 防止 keeper 提前释放后断言悬挂
    }

    /// 创建 NoIdleSleep 断言；已持有时幂等（不重复创建）。
    /// 创建失败时静默回退（视为未持有）：防睡眠是尽力而为的保障，
    /// 失败不应阻断录制本身；无日志依赖（YAGNI，调用方可在返回后自查行为）。
    func activate(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard assertionID == 0 else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        assertionID = (result == kIOReturnSuccess) ? id : 0
    }

    /// 释放断言；未持有时幂等（no-op）。
    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
