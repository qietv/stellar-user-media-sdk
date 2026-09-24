import StellarUserMediaSDK
import SwiftUI

struct MediaDetailsView: View {
  @ObservedObject var library: MediaLibraryModel
  @StateObject private var details: MediaDetailsModel

  init(library: MediaLibraryModel, route: DemoMediaRoute) {
    self.library = library
    _details = StateObject(wrappedValue: MediaDetailsModel(route: route))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        hero
        VStack(alignment: .leading, spacing: 28) {
          if let error = details.error {
            DetailRetry(message: error, isLoading: details.isLoading) {
              Task { await details.load(using: library) }
            }
          }
          if let overview = details.overview, !overview.isEmpty {
            DetailText(title: "Overview", text: overview)
          }
          if details.route.kind == "series" {
            SeriesBrowserView(
              library: library, client: details.client,
              seriesID: details.objectID,
              libraryUID: details.local?.item.mediaUID ?? details.route.libraryUID,
              title: details.title, localSeasons: details.local?.seasons ?? [])
          }
          if !details.files.isEmpty {
            DetailFilesSection(library: library, files: details.files)
          } else if details.route.kind != "series" && !details.isLoading {
            Label("No file linked in this library", systemImage: "externaldrive.badge.questionmark")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          if let client = details.client, let id = details.objectID {
            CreditsSection(client: client, ownerID: id)
          }
          information
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 40)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .background(Color(red: 0.055, green: 0.06, blue: 0.08))
    .preferredColorScheme(.dark)
    .tint(.orange)
    .navigationTitle(details.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await details.load(using: library) }
    .task(id: details.objectID ?? details.local?.item.mediaUID) {
      await details.loadArtwork(using: library)
    }
  }

  private var hero: some View {
    ZStack(alignment: .bottomLeading) {
      DetailImage(
        url: details.backdropURL ?? details.posterURL,
        symbol: details.route.kind == "movie" ? "film" : "tv")
      LinearGradient(
        colors: [
          .black.opacity(0.08), .black.opacity(0.45), Color(red: 0.055, green: 0.06, blue: 0.08),
        ],
        startPoint: .top, endPoint: .bottom)
      HStack(alignment: .bottom, spacing: 20) {
        if details.route.kind != "episode" {
          DetailImage(url: details.posterURL, symbol: details.route.kind == "movie" ? "film" : "tv")
            .frame(width: 108, height: 162)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 10) {
          Text(details.route.airedCoordinate?.label ?? details.route.kind.uppercased())
            .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.orange)
          Text(details.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
          if let original = details.entity?.originalTitle ?? details.local?.originalTitle,
            original != details.title, !original.isEmpty, details.route.kind != "episode"
          {
            Text(original).font(.subheadline).foregroundStyle(.white.opacity(0.7))
          }
          Text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.8))
          let genres = details.entity?.genres?.map(\.name) ?? details.local?.genres ?? []
          if !genres.isEmpty {
            Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
          }
          if details.isLoading {
            ProgressView().controlSize(.small).accessibilityLabel("Loading details")
          }
        }
        Spacer(minLength: 0)
      }
      .padding(22)
      .padding(.top, 160)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .frame(minHeight: 370)
  }

  private var summary: String {
    var values: [String] = []
    if let date = details.entity?.date {
      values.append(String(date.prefix(4)))
    } else if let year = details.local?.item.year {
      values.append(String(year))
    }
    if let runtime = details.entity?.runtimeMinutes, runtime > 0 { values.append("\(runtime) min") }
    if details.route.kind != "episode", let rating = details.local?.contentRating, !rating.isEmpty {
      values.append(rating)
    }
    return values.joined(separator: "  ·  ")
  }

  @ViewBuilder private var information: some View {
    if let entity = details.entity {
      VStack(alignment: .leading, spacing: 12) {
        Text("Information").font(.title3.bold())
        if let date = entity.date {
          DetailFact(label: entity.objectKind == "movie" ? "Released" : "First aired", value: date)
        }
        if let date = entity.lastAirDate { DetailFact(label: "Last aired", value: date) }
        if let language = entity.originalLanguage {
          DetailFact(
            label: "Original language",
            value: Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if let status = entity.status {
          DetailFact(
            label: "Status", value: status.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if let count = entity.episodeCount { DetailFact(label: "Episodes", value: String(count)) }
      }
    }
    if details.route.kind != "episode", let tagline = details.local?.tagline, !tagline.isEmpty {
      Text(tagline).font(.title3.italic()).foregroundStyle(.secondary)
    }
  }
}

struct DetailImage: View {
  let url: URL?
  var symbol = "film"

  var body: some View {
    GeometryReader { geometry in
      AsyncImage(url: url) { phase in
        if case .success(let image) = phase {
          image.resizable().scaledToFill()
        } else {
          ZStack {
            LinearGradient(
              colors: [Color(red: 0.16, green: 0.2, blue: 0.28), .black.opacity(0.7)],
              startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(
              .white.opacity(0.3))
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
  }
}

struct ServiceArtwork: View {
  let client: TestMediaInfoClient
  let ownerID: String
  let kind: String
  var symbol = "person.fill"
  @State private var url: URL?

  var body: some View {
    DetailImage(url: url, symbol: symbol)
      .task(id: "\(ownerID):\(kind)") {
        url = nil
        let result = try? await client.artworkURL(ownerID: ownerID, kind: kind)
        if !Task.isCancelled { url = result }
      }
  }
}

struct DetailText: View {
  let title: String
  let text: String
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.title3.bold())
      Text(text).font(.body).lineSpacing(4).foregroundStyle(.white.opacity(0.8))
        .lineLimit(expanded ? nil : 5)
      if text.count > 160 {
        Button(expanded ? "Show less" : "Read more") { expanded.toggle() }.font(
          .subheadline.weight(.medium))
      }
    }
  }
}

struct DetailRetry: View {
  let message: String
  var isLoading = false
  let retry: () -> Void
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
      Text(message).font(.caption).foregroundStyle(.secondary).frame(
        maxWidth: .infinity, alignment: .leading)
      if isLoading {
        ProgressView()
      } else {
        Button("Retry", action: retry).font(.subheadline.weight(.semibold))
      }
    }
    .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct DetailFact: View {
  let label: String
  let value: String
  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Text(label).foregroundStyle(.secondary).frame(width: 115, alignment: .leading)
      Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }.font(.subheadline)
  }
}

struct DetailFilesSection: View {
  @ObservedObject var library: MediaLibraryModel
  let files: [PosterWallPlayableFile]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Files & versions").font(.title3.bold())
      ForEach(files, id: \.fileUID) { file in
        DetailFileRow(library: library, file: file)
      }
    }
  }
}

private struct DetailFileRow: View {
  @ObservedObject var library: MediaLibraryModel
  let file: PosterWallPlayableFile
  @State private var expanded = false
  @State private var disc: DemoDiscDetails?
  @State private var selectedPlaylist: String?

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 12) {
        Text(file.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let duration = file.durationMilliseconds {
          DetailFact(label: "Duration", value: Self.duration(duration))
        }
        if let size = file.sizeBytes {
          DetailFact(label: "Size", value: size.formatted(.byteCount(style: .file)))
        }
        DetailFact(label: "Availability", value: file.availability.capitalized)
        ForEach(file.streams, id: \.index) { stream in
          HStack(alignment: .top) {
            Image(
              systemName: stream.kind == "audio"
                ? "speaker.wave.2" : (stream.kind == "subtitle" ? "captions.bubble" : "film"))
            Text(
              [
                stream.codec?.uppercased(), stream.language == "und" ? nil : stream.language,
                stream.title,
                stream.isDefault ? "Default" : nil, stream.isForced ? "Forced" : nil,
              ].compactMap { $0 }.joined(separator: " · "))
          }.font(.caption).foregroundStyle(.secondary)
        }
        if let disc {
          Text("Disc titles · \(disc.kind)").font(.subheadline.bold())
          ForEach(disc.playlists) { playlist in
            Button {
              selectedPlaylist = playlist.id
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(playlist.identifier + (playlist.isDefault ? " · Main title" : ""))
                  Text(
                    "\(Self.duration(playlist.durationMilliseconds)) · \(playlist.sizeBytes.formatted(.byteCount(style: .file)))"
                  )
                  .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedPlaylist == playlist.id { Image(systemName: "checkmark.circle.fill") }
              }.font(.caption)
            }.buttonStyle(.plain)
          }
        }
      }.padding(.top, 12)
        .task(id: file.fileUID) {
          let result = try? await library.discDetails(for: file)
          guard !Task.isCancelled else { return }
          disc = result
          selectedPlaylist = result?.playlists.first(where: \.isDefault)?.id
        }
    } label: {
      HStack(spacing: 12) {
        Image(
          systemName: file.availability == "present"
            ? "externaldrive.fill" : "externaldrive.badge.exclamationmark"
        )
        .foregroundStyle(file.availability == "present" ? .orange : .gray)
        VStack(alignment: .leading, spacing: 4) {
          Text((file.relativePath as NSString).lastPathComponent).font(.subheadline.weight(.medium))
            .lineLimit(2)
          Text(fileSummary).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
  }

  private var fileSummary: String {
    var values: [String] = []
    if let width = file.width, let height = file.height { values.append("\(width) × \(height)") }
    if let codec = file.videoCodec { values.append(codec.uppercased()) }
    if file.bindingRole == "extra" { values.append("Extra") }
    if let size = file.sizeBytes { values.append(size.formatted(.byteCount(style: .file))) }
    values.append(file.availability.capitalized)
    return values.joined(separator: " · ")
  }

  private static func duration(_ milliseconds: Int64) -> String {
    let total = max(0, milliseconds / 1000)
    return String(format: "%lld:%02lld:%02lld", total / 3600, total % 3600 / 60, total % 60)
  }
}
