import SwiftUI

/// 定时录制面板（P6b，菜单「定时录制…」）：开始时刻（日期选择 /「N 分钟后」快速 stepper，
/// 两个控件共用同一真源 `startAt`）+ 可选时长上限（opt-in，分钟 stepper）+ 排定/取消。
/// 排定回调把整只 `RecordingScheduler.Schedule` 交回装配层（`scheduler.schedule` 整只
/// 替换语义）；取消回调只收起面板（撤销既有排程走菜单「取消定时录制」，与简报一致）。
/// 本视图无装配副作用（同 PreferencesView 纪律：窗口所有权归装配层）。
struct ScheduledRecordingPanelView: View {
    /// 排定回调（装配层接 `scheduler.schedule` 并收起面板）。
    var onSchedule: (RecordingScheduler.Schedule) -> Void
    /// 取消回调（装配层收起面板）。
    var onClose: () -> Void

    /// 开始时刻（默认「N 分钟后」档位对应时刻——「快速设定」与日期选择共用同一真源）。
    @State private var startAt = Date().addingTimeInterval(
        Double(ScheduledRecordingPanelView.defaultLeadMinutes) * 60)
    /// 「N 分钟后」快速设定档位（stepper 改动即以「当前时刻 + N 分钟」覆写开始时刻）。
    @State private var minutesFromNow = ScheduledRecordingPanelView.defaultLeadMinutes
    /// 时长上限开关（opt-in，默认不限时）。
    @State private var limitEnabled = false
    /// 时长上限档位（分钟）。
    @State private var limitMinutes = ScheduledRecordingPanelView.defaultLimitMinutes

    /// 默认提前量（分钟）。
    private static let defaultLeadMinutes = 10
    /// 默认时长上限（分钟）。
    private static let defaultLimitMinutes = 30
    /// 「N 分钟后」合法档位 1…1440（1 分钟 ~ 24 小时）。
    private static let leadMinutesRange = 1...1440
    /// 时长上限合法档位 1…720 分钟（12 小时封顶——定时录制上限是兜底闸，不替代手动停止）。
    private static let limitMinutesRange = 1...720

    /// 开始时刻已过（不能排定——过去时刻排定会被调度器按「错过」路径立即补通知）。
    private var isStartAtPast: Bool {
        startAt < Date()
    }

    var body: some View {
        Form {
            DatePicker("开始时刻", selection: $startAt)
            Stepper(value: $minutesFromNow, in: Self.leadMinutesRange) {
                Text("快速设定：\(minutesFromNow) 分钟后")
            }
            .onChange(of: minutesFromNow) { newValue in
                startAt = Date().addingTimeInterval(TimeInterval(newValue) * 60)
            }
            Toggle("限制录制时长", isOn: $limitEnabled)
            if limitEnabled {
                Stepper(value: $limitMinutes, in: Self.limitMinutesRange) {
                    Text("时长上限：\(limitMinutes) 分钟")
                }
            }
            if isStartAtPast {
                Label("开始时刻早于当前时间，不能排定", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("排定") {
                    onSchedule(RecordingScheduler.Schedule(
                        startAt: startAt,
                        durationLimit: limitEnabled ? TimeInterval(limitMinutes) * 60 : nil))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isStartAtPast)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
