import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherTextTests {
    @Test func sessionTextRoutesOptionsAndKeepsExactActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionTextResponse = ControlResponse(ok: true, result: ControlResult(text: "line\n"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionText,
            target: "session",
            args: ControlArgs(window: "win", pane: "scratch", lines: 10)
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: "line\n")))
        #expect(actions.calls == [
            .sessionText(target: "session", window: "win",
                         ControlSessionTextOptions(pane: "scratch", all: false, lines: 10))
        ])
    }

    @Test func sessionTextRejectsInvalidLineOptionsBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let both = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionText,
            args: ControlArgs(all: true, lines: 5)
        ))
        let zero = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionText,
            args: ControlArgs(lines: 0)
        ))

        #expect(both == ControlResponse(ok: false, error: "use either --all or --lines, not both"))
        #expect(zero == ControlResponse(ok: false, error: "--lines must be greater than 0"))
        #expect(actions.calls.isEmpty)
    }

    @Test func restoreClearRoutesThroughActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextRestoreClearResponse = ControlResponse(ok: true)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .restoreClear))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.restoreClear])
    }

}
