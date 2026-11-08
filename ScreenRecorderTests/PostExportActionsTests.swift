import XCTest

@testable import ScreenRecorder

/// Q6 编辑导出后动作「计划面」钉测（纯函数）：动作顺序（reveal 在前钉定）、删除
/// 三重校验（开关开 && 成片在盘 && 字节 > 0）、草稿随删搭载（draftURL nil 则不带）。
/// 反目标「任何校验不通过场景误删原始文件」的静态闸：校验不过的计划面绝不产出
/// delete 动作（执行侧生产闭包另有同款校验——纵深防御第二道）。
final class PostExportActionsTests: XCTestCase {
    private let outputURL = URL(fileURLWithPath: "/tmp/钉测/录屏_2026-11-08_09-00-00_缩放.mp4")
    private let originalURL = URL(fileURLWithPath: "/tmp/钉测/录屏_2026-11-08_09-00-00.mp4")
    private let draftURL = URL(fileURLWithPath: "/tmp/钉测/录屏_2026-11-08_09-00-00.mp4.zoomdraft.json")

    /// 双开关全关 → 空计划（默认关：不 reveal 不删）。
    func testPlanEmptyWhenBothDisabled() {
        XCTAssertTrue(
            PostExportActions.plan(
                revealEnabled: false, deleteEnabled: false, outputURL: outputURL,
                outputExists: true, outputBytes: 100,
                originalURL: originalURL, draftURL: draftURL)
                .isEmpty,
            "双开关关：无任何动作")
    }

    /// 只开 reveal → 仅 reveal 动作且指向新成片（不删）。
    func testPlanRevealOnlyWhenOnlyRevealEnabled() {
        XCTAssertEqual(
            PostExportActions.plan(
                revealEnabled: true, deleteEnabled: false, outputURL: outputURL,
                outputExists: true, outputBytes: 100,
                originalURL: originalURL, draftURL: draftURL),
            [.revealInFinder(outputURL)],
            "只开 reveal：恰一个 reveal 动作，指向新成片")
    }

    /// 开删除 + 成片在盘但 0 字节 → 无 delete（三重校验之「字节 > 0」，防误删空产物）。
    func testPlanSkipsDeleteWhenOutputZeroBytes() {
        XCTAssertEqual(
            PostExportActions.plan(
                revealEnabled: true, deleteEnabled: true, outputURL: outputURL,
                outputExists: true, outputBytes: 0,
                originalURL: originalURL, draftURL: draftURL),
            [.revealInFinder(outputURL)],
            "0 字节成片不得进删除计划（反目标：任何校验不通过场景不得误删原始文件）")
    }

    /// 开删除 + 成片不在盘 → 无 delete（三重校验之「在盘」；reveal 关则整体空计划）。
    func testPlanSkipsDeleteWhenOutputMissing() {
        XCTAssertEqual(
            PostExportActions.plan(
                revealEnabled: false, deleteEnabled: true, outputURL: outputURL,
                outputExists: false, outputBytes: 100,
                originalURL: originalURL, draftURL: draftURL),
            [],
            "成片不在盘不得触发删除；reveal 关 → 无动作")
    }

    /// 全条件过（reveal + delete + 在盘 + 字节 > 0 + draftURL 在）→ 恰两动作，
    /// **reveal 在前**（顺序钉定：Finder 焦点绝不被删除动作抢走），delete 搭载草稿。
    func testPlanDeletesWithDraftRidingAlong() {
        XCTAssertEqual(
            PostExportActions.plan(
                revealEnabled: true, deleteEnabled: true, outputURL: outputURL,
                outputExists: true, outputBytes: 100,
                originalURL: originalURL, draftURL: draftURL),
            [.revealInFinder(outputURL), .deleteOriginal(original: originalURL, draft: draftURL)],
            "全条件过：reveal 在前，delete 搭载草稿（<成片>.zoomdraft.json）")
    }

    /// 全条件过但 draftURL nil → delete 不带草稿（无草稿场景不造 URL）。
    func testPlanDeleteWithoutDraftWhenDraftNil() {
        XCTAssertEqual(
            PostExportActions.plan(
                revealEnabled: false, deleteEnabled: true, outputURL: outputURL,
                outputExists: true, outputBytes: 100,
                originalURL: originalURL, draftURL: nil),
            [.deleteOriginal(original: originalURL, draft: nil)],
            "draftURL nil → delete 不搭载草稿")
    }
}
