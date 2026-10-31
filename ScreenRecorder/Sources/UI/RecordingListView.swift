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
/// P8（T16）导出入口：右键菜单「导出 GIF…」「压缩…」→ 模态参数小窗（参数档位直接绑
/// `GIFExportOptions`/`CompressionPreset` 档位集合）+ 进度条（`exportProgress` 已由模型
/// hop 主线程）；完成/失败自动收窗，结果走通知（ExportNotifying 缝）。
struct RecordingListView: View {
    @ObservedObject var viewModel: RecordingListViewModel

    @State private var renameTarget: RecordingFileMetadata?
    @State private var renameText = ""
    @State private var exportTarget: ExportTarget?

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
        .sheet(item: $exportTarget) { target in
            switch target.kind {
            case .gif:
                GIFExportSheet(
                    item: target.item,
                    suggestedName: viewModel.suggestedGIFDestinationName(for: target.item),
                    viewModel: viewModel)
            case .compress:
                CompressSheet(
                    item: target.item,
                    suggestedName: viewModel.suggestedCompressedDestinationName(for: target.item),
                    viewModel: viewModel)
            }
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
        Button("导出 GIF…") {
            guard let item = selection.first else { return }
            exportTarget = ExportTarget(item: item, kind: .gif)
        }
        .disabled(selection.count != 1)
        Button("压缩…") {
            guard let item = selection.first else { return }
            exportTarget = ExportTarget(item: item, kind: .compress)
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

// MARK: - 导出参数小窗（P8/T16）：模态参数 + 进度条

/// 导出小窗载荷（`sheet(item:)` 需 Identifiable）：目标条目 + 种类；参数在小窗内选。
private struct ExportTarget: Identifiable {
    enum Kind {
        case gif
        case compress
    }

    let item: RecordingFileMetadata
    let kind: Kind
    var id: URL { item.id }
}

/// GIF 导出小窗：帧率/宽度/循环参数档位直接绑 `GIFExportOptions` 档位集合（UI 不另造
/// 档位）；输出名预填模型建议名（`<原名>_gif.gif`，含冲突惯例）。开始导出后切换进度条
///（`exportProgress` 已由模型 hop 主线程）；完成/失败自动收窗，结果走通知。
private struct GIFExportSheet: View {
    let item: RecordingFileMetadata
    let suggestedName: String
    @ObservedObject var viewModel: RecordingListViewModel

    @State private var frameRate = 10
    @State private var widthChoice: WidthChoice = .w720
    @State private var loops = true

    @Environment(\.dismiss) private var dismiss

    /// 宽度档位：`GIFExportOptions.maxWidth` 集合 {480, 720, nil(原始)} 的 Pickable 映射。
    enum WidthChoice: Hashable {
        case w480, w720, original

        var maxWidth: Int? {
            switch self {
            case .w480: return 480
            case .w720: return 720
            case .original: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出 GIF").font(.headline)
            Text("输出：\(suggestedName)（与源同目录）")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("帧率", selection: $frameRate) {
                Text("5 fps").tag(5)
                Text("10 fps").tag(10)
                Text("15 fps").tag(15)
            }
            Picker("宽度", selection: $widthChoice) {
                Text("480 px").tag(WidthChoice.w480)
                Text("720 px").tag(WidthChoice.w720)
                Text("原始宽度").tag(WidthChoice.original)
            }
            Toggle("循环播放", isOn: $loops)
            progressArea
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    // 导出进行中取消仅收窗：编排无取消通道，结果仍走通知。
                    dismiss()
                }
                Button("开始导出") {
                    Task {
                        await viewModel.exportGIF(
                            item,
                            options: GIFExportOptions(
                                frameRate: frameRate, maxWidth: widthChoice.maxWidth, loops: loops))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.exportProgress != nil)
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .onChange(of: viewModel.exportProgress) { progress in
            if progress == nil { dismiss() } // 完成/失败均收窗（结果走通知）
        }
    }

    @ViewBuilder
    private var progressArea: some View {
        if let progress = viewModel.exportProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("正在导出 GIF…\(Int((progress * 100).rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 压缩小窗：编码/最大高度档位直接绑 `CompressionPreset` 档位集合；其余同 GIF 小窗。
private struct CompressSheet: View {
    let item: RecordingFileMetadata
    let suggestedName: String
    @ObservedObject var viewModel: RecordingListViewModel

    @State private var codec: VideoCodec = .hevc
    @State private var heightChoice: HeightChoice = .source

    @Environment(\.dismiss) private var dismiss

    /// 高度档位：`CompressionPreset.maxHeight` 集合 {nil(源), 1080, 720} 的 Pickable 映射。
    enum HeightChoice: Hashable {
        case source, h1080, h720

        var maxHeight: Int? {
            switch self {
            case .source: return nil
            case .h1080: return 1080
            case .h720: return 720
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("压缩录像").font(.headline)
            Text("输出：\(suggestedName)（与源同目录）")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("编码", selection: $codec) {
                Text("H.264").tag(VideoCodec.h264)
                Text("HEVC").tag(VideoCodec.hevc)
            }
            Picker("最大高度", selection: $heightChoice) {
                Text("源分辨率").tag(HeightChoice.source)
                Text("1080p").tag(HeightChoice.h1080)
                Text("720p").tag(HeightChoice.h720)
            }
            progressArea
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    dismiss() // 同 GIF 小窗：进行中取消仅收窗，结果仍走通知。
                }
                Button("开始压缩") {
                    Task {
                        await viewModel.compress(
                            item,
                            preset: CompressionPreset(
                                codec: codec, maxHeight: heightChoice.maxHeight))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.exportProgress != nil)
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .onChange(of: viewModel.exportProgress) { progress in
            if progress == nil { dismiss() }
        }
    }

    @ViewBuilder
    private var progressArea: some View {
        if let progress = viewModel.exportProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("正在压缩…\(Int((progress * 100).rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
