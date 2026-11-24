import XCTest
@testable import AmoreChatStandalone

final class SpeechInputTests: XCTestCase {
    func testPartialsReplaceEntireUtteranceAndStopWaitsForFinal() throws {
        var state = SpeechInputState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(id))
        XCTAssertTrue(state.partial("今天", id: id, callback: 1))
        XCTAssertTrue(state.partial("今天天气", id: id, callback: 2))
        XCTAssertEqual(state.transcript, "今天天气")
        XCTAssertTrue(state.stopping(id))
        XCTAssertEqual(state.phase, .finishing)
        XCTAssertTrue(state.partial("今天天气好", id: id, callback: 3))
        XCTAssertEqual(state.complete("今天天气很好。", id: id, callback: 4), "今天天气很好。")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.transcript, "今天天气很好。")
    }

    func testLateAndDuplicateCallbacksCannotCompleteAgain() throws {
        var state = SpeechInputState()
        let first = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(first))
        XCTAssertTrue(state.partial("半句话", id: first, callback: 1))
        XCTAssertEqual(state.complete("完整一句。", id: first, callback: 3), "完整一句。")
        XCTAssertFalse(state.partial("旧的回调", id: first, callback: 2))
        XCTAssertNil(state.complete("重复最终结果", id: first, callback: 4))
        let second = try XCTUnwrap(state.begin())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(state.started(second))
        XCTAssertFalse(state.partial("前一轮", id: first, callback: 5))
        XCTAssertNil(state.complete("前一轮最终结果", id: first, callback: 6))
        XCTAssertTrue(state.partial("新一轮", id: second, callback: 1))
        XCTAssertEqual(state.transcript, "新一轮")
    }

    func testOutOfOrderTasksDoNotRegressTranscriptOrFinalizeOldResult() throws {
        var state = SpeechInputState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(id))
        XCTAssertTrue(state.partial("新的识别", id: id, callback: 4))
        XCTAssertFalse(state.partial("旧的识别", id: id, callback: 2))
        XCTAssertNil(state.complete("旧的最终结果", id: id, callback: 3))
        XCTAssertEqual(state.transcript, "新的识别")
        XCTAssertEqual(state.complete("最新最终结果", id: id, callback: 5), "最新最终结果")
    }

    func testNaturalFinalRolloverPreservesEarlierSpeech() throws {
        var state = SpeechInputState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(id))
        XCTAssertTrue(state.partial("你好", id: id, callback: 1))
        XCTAssertTrue(state.rollSegment("你好。", id: id, callback: 2, segment: 0))
        XCTAssertEqual(state.segmentID, 1)
        XCTAssertEqual(state.transcript, "你好。")
        XCTAssertFalse(state.partial("旧回调", id: id, callback: 3, segment: 0))
        XCTAssertTrue(state.partial("继续说话", id: id, callback: 1, segment: 1))
        XCTAssertEqual(state.transcript, "你好。继续说话")
        XCTAssertTrue(state.stopping(id))
        XCTAssertEqual(state.complete("最终文本", id: id, callback: 2, segment: 1), "你好。最终文本")
        XCTAssertNil(state.complete("迟到的旧段", id: id, callback: 4, segment: 0))
    }

    func testLatinSegmentsHaveWordBoundary() throws {
        var state = SpeechInputState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(id))
        XCTAssertTrue(state.rollSegment("hello", id: id, callback: 1, segment: 0))
        XCTAssertTrue(state.partial("world", id: id, callback: 1, segment: 1))
        XCTAssertEqual(state.transcript, "hello world")
    }

    func testTimeoutUsesLastRealPartialAndCancellationDiscardsIt() throws {
        var state = SpeechInputState()
        let first = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(first))
        XCTAssertTrue(state.partial("真实语音", id: first, callback: 1))
        XCTAssertTrue(state.stopping(first))
        XCTAssertEqual(state.complete(nil, id: first), "真实语音")
        let second = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.started(second))
        XCTAssertTrue(state.partial("不发送", id: second, callback: 1))
        XCTAssertTrue(state.abandon(second))
        XCTAssertEqual(state.transcript, "")
        XCTAssertNil(state.complete("晚到的识别", id: second, callback: 2))
    }

    func testDoubleStopCannotRestartUntilCompletion() throws {
        var state = SpeechInputState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertNil(state.begin())
        XCTAssertTrue(state.started(id))
        XCTAssertTrue(state.stopping(id))
        XCTAssertFalse(state.stopping(id))
        XCTAssertNil(state.begin())
        XCTAssertEqual(state.complete(nil, id: id), "")
        XCTAssertNil(state.complete(nil, id: id))
        XCTAssertNotNil(state.begin())
    }

    func testPermissionStageCancellationBlocksLateStartAndCompletion() throws {
        var state = SpeechInputState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.stopping(id))
        XCTAssertTrue(state.abandon(id))
        XCTAssertFalse(state.started(id))
        XCTAssertNil(state.complete("未录到音", id: id))
        XCTAssertNil(state.complete(nil, id: id))
        XCTAssertEqual(state.phase, .idle)
    }
}
