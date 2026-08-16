import Foundation
import StellarCore
import StellarMediaLibrary
import Testing

@Suite("Metadata candidate matching")
struct MetadataMatchingTests {
  @Test("Shared fixture produces deterministic scores, decisions, and order")
  func matchesSharedFixture() throws {
    let fixture = try loadFixture()
    let scorer = MediaMetadataCandidateScorer()

    #expect(fixture.schemaVersion == 1)
    for testCase in fixture.cases {
      let ranked = scorer.rank(query: testCase.query, candidates: testCase.candidates)
      #expect(ranked.count == testCase.expected.count, "Fixture: \(testCase.name)")
      for (actual, expected) in zip(ranked, testCase.expected) {
        #expect(actual.candidate.candidateID == expected.candidateID, "Fixture: \(testCase.name)")
        #expect(abs(actual.score - expected.score) < 0.000_001, "Fixture: \(testCase.name)")
        #expect(actual.decision == expected.decision, "Fixture: \(testCase.name)")
        #expect(actual.signals == expected.signals, "Fixture: \(testCase.name)")
      }
    }
  }

  @Test("Query builder gives local series metadata precedence for episodes")
  func queryBuilderPrecedence() throws {
    let filename = ParsedMediaFilename(
      kind: .episode,
      title: "Filename Show",
      season: 2,
      episode: 3,
      sourceName: "Filename.Show.S02E03.mkv"
    )
    let identifier = try LocalMetadataExternalID(
      provider: "tmdb",
      namespace: "series",
      value: "119051",
      isPrimary: true
    )
    let localMetadata = try LocalMetadataDocument(
      kind: .series,
      title: "Wednesday",
      year: 2022,
      externalIDs: [identifier]
    )

    let query = try MediaMatchQueryBuilder().build(
      filename: filename,
      localMetadata: localMetadata
    )

    #expect(query.kind == .episode)
    #expect(query.title == "Wednesday")
    #expect(query.year == 2022)
    #expect(query.season == 2)
    #expect(query.episode == 3)
    #expect(query.externalIDs == [identifier])
  }

  @Test("Query builder ignores incompatible local metadata")
  func ignoresIncompatibleLocalMetadata() throws {
    let filename = ParsedMediaFilename(
      kind: .movie,
      title: "Arrival",
      year: 2016,
      sourceName: "Arrival.2016.mkv"
    )
    let seriesMetadata = try LocalMetadataDocument(
      kind: .series,
      title: "Unrelated Show",
      year: 2020
    )

    let query = try MediaMatchQueryBuilder().build(
      filename: filename,
      localMetadata: seriesMetadata
    )

    #expect(query.kind == .movie)
    #expect(query.title == "Arrival")
    #expect(query.year == 2016)
  }

  @Test("Synthetic providers use the same injectable search seam")
  func providerInjection() async throws {
    let testCase = try #require(loadFixture().cases.first)
    let provider = SyntheticMetadataProvider(candidates: testCase.candidates)

    let candidates = try await provider.search(testCase.query)
    let ranked = MediaMetadataCandidateScorer().rank(
      query: testCase.query,
      candidates: candidates
    )

    #expect(ranked.first?.candidate.candidateID == "dune-2021")
    #expect(ranked.first?.decision == .automatic)
  }

  @Test("Incomplete queries and invalid thresholds fail before provider work")
  func validatesInputs() {
    #expect(throws: SDKError.self) {
      try MediaMatchQuery(kind: .unknown, title: "Unknown")
    }
    #expect(throws: SDKError.self) {
      try MediaMatchQuery(kind: .episode, title: "Show", season: 1)
    }
    #expect(throws: SDKError.self) {
      try MediaMatchScoringPolicy(automaticThreshold: 0.7, reviewThreshold: 0.8)
    }
  }

  private func loadFixture() throws -> MetadataMatchingFixture {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/metadata-matching-v1.json")
    return try JSONDecoder().decode(
      MetadataMatchingFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
  }
}

private struct SyntheticMetadataProvider: MediaMetadataProviding {
  let candidates: [MediaMetadataCandidate]

  func search(_: MediaMatchQuery) async throws -> [MediaMetadataCandidate] {
    candidates
  }
}

private struct MetadataMatchingFixture: Decodable {
  let schemaVersion: Int
  let cases: [MetadataMatchingFixtureCase]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case cases
  }
}

private struct MetadataMatchingFixtureCase: Decodable {
  let name: String
  let query: MediaMatchQuery
  let candidates: [MediaMetadataCandidate]
  let expected: [ExpectedMetadataMatch]
}

private struct ExpectedMetadataMatch: Decodable {
  let candidateID: String
  let score: Double
  let decision: MediaMatchDecision
  let signals: [MediaMatchSignal]

  private enum CodingKeys: String, CodingKey {
    case candidateID = "candidate_id"
    case score
    case decision
    case signals
  }
}
