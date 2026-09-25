import Foundation
import StellarRemoteMedia
import StellarStorage

/// Identity supported by a local movie or episode document, usable without an online provider.
/// Episode documents must supply their own series title and coordinates. A filename alone is
/// not treated as provider-confirmed episode existence.
public struct LocalMetadataMatchEvidence: Sendable {
  public let query: MediaMatchQuery
  public let candidate: MediaMetadataCandidate
  public let metadata: LibraryRemoteMetadata

  public static func build(
    document: LocalMetadataDocument, sourceUID: String, mediaRelativePath: String, stableKey: String
  ) throws -> Self? {
    let path = try RemotePath(mediaRelativePath)
    let rootKind: ParsedMediaKind
    let title: String
    let localIdentity: String
    let episodes: [MediaEpisodeCoordinate]
    switch document.kind {
    case .movie:
      guard let localTitle = document.title, !localTitle.isEmpty else { return nil }
      rootKind = .movie
      title = localTitle
      localIdentity = sourceUID + ":" + stableKey
      episodes = []
    case .episode:
      guard let seriesTitle = document.seriesTitle, !seriesTitle.isEmpty,
        let season = document.season, let episode = document.episode
      else { return nil }
      rootKind = .series
      title = seriesTitle
      var directory = path.parent
      if let name = directory?.name,
        name.range(of: #"(?i)^(season[ ._-]*\d+|s\d+|specials)$"#, options: .regularExpression)
          != nil
      {
        directory = directory?.parent
      }
      localIdentity = sourceUID + ":" + (directory?.relativePath ?? "") + ":" + title
      episodes = [try MediaEpisodeCoordinate(season: season, episode: episode)]
    default:
      return nil
    }
    let namespace = rootKind.rawValue
    let rootIDs = document.externalIDs.filter {
      $0.namespace == namespace || (rootKind == .movie && $0.namespace == "title")
    }
    let preferred =
      rootIDs.first(where: { $0.isPrimary && $0.namespace == namespace })
      ?? rootIDs.first(where: { $0.namespace == namespace })
    let provider = preferred?.provider ?? "local-sidecar"
    let identity = preferred?.value ?? localIdentity
    let identifier = try LocalMetadataExternalID(
      provider: provider, namespace: namespace, value: identity)
    let identifiers = rootIDs.contains(identifier) ? rootIDs : rootIDs + [identifier]
    let query = try MediaMatchQuery(
      kind: document.kind, title: title, year: document.year,
      season: document.season, episode: document.episode, externalIDs: identifiers)
    let candidate = try MediaMetadataCandidate(
      provider: provider, candidateID: identity,
      kind: rootKind, title: title,
      originalTitle: rootKind == .movie ? document.originalTitle : nil,
      year: document.year, availableEpisodes: episodes, externalIDs: identifiers)
    let metadata = try LibraryRemoteMetadata(
      provider: provider, providerID: identity,
      kind: rootKind == .movie ? .movie : .series, locale: "und", title: title,
      originalTitle: rootKind == .movie ? document.originalTitle : nil,
      overview: rootKind == .movie ? document.overview : nil, year: document.year)
    return Self(query: query, candidate: candidate, metadata: metadata)
  }
}
