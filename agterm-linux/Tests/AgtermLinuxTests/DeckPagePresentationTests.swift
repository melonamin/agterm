import Testing
@testable import AgtermLinux

@Suite("Linux terminal deck presentation")
struct DeckPagePresentationTests {
    @Test("normal mode maps and targets only the active session")
    func normalMode() {
        let active = DeckPagePresentation(isActive: true, dashboardOpen: false)
        #expect(active.childVisible)
        #expect(active.opacity == 1)
        #expect(active.canTarget)

        let inactive = DeckPagePresentation(isActive: false, dashboardOpen: false)
        #expect(!inactive.childVisible)
        #expect(inactive.opacity == 0)
        #expect(!inactive.canTarget)
    }

    @Test("dashboard renders every session beneath its opaque host without accepting input")
    func dashboardMode() {
        let active = DeckPagePresentation(isActive: true, dashboardOpen: true)
        #expect(active.childVisible)
        #expect(active.opacity == 1)
        #expect(!active.canTarget)

        let inactive = DeckPagePresentation(isActive: false, dashboardOpen: true)
        #expect(inactive.childVisible)
        #expect(inactive.opacity == 1)
        #expect(!inactive.canTarget)
    }
}
