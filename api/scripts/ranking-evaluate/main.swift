// The app's PlaceRanker as a command line tool, for scripts/ranking-evaluate.ts.
//
// Compiled together with the ranker and the models it reads, straight from the
// iOS sources (see `compileRanker` in the script), so what is measured is the
// very code that ships. Reads one JSON document on stdin: the cases to rank,
// each a fix and the candidates the API returned for it, plus any weights to
// override. Writes one JSON document on stdout: where each case's true venue
// landed.

import Foundation

struct EvaluationFix: Decodable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
}

struct EvaluationCase: Decodable {
    let name: String
    /// The id of the place the checkin was really at.
    let truthId: String
    let fix: EvaluationFix
    let candidates: [Place]
    let history: [CheckinHistoryEntry]?
}

/// Only the weights a tuning run is likely to sweep; add more as needed.
struct WeightOverrides: Decodable {
    let spatial: Double?
    let pinPlacementError: Double?
    let pointRadius: Double?
    let popularity: Double?
    let prior: Double?
    let history: Double?

    func apply(to weights: inout RankingWeights) {
        if let spatial { weights.spatial = spatial }
        if let pinPlacementError { weights.pinPlacementError = pinPlacementError }
        if let pointRadius { weights.pointRadius = pointRadius }
        if let popularity { weights.popularity = popularity }
        if let prior { weights.prior = prior }
        if let history { weights.history = history }
    }
}

struct EvaluationInput: Decodable {
    let cases: [EvaluationCase]
    let weights: WeightOverrides?
    /// ISO 8601; the instant the ranking is done at, for the time-of-day terms.
    let now: Date?
}

struct EvaluationResult: Encodable {
    let name: String
    /// 1-based position of the true venue, or 0 when it was not a candidate.
    let rank: Int
    let candidateCount: Int
    let suggested: Bool
    /// The leaders, for reading a failure: "Name (score)".
    let leaders: [String]
}

struct EvaluationOutput: Encodable {
    let results: [EvaluationResult]
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let input = try decoder.decode(EvaluationInput.self, from: FileHandle.standardInput.readDataToEndOfFile())

var weights = RankingWeights.standard
input.weights?.apply(to: &weights)
let ranker = PlaceRanker(weights: weights)
let now = input.now ?? Date()
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

let results = input.cases.map { evaluationCase -> EvaluationResult in
    let fix = LocationFix(
        latitude: evaluationCase.fix.latitude,
        longitude: evaluationCase.fix.longitude,
        horizontalAccuracy: evaluationCase.fix.horizontalAccuracy,
        timestamp: now
    )
    let ranking = ranker.rank(
        candidates: evaluationCase.candidates,
        fix: fix,
        history: evaluationCase.history ?? [],
        now: now,
        calendar: calendar
    )
    let position = ranking.ranked.firstIndex { $0.place.id == evaluationCase.truthId }
    return EvaluationResult(
        name: evaluationCase.name,
        rank: position.map { $0 + 1 } ?? 0,
        candidateCount: ranking.ranked.count,
        suggested: ranking.suggestion?.id == evaluationCase.truthId,
        leaders: ranking.ranked.prefix(3).map { "\($0.place.name) (\(String(format: "%.1f", $0.score)))" }
    )
}

let encoder = JSONEncoder()
let output = try encoder.encode(EvaluationOutput(results: results))
FileHandle.standardOutput.write(output)
