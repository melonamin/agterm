import Foundation

struct SessionSwitcherModel: Equatable, Sendable {
    private var candidates: [UUID] = []
    private var index = 0

    var isActive: Bool { !candidates.isEmpty }
    var current: UUID? { candidates.indices.contains(index) ? candidates[index] : nil }
    var ordered: [UUID] { candidates }

    mutating func begin(_ mru: [UUID]) -> UUID? {
        guard mru.count >= 2 else {
            candidates = []
            index = 0
            return nil
        }
        candidates = mru
        index = 1
        return current
    }

    mutating func advance() -> UUID? {
        guard !candidates.isEmpty else { return nil }
        index = (index + 1) % candidates.count
        return current
    }

    mutating func end() {
        candidates = []
        index = 0
    }
}
