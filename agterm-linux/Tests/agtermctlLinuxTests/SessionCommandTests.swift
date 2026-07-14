import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlLinux

@Suite("agtermctl session command")
struct SessionCommandTests {
    @Test("status forwards stable pane token")
    func statusPaneID() throws {
        let command = try Agtermctl.parseAsRoot([
            "session", "status", "blocked", "--pane", "right", "--pane-id", "token-123",
        ])
        let status = try #require(command as? agtermctlLinux.Session.Status)
        let request = try status.makeRequest()
        #expect(request.args?.pane == "right")
        #expect(request.args?.paneID == "token-123")
    }
}
