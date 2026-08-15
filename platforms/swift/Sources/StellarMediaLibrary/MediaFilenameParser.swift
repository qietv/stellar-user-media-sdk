import Foundation
import StellarCore
import StellarRemoteMedia

public enum ParsedMediaKind: String, Sendable {
  case movie
  case episode
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
  public let sourceName: String

  public init(
    kind: ParsedMediaKind,
    title: String,
    year: Int? = nil,
    season: Int? = nil,
    episode: Int? = nil,
    sourceName: String
  ) {
    self.kind = kind
    self.title = title
    self.year = year
    self.season = season
    self.episode = episode
    self.sourceName = sourceName
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case title
    case year
    case season
    case episode
    case sourceName = "source_name"
  }
}

/// The initial filename parser. Its behavior is intentionally covered by fixtures before it grows.
public struct MediaFilenameParser: Sendable {
  public init() {}

  public func parse(_ path: String) -> ParsedMediaFilename {
    let sourceName = URL(fileURLWithPath: path).lastPathComponent
    let stem = (sourceName as NSString).deletingPathExtension

    if let episodeMatch = firstMatch(
      pattern: #"(?i)(?:^|[\s._-])s(\d{1,2})e(\d{1,3})(?:$|[\s._-])"#,
      in: stem
    ),
      let season = integerCapture(episodeMatch, index: 1, in: stem),
      let episode = integerCapture(episodeMatch, index: 2, in: stem)
    {
      let prefix = String(stem[..<episodeMatch.range.lowerBound])
      let (title, year) = normalizedTitleAndYear(prefix)
      return ParsedMediaFilename(
        kind: .episode,
        title: title,
        year: year,
        season: season,
        episode: episode,
        sourceName: sourceName
      )
    }

    let (title, year) = normalizedTitleAndYear(stem)
    return ParsedMediaFilename(
      kind: year == nil ? .unknown : .movie,
      title: title,
      year: year,
      sourceName: sourceName
    )
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
