import Foundation
import StellarCore
import StellarMediaLibrary
import Testing

@Suite("Local metadata intake")
struct MetadataIntakeTests {
  @Test("Shared sidecar and NFO fixtures normalize deterministically")
  func matchesSharedFixture() throws {
    let fixture = try loadFixture()
    let classifier = MediaSidecarClassifier()
    let filenameParser = MediaFilenameParser()
    let nfoParser = NFOParser()
    let jsonParser = LocalMetadataJSONParser()

    #expect(fixture.schemaVersion == 1)
    for testCase in fixture.filenameEvidenceCases {
      let actual = try filenameParser.analyze(testCase.input)
      #expect(actual == testCase.expected, "Filename: \(testCase.input)")
    }
    for testCase in fixture.sidecarCases {
      let actual = try classifier.classify(
        mediaPath: testCase.mediaPath,
        candidatePath: testCase.candidatePath
      )
      #expect(actual == testCase.expected, "Sidecar: \(testCase.candidatePath)")
    }
    for testCase in fixture.nfoCases {
      let actual = try nfoParser.parse(Data(testCase.xml.utf8))
      #expect(actual == testCase.expected, "NFO: \(testCase.name)")
    }
    for testCase in fixture.localJSONCases {
      let actual = try jsonParser.parse(Data(testCase.json.utf8))
      #expect(actual == testCase.expected, "Local JSON: \(testCase.name)")
    }
  }

  @Test("Technical probe fixture round-trips and keeps stream order stable")
  func technicalProbeFixture() throws {
    let result = try loadFixture().technicalProbe

    #expect(result.probeProvider == "fixture-probe")
    #expect(result.summary.durationMilliseconds == 7_020_123)
    #expect(result.summary.width == 3_840)
    #expect(result.streams.map(\.streamIndex) == [0, 1, 2])
    #expect(result.streams[1].language == "en")
    #expect(result.streams[2].kind == .subtitle)

    let roundTrip = try JSONDecoder().decode(
      MediaTechnicalProbeResult.self,
      from: JSONEncoder().encode(result)
    )
    #expect(roundTrip == result)
  }

  @Test("NFO parser rejects unsafe, malformed, and oversized XML")
  func rejectsUnsafeNFO() {
    let parser = NFOParser(maximumDocumentBytes: 64)

    #expect(throws: SDKError.self) {
      try parser.parse(Data(#"<!DOCTYPE movie><movie><title>Unsafe</title></movie>"#.utf8))
    }
    #expect(throws: SDKError.self) {
      try parser.parse(Data("<movie><title>Broken</movie>".utf8))
    }
    #expect(throws: SDKError.self) {
      try parser.parse(Data(repeating: 0x20, count: 65))
    }
  }

  @Test("Local JSON parser rejects empty, malformed, and oversized documents")
  func rejectsInvalidLocalJSON() {
    let parser = LocalMetadataJSONParser(maximumDocumentBytes: 64)

    #expect(throws: SDKError.self) {
      try parser.parse(Data(#"{"kind":"movie","external_ids":[],"artwork":[]}"#.utf8))
    }
    #expect(throws: SDKError.self) {
      try parser.parse(Data(#"{"kind":"movie""#.utf8))
    }
    #expect(throws: SDKError.self) {
      try parser.parse(Data(repeating: 0x20, count: 65))
    }
  }

  @Test("NFO parser ignores nested scalar names")
  func ignoresNestedScalars() throws {
    let document = try NFOParser().parse(
      Data("<movie><title>Correct</title><actor><title>Wrong</title></actor></movie>".utf8)
    )

    #expect(document.title == "Correct")
  }

  @Test("Probe models reject duplicate streams and decode future enum values")
  func validatesProbeModels() throws {
    let stream = try MediaTechnicalStream(streamIndex: 0, kind: .video)
    let summary = try MediaTechnicalSummary()

    #expect(throws: SDKError.self) {
      try MediaTechnicalProbeResult(
        probeProvider: "fixture",
        probeVersion: 1,
        summary: summary,
        streams: [stream, stream]
      )
    }
    let unknown = try JSONDecoder().decode(
      MediaTechnicalStreamKind.self,
      from: Data(#""future_stream""#.utf8)
    )
    #expect(unknown == .unknown)
  }

  private func loadFixture() throws -> MetadataIntakeFixture {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/metadata-intake-v1.json")
    return try JSONDecoder().decode(
      MetadataIntakeFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
  }
}

private struct MetadataIntakeFixture: Decodable {
  let schemaVersion: Int
  let filenameEvidenceCases: [FilenameEvidenceFixtureCase]
  let sidecarCases: [SidecarFixtureCase]
  let nfoCases: [NFOFixtureCase]
  let localJSONCases: [LocalJSONFixtureCase]
  let technicalProbe: MediaTechnicalProbeResult

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case filenameEvidenceCases = "filename_evidence_cases"
    case sidecarCases = "sidecar_cases"
    case nfoCases = "nfo_cases"
    case localJSONCases = "local_json_cases"
    case technicalProbe = "technical_probe"
  }
}

private struct FilenameEvidenceFixtureCase: Decodable {
  let input: String
  let expected: MediaFilenameAnalysis
}

private struct SidecarFixtureCase: Decodable {
  let mediaPath: String
  let candidatePath: String
  let expected: MediaSidecarDescriptor?

  private enum CodingKeys: String, CodingKey {
    case mediaPath = "media_path"
    case candidatePath = "candidate_path"
    case expected
  }
}

private struct NFOFixtureCase: Decodable {
  let name: String
  let xml: String
  let expected: LocalMetadataDocument
}

private struct LocalJSONFixtureCase: Decodable {
  let name: String
  let json: String
  let expected: LocalMetadataDocument
}
