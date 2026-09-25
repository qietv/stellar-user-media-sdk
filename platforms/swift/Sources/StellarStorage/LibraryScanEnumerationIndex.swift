import Foundation
import GRDB
import StellarCore
import StellarRemoteMedia

/// Counts and cursor lifetime checks without materializing the durable frontier or seen set.
package struct LibraryScanEnumerationSummary: Sendable {
  package let pendingPageCount: Int
  package let completedPageCount: Int64
  package let seenEntryCount: Int64
  package let hasSessionCursor: Bool
}

extension LibraryStore {
  package func scanEnumerationSummary(runUID: String, sourceUID: String) async throws
    -> LibraryScanEnumerationSummary?
  {
    try await database.read { database in
      guard
        let runID = try Int64.fetchOne(
          database, sql: "SELECT id FROM scan_run WHERE uid = ?", arguments: [runUID])
      else { return nil }
      let rows = try Row.fetchCursor(
        database,
        sql: "SELECT directory_json, cursor_token, state FROM scan_frontier WHERE run_id = ?",
        arguments: [runID])
      var pending = 0
      var completed: Int64 = 0
      var sessionCursor = false
      // Stream validation as well: corrupt completed rows must not silently authorize reconciliation.
      while let row = try rows.next() {
        let page = try Self.indexedPage(row)
        guard page.directory.sourceUID == sourceUID else {
          throw SDKError(code: .storageFailure, message: "scan frontier source is inconsistent")
        }
        if (row["state"] as String) == "pending" {
          pending += 1
          if let cursor = page.cursor, RemoteDirectorySessionCursor.requiresRestart(cursor) {
            sessionCursor = true
          }
        } else {
          completed += 1
        }
      }
      let seen =
        try Int64.fetchOne(
          database, sql: "SELECT COUNT(*) FROM scan_seen WHERE run_id = ?", arguments: [runID]) ?? 0
      return LibraryScanEnumerationSummary(
        pendingPageCount: pending, completedPageCount: completed, seenEntryCount: seen,
        hasSessionCursor: sessionCursor)
    }
  }

  /// Uses the pending-frontier index and a bounded LIMIT, independent of library size.
  package func scanPendingPages(runUID: String, limit: Int) async throws
    -> [LibraryScanFrontierPage]
  {
    guard (1...128).contains(limit) else {
      throw SDKError(code: .invalidConfiguration, message: "scan frontier window is invalid")
    }
    return try await database.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT directory_json, cursor_token FROM scan_frontier
          WHERE run_id = (SELECT id FROM scan_run WHERE uid = ?) AND state = 'pending'
          ORDER BY directory_json, cursor_token LIMIT ?
          """, arguments: [runUID, limit])
      return try rows.map(Self.indexedPage)
    }
  }

  /// Index probes for just one response's identities and possible frontier transitions.
  package func scanEnumerationMembership(
    runUID: String, pages: [LibraryScanFrontierPage], identityKeys: [String]
  ) async throws -> LibraryScanEnumerationState {
    try await database.read { database in
      guard
        let runID = try Int64.fetchOne(
          database, sql: "SELECT id FROM scan_run WHERE uid = ?", arguments: [runUID])
      else {
        throw SDKError(code: .storageFailure, message: "scan frontier is missing")
      }
      let frontier = try database.makeStatement(
        sql:
          "SELECT state FROM scan_frontier WHERE run_id = ? AND directory_json = ? AND cursor_token = ?"
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var pending: [LibraryScanFrontierPage] = []
      var completed: [LibraryScanFrontierPage] = []
      for page in Set(pages) {
        let json = String(decoding: try encoder.encode(page.directory), as: UTF8.self)
        if let state = try String.fetchOne(frontier, arguments: [runID, json, page.cursor ?? ""]) {
          if state == "pending" { pending.append(page) } else { completed.append(page) }
        }
      }
      let seen = try database.makeStatement(
        sql: "SELECT is_directory FROM scan_seen WHERE run_id = ? AND identity_key = ?")
      var entries: [String] = []
      var directories: [String] = []
      for key in Set(identityKeys) {
        if let isDirectory = try Int.fetchOne(seen, arguments: [runID, key]) {
          entries.append(key)
          if isDirectory == 1 { directories.append(key) }
        }
      }
      return try LibraryScanEnumerationState(
        pendingPages: pending, completedPages: completed, seenEntryIdentityKeys: entries,
        seenDirectoryIdentityKeys: directories)
    }
  }

  private static func indexedPage(_ row: Row) throws -> LibraryScanFrontierPage {
    let json: String = row["directory_json"]
    let locator = try JSONDecoder().decode(RemoteLocator.self, from: Data(json.utf8))
    let cursor: String = row["cursor_token"]
    return try LibraryScanFrontierPage(directory: locator, cursor: cursor.isEmpty ? nil : cursor)
  }
}
