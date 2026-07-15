struct GhosttyResourceResolver {
    let candidates: [String]
    let fileExists: (String) -> Bool

    func resolve() -> String? {
        candidates.first { fileExists($0 + "/shell-integration") }
    }
}
