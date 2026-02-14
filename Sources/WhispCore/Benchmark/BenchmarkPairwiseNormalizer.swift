import Foundation

public struct BenchmarkPairCanonicalID: Codable, Equatable, Hashable, Sendable {
    public let leftCandidateID: String
    public let rightCandidateID: String

    public init(leftCandidateID: String, rightCandidateID: String) {
        self.leftCandidateID = leftCandidateID
        self.rightCandidateID = rightCandidateID
    }

    public var pairKeyCandidateID: String {
        "pair:\(leftCandidateID)__vs__\(rightCandidateID)"
    }
}

public struct BenchmarkPairExecutionOrder: Codable, Equatable, Sendable {
    public let firstCandidateID: String
    public let secondCandidateID: String

    public init(firstCandidateID: String, secondCandidateID: String) {
        self.firstCandidateID = firstCandidateID
        self.secondCandidateID = secondCandidateID
    }
}

public enum BenchmarkPairwiseNormalizer {
    public static func canonicalize(_ first: String, _ second: String) -> BenchmarkPairCanonicalID {
        if first <= second {
            return BenchmarkPairCanonicalID(leftCandidateID: first, rightCandidateID: second)
        }
        return BenchmarkPairCanonicalID(leftCandidateID: second, rightCandidateID: first)
    }

    public static func normalize(
        first: String,
        second: String
    ) -> (canonical: BenchmarkPairCanonicalID, execution: BenchmarkPairExecutionOrder) {
        let canonical = canonicalize(first, second)
        let execution = BenchmarkPairExecutionOrder(firstCandidateID: first, secondCandidateID: second)
        return (canonical, execution)
    }
}
