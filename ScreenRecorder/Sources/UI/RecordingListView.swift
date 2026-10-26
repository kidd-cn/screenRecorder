import AppKit
import SwiftUI

/// 文件列表窗口（Task 18 brief Produces）：`Table` 列名称/大小/时长/创建时间；行操作
/// 播放（`NSWorkspace.shared.open`）/ Finder 显示 / 重命名 / 删除（`NSAlert` 确认）。
/// 刷新入口（审查修复轮 1）：窗口内容内底部刷新栏（条目数随显）——SwiftUI `.toolbar`
/// 从 NSHostingView 桥接进 NSWindow 需 macOS 14（sceneBridgingOptions），macOS 13 不渲染，
/// 故不用工具栏；复用窗口（`isReleasedWhenClosed = false`）下 `.task` 每窗口生命周期仅
/// 首帧一次，故首开刷新（`.task`）+ 每次激活刷新（didBecomeKeyNotification，由
/// `RecordingListWindowController` 承担）双通道。列表真源是 `RecordingListViewModel`
///（store 经取数缝在调用时刻读装配层当前值——输出目录变更后刷新即见新目录，T17 审查修复）。
///
/// 行操作挂载方式（偏差台账）：brief 行操作以右键行菜单 + 双击行（播放）承载——SDK
///（Xcode 27.1 / Swift 6.4）下 `Table(_:actions:columns:)` 初始化器在最小用例即泛型推断
/// 失败无法编译，改用 macOS 13 起的官方等价物 `contextMenu(forSelectionType:menu:primaryAction:)`；
/// 操作集合与 brief 逐字一致。
/// 重命名走模态 sheet（macOS 13 `Table` 无单元格就地编辑；brief「rename inline」的等价实现）。
struct RecordingListView: View {
    @ObservedObject var viewModel: RecordingListViewModel

    @State private var renameTarget: RecordingFileMetadata?
    @State private var renameText = ""

    var body: some View {
        Table(viewModel.items) {
            TableColumn("名称", value: \.name)
            TableColumn("大小") { item in
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
            }
            TableColumn("时长") { item in
                Text(Self.durationText(item.duration))
            }
            TableColumn("创建时间") { item in
                Text(Self.createdAtText(item.createdAt))
            }
        }
        .contextMenu(forSelectionType: RecordingFileMetadata.self) { selection in
            rowMenu(for: selection)
        } primaryAction: { selection in
            if let item = selection.first { // 双击行：播放
                NSWorkspace.shared.open(item.url)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .sheet(item: $renameTarget) { item in
            renameSheet(item: item)
        }
        .task { await viewModel.refresh() } // 窗口首开刷新（复用窗口下仅生命周期首帧一次；后续激活刷新由窗口 didBecomeKeyNotification 承担）
    }

    /// 内容区底部刷新栏（审查修复轮 1 #1）：macOS 13 可渲染的窗口内控件——刷新按钮 +
    /// 条目计数。
    private var bottomBar: some View {
        HStack {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Spacer()
            Text("\(viewModel.items.count) 个录制")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - 行操作（右键菜单；选中集非单选时部分操作收敛）

    @ViewBuilder
    private func rowMenu(for selection: Set<RecordingFileMetadata>) -> some View {
        Button("播放") {
            selection.forEach { NSWorkspace.shared.open($0.url) }
        }
        .disabled(selection.isEmpty)
        Button("在 Finder 中显示") {
            if let first = selection.first {
                viewModel.revealInFinder(first)
            }
        }
        .disabled(selection.isEmpty)
        Button("重命名…") {
            guard let item = selection.first else { return }
            renameText = item.name
            renameTarget = item
        }
        .disabled(selection.count != 1)
        Button("删除…", role: .destructive) {
            confirmDelete(Array(selection))
        }
        .disabled(selection.isEmpty)
    }

    // MARK: - 重命名（inline 语义的模态等价实现）

    private func renameSheet(item: RecordingFileMetadata) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名录像").font(.headline)
            TextField("名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    renameTarget = nil
                }
                Button("确定") {
                    commitRename(item: item)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename(currentName: item.name))
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func canRename(currentName: String) -> Bool {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != currentName
    }

    private func commitRename(item: RecordingFileMetadata) {
        let target = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard canRename(currentName: item.name) else { return }
        Task {
            do {
                try await viewModel.rename(item, to: target)
            } catch {
                // 失败可见（审查修复轮 1 #4）：模型侧已 refresh 以磁盘复核列表，此处告警。
                presentRenameFailure(error)
            }
        }
    }

    /// 重命名失败反馈：NSAlert 呈现原因——同名冲突给明确文案，其余（权限等）透出系统
    /// 本地化描述；列表已由模型 refresh 复核磁盘现状。
    private func presentRenameFailure(_ error: Error) {
        let nsError = error as NSError
        let detail: String
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileWriteFileExists {
            detail = "同名文件已存在，请换一个名称。"
        } else {
            detail = nsError.localizedDescription
        }
        let alert = NSAlert()
        alert.messageText = "重命名失败"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 删除（brief：NSAlert 带确认）

    private func confirmDelete(_ targets: [RecordingFileMetadata]) {
        guard let first = targets.first else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "删除「\(first.name)」？" : "删除 \(targets.count) 条录像？"
        alert.informativeText = "录像文件将从磁盘删除，且不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in targets {
            viewModel.delete(item)
        }
    }

    // MARK: - 展示格式

    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let total = Int(duration.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func createdAtText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
