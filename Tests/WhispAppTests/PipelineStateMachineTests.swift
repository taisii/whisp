import XCTest
@testable import WhispApp

final class PipelineStateMachineTests: XCTestCase {
    func testHappyPathTransitions() {
        var machine = PipelineStateMachine()

        XCTAssertEqual(machine.current, .idle)
        XCTAssertEqual(machine.apply(.startRecording), .recording)
        XCTAssertEqual(machine.apply(.stopRecording), .sttStreaming)
        XCTAssertEqual(machine.apply(.startPostProcessing), .postProcessing)
        XCTAssertEqual(machine.apply(.startDirectInput), .directInput)
        XCTAssertEqual(machine.apply(.finish), .done)
        XCTAssertEqual(machine.apply(.reset), .idle)
    }

    func testInvalidTransitionKeepsState() {
        var machine = PipelineStateMachine()

        XCTAssertEqual(machine.apply(.startPostProcessing), .idle)
        XCTAssertEqual(machine.apply(.startRecording), .recording)
        XCTAssertEqual(machine.apply(.startDirectInput), .recording)
        XCTAssertEqual(machine.current, .recording)
    }

    func testFailCanInterruptAnyState() {
        var machine = PipelineStateMachine()

        _ = machine.apply(.startRecording)
        XCTAssertEqual(machine.apply(.fail), .error)
        XCTAssertEqual(machine.apply(.reset), .idle)
    }
}
