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

/// Provider-specific identifiers embedded in a filename.
public struct FilenameProviderHint: Codable, Equatable, Sendable {
  public let provider: String
  public let value: String

  public init(provider: String, value: String) throws {
    guard !provider.isEmpty, !value.isEmpty, !provider.contains("\0"), !value.contains("\0") else {
      throw SDKError(code: .parseFailure, message: "filename provider hint is invalid")
    }
    self.provider = provider
    self.value = value
  }
}

/// Explainable filename evidence retained for matching and diagnostics.
public struct MediaFilenameEvidence: Codable, Equatable, Sendable {
  public let rawTokens: [String]
  public let noiseTokens: [String]
  public let releaseGroup: String?
  public let languageHint: String?
  public let providerHints: [FilenameProviderHint]
  public let confidence: Double

  public init(
    rawTokens: [String],
    noiseTokens: [String],
    releaseGroup: String? = nil,
    languageHint: String? = nil,
    providerHints: [FilenameProviderHint] = [],
    confidence: Double
  ) throws {
    let strings = rawTokens + noiseTokens + [releaseGroup, languageHint].compactMap { $0 }
    guard strings.allSatisfy({ !$0.contains("\0") }), confidence.isFinite,
      (0...1).contains(confidence)
    else {
      throw SDKError(code: .parseFailure, message: "filename evidence is invalid")
    }
    self.rawTokens = rawTokens
    self.noiseTokens = noiseTokens
    self.releaseGroup = releaseGroup
    self.languageHint = languageHint
    self.providerHints = providerHints.sorted {
      ($0.provider, $0.value) < ($1.provider, $1.value)
    }
    self.confidence = confidence
  }

  private enum CodingKeys: String, CodingKey {
    case rawTokens = "raw_tokens"
    case noiseTokens = "noise_tokens"
    case releaseGroup = "release_group"
    case languageHint = "language_hint"
    case providerHints = "provider_hints"
    case confidence
  }
}

/// A parser result paired with the evidence used by later matching stages.
public struct MediaFilenameAnalysis: Codable, Equatable, Sendable {
  public let parserVersion: Int
  public let parsed: ParsedMediaFilename
  public let evidence: MediaFilenameEvidence

  public init(
    parserVersion: Int,
    parsed: ParsedMediaFilename,
    evidence: MediaFilenameEvidence
  ) throws {
    guard parserVersion > 0 else {
      throw SDKError(code: .parseFailure, message: "filename parser version is invalid")
    }
    self.parserVersion = parserVersion
    self.parsed = parsed
    self.evidence = evidence
  }

  private enum CodingKeys: String, CodingKey {
    case parserVersion = "parser_version"
    case parsed
    case evidence
  }
}

/// The initial filename parser. Its behavior is intentionally covered by fixtures before it grows.
public struct MediaFilenameParser: Sendable {
  public static let version = 2

  public init() {}

  /// Parses a path and returns normalized, explainable matching evidence.
  public func analyze(_ path: String) throws -> MediaFilenameAnalysis {
    let parsed = parse(path)
    let sourceStem = (parsed.sourceName as NSString).deletingPathExtension
    let rawTokens = tokens(in: sourceStem)
    let noiseTokens = rawTokens.filter(isNoiseToken)
    let hints = providerHints(in: sourceStem)
    let releaseGroup = releaseGroup(in: sourceStem, rawTokens: rawTokens)
    let languageHint = rawTokens.first(where: isLanguageHint).map(normalizeLanguageHint)
    let confidence: Double
    switch parsed.kind {
    case .episode:
      confidence = 0.95
    case .movie:
      confidence = 0.85
    case .extra:
      confidence = parsed.episode == nil ? 0.65 : 0.75
    case .series, .season:
      confidence = 0.80
    case .unknown:
      confidence = hints.isEmpty ? 0.25 : 0.60
    }
    let evidence = try MediaFilenameEvidence(
      rawTokens: rawTokens,
      noiseTokens: noiseTokens,
      releaseGroup: releaseGroup,
      languageHint: languageHint,
      providerHints: hints,
      confidence: confidence
    )
    return try MediaFilenameAnalysis(
      parserVersion: Self.version,
      parsed: parsed,
      evidence: evidence
    )
  }

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

  private func tokens(in input: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*"#)
    else { return [] }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return expression.matches(in: input, range: range).compactMap { match in
      Range(match.range, in: input).map { String(input[$0]) }
    }
  }

  private func isNoiseToken(_ token: String) -> Bool {
    let normalized = token.lowercased()
    let exact = Set([
      "480p", "576p", "720p", "1080p", "1080i", "2160p", "4320p", "4k", "8k",
      "bluray", "blu-ray", "bdrip", "brrip", "remux", "web", "web-dl", "webdl",
      "webrip", "hdtv", "dvdrip", "uhd", "hdr", "hdr10", "hdr10plus", "dv",
      "dolbyvision", "x264", "x265", "h264", "h265", "hevc", "av1", "mpeg2",
      "10bit", "8bit", "aac", "ac3", "eac3", "dts", "dts-hd", "truehd", "atmos",
      "proper", "repack", "extended", "theatrical", "criterion", "imax", "sample",
    ])
    if exact.contains(normalized) { return true }
    let pieces = normalized.split(separator: "-").map(String.init)
    return pieces.count > 1 && pieces.allSatisfy { exact.contains($0) }
  }

  private func providerHints(in input: String) -> [FilenameProviderHint] {
    let pattern = #"(?i)[\[\{(](tmdb|imdb|tvdb)[-:= ]+([a-z0-9]+)[\]\})]"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    var seen = Set<String>()
    return expression.matches(in: input, range: range).compactMap { match in
      guard let providerRange = Range(match.range(at: 1), in: input),
        let valueRange = Range(match.range(at: 2), in: input)
      else { return nil }
      let provider = input[providerRange].lowercased()
      let value = String(input[valueRange])
      guard seen.insert("\(provider)\0\(value)").inserted else { return nil }
      return try? FilenameProviderHint(provider: provider, value: value)
    }
  }

  private func releaseGroup(in input: String, rawTokens: [String]) -> String? {
    guard rawTokens.contains(where: isNoiseToken),
      let match = firstMatch(pattern: #"-([A-Za-z0-9][A-Za-z0-9._]{1,31})$"#, in: input),
      match.result.numberOfRanges > 1,
      let range = Range(match.result.range(at: 1), in: input)
    else { return nil }
    let value = String(input[range])
    return isNoiseToken(value) ? nil : value
  }

  private func isLanguageHint(_ token: String) -> Bool {
    let normalized = token.lowercased()
    let supported = Set([
      "ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "pt", "ru", "th", "vi",
      "zh", "en-us", "en-gb", "pt-br", "pt-pt", "zh-hans", "zh-hant",
    ])
    return supported.contains(normalized)
  }

  private func normalizeLanguageHint(_ token: String) -> String {
    let parts = token.split(separator: "-").map(String.init)
    guard let language = parts.first, parts.count == 2 else { return token.lowercased() }
    let suffix = parts[1]
    return language.lowercased() + "-"
      + (suffix.count == 4
        ? suffix.prefix(1).uppercased() + suffix.dropFirst().lowercased()
        : suffix.uppercased())
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
