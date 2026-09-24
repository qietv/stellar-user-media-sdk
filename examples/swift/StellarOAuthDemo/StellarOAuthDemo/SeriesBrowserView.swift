import StellarUserMediaSDK
import SwiftUI

struct SeriesBrowserView: View {
  @ObservedObject var library: MediaLibraryModel
  let client: TestMediaInfoClient?
  let seriesID: String?
  let libraryUID: String?
  let title: String
  let localSeasons: [PosterWallSeason]
  @StateObject private var browser = SeriesBrowserModel()
  @State private var season: MediaInfoEntity?
  @State private var showSeasonCredits = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Episodes").font(.title2.bold())
        Spacer()
        if browser.isLoading { ProgressView().controlSize(.small) }
      }
      if let error = browser.error {
        DetailRetry(message: error, isLoading: browser.isLoading) { Task { await reload() } }
      }
      if browser.orderMenuUnavailable {
        DetailRetry(
          message: "Other episode orders are unavailable. Showing the verified aired order.",
          isLoading: browser.isLoading
        ) {
          Task { await reload() }
        }
      }
      controls
      if let overview = season?.overview, !overview.isEmpty {
        DetailText(title: season?.title ?? seasonLabel(browser.selectedSeason), text: overview)
      }
      let rows = browser.rows(local: localSeasons).filter {
        $0.coordinate.season == browser.selectedSeason
      }
      if rows.isEmpty && !browser.isLoading {
        Text(
          browser.libraryOnly
            ? "No library episodes in this order. Select All episodes to browse the catalog."
            : "No episodes are available yet."
        )
        .font(.subheadline).foregroundStyle(.secondary)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 16) {
          ForEach(rows) { row in
            NavigationLink(
              value: DemoMediaRoute(
                libraryUID: libraryUID, objectID: row.objectID,
                kind: "episode", title: row.title, airedCoordinate: row.airedCoordinate)
            ) {
              EpisodeCard(client: client, row: row)
            }.buttonStyle(.plain)
          }
        }
      }
      if let client, let id = browser.seasonID(local: localSeasons) {
        DisclosureGroup("Season cast & crew", isExpanded: $showSeasonCredits) {
          if showSeasonCredits {
            CreditsSection(client: client, ownerID: id).padding(.top, 16).id(id)
          }
        }.font(.subheadline)
      }
    }
    .task(id: seriesID) { await reload() }
    .task(id: browser.selectedOrderID) {
      guard let client, let seriesID, let orderID = browser.selectedOrderID else { return }
      await browser.select(
        orderID: orderID, client: client, seriesID: seriesID, local: localSeasons)
    }
    .task(id: browser.seasonID(local: localSeasons)) {
      season = nil
      guard let client, let id = browser.seasonID(local: localSeasons) else { return }
      let result = try? await client.entity(id: id)
      if !Task.isCancelled, result?.objectKind == "season" { season = result }
    }
    .onChange(of: browser.libraryOnly) { _, _ in browser.normalizeSeason(local: localSeasons) }
    .onChange(of: localSeasons) { _, _ in browser.normalizeSeason(local: localSeasons) }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        let seasons = browser.seasons(local: localSeasons)
        Picker("Season", selection: $browser.selectedSeason) {
          ForEach(seasons, id: \.self) { number in Text(seasonLabel(number)).tag(number) }
        }.pickerStyle(.menu).disabled(seasons.isEmpty)
        Spacer()
        if !localSeasons.isEmpty {
          Picker("Episode availability", selection: $browser.libraryOnly) {
            Text("In library").tag(true)
            Text("All episodes").tag(false)
          }.pickerStyle(.menu)
        }
      }
      if browser.orders.count > 1 {
        Picker("Episode order", selection: $browser.selectedOrderID) {
          ForEach(browser.orders) { order in
            Text(order.label.isEmpty ? order.orderKind.capitalized : order.label).tag(
              Optional(order.id))
          }
        }.pickerStyle(.menu)
      }
      if browser.error != nil && !localSeasons.isEmpty {
        Text("Showing episodes from your library in aired order.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func reload() async {
    browser.normalizeSeason(local: localSeasons)
    guard let client, let seriesID else { return }
    await browser.load(client: client, seriesID: seriesID, local: localSeasons)
  }

  private func seasonLabel(_ number: Int) -> String {
    number == 0 ? "Specials" : "Season \(number)"
  }
}

private struct EpisodeCard: View {
  let client: TestMediaInfoClient?
  let row: DemoEpisodeRow
  @State private var episode: MediaInfoEntity?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomTrailing) {
        Group {
          if let client, let id = row.objectID {
            ServiceArtwork(client: client, ownerID: id, kind: "still", symbol: "tv")
          } else {
            DetailImage(url: nil, symbol: "tv")
          }
        }.frame(width: 270, height: 152).clipShape(RoundedRectangle(cornerRadius: 10))
        if let runtime = episode?.runtimeMinutes, runtime > 0 {
          Text("\(runtime) min").font(.caption2.weight(.medium)).padding(6)
            .background(.black.opacity(0.75), in: Capsule()).padding(8)
        }
      }
      Text("\(row.coordinate.episode). \(episode?.title ?? row.title)")
        .font(.subheadline.weight(.semibold)).lineLimit(2)
      if let date = episode?.airDate { Text(date).font(.caption2).foregroundStyle(.secondary) }
      if let overview = episode?.overview, !overview.isEmpty {
        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
      }
      if !row.files.isEmpty {
        Label(
          row.files.contains(where: { $0.availability == "present" })
            ? "In library" : "File unavailable",
          systemImage: "externaldrive"
        ).font(.caption2).foregroundStyle(.secondary)
      }
      if row.localEpisode?.isCompleted == true {
        Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(
          .orange)
      } else if let progress = row.localEpisode?.progress, progress > 0 {
        ProgressView(value: progress).tint(.orange)
      }
    }
    .frame(width: 270, alignment: .leading)
    .contentShape(Rectangle())
    .task(id: row.objectID) {
      episode = nil
      guard let client, let id = row.objectID else { return }
      let result = try? await client.entity(id: id)
      if !Task.isCancelled, result?.objectKind == "episode" { episode = result }
    }
  }
}
