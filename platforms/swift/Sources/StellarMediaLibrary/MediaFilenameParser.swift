import Foundation
import StellarCore
import StellarRemoteMedia

/// The coarse media category inferred from a source filename.
public enum ParsedMediaKind: String, Sendable {
  case movie
  case series
  case season
  case episode
  case extra
  case unknown
}

extension ParsedMediaKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = ParsedMediaKind(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A deliberately small, deterministic result used to establish the shared parser contract.
public struct ParsedMediaFilename: Codable, Equatable, Sendable {
  public let kind: ParsedMediaKind
  public let title: String
  public let year: Int?
  public let season: Int?
  public let episode: Int?
  public let episodeEnd: Int?
  public let edition: String?
  public let isSample: Bool
  public let sourceName: String

  public init(
    kind: ParsedMediaKind,
    title: String,
    year: Int? = nil,
    season: Int? = nil,
    episode: Int? = nil,
    episodeEnd: Int? = nil,
    edition: String? = nil,
    isSample: Bool = false,
    sourceName: String
  ) {
    self.kind = kind
    self.title = title
    self.year = year
    self.season = season
    self.episode = episode
    self.episodeEnd = episodeEnd
    self.edition = edition
    self.isSample = isSample
    self.sourceName = sourceName
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(ParsedMediaKind.self, forKey: .kind)
    title = try container.decode(String.self, forKey: .title)
    year = try container.decodeIfPresent(Int.self, forKey: .year)
    season = try container.decodeIfPresent(Int.self, forKey: .season)
    episode = try container.decodeIfPresent(Int.self, forKey: .episode)
    episodeEnd = try container.decodeIfPresent(Int.self, forKey: .episodeEnd)
    edition = try container.decodeIfPresent(String.self, forKey: .edition)
    isSample = try container.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
    sourceName = try container.decode(String.self, forKey: .sourceName)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(year, forKey: .year)
    try container.encodeIfPresent(season, forKey: .season)
    try container.encodeIfPresent(episode, forKey: .episode)
    try container.encodeIfPresent(episodeEnd, forKey: .episodeEnd)
    try container.encodeIfPresent(edition, forKey: .edition)
    try container.encode(isSample, forKey: .isSample)
    try container.encode(sourceName, forKey: .sourceName)
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case title
    case year
    case season
    case episode
    case episodeEnd = "episode_end"
    case edition
    case isSample = "is_sample"
    case sourceName = "source_name"
  }
}

/// The initial filename parser. Its behavior is intentionally covered by fixtures before it grows.
public struct MediaFilenameParser: Sendable {
  public init() {}

  public func parse(_ path: String) -> ParsedMediaFilename {
    let url = URL(fileURLWithPath: path)
    let sourceName = url.lastPathComponent
    let stem = (sourceName as NSString).deletingPathExtension
    let isDirectoryHint = path.hasSuffix("/")

    if isDirectoryHint {
      if let seasonMatch = firstMatch(
        pattern: #"(?i)^season[\s._-]*(\d{1,2})(?:$|[\s._-])"#,
        in: stem
      ), let season = integerCapture(seasonMatch, index: 1, in: stem) {
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let (title, year) = normalizedTitleAndYear(parentName)
        return ParsedMediaFilename(
          kind: .season,
          title: title,
          year: year,
          season: season,
          sourceName: sourceName
        )
      }
      let (title, year) = normalizedTitleAndYear(stem)
      return ParsedMediaFilename(
        kind: .series,
        title: title,
        year: year,
        sourceName: sourceName
      )
    }

    let isSample =
      firstMatch(
        pattern: #"(?i)(?:^|[\s._-])sample(?:$|[\s._-])"#,
        in: stem
      ) != nil
    let edition = editionLabel(in: stem)

    if let episodeMatch = firstMatch(
      pattern: #"(?i)(?:^|[\s._-])s(\d{1,2})e(\d{1,3})(?:-?e(\d{1,3}))?(?:$|[\s._-])"#,
      in: stem
    ),
      let season = integerCapture(episodeMatch, index: 1, in: stem),
      let episode = integerCapture(episodeMatch, index: 2, in: stem)
    {
      let prefix = String(stem[..<episodeMatch.range.lowerBound])
      let (title, year) = normalizedTitleAndYear(prefix)
      return ParsedMediaFilename(
        kind: isSample ? .extra : .episode,
        title: title,
        year: year,
        season: season,
        episode: episode,
        episodeEnd: integerCapture(episodeMatch, index: 3, in: stem),
        edition: edition,
        isSample: isSample,
        sourceName: sourceName
      )
    }

    if let episodeMatch = firstMatch(
      pattern: #"(?i)(?:^|[\s._-])(\d{1,2})x(\d{1,3})(?:$|[\s._-])"#,
      in: stem
    ),
      let season = integerCapture(episodeMatch, index: 1, in: stem),
      let episode = integerCapture(episodeMatch, index: 2, in: stem)
    {
      let prefix = String(stem[..<episodeMatch.range.lowerBound])
      let (title, year) = normalizedTitleAndYear(prefix)
      return ParsedMediaFilename(
        kind: isSample ? .extra : .episode,
        title: title,
        year: year,
        season: season,
        episode: episode,
        edition: edition,
        isSample: isSample,
        sourceName: sourceName
      )
    }

    let titleInput =
      isSample
      ? stem.replacingOccurrences(
        of: #"(?i)(?:^|[\s._-])sample(?:$|[\s._-])"#,
        with: " ",
        options: .regularExpression
      )
      : stem
    let (title, year) = normalizedTitleAndYear(titleInput)
    return ParsedMediaFilename(
      kind: isSample ? .extra : (year == nil ? .unknown : .movie),
      title: title,
      year: year,
      edition: edition,
      isSample: isSample,
      sourceName: sourceName
    )
  }

  private func editionLabel(in input: String) -> String? {
    guard
      let match = firstMatch(
        pattern:
          #"(?i)(?:^|[\s._\[( -])(director'?s[\s._-]+cut|final[\s._-]+cut|extended(?:[\s._-]+(?:edition|cut))?|imax|theatrical(?:[\s._-]+cut)?|criterion)(?:$|[\s._\]) -])"#,
        in: input
      ), match.result.numberOfRanges > 1,
      let range = Range(match.result.range(at: 1), in: input)
    else {
      return nil
    }
    let normalized = input[range]
      .replacingOccurrences(of: #"[._-]+"#, with: " ", options: .regularExpression)
      .lowercased()
    switch normalized {
    case "director's cut", "directors cut":
      return "Director's Cut"
    case "final cut":
      return "Final Cut"
    case "extended", "extended edition", "extended cut":
      return "Extended"
    case "imax":
      return "IMAX"
    case "theatrical", "theatrical cut":
      return "Theatrical"
    case "criterion":
      return "Criterion"
    default:
      return nil
    }
  }

  private func normalizedTitleAndYear(_ input: String) -> (String, Int?) {
    let match = firstMatch(
      pattern: #"(?:^|[\s._(\[])((?:19|20)\d{2})(?=$|[\s._)\]-])"#,
      in: input
    )
    let year = match.flatMap { integerCapture($0, index: 1, in: input) }
    let titleInput = match.map { String(input[..<$0.range.lowerBound]) } ?? input
    return (normalizeTitle(titleInput), year)
  }

  private func normalizeTitle(_ input: String) -> String {
    input
      .replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()[]")))
  }

  private func firstMatch(pattern: String, in input: String) -> Match? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    let fullRange = NSRange(input.startIndex..<input.endIndex, in: input)
    guard let result = expression.firstMatch(in: input, range: fullRange),
      let range = Range(result.range, in: input)
    else {
      return nil
    }
    return Match(result: result, range: range)
  }

  private func integerCapture(_ match: Match, index: Int, in input: String) -> Int? {
    guard index < match.result.numberOfRanges,
      let range = Range(match.result.range(at: index), in: input)
    else {
      return nil
    }
    return Int(input[range])
  }

  private struct Match {
    let result: NSTextCheckingResult
    let range: Range<String.Index>
  }
}
