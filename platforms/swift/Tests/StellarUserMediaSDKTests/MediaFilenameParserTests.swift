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

  @Test(
    "Episode identity uses explicit path ancestors without listing siblings",
    arguments: [
      "TV/Wednesday (2022)/S02E03.mkv",
      "TV/Wednesday (2022)/Season 2/S02E03.mkv",
      "TV/Wednesday (2022)/Season 2/03 Episode.mkv",
      "TV/Wednesday (2022)/02-003 Episode.mkv",
      "TV/Wednesday (2022)/Season 2/2x03.mkv",
    ]
  )
  func parentEpisodeContext(path: String) throws {
    let result = parser.parse(path)
    #expect(result.kind == .episode)
    #expect(result.title == "Wednesday")
    #expect(result.year == 2022)
    #expect(result.season == 2)
    #expect(result.episode == 3)
    let query = try MediaMatchQueryBuilder().build(filename: result)
    #expect(query.title == "Wednesday")
    #expect(query.kind == .episode)
  }

  @Test("Specials supply season zero and episode filenames retain precedence")
  func parentContextPrecedence() {
    let special = parser.parse("TV/Wednesday (2022)/Specials/01 Episode.mkv")
    #expect(special.title == "Wednesday")
    #expect(special.season == 0)
    #expect(special.episode == 1)

    let named = parser.parse("TV/Wrong Show (1999)/Season 9/Wednesday.2022.S02E03.mkv")
    #expect(named.title == "Wednesday")
    #expect(named.year == 2022)
    #expect(named.season == 2)

    let parentYear = parser.parse("TV/Wednesday (2022)/Wednesday.S02E03.mkv")
    #expect(parentYear.year == 2022)
    let unrelatedYear = parser.parse("TV/Wrong Show (1999)/Wednesday.S02E03.mkv")
    #expect(unrelatedYear.year == nil)

    let sample = parser.parse("TV/Wednesday (2022)/Season 2/S02E03.sample.mkv")
    #expect(sample.kind == .extra)
    #expect(sample.isSample)
    #expect(sample.title == "Wednesday")
  }

  @Test("Relative inputs never borrow the working directory or generic library roots")
  func parentContextBoundaries() {
    #expect(parser.parse("S02E03.mkv").title.isEmpty)
    #expect(parser.parse("TV/Season 2/S02E03.mkv").title.isEmpty)
    #expect(parser.parse("TV/Wednesday (2022)/03 Episode.mkv").kind != .episode)
    #expect(parser.parse("Movies/01 Home Video.mkv").kind != .episode)
    let dotted = parser.parse("TV/Show.Name/Season.02/03 Episode.mkv")
    #expect(dotted.title == "Show Name")
    #expect(dotted.season == 2)
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
