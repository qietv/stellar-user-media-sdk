import SwiftUI

struct PosterWallView: View {
  @ObservedObject var model: MediaLibraryModel
  @State private var selectedItem: DemoPosterItem?

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
          LazyVGrid(columns: columns, spacing: 22) {
            ForEach(model.posterItems) { item in
              Button {
                selectedItem = item
              } label: {
                PosterCard(item: item)
              }
              .buttonStyle(.plain)
            }
          }
          .padding()
        }
      }
      .navigationTitle("Poster Wall")
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
      .sheet(item: $selectedItem) { item in
        PosterDetailsView(model: model, item: item)
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
            ZStack {
              posterPlaceholder
              ProgressView()
            }
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

private struct PosterDetailsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: MediaLibraryModel
  let item: DemoPosterItem
  @State private var loadedItem: DemoPosterItem?

  private var displayedItem: DemoPosterItem { loadedItem ?? item }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          AsyncImage(url: displayedItem.artworkURL) { image in
            image.resizable().scaledToFit()
          } placeholder: {
            RoundedRectangle(cornerRadius: 16)
              .fill(.quaternary)
              .aspectRatio(2.0 / 3.0, contentMode: .fit)
              .overlay { ProgressView() }
          }
          .frame(maxWidth: 280)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .frame(maxWidth: .infinity)

          Text(displayedItem.title)
            .font(.title.bold())
          if let originalTitle = displayedItem.originalTitle,
            originalTitle != displayedItem.title
          {
            Text(originalTitle)
              .font(.headline)
              .foregroundStyle(.secondary)
          }
          if let year = displayedItem.year {
            Text(String(year))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          if let overview = displayedItem.overview, !overview.isEmpty {
            Text(overview)
              .font(.body)
          }
        }
        .padding()
      }
      .navigationTitle(displayedItem.kind == .series ? "Series" : "Movie")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task(id: item.id) {
        loadedItem = await model.posterDetails(for: item)
      }
    }
  }
}

#Preview {
  PosterWallView(model: MediaLibraryModel())
}
