import SwiftUI

struct CreditsSection: View {
  let client: TestMediaInfoClient
  let ownerID: String
  @State private var credits: MediaInfoCredits?
  @State private var error: String?
  @State private var isLoading = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Cast & crew").font(.title3.bold())
        Spacer()
        if let credits {
          NavigationLink("View all") { FullCreditsView(client: client, credits: credits) }
            .font(.subheadline.weight(.medium))
        }
      }
      if let error {
        DetailRetry(message: error, isLoading: isLoading) { Task { await load() } }
      } else if isLoading {
        ProgressView("Loading cast & crew…").font(.caption)
      }
      if let credits {
        if credits.cast.isEmpty && credits.crew.isEmpty {
          Text("No cast or crew information is available.").font(.subheadline).foregroundStyle(
            .secondary)
        }
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: 20) {
            ForEach(credits.cast.prefix(16)) { person in
              PersonCard(
                client: client, id: person.personID, name: person.name, subtitle: person.subtitle)
            }
            ForEach(credits.crew.prefix(8)) { person in
              PersonCard(
                client: client, id: person.personID, name: person.name, subtitle: person.subtitle)
            }
          }
        }
      }
    }
    .task(id: ownerID) {
      credits = nil
      await load()
    }
  }

  private func load() async {
    error = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await client.credits(id: ownerID)
      try Task.checkCancellation()
      credits = result
    } catch is CancellationError {} catch { self.error = MediaDetailsModel.message(error) }
  }
}

private struct PersonCard: View {
  let client: TestMediaInfoClient
  let id: String
  let name: String
  let subtitle: String

  var body: some View {
    NavigationLink(value: DemoPersonRoute(id: id, name: name)) {
      VStack(spacing: 8) {
        ServiceArtwork(client: client, ownerID: id, kind: "profile")
          .frame(width: 96, height: 96).clipShape(Circle())
        Text(name).font(.caption.weight(.semibold)).lineLimit(2)
        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
      }.multilineTextAlignment(.center).frame(width: 112, alignment: .top)
    }.buttonStyle(.plain)
  }
}

private struct FullCreditsView: View {
  let client: TestMediaInfoClient
  let credits: MediaInfoCredits
  @State private var search = ""
  @State private var tab = "Cast"

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        Picker("Credits", selection: $tab) {
          Text("Cast (\(credits.cast.count))").tag("Cast")
          Text("Crew (\(credits.crew.count))").tag("Crew")
        }.pickerStyle(.segmented)
        if tab == "Cast" {
          ForEach(credits.cast.filter { matches($0.name + " " + $0.subtitle) }) { person in
            row(id: person.personID, name: person.name, subtitle: person.subtitle)
          }
        } else {
          ForEach(
            credits.crew.filter {
              matches($0.name + " " + $0.subtitle + " " + ($0.department ?? ""))
            }
          ) { person in
            row(id: person.personID, name: person.name, subtitle: person.subtitle)
          }
        }
      }.padding(22)
    }
    .navigationTitle("Cast & crew").navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search, prompt: "Name, role or department")
    .background(Color(red: 0.055, green: 0.06, blue: 0.08)).preferredColorScheme(.dark).tint(
      .orange)
  }

  private func matches(_ value: String) -> Bool {
    search.isEmpty || value.localizedStandardContains(search)
  }

  private func row(id: String, name: String, subtitle: String) -> some View {
    NavigationLink(value: DemoPersonRoute(id: id, name: name)) {
      HStack(spacing: 16) {
        ServiceArtwork(client: client, ownerID: id, kind: "profile").frame(width: 56, height: 56)
          .clipShape(Circle())
        VStack(alignment: .leading, spacing: 5) {
          Text(name).font(.headline)
          Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }
    }.buttonStyle(.plain)
  }
}

struct PersonDetailsView: View {
  @ObservedObject var library: MediaLibraryModel
  let route: DemoPersonRoute
  @State private var client: TestMediaInfoClient?
  @State private var person: MediaInfoEntity?
  @State private var error: String?
  @State private var isLoading = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        HStack(alignment: .top, spacing: 22) {
          Group {
            if let client {
              ServiceArtwork(client: client, ownerID: route.id, kind: "profile")
            } else {
              DetailImage(url: nil, symbol: "person.fill")
            }
          }.frame(width: 124, height: 174).clipShape(RoundedRectangle(cornerRadius: 12))
          VStack(alignment: .leading, spacing: 10) {
            Text(person?.name ?? route.name).font(.largeTitle.bold())
            if let department = person?.knownForDepartment {
              Text(department).font(.headline).foregroundStyle(.orange)
            }
            if let date = person?.birthDate {
              Text("Born \(date)").font(.subheadline).foregroundStyle(.secondary)
            }
            if let date = person?.deathDate {
              Text("Died \(date)").font(.subheadline).foregroundStyle(.secondary)
            }
            if let place = person?.placeOfBirth {
              Text(place).font(.subheadline).foregroundStyle(.secondary)
            }
            if isLoading { ProgressView().controlSize(.small) }
          }
          Spacer(minLength: 0)
        }
        if let error { DetailRetry(message: error, isLoading: isLoading) { Task { await load() } } }
        if let biography = person?.biography, !biography.isEmpty {
          DetailText(title: "Biography", text: biography)
        } else if person != nil {
          Text("No biography is available in this language.").font(.subheadline).foregroundStyle(
            .secondary)
        }
        if let client { FilmographySection(client: client, personID: route.id) }
      }.padding(22).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
    }
    .navigationTitle(person?.name ?? route.name).navigationBarTitleDisplayMode(.inline)
    .background(Color(red: 0.055, green: 0.06, blue: 0.08)).preferredColorScheme(.dark).tint(
      .orange
    )
    .task(id: route.id) { await load() }
  }

  private func load() async {
    error = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let service = try await library.detailsClient()
      try Task.checkCancellation()
      client = service
      let result = try await service.entity(id: route.id)
      try Task.checkCancellation()
      guard result.objectKind == "person" else { throw PersonDetailError.wrongKind }
      person = result
    } catch is CancellationError {} catch { self.error = MediaDetailsModel.message(error) }
  }
}

private enum PersonDetailError: Error { case wrongKind }

private struct FilmographySection: View {
  let client: TestMediaInfoClient
  let personID: String
  @State private var filmography: MediaInfoFilmography?
  @State private var error: String?
  @State private var isLoading = false
  @State private var kind = "all"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Filmography").font(.title2.bold())
        Spacer()
        Picker("Media type", selection: $kind) {
          Text("All").tag("all")
          Text("Movies").tag("movie")
          Text("TV Shows").tag("series")
        }.pickerStyle(.menu)
      }
      if let error {
        DetailRetry(message: error, isLoading: isLoading) { Task { await load() } }
      } else if isLoading {
        ProgressView("Loading filmography…").font(.caption)
      }
      if let filmography {
        if filmography.truncated {
          Text(
            "Showing \(filmography.items.count) of \(filmography.sourceCount) credits available from the service."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        let works = filmography.items.filter { kind == "all" || $0.mediaKind == kind }.sorted {
          ($0.date ?? "", -$0.order) > ($1.date ?? "", -$1.order)
        }
        if works.isEmpty {
          Text("No credits available.").font(.subheadline).foregroundStyle(.secondary)
        }
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 16)],
          alignment: .leading, spacing: 24
        ) {
          ForEach(works) { work in
            NavigationLink(
              value: DemoMediaRoute(objectID: work.mediaID, kind: work.mediaKind, title: work.title)
            ) {
              VStack(alignment: .leading, spacing: 8) {
                ServiceArtwork(
                  client: client, ownerID: work.mediaID, kind: "poster",
                  symbol: work.mediaKind == "movie" ? "film" : "tv"
                )
                .aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(
                  RoundedRectangle(cornerRadius: 10))
                Text(work.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let date = work.date {
                  Text(String(date.prefix(4))).font(.caption).foregroundStyle(.secondary)
                }
                if !work.subtitle.isEmpty {
                  Text(work.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
              }
            }.buttonStyle(.plain)
          }
        }
      }
    }
    .task(id: personID) { await load() }
  }

  private func load() async {
    error = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await client.filmography(id: personID)
      try Task.checkCancellation()
      filmography = result
    } catch is CancellationError {} catch { self.error = MediaDetailsModel.message(error) }
  }
}
