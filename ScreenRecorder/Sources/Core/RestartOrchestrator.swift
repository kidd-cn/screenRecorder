import Foundation

/// Q3 重新录制编排（有界等待 idle 后重开的可测编排）：丢弃后收尾是异步 Task（`.finishing`
/// → `finalize` → `.idle`，时长随成片收尾浮动），重开必须等回 `.idle` 且**有界**——
/// 判定全部收在注入的 poll 闭包内（时间也归 poll「含等待」，本类型零时钟依赖，无头可测）。
enum RestartOrchestrator {
    /// 轮询 poll（含等待）；首次 true → 执行 start（恰一次）返回 true；
    /// pollBudget 次全 false → 不执行 start 返回 false（超时静默放弃：不重开、不通知、
    /// 不循环——预算 50 × 0.1s = 5s，让步收在生产 poll 闭包内）。
    static func run(poll: () async -> Bool, pollBudget: Int = 50, start: () async -> Void) async -> Bool {
        for _ in 0..<pollBudget {
            if await poll() {
                await start()
                return true
            }
        }
        return false
    }
}
