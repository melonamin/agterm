import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherOverlayTests {
    @Test func sessionOverlayOpenRejectsInvalidInputsBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayOpen, target: "session"))
        let empty = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(command: "")
        ))
        let badColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(command: "cat", color: "purple")
        ))

        #expect(missing == ControlResponse(ok: false, error: "session.overlay.open requires a command"))
        #expect(empty == ControlResponse(ok: false, error: "session.overlay.open requires a command"))
        #expect(badColor == ControlResponse(ok: false, error: "invalid color: purple (#rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionOverlayOpenRoutesOptionsAndEchoesActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: false, error: "overlay already open")

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(cwd: "/tmp", command: "cat", wait: true,
                              sizePercent: 70, follow: true, window: "win", color: "#2a1a3a")
        ))

        #expect(response == ControlResponse(ok: false, error: "overlay already open"))
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: "win",
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: "/tmp", wait: true,
                                                          sizePercent: 70, backgroundColor: "#2a1a3a",
                                                          follow: true))
        ])
    }

    @Test func sessionOverlayOpenDefaultsFollowToFalseWhenOmitted() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen,
            target: "session",
            args: ControlArgs(command: "cat")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .overlayOpen(target: "session", window: nil,
                         ControlSessionOverlayOpenOptions(command: "cat", cwd: nil, wait: false,
                                                          sizePercent: nil, backgroundColor: nil,
                                                          follow: false))
        ])
    }

    @Test func sessionOverlayCloseAndResultRouteTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayCloseResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))
        actions.nextOverlayResultResponse = ControlResponse(ok: true, result: ControlResult(id: "session", exitCode: 7))

        let close = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayClose,
            target: "session",
            args: ControlArgs(window: "win")
        ))
        let result = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayResult,
            target: "session",
            args: ControlArgs(window: "win")
        ))

        #expect(close == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(result == ControlResponse(ok: true, result: ControlResult(id: "session", exitCode: 7)))
        #expect(actions.calls == [
            .overlayClose(target: "session", window: "win"),
            .overlayResult(target: "session", window: "win")
        ])
    }

    @Test func sessionOverlayResultKeepsExactActionErrorResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayResultResponse = ControlResponse(ok: false, error: OverlayResultError.stillRunning)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResult, target: "session"))

        #expect(response == ControlResponse(ok: false, error: OverlayResultError.stillRunning))
        #expect(actions.calls == [.overlayResult(target: "session", window: nil)])
    }

    @Test func sessionBackgroundRoutesParsedTextImageColorAndClearForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionBackgroundResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let text = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            target: "session",
            args: ControlArgs(text: "DRAFT", mode: "text", window: "win", color: "#ff0000",
                              opacity: 0.15, fit: "contain", position: "top-left")
        ))
        let image = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            target: "session",
            args: ControlArgs(mode: "image", path: "/tmp/bg.png", fit: "cover",
                              position: "bottom-right", repeats: true)
        ))
        let color = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            target: "session",
            args: ControlArgs(mode: "color", color: "#102030")
        ))
        let clear = await dispatcher.dispatch(ControlRequest(cmd: .sessionBackground, target: "session"))

        let textWatermark = BackgroundWatermark(kind: .text, text: "DRAFT", colorHex: "#ff0000",
                                                opacity: 0.15, fit: .contain, position: .topLeft)
        let imageWatermark = BackgroundWatermark(kind: .image, imagePath: "/tmp/bg.png",
                                                 fit: .cover, position: .bottomRight, repeats: true)
        let colorWatermark = BackgroundWatermark(kind: .color, colorHex: "#102030")
        #expect(text == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(image == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(color == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(clear == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .sessionBackground(target: "session", window: "win",
                               ControlSessionBackgroundOptions(watermark: textWatermark)),
            .sessionBackground(target: "session", window: nil,
                               ControlSessionBackgroundOptions(watermark: imageWatermark)),
            .sessionBackground(target: "session", window: nil,
                               ControlSessionBackgroundOptions(watermark: colorWatermark)),
            .sessionBackground(target: "session", window: nil,
                               ControlSessionBackgroundOptions(watermark: nil))
        ])
    }

    @Test func sessionBackgroundRejectsInvalidInputsBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let tooLong = String(repeating: "x", count: WatermarkConfig.maxTextLength + 1)

        let badFit = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "image", path: "/tmp/bg.png", fit: "wide")
        ))
        let badPosition = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "image", path: "/tmp/bg.png", position: "middle")
        ))
        let badOpacity = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "image", path: "/tmp/bg.png", opacity: 1.5)
        ))
        let missingPath = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "image")
        ))
        let controlPath = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "image", path: "/tmp/bg\n.png")
        ))
        let missingText = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "text")
        ))
        let longText = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(text: tooLong, mode: "text")
        ))
        let badTextColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(text: "DRAFT", mode: "text", color: "red")
        ))
        let missingColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "color")
        ))
        let badColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "color", color: "blue")
        ))
        let badMode = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBackground,
            args: ControlArgs(mode: "pattern")
        ))

        #expect(badFit == ControlResponse(ok: false, error: "invalid fit: wide (contain|cover|stretch|none)"))
        #expect(badPosition == ControlResponse(ok: false, error: "invalid position: middle"))
        #expect(badOpacity == ControlResponse(ok: false, error: "invalid opacity: 1.5 (0.0-1.0)"))
        #expect(missingPath == ControlResponse(ok: false, error: "session.background image requires a path"))
        #expect(controlPath == ControlResponse(ok: false, error: "image path must not contain control characters"))
        #expect(missingText == ControlResponse(ok: false, error: "session.background text requires text"))
        #expect(longText == ControlResponse(
            ok: false,
            error: "session.background text too long (max \(WatermarkConfig.maxTextLength) characters)"
        ))
        #expect(badTextColor == ControlResponse(ok: false, error: "invalid color: red (#rrggbb)"))
        #expect(missingColor == ControlResponse(ok: false, error: "session.background color requires a color"))
        #expect(badColor == ControlResponse(ok: false, error: "invalid color: blue (#rrggbb)"))
        #expect(badMode == ControlResponse(
            ok: false,
            error: "invalid background mode: pattern (image|text|color|clear)"
        ))
        #expect(actions.calls.isEmpty)
    }

}
