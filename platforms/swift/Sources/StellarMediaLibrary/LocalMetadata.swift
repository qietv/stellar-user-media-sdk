import Foundation
import StellarCore
import StellarRemoteMedia

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// A sidecar category aligned with the `library.sqlite` v1 contract.
public enum MediaSidecarKind: String, Sendable {
  case nfo
  case metadataJSON = "metadata_json"
  case poster
  case backdrop
  case logo
  case subtitle
  case chapters
  case other
  case unknown
}

extension MediaSidecarKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = MediaSidecarKind(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A normalized sidecar association discovered beside one media file.
public struct MediaSidecarDescriptor: Codable, Equatable, Sendable {
  public let kind: MediaSidecarKind
  public let relativePath: String
  public let language: String
  public let isForced: Bool
  public let isHearingImpaired: Bool

  public init(
    kind: MediaSidecarKind,
    relativePath: String,
    language: String = "und",
    isForced: Bool = false,
    isHearingImpaired: Bool = false
  ) throws {
    let path = try RemotePath(relativePath)
    guard !path.isRoot, !language.isEmpty, !language.contains("\0") else {
      throw SDKError(code: .invalidConfiguration, message: "sidecar descriptor is invalid")
    }
    self.kind = kind
    self.relativePath = path.relativePath
    self.language = language
    self.isForced = isForced
    self.isHearingImpaired = isHearingImpaired
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        kind: container.decode(MediaSidecarKind.self, forKey: .kind),
        relativePath: container.decode(String.self, forKey: .relativePath),
        language: container.decodeIfPresent(String.self, forKey: .language) ?? "und",
        isForced: container.decodeIfPresent(Bool.self, forKey: .isForced) ?? false,
        isHearingImpaired: container.decodeIfPresent(Bool.self, forKey: .isHearingImpaired)
          ?? false
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case relativePath = "relative_path"
    case language
    case isForced = "forced"
    case isHearingImpaired = "hearing_impaired"
  }
}

/// Deterministically classifies supported sidecars without reading their contents.
public struct MediaSidecarClassifier: Sendable {
  public init() {}

  public func classify(mediaPath: String, candidatePath: String) throws
    -> MediaSidecarDescriptor?
  {
    let media = try RemotePath(mediaPath)
    let candidate = try RemotePath(candidatePath)
    guard !media.isRoot, !candidate.isRoot, media != candidate,
      media.parent == candidate.parent
    else {
      return nil
    }

    let mediaStem = deletingPathExtension(media.name)
    let candidateStem = deletingPathExtension(candidate.name)
    let candidateExtension = pathExtension(candidate.name).lowercased()
    let lowerMediaStem = mediaStem.lowercased()
    let lowerCandidateStem = candidateStem.lowercased()
    let imageExtensions = ["jpg", "jpeg", "png", "webp", "avif"]

    if candidateExtension == "nfo",
      lowerCandidateStem == lowerMediaStem
        || ["movie", "tvshow", "season"].contains(lowerCandidateStem)
    {
      return try descriptor(kind: .nfo, path: candidate.relativePath)
    }

    if candidateExtension == "json",
      lowerCandidateStem == lowerMediaStem
        || ["movie", "tvshow", "season"].contains(lowerCandidateStem)
    {
      return try descriptor(kind: .metadataJSON, path: candidate.relativePath)
    }

    if ["srt", "ass", "ssa", "vtt"].contains(candidateExtension),
      lowerCandidateStem == lowerMediaStem
        || lowerCandidateStem.hasPrefix(lowerMediaStem + ".")
        || lowerCandidateStem.hasPrefix(lowerMediaStem + "-")
        || lowerCandidateStem.hasPrefix(lowerMediaStem + "_")
    {
      let suffix = String(candidateStem.dropFirst(mediaStem.count))
      let tags =
        suffix
        .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        .split(separator: ".")
        .map(String.init)
      let loweredTags = tags.map { $0.lowercased() }
      let language = tags.first(where: Self.isLanguageTag).map(Self.normalizeLanguageTag) ?? "und"
      return try descriptor(
        kind: .subtitle,
        path: candidate.relativePath,
        language: language,
        forced: loweredTags.contains("forced") || loweredTags.contains("foreign"),
        hearingImpaired: loweredTags.contains("sdh") || loweredTags.contains("hi")
          || loweredTags.contains("cc")
      )
    }

    if imageExtensions.contains(candidateExtension) {
      if ["poster", "folder", "cover", lowerMediaStem + "-poster"].contains(
        lowerCandidateStem)
      {
        return try descriptor(kind: .poster, path: candidate.relativePath)
      }
      if [
        "fanart", "backdrop", lowerMediaStem + "-fanart", lowerMediaStem + "-backdrop",
      ].contains(lowerCandidateStem) {
        return try descriptor(kind: .backdrop, path: candidate.relativePath)
      }
      if ["logo", "clearlogo", lowerMediaStem + "-logo", lowerMediaStem + "-clearlogo"]
        .contains(lowerCandidateStem)
      {
        return try descriptor(kind: .logo, path: candidate.relativePath)
      }
    }

    if ["xml", "txt"].contains(candidateExtension),
      lowerCandidateStem == "chapters" || lowerCandidateStem == lowerMediaStem + ".chapters"
    {
      return try descriptor(kind: .chapters, path: candidate.relativePath)
    }

    return nil
  }

  private func descriptor(
    kind: MediaSidecarKind,
    path: String,
    language: String = "und",
    forced: Bool = false,
    hearingImpaired: Bool = false
  ) throws -> MediaSidecarDescriptor {
    try MediaSidecarDescriptor(
      kind: kind,
      relativePath: path,
      language: language,
      isForced: forced,
      isHearingImpaired: hearingImpaired
    )
  }

  private func deletingPathExtension(_ value: String) -> String {
    (value as NSString).deletingPathExtension
  }

  private func pathExtension(_ value: String) -> String {
    (value as NSString).pathExtension
  }

  private static func isLanguageTag(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z]{2,3}(?:-[A-Za-z]{2,4})?$"#,
      options: .regularExpression
    ) != nil
  }

  private static func normalizeLanguageTag(_ value: String) -> String {
    let parts = value.split(separator: "-").map(String.init)
    guard let language = parts.first else { return "und" }
    guard parts.count == 2 else { return language.lowercased() }
    let suffix = parts[1]
    let normalizedSuffix =
      suffix.count == 4
      ? suffix.prefix(1).uppercased() + suffix.dropFirst().lowercased()
      : suffix.uppercased()
    return "\(language.lowercased())-\(normalizedSuffix)"
  }
}

/// A provider identifier extracted from local metadata.
public struct LocalMetadataExternalID: Codable, Equatable, Sendable {
  public let provider: String
  public let namespace: String
  public let value: String
  public let isPrimary: Bool

  public init(provider: String, namespace: String, value: String, isPrimary: Bool = false) throws {
    guard !provider.isEmpty, !namespace.isEmpty, !value.isEmpty,
      !provider.contains("\0"), !namespace.contains("\0"), !value.contains("\0")
    else {
      throw SDKError(code: .parseFailure, message: "local metadata external ID is invalid")
    }
    self.provider = provider
    self.namespace = namespace
    self.value = value
    self.isPrimary = isPrimary
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        provider: container.decode(String.self, forKey: .provider),
        namespace: container.decode(String.self, forKey: .namespace),
        value: container.decode(String.self, forKey: .value),
        isPrimary: container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case namespace
    case value
    case isPrimary = "is_primary"
  }
}

/// An artwork category extracted from local metadata.
public enum LocalMetadataArtworkKind: String, Sendable {
  case poster
  case backdrop
  case logo
  case banner
  case thumbnail
  case unknown
}

extension LocalMetadataArtworkKind: Codable {
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = LocalMetadataArtworkKind(rawValue: value) ?? .unknown
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A deferred local or remote artwork reference. Parsing never fetches this location.
public struct LocalMetadataArtwork: Codable, Equatable, Sendable {
  public let kind: LocalMetadataArtworkKind
  public let location: String

  public init(kind: LocalMetadataArtworkKind, location: String) throws {
    guard !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !location.contains("\0")
    else {
      throw SDKError(code: .parseFailure, message: "local artwork location is invalid")
    }
    self.kind = kind
    self.location = location
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        kind: container.decode(LocalMetadataArtworkKind.self, forKey: .kind),
        location: container.decode(String.self, forKey: .location)
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case location
  }
}

/// Local metadata normalized independently of XML parser implementation details.
public struct LocalMetadataDocument: Codable, Equatable, Sendable {
  public let kind: ParsedMediaKind
  public let title: String?
  public let originalTitle: String?
  public let sortTitle: String?
  public let seriesTitle: String?
  public let year: Int?
  public let overview: String?
  public let tagline: String?
  public let contentRating: String?
  public let releaseDate: String?
  public let runtimeMilliseconds: Int64?
  public let season: Int?
  public let episode: Int?
  public let externalIDs: [LocalMetadataExternalID]
  public let artwork: [LocalMetadataArtwork]

  public init(
    kind: ParsedMediaKind,
    title: String? = nil,
    originalTitle: String? = nil,
    sortTitle: String? = nil,
    seriesTitle: String? = nil,
    year: Int? = nil,
    overview: String? = nil,
    tagline: String? = nil,
    contentRating: String? = nil,
    releaseDate: String? = nil,
    runtimeMilliseconds: Int64? = nil,
    season: Int? = nil,
    episode: Int? = nil,
    externalIDs: [LocalMetadataExternalID] = [],
    artwork: [LocalMetadataArtwork] = []
  ) throws {
    let strings = [
      title, originalTitle, sortTitle, seriesTitle, overview, tagline, contentRating,
      releaseDate,
    ]
    guard strings.allSatisfy({ $0?.contains("\0") != true }),
      year.map({ (1000...9999).contains($0) }) ?? true,
      runtimeMilliseconds.map({ $0 >= 0 }) ?? true,
      season.map({ $0 >= 0 }) ?? true,
      episode.map({ $0 >= 0 }) ?? true
    else {
      throw SDKError(code: .parseFailure, message: "local metadata document is invalid")
    }
    self.kind = kind
    self.title = title
    self.originalTitle = originalTitle
    self.sortTitle = sortTitle
    self.seriesTitle = seriesTitle
    self.year = year
    self.overview = overview
    self.tagline = tagline
    self.contentRating = contentRating
    self.releaseDate = releaseDate
    self.runtimeMilliseconds = runtimeMilliseconds
    self.season = season
    self.episode = episode
    self.externalIDs = externalIDs
    self.artwork = artwork
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        kind: container.decode(ParsedMediaKind.self, forKey: .kind),
        title: container.decodeIfPresent(String.self, forKey: .title),
        originalTitle: container.decodeIfPresent(String.self, forKey: .originalTitle),
        sortTitle: container.decodeIfPresent(String.self, forKey: .sortTitle),
        seriesTitle: container.decodeIfPresent(String.self, forKey: .seriesTitle),
        year: container.decodeIfPresent(Int.self, forKey: .year),
        overview: container.decodeIfPresent(String.self, forKey: .overview),
        tagline: container.decodeIfPresent(String.self, forKey: .tagline),
        contentRating: container.decodeIfPresent(String.self, forKey: .contentRating),
        releaseDate: container.decodeIfPresent(String.self, forKey: .releaseDate),
        runtimeMilliseconds: container.decodeIfPresent(Int64.self, forKey: .runtimeMilliseconds),
        season: container.decodeIfPresent(Int.self, forKey: .season),
        episode: container.decodeIfPresent(Int.self, forKey: .episode),
        externalIDs: container.decodeIfPresent([LocalMetadataExternalID].self, forKey: .externalIDs)
          ?? [],
        artwork: container.decodeIfPresent([LocalMetadataArtwork].self, forKey: .artwork) ?? []
      )
    } catch let error as SDKError {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(originalTitle, forKey: .originalTitle)
    try container.encodeIfPresent(sortTitle, forKey: .sortTitle)
    try container.encodeIfPresent(seriesTitle, forKey: .seriesTitle)
    try container.encodeIfPresent(year, forKey: .year)
    try container.encodeIfPresent(overview, forKey: .overview)
    try container.encodeIfPresent(tagline, forKey: .tagline)
    try container.encodeIfPresent(contentRating, forKey: .contentRating)
    try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
    try container.encodeIfPresent(runtimeMilliseconds, forKey: .runtimeMilliseconds)
    try container.encodeIfPresent(season, forKey: .season)
    try container.encodeIfPresent(episode, forKey: .episode)
    try container.encode(externalIDs, forKey: .externalIDs)
    try container.encode(artwork, forKey: .artwork)
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case title
    case originalTitle = "original_title"
    case sortTitle = "sort_title"
    case seriesTitle = "series_title"
    case year
    case overview
    case tagline
    case contentRating = "content_rating"
    case releaseDate = "release_date"
    case runtimeMilliseconds = "runtime_ms"
    case season
    case episode
    case externalIDs = "external_ids"
    case artwork
  }
}

/// A bounded, non-fetching parser for Kodi-compatible NFO metadata.
public struct NFOParser: Sendable {
  public let maximumDocumentBytes: Int

  public init(maximumDocumentBytes: Int = 2 * 1024 * 1024) {
    self.maximumDocumentBytes = max(1, maximumDocumentBytes)
  }

  public func parse(_ data: Data) throws -> LocalMetadataDocument {
    guard !data.isEmpty, data.count <= maximumDocumentBytes else {
      throw SDKError(code: .parseFailure, message: "NFO document size is invalid")
    }
    let inspection =
      String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? ""
    guard inspection.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
      inspection.range(of: "<!ENTITY", options: .caseInsensitive) == nil
    else {
      throw SDKError(code: .parseFailure, message: "NFO declarations are not allowed")
    }

    let collector = NFOXMLCollector()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = collector
    guard parser.parse(), !collector.encounteredForbiddenDeclaration else {
      throw SDKError(code: .parseFailure, message: "NFO XML is invalid")
    }
    return try collector.makeDocument()
  }
}

/// A bounded parser for normalized local JSON metadata sidecars.
public struct LocalMetadataJSONParser: Sendable {
  public let maximumDocumentBytes: Int

  public init(maximumDocumentBytes: Int = 2 * 1024 * 1024) {
    self.maximumDocumentBytes = max(1, maximumDocumentBytes)
  }

  public func parse(_ data: Data) throws -> LocalMetadataDocument {
    guard !data.isEmpty, data.count <= maximumDocumentBytes else {
      throw SDKError(code: .parseFailure, message: "local JSON document size is invalid")
    }
    do {
      let document = try JSONDecoder().decode(LocalMetadataDocument.self, from: data)
      let hasTitle = [document.title, document.originalTitle, document.seriesTitle]
        .contains { value in
          value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
      guard hasTitle || !document.externalIDs.isEmpty || !document.artwork.isEmpty else {
        throw SDKError(code: .parseFailure, message: "local JSON has no usable metadata")
      }
      return document
    } catch let error as SDKError {
      throw error
    } catch {
      throw SDKError(code: .parseFailure, message: "local JSON is invalid")
    }
  }
}

private final class NFOXMLCollector: NSObject, XMLParserDelegate {
  private var elements: [String] = []
  private var buffers: [String] = []
  private var attributes: [[String: String]] = []
  private var root: String?
  private var values: [String: String] = [:]
  private var pendingIDs: [(type: String, value: String, primary: Bool)] = []
  private var pendingArtwork: [(kind: LocalMetadataArtworkKind, location: String)] = []
  var encounteredForbiddenDeclaration = false

  func parser(
    _: XMLParser,
    didStartElement elementName: String,
    namespaceURI _: String?,
    qualifiedName _: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = elementName.lowercased()
    if root == nil { root = name }
    elements.append(name)
    buffers.append("")
    attributes.append(
      attributeDict.reduce(into: [:]) { result, pair in
        result[pair.key.lowercased()] = pair.value
      })
  }

  func parser(_: XMLParser, foundCharacters string: String) {
    guard !buffers.isEmpty else { return }
    buffers[buffers.count - 1].append(string)
  }

  func parser(
    _: XMLParser,
    didEndElement _: String,
    namespaceURI _: String?,
    qualifiedName _: String?
  ) {
    guard let name = elements.last, let buffer = buffers.last, let attribute = attributes.last
    else { return }
    let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    let parent = elements.dropLast().last

    if elements.count == 2, parent == root, !value.isEmpty {
      if name == "uniqueid" {
        let type = attribute["type"]?.lowercased() ?? "unknown"
        let primary = ["true", "1", "yes"].contains(attribute["default"]?.lowercased() ?? "")
        pendingIDs.append((type, value, primary))
      } else if name == "thumb" {
        pendingArtwork.append((artworkKind(attribute["aspect"]), value))
      } else if values[name] == nil {
        values[name] = value
      }
    } else if name == "thumb", parent == "fanart", !value.isEmpty {
      pendingArtwork.append((.backdrop, value))
    }

    elements.removeLast()
    buffers.removeLast()
    attributes.removeLast()
  }

  func parser(
    _: XMLParser,
    foundInternalEntityDeclarationWithName _: String,
    value _: String?
  ) {
    encounteredForbiddenDeclaration = true
  }

  func parser(
    _: XMLParser,
    foundExternalEntityDeclarationWithName _: String,
    publicID _: String?,
    systemID _: String?
  ) {
    encounteredForbiddenDeclaration = true
  }

  func parser(
    _: XMLParser,
    resolveExternalEntityName _: String,
    systemID _: String?
  ) -> Data? {
    encounteredForbiddenDeclaration = true
    return nil
  }

  func makeDocument() throws -> LocalMetadataDocument {
    let kind = mediaKind(root)
    guard kind != .unknown else {
      throw SDKError(code: .parseFailure, message: "NFO root element is unsupported")
    }

    appendLegacyID(tag: "tmdbid", type: "tmdb")
    appendLegacyID(tag: "imdbid", type: "imdb")
    appendLegacyID(tag: "tvdbid", type: "tvdb")
    appendLegacyID(tag: "id", type: "imdb")

    var externalIDs: [LocalMetadataExternalID] = []
    var seenIDs = Set<String>()
    for item in pendingIDs {
      let provider = item.type.isEmpty ? "unknown" : item.type
      let namespace = provider == "imdb" ? "title" : namespace(for: kind)
      let key = "\(provider)\0\(namespace)\0\(item.value)"
      guard seenIDs.insert(key).inserted else { continue }
      externalIDs.append(
        try LocalMetadataExternalID(
          provider: provider,
          namespace: namespace,
          value: item.value,
          isPrimary: item.primary
        )
      )
    }

    var artwork: [LocalMetadataArtwork] = []
    var seenArtwork = Set<String>()
    for item in pendingArtwork {
      let key = "\(item.kind.rawValue)\0\(item.location)"
      guard seenArtwork.insert(key).inserted else { continue }
      artwork.append(try LocalMetadataArtwork(kind: item.kind, location: item.location))
    }

    let title = values["title"]
    guard title != nil || !externalIDs.isEmpty || !artwork.isEmpty else {
      throw SDKError(code: .parseFailure, message: "NFO document has no usable metadata")
    }

    return try LocalMetadataDocument(
      kind: kind,
      title: title,
      originalTitle: values["originaltitle"],
      sortTitle: values["sorttitle"],
      seriesTitle: values["showtitle"],
      year: values["year"].flatMap(Int.init),
      overview: values["plot"],
      tagline: values["tagline"],
      contentRating: values["mpaa"] ?? values["certification"],
      releaseDate: values["premiered"] ?? values["aired"],
      runtimeMilliseconds: runtimeMilliseconds(values["runtime"]),
      season: values["season"].flatMap(Int.init),
      episode: values["episode"].flatMap(Int.init),
      externalIDs: externalIDs,
      artwork: artwork
    )
  }

  private func mediaKind(_ root: String?) -> ParsedMediaKind {
    switch root {
    case "movie": .movie
    case "tvshow": .series
    case "season": .season
    case "episodedetails": .episode
    default: .unknown
    }
  }

  private func namespace(for kind: ParsedMediaKind) -> String {
    switch kind {
    case .series: "series"
    case .season: "season"
    case .episode: "episode"
    case .movie: "movie"
    case .extra: "extra"
    case .unknown: "unknown"
    }
  }

  private func appendLegacyID(tag: String, type: String) {
    guard let value = values[tag], !value.isEmpty else { return }
    pendingIDs.append((type, value, false))
  }

  private func artworkKind(_ aspect: String?) -> LocalMetadataArtworkKind {
    switch aspect?.lowercased() {
    case "fanart", "backdrop": .backdrop
    case "logo", "clearlogo": .logo
    case "banner": .banner
    case "thumb", "thumbnail": .thumbnail
    default: .poster
    }
  }

  private func runtimeMilliseconds(_ value: String?) -> Int64? {
    guard let value, let minutes = Double(value), minutes >= 0,
      minutes <= Double(Int64.max) / 60_000
    else { return nil }
    return Int64((minutes * 60_000).rounded())
  }
}
