import XCTest

@testable import ScreenRecorder

/// SCStreamRecorder 暂停/恢复生命周期边界（Task 10）。不启动真实采集（SCStream 需要
/// 屏幕录制权限，无头不可用），只验证「未开始录制」的边界语义；暂停门控/平移/单调
/// 护栏的状态机行为由 PauseMediaClockTests 覆盖。
final class SCStreamRecorderPauseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SCStreamRecorderPauseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func makeRecorder() -> SCStreamRecorder {
        SCStreamRecorder(config: RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: true,
            captureMicrophone: true,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: directory.appendingPathComponent("录屏_pause.mp4"),
            clickHighlightEnabled: false
        ))
    }

    /// 生命周期边界（Task 10 报告裁定）：录制未开始时 pause/resume 为 no-op——
    /// 不抛错、不置位（上层浮条无需跟踪录制生命周期状态）。
    func testPauseResumeBeforeStartAreNoOps() {
        let recorder = makeRecorder()

        XCTAssertFalse(recorder.isPaused)
        recorder.pause()
        XCTAssertFalse(recorder.isPaused, "录制未开始时 pause 必须 no-op")
        recorder.resume()
        XCTAssertFalse(recorder.isPaused, "录制未开始时 resume 必须 no-op")
    }

    /// 重复 pause/resume 幂等且边界外调用无副作用。
    func testRepeatedCallsStayNoOps() {
        let recorder = makeRecorder()

        recorder.pause()
        recorder.pause()
        XCTAssertFalse(recorder.isPaused)
        recorder.resume()
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
    }
}
