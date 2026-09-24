import SwiftUI

struct PosterWallView: View {
  @ObservedObject var model: MediaLibraryModel
  @State private var searchText = ""
  @State private var mediaKind = "all"
  @State private var newestFirst = false

  private var visibleItems: [DemoPosterItem] {
    let filtered = model.posterItems.filter {
      (mediaKind == "all" || $0.kind.rawValue == mediaKind)
        && (searchText.isEmpty || $0.title.localizedStandardContains(searchText))
    }
    return newestFirst
      ? filtered.sorted { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) } : filtered
  }

  private let columns = [
    GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 16, alignment: .top)
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        if model.isPosterWallLoading && model.posterItems.isEmpty {
          ProgressView("Loading poster wall…")
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if model.posterItems.isEmpty {
          ContentUnavailableView(
            "Poster wall is empty",
            systemImage: "rectangle.grid.2x2",
            description: Text(model.posterWallNotice)
          )
          .frame(maxWidth: .infinity, minHeight: 320)
        } else {
          if visibleItems.isEmpty {
            ContentUnavailableView.search(text: searchText)
          }
          LazyVGrid(columns: columns, spacing: 22) {
            ForEach(visibleItems) { item in
              NavigationLink(
                value: DemoMediaRoute(
                  libraryUID: item.mediaUID, kind: item.kind.rawValue, title: item.title)
              ) {
                PosterCard(item: item)
              }
              .buttonStyle(.plain)
            }
          }
          .padding()
        }
      }
      .navigationTitle("Library")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .searchable(text: $searchText, prompt: "Movies and TV shows")
      .safeAreaInset(edge: .top, spacing: 0) {
        HStack {
          Picker("Media type", selection: $mediaKind) {
            Text("All").tag("all")
            Text("Movies").tag("movie")
            Text("TV Shows").tag("series")
          }.pickerStyle(.segmented)
          Menu {
            Button("Title", systemImage: newestFirst ? "textformat.abc" : "checkmark") {
              newestFirst = false
            }
            Button("Newest first", systemImage: newestFirst ? "checkmark" : "calendar") {
              newestFirst = true
            }
          } label: {
            Image(systemName: "arrow.up.arrow.down").padding(.leading, 8)
          }
          .accessibilityLabel("Sort library")
        }.padding(.horizontal).padding(.vertical, 10).background(.bar)
      }
      .background(Color(red: 0.055, green: 0.06, blue: 0.08))
      .preferredColorScheme(.dark)
      .tint(.orange)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await model.refreshPosterWall() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(model.isPosterWallLoading)
          .accessibilityLabel("Refresh poster wall")
        }
      }
      .refreshable {
        await model.refreshPosterWall()
      }
      .task {
        await model.refreshPosterWall()
      }
      .navigationDestination(for: DemoMediaRoute.self) { route in
        MediaDetailsView(library: model, route: route)
      }
      .navigationDestination(for: DemoPersonRoute.self) { route in
        PersonDetailsView(library: model, route: route)
      }
    }
  }
}

private struct PosterCard: View {
  let item: DemoPosterItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        AsyncImage(url: item.artworkURL) { phase in
          switch phase {
          case .success(let image):
            image
              .resizable()
              .scaledToFill()
          case .failure:
            posterPlaceholder
          case .empty:
            posterPlaceholder
          @unknown default:
            posterPlaceholder
          }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        Text(item.kind == .series ? "SERIES" : "MOVIE")
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(.black.opacity(0.72), in: Capsule())
          .foregroundStyle(.white)
          .padding(8)
      }

      Text(item.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(2)
      if let year = item.year {
        Text(String(year))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var posterPlaceholder: some View {
    ZStack {
      LinearGradient(
        colors: [.indigo.opacity(0.55), .black.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: item.kind == .series ? "tv" : "film")
        .font(.system(size: 38, weight: .light))
        .foregroundStyle(.white.opacity(0.8))
    }
  }
}
