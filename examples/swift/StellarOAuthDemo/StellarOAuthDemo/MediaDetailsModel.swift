import Combine
import Foundation
import StellarUserMediaSDK

struct DemoMediaRoute: Hashable {
  var libraryUID: String?
  var objectID: String?
  let kind: String
  let title: String
  var airedCoordinate: MediaInfoCoordinate?
}

struct DemoPersonRoute: Hashable {
  let id: String
  let name: String
}

struct DemoEpisodeRow: Identifiable {
  let id: String
  let coordinate: MediaInfoCoordinate
  let objectID: String?
  let localEpisode: PosterWallEpisode?
  let airedCoordinate: MediaInfoCoordinate?
  var title: String { localEpisode?.title ?? "Episode \(coordinate.episode)" }
  var files: [PosterWallPlayableFile] { localEpisode?.files ?? [] }
}

@MainActor
final class MediaDetailsModel: ObservableObject {
  @Published private(set) var local: PosterWallDetails?
  @Published private(set) var entity: MediaInfoEntity?
  @Published private(set) var client: TestMediaInfoClient?
  @Published private(set) var objectID: String?
  @Published private(set) var posterURL: URL?
  @Published private(set) var backdropURL: URL?
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  let route: DemoMediaRoute

  init(route: DemoMediaRoute) { self.route = route }

  var title: String {
    entity?.title ?? (route.kind == "episode" ? localEpisode?.title : local?.item.title)
      ?? route.title
  }
  var overview: String? { entity?.overview ?? (route.kind == "episode" ? nil : local?.overview) }
  var files: [PosterWallPlayableFile] {
    route.kind == "episode" ? (localEpisode?.files ?? []) : (local?.playableFiles ?? [])
  }
  var localEpisode: PosterWallEpisode? {
    guard let coordinate = route.airedCoordinate else { return nil }
    return local?.seasons.first(where: { $0.seasonNumber == coordinate.season })?
      .episodes.first(where: { $0.episodeNumber == coordinate.episode })
  }

  func load(using library: MediaLibraryModel) async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      var localUID = route.libraryUID
      if localUID == nil, let id = route.objectID, ["movie", "series"].contains(route.kind) {
        localUID = try await library.localMediaUID(objectID: id, kind: route.kind)
      }
      if let uid = localUID, local == nil {
        do {
          let details = try await library.localDetails(mediaUID: uid)
          try Task.checkCancellation()
          local = details
          if route.kind != "episode" {
            posterURL = library.localArtworkURL(details.item.poster)
            backdropURL = library.localArtworkURL(details.item.backdrop)
          }
        } catch is CancellationError { throw CancellationError() } catch {
          self.error = "Local details could not be loaded. \(Self.message(error))"
        }
      }
      let service = try await library.detailsClient()
      try Task.checkCancellation()
      client = service
      objectID = route.objectID
      if objectID == nil, route.kind != "episode" {
        objectID =
          local?.externalIDs.first {
            $0.provider == ResolvedPosterMetadata.provider && $0.namespace == route.kind
          }?.value
      }
      guard let objectID else { return }
      let result = try await service.entity(id: objectID)
      try Task.checkCancellation()
      guard result.objectKind == route.kind else {
        throw SDKError(code: .parseFailure, message: "The service returned a different media type.")
      }
      entity = result
    } catch is CancellationError {} catch { self.error = Self.message(error) }
  }

  func loadArtwork(using library: MediaLibraryModel) async {
    guard let client, let objectID else {
      if let local, route.kind != "episode", posterURL == nil {
        let url = await library.requestPosterThumbnail(for: local)
        if !Task.isCancelled { posterURL = url }
      }
      return
    }
    async let poster = try? client.artworkURL(
      ownerID: objectID, kind: route.kind == "episode" ? "still" : "poster")
    async let backdrop = try? client.artworkURL(
      ownerID: objectID, kind: route.kind == "episode" ? "still" : "backdrop")
    let images = await (poster, backdrop)
    guard !Task.isCancelled else { return }
    // A selected local image keeps precedence over the service's general artwork gallery.
    posterURL = posterURL ?? images.0
    backdropURL = backdropURL ?? images.1
    if posterURL == nil, let local, route.kind != "episode" {
      let url = await library.requestPosterThumbnail(for: local)
      if !Task.isCancelled { posterURL = url }
    }
  }

  static func message(_ error: Error) -> String {
    if let sdk = error as? SDKError {
      switch sdk.code {
      case .networkUnavailable:
        return "You appear to be offline. Your library files are still available."
      case .remoteUnavailable: return "Details are temporarily unavailable. Please try again."
      case .rateLimited: return "Too many requests. Please try again shortly."
      case .metadataNotFound: return "No information was found for this item."
      default: return sdk.message
      }
    }
    if error is MediaInfoPaginationError { return "The episode catalog changed. Please reload it." }
    return "Details are temporarily unavailable. Please try again."
  }
}

@MainActor
final class SeriesBrowserModel: ObservableObject {
  @Published private(set) var orders: [MediaInfoEpisodeOrder] = []
  @Published private(set) var entries: [MediaInfoEpisodeEntry] = []
  @Published private(set) var airedEntries: [MediaInfoEpisodeEntry] = []
  @Published private(set) var error: String?
  @Published private(set) var isLoading = false
  @Published private(set) var orderMenuUnavailable = false
  @Published var selectedOrderID: String?
  @Published var selectedSeason = 1
  @Published var libraryOnly = true
  private var generation = 0
  private var loadedOrders: [String: [MediaInfoEpisodeEntry]] = [:]

  func load(client: TestMediaInfoClient, seriesID: String, local: [PosterWallSeason]) async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let values: [MediaInfoEpisodeOrder]
      do {
        values = try await client.episodeOrders(seriesID: seriesID)
        orderMenuUnavailable = false
      } catch {
        try Task.checkCancellation()
        let paths = local.flatMap { $0.episodes.flatMap { $0.files.map(\.relativePath) } }
        guard let airedID = await client.cachedAiredOrderID(seriesID: seriesID, paths: paths) else {
          throw error
        }
        values = [
          MediaInfoEpisodeOrder(
            orderID: airedID, seriesID: seriesID, orderKind: "aired", label: "Aired", entryCount: 0)
        ]
        orderMenuUnavailable = true
      }
      try Task.checkCancellation()
      orders = values
      // Always fetch aired identity mapping, even when displaying an alternate order.
      if let aired = values.first(where: { $0.orderKind == "aired" }) {
        let values = try await client.episodeEntries(seriesID: seriesID, orderID: aired.id)
        try Task.checkCancellation()
        airedEntries = values
        loadedOrders[aired.id] = values
      }
      let selection =
        values.first(where: { $0.id == selectedOrderID })
        ?? values.first(where: { $0.orderKind == "aired" }) ?? values.first
      if local.isEmpty { libraryOnly = false }
      if let selection, selection.id == selectedOrderID {
        await select(orderID: selection.id, client: client, seriesID: seriesID, local: local)
      } else {
        // The view's task(id:) cancels any previous order load when this changes.
        selectedOrderID = selection?.id
      }
    } catch is CancellationError {} catch { self.error = MediaDetailsModel.message(error) }
  }

  func select(
    orderID: String, client: TestMediaInfoClient, seriesID: String, local: [PosterWallSeason]
  ) async {
    generation += 1
    let requestGeneration = generation
    isLoading = true
    error = nil
    // Keep a failed selection from displaying entries labeled with the previous order.
    entries = []
    defer { if generation == requestGeneration { isLoading = false } }
    do {
      let values: [MediaInfoEpisodeEntry]
      if let cached = loadedOrders[orderID] {
        values = cached
      } else {
        values = try await client.episodeEntries(seriesID: seriesID, orderID: orderID)
      }
      try Task.checkCancellation()
      guard generation == requestGeneration else { return }
      loadedOrders[orderID] = values
      entries = values
      normalizeSeason(local: local)
    } catch is CancellationError {} catch {
      if generation == requestGeneration { self.error = MediaDetailsModel.message(error) }
    }
  }

  func rows(local: [PosterWallSeason]) -> [DemoEpisodeRow] {
    let localByCoordinate = Dictionary(
      local.flatMap { season in
        season.episodes.map {
          (MediaInfoCoordinate(season: season.seasonNumber, episode: $0.episodeNumber), $0)
        }
      }, uniquingKeysWith: { first, _ in first })
    // Local-only fallback has no invented remote identities.
    if entries.isEmpty {
      guard !isLoading || selectedOrderID == nil else { return [] }
      guard
        error != nil || selectedOrderID == nil
          || orders.first(where: { $0.id == selectedOrderID })?.orderKind == "aired"
      else { return [] }
      return localByCoordinate.map { coordinate, episode in
        DemoEpisodeRow(
          id: episode.mediaUID, coordinate: coordinate, objectID: nil,
          localEpisode: episode, airedCoordinate: coordinate)
      }.sorted {
        ($0.coordinate.season, $0.coordinate.episode) < (
          $1.coordinate.season, $1.coordinate.episode
        )
      }
    }
    let index = MediaInfoEpisodeIndex(airedEntries: airedEntries)
    var result = entries.sorted { $0.ordinal < $1.ordinal }.map { entry in
      let coordinate = index.airedCoordinate(for: entry)
      return DemoEpisodeRow(
        id: entry.id, coordinate: entry.coordinate, objectID: entry.episodeID,
        localEpisode: coordinate.flatMap { localByCoordinate[$0] }, airedCoordinate: coordinate)
    }
    // A partial upstream catalog must not make locally scanned episodes disappear from aired view.
    if orders.first(where: { $0.id == selectedOrderID })?.orderKind == "aired" {
      let known = Set(result.compactMap(\.airedCoordinate))
      result += localByCoordinate.filter { !known.contains($0.key) }.map { coordinate, episode in
        DemoEpisodeRow(
          id: episode.mediaUID, coordinate: coordinate, objectID: nil,
          localEpisode: episode, airedCoordinate: coordinate)
      }
      result.sort {
        ($0.coordinate.season, $0.coordinate.episode) < (
          $1.coordinate.season, $1.coordinate.episode
        )
      }
    }
    return libraryOnly ? result.filter { $0.localEpisode != nil } : result
  }

  func seasons(local: [PosterWallSeason]) -> [Int] {
    Array(Set(rows(local: local).map { $0.coordinate.season })).sorted()
  }

  func normalizeSeason(local: [PosterWallSeason]) {
    let values = seasons(local: local)
    if !values.contains(selectedSeason) {
      selectedSeason = values.first(where: { $0 > 0 }) ?? values.first ?? 1
    }
  }

  func seasonID(local: [PosterWallSeason]) -> String? {
    // Aggregate season metadata is defined for aired seasons only.
    guard orders.first(where: { $0.id == selectedOrderID })?.orderKind == "aired" else {
      return nil
    }
    return entries.first(where: { $0.seasonNumber == selectedSeason })?.seasonID
  }
}
