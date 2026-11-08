import Foundation

/// 编辑导出完成后的动作（Q6，仅缩放分段编辑器导出挂钩）：`plan` 是**纯函数**计划面
///——编排层（RecordingListViewModel.renderZoom 成功路径）拉取输出现状（存在性/字节
/// 数）与偏好开关喂进来，产出一串按序动作；执行面（reveal / delete 闭包缝）归装配层
/// 注入，计划面不做任何 IO。
///
/// 顺序钉定（spec 安全纪律）：reveal 恒在前——Finder 焦点绝不被删除动作抢走；reveal
/// 恒指向**新成片**（outputURL）；删除完成通知向用户注明原始文件已删（见
/// `ExportNotifying.notifyExportCompleted(fileURL:originalDeleted:)` 文案钉定）。
///
/// 反目标（出现即失败）：「Q6 在任何校验不通过场景误删原始文件」。计划面闸门：delete
/// 动作仅当 `deleteEnabled && outputExists && outputBytes > 0` 才入计划（三重校验的
/// 第一道）；执行侧生产 delete 闭包在删除前再做一道同款校验（纵深防御第二道，见
/// AppAssembly 装配注释）——两道闸各自独立成立，任何一道不过即不删。
enum PostExportAction: Equatable {
    /// 在 Finder 中定位并选中（reveal 恒指向新成片）。
    case revealInFinder(URL)
    /// 删除原始成片；`draft` 随删搭载（`<成片>.zoomdraft.json`，nil 则不带）。
    case deleteOriginal(original: URL, draft: URL?)
}

enum PostExportActions {
    /// 顺序钉定：reveal 在前。delete 仅当 deleteEnabled && outputExists && outputBytes > 0；
    /// draft 随 delete 搭载（draftURL nil 则不带）。
    static func plan(revealEnabled: Bool, deleteEnabled: Bool, outputURL: URL,
                     outputExists: Bool, outputBytes: Int64,
                     originalURL: URL, draftURL: URL?) -> [PostExportAction] {
        var actions: [PostExportAction] = []
        if revealEnabled {
            actions.append(.revealInFinder(outputURL))
        }
        if deleteEnabled, outputExists, outputBytes > 0 {
            actions.append(.deleteOriginal(original: originalURL, draft: draftURL))
        }
        return actions
    }
}
