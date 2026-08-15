import Foundation
import StellarMediaLibrary
import Testing

@Suite("Media filename parser")
struct MediaFilenameParserTests {
  private let parser = MediaFilenameParser()

  @Test("Parses a movie title and year")
  func parsesMovie() {
    let result = parser.parse("/Movies/The.Matrix.1999.2160p.mkv")

    #expect(result.kind == .movie)
    #expect(result.title == "The Matrix")
    #expect(result.year == 1999)
    #expect(result.season == nil)
    #expect(result.episode == nil)
    #expect(result.sourceName == "The.Matrix.1999.2160p.mkv")
  }

  @Test("Parses an episode")
  func parsesEpisode() {
    let result = parser.parse("Show.Name.S02E07.1080p.mkv")

    #expect(result.kind == .episode)
    #expect(result.title == "Show Name")
    #expect(result.season == 2)
    #expect(result.episode == 7)
  }

  @Test("Preserves an unclassified title")
  func parsesUnknownTitle() {
    let result = parser.parse("Home Video.mov")

    #expect(result.kind == .unknown)
    #expect(result.title == "Home Video")
  }

  @Test("Matches the repository-wide parser fixture")
  func matchesSharedFixture() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/media-library/filename-parser-v1.json")
    let fixture = try JSONDecoder().decode(
      FilenameParserFixture.self,
      from: Data(contentsOf: fixtureURL)
    )

    #expect(fixture.schemaVersion == 1)
    for testCase in fixture.cases {
      #expect(parser.parse(testCase.input) == testCase.expected, "Fixture input: \(testCase.input)")
    }
  }
}

private struct FilenameParserFixture: Decodable {
  let schemaVersion: Int
  let cases: [FilenameParserCase]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case cases
  }
}

private struct FilenameParserCase: Decodable {
  let input: String
  let expected: ParsedMediaFilename
}
