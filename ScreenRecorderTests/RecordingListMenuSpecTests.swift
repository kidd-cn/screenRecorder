import AppKit
import XCTest

@testable import ScreenRecorder

/// 文件列表右键菜单规格钉测（交互层修复）：条目/顺序/置灰语义与原 SwiftUI
/// `contextMenu(forSelectionType:)` 菜单逐字一致；NSMenu 组装须镜像规格。
final class RecordingListMenuSpecTests: XCTestCase {
    private let expectedTitles = [
        "播放", "在 Finder 中显示", "重命名…", "编辑…", "导出 GIF…", "压缩…", "移出列表", "删除…"
    ]

    /// 空白区右键（空选择）→ 全灰菜单（对齐旧行为）。
    private func noOpHandlers() -> RecordingListMenuSpec.Handlers {
        .init(
            play: {}, reveal: {}, rename: {}, edit: {},
            exportGIF: {}, compress: {}, removeFromList: {}, delete: {})
    }

    private func enabledActions(_ entries: [RecordingListMenuSpec.Entry]) -> [String] {
        entries.filter(\.isEnabled).map(\.title)
    }

    func testTitlesAndOrderMatchBriefVerbatim() {
        let entries = RecordingListMenuSpec.entries(selectionCount: 1, firstIsAudioOnly: false)
        XCTAssertEqual(entries.map(\.title), expectedTitles)
        XCTAssertEqual(entries.last?.isDestructive, true) // 仅「删除…」destructive
        XCTAssertEqual(entries.dropLast().filter(\.isDestructive).count, 0)
    }

    func testEmptySelectionDisablesEverything() {
        let entries = RecordingListMenuSpec.entries(selectionCount: 0, firstIsAudioOnly: false)
        XCTAssertEqual(entries.filter(\.isEnabled).count, 0, "空选择须全灰（空白区右键）")
    }

    func testSingleVideoSelectionEnablesEverything() {
        let entries = RecordingListMenuSpec.entries(selectionCount: 1, firstIsAudioOnly: false)
        XCTAssertEqual(enabledActions(entries), expectedTitles)
    }

    func testSingleAudioOnlySelectionDisablesEditOnly() {
        // 仅声音成片（.m4a）无视频画布 → 编辑…不适用，其余单选操作可用。
        let entries = RecordingListMenuSpec.entries(selectionCount: 1, firstIsAudioOnly: true)
        XCTAssertEqual(
            entries.filter { !$0.isEnabled }.map(\.title), ["编辑…"],
            "单选纯声音成片只应置灰「编辑…」")
    }

    func testMultiSelectionKeepsBatchActionsOnly() {
        // 多选收敛：仅批量动作（播放/Finder/移出列表/删除）可用，单选动作全灰。
        let entries = RecordingListMenuSpec.entries(selectionCount: 3, firstIsAudioOnly: false)
        XCTAssertEqual(
            enabledActions(entries),
            ["播放", "在 Finder 中显示", "移出列表", "删除…"])
    }

    func testMenuAssemblyMirrorsSpec() {
        // 组装薄层不得偏离规格：条数/标题/置灰一一对应。
        let menu = RecordingListMenuSpec.menu(
            selectionCount: 3, firstIsAudioOnly: false, handlers: noOpHandlers())
        let items = menu.items
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items.map(\.title), expectedTitles)
        XCTAssertEqual(
            items.filter(\.isEnabled).map(\.title),
            ["播放", "在 Finder 中显示", "移出列表", "删除…"])
        // 「删除…」红字走标题属性，其余条目用普通标题。
        XCTAssertNotNil(items.last?.attributedTitle, "「删除…」须红字（attributedTitle）")
        XCTAssertEqual(items.dropLast().filter { $0.attributedTitle != nil }.count, 0)
    }

    func testMenuProxyDispatchesToWiredHandler() {
        // 点击分发：各条目的代理须回调到对应 handler（组装接线钉测）。
        var fired: [String] = []
        let menu = RecordingListMenuSpec.menu(
            selectionCount: 1, firstIsAudioOnly: false,
            handlers: .init(
                play: { fired.append("播放") }, reveal: { fired.append("显示") },
                rename: { fired.append("重命名") }, edit: { fired.append("编辑") },
                exportGIF: { fired.append("GIF") }, compress: { fired.append("压缩") },
                removeFromList: { fired.append("移出") }, delete: { fired.append("删除") }))
        XCTAssertEqual(fired, [])
        for item in menu.items {
            (item.target as? MenuActionProxy)?.picked()
        }
        XCTAssertEqual(fired, ["播放", "显示", "重命名", "编辑", "GIF", "压缩", "移出", "删除"])
    }
}
