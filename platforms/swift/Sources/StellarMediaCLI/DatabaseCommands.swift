import Foundation
import StellarUserMediaSDK

enum DatabaseCLICommand {
  static func run(arguments: [String]) async -> Int32 {
    guard arguments.count == 3, ["migrate", "verify"].contains(arguments[0]) else {
      writeError("db expects migrate|verify <library|account|metadata-cache> <database-path>")
      return 2
    }
    guard let kind = databaseKind(arguments[1]) else {
      writeError("unknown database kind")
      return 2
    }
    let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL

    do {
      let report: StorageVerificationReport
      if arguments[0] == "migrate" {
        report = try await StorageDatabase.open(kind: kind, at: url).verify()
      } else {
        report = try await StorageDatabase.verifyExisting(kind: kind, at: url)
      }
      try printJSON(
        DatabaseCommandOutput(
          schema: "stellar.database.\(arguments[0]).v1",
          report: report
        )
      )
      return report.isValid ? 0 : 1
    } catch let error as SDKError {
      writeError(error.message)
      return 1
    } catch {
      writeError("database command failed")
      return 1
    }
  }

  private static func databaseKind(_ value: String) -> StorageDatabaseKind? {
    switch value {
    case "library": .library
    case "account": .account
    case "metadata-cache", "metadata_cache": .metadataCache
    default: nil
    }
  }

  private static func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
      throw SDKError(code: .parseFailure, message: "database output is not UTF-8")
    }
    print(output)
  }

  private static func writeError(_ message: String) {
    let safeMessage = SensitiveDataRedactor().redact(message: message)
    FileHandle.standardError.write(Data("error: \(safeMessage)\n".utf8))
  }
}

private struct DatabaseCommandOutput: Encodable {
  let schema: String
  let report: StorageVerificationReport
}

enum LibraryCLICommand {
  static func run(arguments: [String]) async -> Int32 {
    guard let command = arguments.first else {
      writeError("library expects scan|inspect|list|search|show")
      return 2
    }
    switch command {
    case "inspect":
      guard arguments.count == 2 else {
        writeError("library inspect expects <database-path>")
        return 2
      }
      return await inspect(databasePath: arguments[1])
    case "scan":
      guard arguments.count == 4 else {
        writeError("library scan expects <database-path> <root-directory> <source-uid>")
        return 2
      }
      return await scan(
        databasePath: arguments[1],
        rootPath: arguments[2],
        sourceUID: arguments[3]
      )
    case "list":
      guard arguments.count >= 2 else {
        writeError("library list expects <database-path> [options]")
        return 2
      }
      return await list(
        databasePath: arguments[1],
        arguments: Array(arguments.dropFirst(2)),
        searchText: nil
      )
    case "search":
      guard arguments.count >= 3 else {
        writeError("library search expects <database-path> <query> [options]")
        return 2
      }
      return await list(
        databasePath: arguments[1],
        arguments: Array(arguments.dropFirst(3)),
        searchText: arguments[2]
      )
    case "show":
      guard arguments.count >= 3 else {
        writeError("library show expects <database-path> <media-uid> [options]")
        return 2
      }
      return await show(
        databasePath: arguments[1],
        mediaUID: arguments[2],
        arguments: Array(arguments.dropFirst(3))
      )
    default:
      writeError("library expects scan|inspect|list|search|show")
      return 2
    }
  }

  private static func inspect(databasePath: String) async -> Int32 {
    do {
      let database = try await StorageDatabase.open(
        kind: .library,
        at: URL(fileURLWithPath: databasePath).standardizedFileURL
      )
      let store = try LibraryStore(database: database)
      try printJSON(try await store.snapshot())
      return 0
    } catch let error as SDKError {
      writeError(error.message)
      return 1
    } catch {
      writeError("library inspection failed")
      return 1
    }
  }

  private static func scan(
    databasePath: String,
    rootPath: String,
    sourceUID: String
  ) async -> Int32 {
    do {
      let database = try await StorageDatabase.open(
        kind: .library,
        at: URL(fileURLWithPath: databasePath).standardizedFileURL
      )
      let store = try LibraryStore(database: database)
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
      try await store.registerSource(
        LibrarySourceDefinition(
          uid: sourceUID,
          kind: .localFolder,
          displayName: rootURL.lastPathComponent,
          rootURI: rootURL.absoluteString
        )
      )
      let connector = LocalMediaSourceConnector(
        configuration: try LocalMediaSourceConfiguration(
          sourceUID: sourceUID,
          rootURL: rootURL
        )
      )
      let root = try RemoteLocator(sourceUID: sourceUID, path: RemotePath())
      let request = try MediaScanRequest(
        runUID: UUID().uuidString.lowercased(),
        sourceUID: sourceUID,
        mode: .full,
        roots: [root]
      )
      _ = try await MediaScanner().scan(
        request,
        using: connector,
        sink: SQLiteMediaScanSink(store: store)
      )
      try printJSON(try await store.snapshot())
      return 0
    } catch let error as SDKError {
      writeError(error.message)
      return 1
    } catch {
      writeError("library scan failed")
      return 1
    }
  }

  private static func list(
    databasePath: String,
    arguments: [String],
    searchText: String?
  ) async -> Int32 {
    do {
      let options = try LibraryListOptions(arguments: arguments)
      let database = try await StorageDatabase.open(
        kind: .library,
        at: URL(fileURLWithPath: databasePath).standardizedFileURL
      )
      let filter = try PosterWallFilter(
        mediaKinds: options.mediaKinds,
        sourceUIDs: options.sourceUIDs,
        genres: options.genres,
        availability: options.availability,
        watchState: options.watchState
      )
      let query = try PosterWallQuery(
        section: options.section,
        sort: options.sort,
        filter: filter,
        searchText: searchText,
        profileUID: options.profileUID,
        collectionUID: options.collectionUID,
        locale: options.locale,
        pageSize: options.limit,
        cursor: options.cursor,
        libraryRevision: options.libraryRevision,
        randomSeed: options.randomSeed
      )
      try printJSON(try await PosterWallStore(database: database).page(query))
      return 0
    } catch let error as SDKError {
      writeError(error.message)
      return error.code == .invalidConfiguration ? 2 : 1
    } catch {
      writeError("library query failed")
      return 1
    }
  }

  private static func show(
    databasePath: String,
    mediaUID: String,
    arguments: [String]
  ) async -> Int32 {
    do {
      let options = try LibraryShowOptions(arguments: arguments)
      let database = try await StorageDatabase.open(
        kind: .library,
        at: URL(fileURLWithPath: databasePath).standardizedFileURL
      )
      try printJSON(
        try await PosterWallStore(database: database).details(
          mediaUID: mediaUID,
          profileUID: options.profileUID,
          locale: options.locale
        )
      )
      return 0
    } catch let error as SDKError {
      writeError(error.message)
      return error.code == .invalidConfiguration ? 2 : 1
    } catch {
      writeError("library details query failed")
      return 1
    }
  }

  private static func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
      throw SDKError(code: .parseFailure, message: "library output is not UTF-8")
    }
    print(output)
  }

  private static func writeError(_ message: String) {
    let safeMessage = SensitiveDataRedactor().redact(message: message)
    FileHandle.standardError.write(Data("error: \(safeMessage)\n".utf8))
  }
}

private struct LibraryListOptions {
  var section: PosterWallSection = .all
  var sort: PosterWallSort = .title
  var mediaKinds: [PosterWallMediaKind] = []
  var sourceUIDs: [String] = []
  var genres: [String] = []
  var availability: PosterWallAvailabilityFilter = .any
  var watchState: PosterWallWatchFilter = .any
  var profileUID: String?
  var collectionUID: String?
  var locale = "und"
  var limit = 50
  var cursor: String?
  var libraryRevision: String?
  var randomSeed: UInt64 = 0

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let option = arguments[index]
      guard index + 1 < arguments.count else { throw Self.invalid() }
      let value = arguments[index + 1]
      switch option {
      case "--section":
        guard let parsed = Self.section(value) else { throw Self.invalid() }
        section = parsed
      case "--sort":
        guard let parsed = Self.sort(value) else { throw Self.invalid() }
        sort = parsed
      case "--kind":
        guard let parsed = PosterWallMediaKind(rawValue: value), parsed != .unknown else {
          throw Self.invalid()
        }
        mediaKinds.append(parsed)
      case "--source":
        sourceUIDs.append(value)
      case "--genre":
        genres.append(value)
      case "--availability":
        guard let parsed = PosterWallAvailabilityFilter(rawValue: value), parsed != .unknown else {
          throw Self.invalid()
        }
        availability = parsed
      case "--watch":
        guard let parsed = PosterWallWatchFilter(rawValue: value), parsed != .unknown else {
          throw Self.invalid()
        }
        watchState = parsed
      case "--profile":
        profileUID = value
      case "--collection":
        collectionUID = value
      case "--locale":
        locale = value
      case "--limit":
        guard let parsed = Int(value) else { throw Self.invalid() }
        limit = parsed
      case "--cursor":
        cursor = value
      case "--revision":
        libraryRevision = value
      case "--random-seed":
        guard let parsed = UInt64(value) else { throw Self.invalid() }
        randomSeed = parsed
      default:
        throw Self.invalid()
      }
      index += 2
    }
  }

  private static func section(_ value: String) -> PosterWallSection? {
    PosterWallSection(rawValue: value.replacingOccurrences(of: "-", with: "_"))
  }

  private static func sort(_ value: String) -> PosterWallSort? {
    PosterWallSort(rawValue: value.replacingOccurrences(of: "-", with: "_"))
  }

  private static func invalid() -> SDKError {
    SDKError(code: .invalidConfiguration, message: "library list/search options are invalid")
  }
}

private struct LibraryShowOptions {
  var profileUID: String?
  var locale = "und"

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      guard index + 1 < arguments.count else { throw Self.invalid() }
      switch arguments[index] {
      case "--profile":
        profileUID = arguments[index + 1]
      case "--locale":
        locale = arguments[index + 1]
      default:
        throw Self.invalid()
      }
      index += 2
    }
  }

  private static func invalid() -> SDKError {
    SDKError(code: .invalidConfiguration, message: "library show options are invalid")
  }
}
