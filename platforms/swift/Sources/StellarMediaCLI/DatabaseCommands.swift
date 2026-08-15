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
      writeError("library expects scan or inspect")
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
    default:
      writeError("library expects scan or inspect")
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
